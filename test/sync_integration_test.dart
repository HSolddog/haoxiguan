import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_preview.dart';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/sync_client.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_engine.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/services/sync_recovery.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:uuid/uuid.dart';

import 'support/sync_relay.dart';

void main() {
  const endpoint = String.fromEnvironment('TEST_SYNC_ENDPOINT');
  const certificate = String.fromEnvironment('TEST_SYNC_CERT');
  const invitesFile = String.fromEnvironment('TEST_SYNC_INVITES_FILE');
  const operator = String.fromEnvironment('TEST_SYNC_OPERATOR');
  const database = String.fromEnvironment('TEST_SYNC_DB');
  const tlsKey = String.fromEnvironment('TEST_SYNC_KEY');
  const serverPid = String.fromEnvironment('TEST_SYNC_SERVER_PID');
  const listen = String.fromEnvironment('TEST_SYNC_LISTEN');
  test(
    'real HTTPS Go relay: encrypted recovery, two devices, conflict, revoke and remote deletion',
    () async {
      final invites =
          (jsonDecode(await File(invitesFile).readAsString())['invites']
                  as List)
              .cast<String>();
      final root = await Directory.systemTemp.createTemp(
        'haoxiguan-real-sync-',
      );
      final tls = SecurityContext(withTrustedRoots: true)
        ..setTrustedCertificates(certificate);
      final transports = [
        for (var i = 0; i < 2; i++)
          HttpSyncTransport(endpoint, client: HttpClient(context: tls)),
      ];
      final repositories = [
        for (var i = 0; i < 2; i++)
          SqliteHabitRepository(
            HabitDatabase(NativeDatabase(File('${root.path}/$i.sqlite'))),
          ),
      ];
      final controllers = [for (final r in repositories) HabitController(r)];
      final keys = <SyncKeyring>[];
      Process? replacementServer;
      try {
        final engines = <SyncEngine>[];
        for (var i = 0; i < 2; i++) {
          await controllers[i].load();
          expect(controllers[i].loaded, true);
          final tokens = await transports[i].request(
            'POST',
            '/v1/auth/enroll',
            body: {'invite': invites[i], 'deviceName': 'synthetic-device-$i'},
          );
          SyncSettings.validateTokens(tokens);
          if (i == 0) {
            keys.add(await SyncKeyring.create(tokens['vaultId'] as String));
          } else {
            // Device two receives only a password-protected recovery file, never a
            // token or key retrieved from the server.
            final file = await SyncRecoveryCodec.encrypt(
              keys.first,
              'public synthetic recovery password',
            );
            keys.add(
              await SyncRecoveryCodec.decrypt(
                file,
                'public synthetic recovery password',
              ),
            );
            expect(keys.last.vault, tokens['vaultId']);
          }
          final settings = SyncSettings(
            id: const Uuid().v4(),
            endpoint: endpoint,
            localVault:
                jsonDecode(controllers[i].exportJson())['vaultId'] as String,
            keys: keys[i],
            tokens: tokens,
            recoveryExported: true,
          );
          final store = SyncSettingsStore(MemorySecrets());
          await store.save(settings);
          engines.add(
            SyncEngine(
              repositories[i],
              SyncSession(settings, store, transports[i]),
            ),
          );
        }
        Future<SyncOutcome> sync(int i) async {
          var result = await engines[i].run();
          if (result.preview != null) {
            await engines[i].confirmInitialSync(result.preview!);
            result = await engines[i].run();
          }
          await controllers[i].load();
          return result;
        }

        final a = controllers[0], b = controllers[1];
        expect(
          await a.addHabit(
            title: '端到端中文阅读',
            emoji: '📖',
            colorValue: 0xff123456,
            weekdays: {1, 2, 3, 4, 5, 6, 7},
            recordType: 'count',
            scale: 100,
            dailyTarget: 100,
          ),
          true,
        );
        final id = a.habits.single.id, today = a.today;
        expect((await sync(0)).complete, true);
        expect((await sync(1)).complete, true);
        await a.addValue(id, today, 10);
        await b.addValue(id, today, 20);
        await sync(0);
        await sync(1);
        await sync(0);
        expect(
          SyncEntities.encodeFacts(a.exportJson()),
          SyncEntities.encodeFacts(b.exportJson()),
        );
        expect(a.habits.single.entries.length, 2);
        await a.setNote(id, today, '设备甲');
        await b.setNote(id, today, '设备乙');
        await sync(0);
        expect((await sync(1)).conflicts, [id]);
        await engines[1].resolve({id: false});
        await b.load();
        await sync(1);
        await sync(0);
        expect(a.habits.single.notes.values, contains('设备乙'));
        final devices = await engines[0].session.request('GET', '/v1/devices');
        expect((devices['devices'] as List).length, 2);
        final target = engines[1].settings.tokens['deviceId'] as String;
        await engines[0].session.request('POST', '/v1/devices/$target/revoke');
        await expectLater(
          engines[1].session.request('GET', '/v1/devices'),
          throwsA(
            isA<SyncApiException>().having((e) => e.status, 'status', 401),
          ),
        );
        if (operator.isNotEmpty) {
          final user =
              jsonDecode(await File(invitesFile).readAsString())['userId']
                  as String;
          Future<void> admin(List<String> arguments) async {
            final result = await Process.run(operator, [
              ...arguments,
              '--db',
              database,
            ]);
            expect(result.exitCode, 0, reason: result.stderr.toString());
          }

          await admin(['freeze-user', '--user', user]);
          await a.addValue(id, today, 30);
          await expectLater(
            engines[0].run(),
            throwsA(
              isA<SyncApiException>().having(
                (e) => e.code,
                'code',
                'maintenance_read_only',
              ),
            ),
          );
          expect((await engines[0].prepareRotation()).complete, true);
          await a.load();
          expect(a.habits.single.entries.length, 3);
          final prepared = a.exportJson();
          final dataBackup = await BackupCodec.encrypt(
            prepared,
            'public synthetic data backup password',
          );
          final recovered = await BackupCodec.decrypt(
            dataBackup,
            'public synthetic data backup password',
          );
          expect(
            SyncEntities.encodeFacts(recovered),
            SyncEntities.encodeFacts(prepared),
          );
          expect(
            Process.killPid(int.parse(serverPid), ProcessSignal.sigterm),
            true,
          );
          final rotationFile = '${root.path}/rotated-invite.json';
          for (var attempt = 0; attempt < 50; attempt++) {
            final result = await Process.run(operator, [
              'rotate-vault',
              '--db',
              database,
              '--user',
              user,
              '--prepared',
              '--out',
              rotationFile,
            ]);
            if (result.exitCode == 0) break;
            if (!result.stderr.toString().contains(
                  'server is already running',
                ) ||
                attempt == 49) {
              fail('rotation maintenance failed: ${result.stderr}');
            }
            await Future<void>.delayed(const Duration(milliseconds: 100));
          }
          final rotation =
              jsonDecode(await File(rotationFile).readAsString()) as Map;
          replacementServer = await Process.start(operator, [
            'serve',
            '--db',
            database,
            '--listen',
            listen,
            '--tls-cert',
            certificate,
            '--tls-key',
            tlsKey,
          ]);
          for (var attempt = 0; attempt < 50; attempt++) {
            try {
              await transports[0].request('GET', '/v1/capabilities');
              break;
            } on SocketException {
              if (attempt == 49) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            } on HttpException {
              if (attempt == 49) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
          await expectLater(
            engines[0].session.request('GET', '/v1/devices'),
            throwsA(
              isA<SyncApiException>().having((e) => e.status, 'status', 401),
            ),
          );
          final oldVault = keys.first.vault;
          final token = await transports[0].request(
            'POST',
            '/v1/auth/enroll',
            body: {
              'invite': rotation['invite'],
              'deviceName': 'rotated trusted phone',
            },
          );
          final nextKeys = await SyncKeyring.create(token['vaultId'] as String);
          keys.add(nextKeys);
          expect(nextKeys.vault, isNot(oldVault));
          expect(nextKeys.idKey, isNot(keys.first.idKey));
          final newSettings = SyncSettings(
            id: const Uuid().v4(),
            endpoint: endpoint,
            localVault: jsonDecode(a.exportJson())['vaultId'] as String,
            keys: nextKeys,
            tokens: token,
            recoveryExported: true,
          );
          engines[0] = SyncEngine(
            repositories[0],
            SyncSession(
              newSettings,
              SyncSettingsStore(MemorySecrets()),
              transports[0],
            ),
          );
          expect((await sync(0)).complete, true);
          expect(
            SyncEntities.encodeFacts(a.exportJson()),
            SyncEntities.encodeFacts(prepared),
          );
          final page = await engines[0].session.request(
            'GET',
            '/v1/pull?epoch=${token['epoch']}&limit=20',
          );
          final object = (page['objects'] as List).first as Map;
          final attackerKeys = SyncKeyring(
            vault: nextKeys.vault,
            idKey: Uint8List.fromList(keys.first.idKey),
            currentGeneration: 1,
            contentKeys: {1: Uint8List.fromList(keys.first.contentKeys[1]!)},
          );
          await expectLater(
            SyncCrypto.decrypt(
              attackerKeys,
              SyncObjectContext(
                vault: nextKeys.vault,
                epoch: object['encryptionEpoch'] as String,
                entityId: object['entityId'] as String,
                baseRevision: object['baseRevision'] as int,
                deleted: object['deleted'] as bool,
              ),
              object['ciphertext'] as String,
            ),
            throwsFormatException,
          );
          attackerKeys.dispose();
          final newInviteFile = '${root.path}/new-device-invite.json';
          await admin(['invite', '--user', user, '--out', newInviteFile]);
          final invited =
              jsonDecode(await File(newInviteFile).readAsString()) as Map;
          final secondTokens = await transports[1].request(
            'POST',
            '/v1/auth/enroll',
            body: {
              'invite': invited['invite'],
              'deviceName': 'rejoined second phone',
            },
          );
          final recoveryFile = await SyncRecoveryCodec.encrypt(
            nextKeys,
            'public new recovery file password',
          );
          final secondKeys = await SyncRecoveryCodec.decrypt(
            recoveryFile,
            'public new recovery file password',
          );
          keys.add(secondKeys);
          final rejoined = SyncSettings(
            id: const Uuid().v4(),
            endpoint: endpoint,
            localVault: jsonDecode(b.exportJson())['vaultId'] as String,
            keys: secondKeys,
            tokens: secondTokens,
            recoveryExported: true,
            initialReview: true,
          );
          engines[1] = SyncEngine(
            repositories[1],
            SyncSession(
              rejoined,
              SyncSettingsStore(MemorySecrets()),
              transports[1],
            ),
          );
          expect((await sync(1)).conflicts, [id]);
          await engines[1].resolve({id: true});
          await b.load();
          await sync(1);
          expect(
            SyncEntities.encodeFacts(b.exportJson()),
            SyncEntities.encodeFacts(prepared),
          );
        }
        final before = a.exportJson();
        await engines[0].session.request(
          'DELETE',
          '/v1/account',
          headers: {'X-Confirm-Delete': 'delete-remote-account'},
        );
        await a.load();
        expect(
          SyncEntities.encodeFacts(a.exportJson()),
          SyncEntities.encodeFacts(before),
        );
      } finally {
        replacementServer?.kill(ProcessSignal.sigterm);
        if (replacementServer != null) await replacementServer.exitCode;
        for (final c in controllers) {
          c.dispose();
        }
        for (final r in repositories) {
          await r.close();
        }
        for (final t in transports) {
          t.close();
        }
        for (final k in keys) {
          k.dispose();
        }
        await root.delete(recursive: true);
      }
    },
    skip: endpoint.isEmpty ? '需要隔离的真实 HTTPS Go 服务与两个一次性测试邀请' : false,
  );
  test(
    'two independent HTTPS services: verified backup restore and fresh pairing migration',
    () async {
      final root = await Directory.systemTemp.createTemp(
        'haoxiguan-migrate-e2e-',
      );
      final processes = <Process>[];
      final transports = <HttpSyncTransport>[];
      final repositories = <SqliteHabitRepository>[];
      final controllers = <HabitController>[];
      final keys = <SyncKeyring>[];
      final stores = <SyncSettingsStore>[];
      try {
        final endpoints = <String>[];
        final tokens = <Map<String, dynamic>>[];
        final users = <String>[];
        final databases = <String>[];
        for (var index = 0; index < 2; index++) {
          final db = '${root.path}/service-$index.sqlite';
          databases.add(db);
          final invitation = '${root.path}/service-$index-invitation.json';
          final create = await Process.run(operator, [
            'create-user',
            '--db',
            db,
            '--name',
            'migration-synthetic-$index',
            '--out',
            invitation,
          ]);
          expect(create.exitCode, 0, reason: create.stderr.toString());
          final account =
              jsonDecode(await File(invitation).readAsString()) as Map;
          users.add(account['userId'] as String);
          final reservation = await ServerSocket.bind(
            InternetAddress.loopbackIPv4,
            0,
          );
          final port = reservation.port;
          await reservation.close();
          final endpoint = 'https://localhost:$port';
          endpoints.add(endpoint);
          final process = await Process.start(operator, [
            'serve',
            '--db',
            db,
            '--listen',
            '127.0.0.1:$port',
            '--tls-cert',
            certificate,
            '--tls-key',
            tlsKey,
          ]);
          processes.add(process);
          process.stdout.drain<void>();
          process.stderr.drain<void>();
          final transport = HttpSyncTransport(
            endpoint,
            client: HttpClient(
              context: SecurityContext(withTrustedRoots: true)
                ..setTrustedCertificates(certificate),
            ),
          );
          transports.add(transport);
          for (var retry = 0; retry < 100; retry++) {
            try {
              await transport.request('GET', '/v1/capabilities');
              break;
            } on SocketException {
              if (retry == 99) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            } on HttpException {
              if (retry == 99) rethrow;
              await Future<void>.delayed(const Duration(milliseconds: 100));
            }
          }
          tokens.add(
            await transport.request(
              'POST',
              '/v1/auth/enroll',
              body: {
                'invite': account['invite'],
                'deviceName': 'migration-device-$index',
              },
            ),
          );
          keys.add(await SyncKeyring.create(tokens.last['vaultId'] as String));
        }
        Future<HabitController> makeController(int index) async {
          final repository = SqliteHabitRepository(
            HabitDatabase(
              NativeDatabase(File('${root.path}/device-$index.sqlite')),
            ),
          );
          repositories.add(repository);
          final controller = HabitController(repository);
          controllers.add(controller);
          await controller.load();
          return controller;
        }

        Future<SyncEngine> makeEngine(
          int device,
          int service,
          SyncKeyring key,
          Map<String, dynamic> token,
        ) async {
          final store = SyncSettingsStore(MemorySecrets());
          stores.add(store);
          final settings = SyncSettings(
            id: const Uuid().v4(),
            endpoint: endpoints[service],
            localVault:
                jsonDecode(controllers[device].exportJson())['vaultId']
                    as String,
            keys: key,
            tokens: token,
            recoveryExported: true,
          );
          await store.save(settings);
          return SyncEngine(
            repositories[device],
            SyncSession(settings, store, transports[service]),
          );
        }

        Future<void> confirmedSync(
          SyncEngine engine,
          HabitController controller,
        ) async {
          var result = await engine.run();
          if (result.preview != null) {
            await engine.confirmInitialSync(result.preview!);
            result = await engine.run();
          }
          expect(result.complete, true);
          await controller.load();
        }

        final source = await makeController(0);
        expect(
          await source.addHabit(
            title: '完整迁出阅读',
            emoji: '📚',
            colorValue: 0xff123456,
            weekdays: {1, 2, 3, 4, 5, 6, 7},
            recordType: 'count',
            scale: 1,
            dailyTarget: 3,
          ),
          true,
        );
        final id = source.habits.single.id;
        await source.addValue(id, source.today, 1);
        await source.setNote(id, source.today, '记录与备注均迁出');
        final sourceEngine = await makeEngine(0, 0, keys[0], tokens[0]);
        await confirmedSync(sourceEngine, source);
        final oldStatus = await sourceEngine.session.request(
          'GET',
          '/v1/vault',
        );
        await source.addValue(
          id,
          source.today,
          2,
        ); // Local unsent facts also travel.
        final expected = SyncEntities.encodeFacts(source.exportJson());
        final backup = await BackupCodec.encrypt(
          source.exportJson(),
          'synthetic migration data password',
        );
        final restored = await BackupCodec.decrypt(
          backup,
          'synthetic migration data password',
        );
        expect(SyncEntities.encodeFacts(restored), expected);
        final destination = await makeController(1);
        expect(await destination.importJson(restored), true);
        expect(
          jsonDecode(destination.exportJson())['vaultId'],
          isNot(sourceEngine.settings.localVault),
        );
        final destinationEngine = await makeEngine(1, 1, keys[1], tokens[1]);
        final preview = (await destinationEngine.run()).preview!;
        expect(preview.remote, isEmpty);
        expect(
          (await destinationEngine.session.request(
            'GET',
            '/v1/vault',
          ))['objects'],
          0,
        );
        await destinationEngine.confirmInitialSync(preview);
        await confirmedSync(destinationEngine, destination);
        expect(SyncEntities.encodeFacts(destination.exportJson()), expected);
        expect(keys[1].vault, isNot(keys[0].vault));
        expect(keys[1].idKey, isNot(keys[0].idKey));
        expect(tokens[1]['accessToken'], isNot(tokens[0]['accessToken']));
        final recovery = await SyncRecoveryCodec.encrypt(
          keys[1],
          'synthetic migration pairing password',
        );
        final peerKey = await SyncRecoveryCodec.decrypt(
          recovery,
          'synthetic migration pairing password',
        );
        keys.add(peerKey);
        final inviteFile = '${root.path}/destination-peer.json';
        final invite = await Process.run(operator, [
          'invite',
          '--db',
          databases[1],
          '--user',
          users[1],
          '--out',
          inviteFile,
        ]);
        expect(invite.exitCode, 0, reason: invite.stderr.toString());
        final invited =
            jsonDecode(await File(inviteFile).readAsString()) as Map;
        final peerToken = await transports[1].request(
          'POST',
          '/v1/auth/enroll',
          body: {
            'invite': invited['invite'],
            'deviceName': 'destination-independent-peer',
          },
        );
        final peer = await makeController(2);
        final peerEngine = await makeEngine(2, 1, peerKey, peerToken);
        await confirmedSync(peerEngine, peer);
        expect(SyncEntities.encodeFacts(peer.exportJson()), expected);
        expect(
          peer.habits.single.entries.map((e) => e.id).toSet(),
          source.habits.single.entries.map((e) => e.id).toSet(),
        );
        expect(
          peer.habits.single.plans.length,
          source.habits.single.plans.length,
        );
        expect(peer.habits.single.notes, source.habits.single.notes);
        expect(
          (await sourceEngine.session.request('GET', '/v1/vault'))['highWater'],
          oldStatus['highWater'],
        );
        await stores.first
            .disconnect(); // Stop old service only after destination verification.
        expect(await stores.first.load(), isNull);
        expect(SyncEntities.encodeFacts(source.exportJson()), expected);
        final existingIds = source.habits.single.entries
            .map((e) => e.id)
            .toSet();
        expect(await source.addValue(id, source.today, 4), true);
        expect(
          await source.setNote(id, source.today, '记录与备注均迁出\n断开旧服务后继续离线记录'),
          true,
        );
        final newId = source.habits.single.entries
            .map((e) => e.id)
            .toSet()
            .difference(existingIds)
            .single;
        final offlineSnapshot = source.exportJson();
        final offlineFile = File('${root.path}/disconnected-local.hgbak');
        await offlineFile.writeAsBytes(
          await BackupCodec.encrypt(
            offlineSnapshot,
            'synthetic offline data password',
          ),
          flush: true,
        );
        final offlineContents = await BackupCodec.decryptWithMetadata(
          await offlineFile.readAsBytes(),
          'synthetic offline data password',
        );
        final offlinePreview = BackupPreview.fromSnapshot(
          offlineContents.snapshot,
          createdAtUtc: offlineContents.createdAtUtc,
        );
        expect(offlinePreview.createdAtUtc, isNotNull);
        expect(offlinePreview.habits, 1);
        expect(offlinePreview.records, existingIds.length + 1);
        expect(offlinePreview.notes, 1);
        final offlineFacts = SyncEntities.encodeFacts(offlineContents.snapshot);
        expect(offlineFacts, SyncEntities.encodeFacts(offlineSnapshot));
        expect(offlineFacts['r/$newId']['data']['value'], 4);
        expect(
          offlineFacts.entries
              .singleWhere((e) => e.key.startsWith('n/'))
              .value['text'],
          '记录与备注均迁出\n断开旧服务后继续离线记录',
        );
        expect(
          (await sourceEngine.session.request('GET', '/v1/vault'))['highWater'],
          oldStatus['highWater'],
        );
      } finally {
        for (final controller in controllers) {
          controller.dispose();
        }
        for (final repository in repositories) {
          await repository.close();
        }
        for (final transport in transports) {
          transport.close();
        }
        for (final key in keys) {
          key.dispose();
        }
        for (final process in processes) {
          process.kill(ProcessSignal.sigterm);
          await process.exitCode.timeout(const Duration(seconds: 20));
        }
        await root.delete(recursive: true);
      }
    },
    skip: operator.isEmpty ? '需要隔离 Go 可执行文件及已信任的合成 HTTPS 证书' : false,
    timeout: const Timeout(Duration(minutes: 5)),
  );
}
