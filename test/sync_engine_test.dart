import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/sync_client.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_engine.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:uuid/uuid.dart';
import 'support/sync_relay.dart';

final today = DateTime(2026, 10, 2, 12);

class Device {
  Device(this.dir, this.keys, this.relay);
  final Directory dir;
  final SyncKeyring keys;
  final TestSyncRelay relay;
  late SqliteHabitRepository repository;
  late HabitController controller;
  late SyncSettings settings;
  late SyncEngine engine;
  Future<void> open({bool first = false}) async {
    repository = SqliteHabitRepository(
      HabitDatabase(NativeDatabase(File('${dir.path}/data.sqlite'))),
    );
    controller = HabitController(repository, clock: () => today);
    await controller.load();
    expect(controller.loaded, true);
    if (first) {
      settings = SyncSettings(
        id: const Uuid().v4(),
        endpoint: 'https://example.test',
        localVault: jsonDecode(controller.exportJson())['vaultId'] as String,
        keys: keys,
        tokens: {
          'accessToken': 'a' * 43,
          'refreshToken': 'r' * 43,
          'accessExpiresAt': 9999999999,
          'deviceId': 'd' * 32,
          'vaultId': keys.vault,
          'epoch': TestSyncRelay.epoch,
        },
      );
    }
    engine = SyncEngine(
      repository,
      SyncSession(settings, SyncSettingsStore(MemorySecrets()), relay),
    );
  }

  Future<String> add({String type = 'count'}) async {
    expect(
      await controller.addHabit(
        title: '中文测试习惯',
        emoji: '📖',
        colorValue: 0xff223344,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        recordType: type,
        dailyTarget: type == 'boolean' ? 1 : 100,
        scale: type == 'count' ? 100 : 1,
      ),
      true,
    );
    return controller.habits.last.id;
  }

  Future<SyncOutcome> sync() async {
    final result = await engine.run();
    await controller.load();
    return result;
  }

  Future<void> close() async {
    controller.dispose();
    await repository.close();
  }
}

