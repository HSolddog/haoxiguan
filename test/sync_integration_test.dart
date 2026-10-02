import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';
import 'package:haoxiguan/services/backup_codec.dart';

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
          final result = await engines[i].run();
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
          SyncEntities.encode(a.exportJson()),
          SyncEntities.encode(b.exportJson()),
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
          expect(SyncEntities.encode(recovered), SyncEntities.encode(prepared));
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
            SyncEntities.encode(a.exportJson()),
            SyncEntities.encode(prepared),
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
            SyncEntities.encode(b.exportJson()),
            SyncEntities.encode(prepared),
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
          SyncEntities.encode(a.exportJson()),
          SyncEntities.encode(before),
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
}
