import 'dart:convert';
import 'dart:io';

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