void main() {
  late Directory root;
  late TestSyncRelay relay;
  late SyncKeyring keys;
  late Device a, b;
  setUp(() async {
    root = await Directory.systemTemp.createTemp('hgw-sync-');
    relay = TestSyncRelay();
    keys = await SyncKeyring.create(TestSyncRelay.vault);
    a = Device(await Directory('${root.path}/a').create(), keys, relay);
    b = Device(await Directory('${root.path}/b').create(), keys, relay);
    await a.open(first: true);
    await b.open(first: true);
  });
  tearDown(() async {
    await a.close();
    await b.close();
    keys.dispose();
    await root.delete(recursive: true);
  });

  test(
    'two offline devices merge independent numeric records without plaintext at relay',
    () async {
      final id = await a.add();
      expect((await a.sync()).complete, true);
      expect((await b.sync()).complete, true);
      expect(await a.controller.addValue(id, today, 10), true);
      expect(await b.controller.addValue(id, today, 20), true);
      await a.sync();
      await b.sync();
      await a.sync();
      expect(
        a.controller
            .habitById(id)!
            .entries
            .map((e) => e.value)
            .reduce((a, b) => a + b),
        30,
      );
      expect(
        SyncEntities.encode(a.controller.exportJson()),
        SyncEntities.encode(b.controller.exportJson()),
      );
      expect(jsonEncode(relay.objects).contains('中文测试习惯'), false);
      expect(
        relay.objects.keys.every(
          (k) => RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(k),
        ),
        true,
      );
    },
  );

  test(
    'lost response survives process reopen and a newer local edit; retries frozen op once',
    () async {
      final id = await a.add();
      await a.sync();
      await a.controller.addValue(id, today, 10);
      relay.loseNextPushResponse = true;
      await expectLater(a.engine.run(), throwsA(isA<SyncApiException>()));
      final pending =
          (await a.repository.readSyncFrame()).state!['pending'] as List;
      expect(pending, isNotEmpty);
      final acceptedBefore = relay.changes.length;
      await a.close();
      await a.open();
      await a.controller.addValue(id, today, 20);
      await a.sync();
      await b.sync();
      expect(relay.changes.length, acceptedBefore + 1);
      expect(b.controller.habitById(id)!.entries.length, 2);
      expect((await a.repository.readSyncFrame()).state!['pending'], isEmpty);
    },
  );

  test(
    'concurrent note edits preserve local until explicit whole-habit choice',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.setNote(id, today, '来自甲');
      await b.controller.setNote(id, today, '来自乙');
      await a.sync();
      final result = await b.sync();
      expect(result.conflicts, [id]);
      expect(b.controller.habitById(id)!.notes.values, contains('来自乙'));
      await b.engine.resolve({id: true});
      await b.controller.load();
      await b.sync();
      expect(b.controller.habitById(id)!.notes.values, contains('来自甲'));
      expect((await b.repository.loadBackup())!, contains('来自乙'));
    },
  );

  test(
    'pull cursor does not advance when local commit fails; retry receives all facts',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.addValue(id, today, 10);
      await a.sync();
      final before = (await b.repository.readSyncFrame()).state!['cursor'];
      b.repository.database.beforeSyncCommit = () async =>
          throw const FileSystemException('injected disk failure');
      await expectLater(b.engine.run(), throwsA(isA<FileSystemException>()));
      expect((await b.repository.readSyncFrame()).state!['cursor'], before);
      expect(b.controller.habitById(id)!.entries, isEmpty);
      b.repository.database.beforeSyncCommit = null;
      await b.sync();
      expect(b.controller.habitById(id)!.entries.length, 1);
    },
  );

  test(
    'foreground write while pulling invalidates sync frame without losing acknowledged fact',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.addValue(id, today, 10);
      await a.sync();
      relay.afterNextPull = () async {
        expect(await b.controller.addValue(id, today, 20), true);
      };
      await expectLater(b.engine.run(), throwsA(anything));
      expect(b.controller.habitById(id)!.entries.single.value, 20);
      await b.sync();
      await a.sync();
      expect(a.controller.habitById(id)!.entries.length, 2);
    },
  );

  test('same boolean completion converges as one fact', () async {
    final id = await a.add(type: 'boolean');
    await a.sync();
    await b.sync();
    await a.controller.markCompleted(id, today);
    await b.controller.markCompleted(id, today);
    await a.sync();
    expect((await b.sync()).conflicts, isEmpty);
    await a.sync();
    expect(
      a.controller.habitById(id)!.entries.where((e) => !e.deleted).length,
      1,
    );
  });

  test(
    'multi-batch initial upload finishes before assembling a partial remote graph',
    () async {
      for (var i = 0; i < 52; i++) {
        await a.add();
      }
      expect((await a.sync()).complete, true);
      expect((await b.sync()).complete, true);
      expect(b.controller.habits.length, 52);
    },
  );
  test(
    'delete versus offline child edit requires explicit choice and preserves candidate archive',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.deleteHabit(id);
      await a.controller.permanentlyDeleteHabit(id);
      await b.controller.setNote(id, today, '离线备注不能静默丢失');
      await a.sync();
      expect((await b.sync()).conflicts, [id]);
      expect(b.controller.habitById(id), isNotNull);
      await b.engine.resolve({id: false});
      await b.controller.load();
      await b.sync();
      await a.sync();
      expect(a.controller.habitById(id)!.notes.values, contains('离线备注不能静默丢失'));
      final archives = await b.repository.database
          .customSelect('SELECT payload FROM sync_protections')
          .get();
      expect(archives.length, 1);
      expect(archives.single.read<String>('payload'), contains('h/$id'));
    },
  );

  test(
    'explicit baseline recovery reviews even one-sided absence before any upload or deletion',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await b.controller.addValue(id, today, 10);
      await b.engine.resetBaselineForReview();
      final result = await b.sync();
      expect(result.conflicts, [id]);
      expect(b.controller.habitById(id)!.entries.length, 1);
      await b.engine.resolve({id: false});
      await b.controller.load();
      await b.sync();
      await a.sync();
      expect(a.controller.habitById(id)!.entries.length, 1);
    },
  );

  test(
    'invalid recovery key cannot advance pull cursor or replace local facts',
    () async {
      await a.add();
      await a.sync();
      final wrongKeys = await SyncKeyring.create(TestSyncRelay.vault);
      final wrongSettings = SyncSettings(
        id: b.settings.id,
        endpoint: b.settings.endpoint,
        localVault: b.settings.localVault,
        keys: wrongKeys,
        tokens: b.settings.tokens,
      );
      final engine = SyncEngine(
        b.repository,
        SyncSession(wrongSettings, SyncSettingsStore(MemorySecrets()), relay),
      );
      await expectLater(engine.run(), throwsFormatException);
      expect((await b.repository.readSyncFrame()).state!['cursor'], '');
      expect(b.controller.habits, isEmpty);
      wrongKeys.dispose();
    },
  );
  test(
    'rejoining with stale local data reviews deletions instead of silently resurrecting them',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.deleteHabit(id);
      await a.controller.permanentlyDeleteHabit(id);
      await a.sync();
      final before = relay.changes.length;
      final settings = SyncSettings(
        id: const Uuid().v4(),
        endpoint: b.settings.endpoint,
        localVault: b.settings.localVault,
        keys: keys,
        tokens: b.settings.tokens,
        initialReview: true,
      );
      final engine = SyncEngine(
        b.repository,
        SyncSession(settings, SyncSettingsStore(MemorySecrets()), relay),
      );
      expect((await engine.run()).conflicts, [id]);
      expect(relay.changes.length, before);
      expect(b.controller.habitById(id), isNotNull);
    },
  );

  test(
    'frozen-space preparation keeps unsent intentions and saves exact previous outbox',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.addValue(id, today, 10);
      await a.sync();
      await b.controller.addValue(id, today, 20);
      relay.readOnly = true;
      await expectLater(
        b.engine.run(),
        throwsA(
          isA<SyncApiException>().having(
            (e) => e.code,
            'code',
            'maintenance_read_only',
          ),
        ),
      );
      final before = (await b.repository.readSyncFrame()).state!['pending'];
      expect(before, isNotEmpty);
      expect((await b.engine.prepareRotation()).complete, true);
      await b.controller.load();
      expect(b.controller.habitById(id)!.entries.map((e) => e.value).toSet(), {
        10,
        20,
      });
      final frame = await b.repository.readSyncFrame();
      expect(frame.state!['pending'], isEmpty);
      final archives = await b.repository.database
          .customSelect('SELECT payload FROM sync_protections')
          .get();
      expect(
        jsonDecode(archives.last.read<String>('payload'))['pending'],
        before,
      );
    },
  );

  test(
    'maintenance state changing during preparation prevents a false completion',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.addValue(id, today, 10);
      await a.sync();
      relay.readOnly = true;
      relay.afterNextPull = () async {
        relay.readOnly = false;
      };
      await expectLater(b.engine.prepareRotation(), throwsFormatException);
      expect(b.controller.habitById(id)!.entries, isEmpty);
      expect(
        (await b.repository.readSyncFrame()).state!['rotationPrepared'],
        isNull,
      );
    },
  );
}
