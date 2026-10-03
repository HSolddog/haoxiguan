import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/sync_client.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/services/sync_recovery.dart';
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
          'epoch': relay.epochId,
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
    var result = await engine.run();
    if (result.preview != null) {
      await engine.confirmInitialSync(result.preview!);
      result = await engine.run();
    }
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
      expect(
        (await a.repository.readSyncFrame()).state!['lastFailureCode'],
        'unavailable',
      );
      expect(
        (await a.repository.readSyncFrame()).state!['lastFailureAt'],
        isA<String>(),
      );
      final originalEntry = a.controller.habitById(id)!.entries.single.id;
      await a.close();
      await a.open();
      await a.controller.addValue(id, today, 20);
      await a.sync();
      await b.sync();
      expect(
        relay.changes
            .where(
              (change) =>
                  change['entityId'] == keys.opaqueId('r/$originalEntry'),
            )
            .length,
        1,
      );
      expect(b.controller.habitById(id)!.entries.length, 2);
      expect((await a.repository.readSyncFrame()).state!['pending'], isEmpty);
      expect(
        (await a.repository.readSyncFrame()).state!['lastFailureCode'],
        isNull,
      );
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
      expect(archives, isNotEmpty);
      expect(archives.last.read<String>('payload'), contains('h/$id'));
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
      final preview = (await engine.run()).preview!;
      expect(relay.changes.length, before);
      await engine.confirmInitialSync(preview);
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

  test(
    'first sync previews both empty sides and cancellation survives reopen',
    () async {
      final first = await a.engine.run();
      expect(first.preview, isNotNull);
      expect(first.complete, false);
      expect(relay.changes, isEmpty);
      await a.close();
      await a.open();
      final repeated = await a.engine.run();
      expect(repeated.preview, isNotNull);
      expect(
        (await a.repository.readSyncFrame()).state!['previewRequired'],
        true,
      );
      await a.engine.confirmInitialSync(repeated.preview!);
      expect((await a.engine.run()).complete, true);
    },
  );

  test(
    'nonempty local and empty remote wait for explicit confirmation',
    () async {
      final id = await a.add();
      final before = a.controller.exportJson();
      final preview = (await a.engine.run()).preview!;
      expect(preview.local['h/$id'], isNotNull);
      expect(preview.remote, isEmpty);
      expect(relay.changes, isEmpty);
      expect(a.controller.exportJson(), before);
      await a.engine.confirmInitialSync(preview);
      expect((await a.sync()).complete, true);
      expect(relay.changes, isNotEmpty);
    },
  );

  test(
    'empty local previews remote, and remote change invalidates confirmation',
    () async {
      final id = await a.add();
      await a.sync();
      final preview = (await b.engine.run()).preview!;
      expect(preview.local, isEmpty);
      expect(preview.remote['h/$id'], isNotNull);
      await b.controller.load();
      expect(b.controller.habits, isEmpty);
      await a.controller.setNote(id, today, '预览后新备注');
      await a.sync();
      await expectLater(
        b.engine.confirmInitialSync(preview),
        throwsFormatException,
      );
      expect(
        (await b.repository.readSyncFrame()).state!['previewRequired'],
        true,
      );
      expect(b.controller.habits, isEmpty);
      final updated = (await b.engine.run()).preview!;
      await b.engine.confirmInitialSync(updated);
      await b.sync();
      expect(b.controller.habitById(id)!.notes.values, ['预览后新备注']);
    },
  );

  test('local change invalidates initial preview without uploading', () async {
    final id = await a.add();
    final preview = (await a.engine.run()).preview!;
    await a.controller.addValue(id, today, 10);
    await expectLater(
      a.engine.confirmInitialSync(preview),
      throwsFormatException,
    );
    expect(relay.changes, isEmpty);
    expect(a.controller.habitById(id)!.entries.single.value, 10);
  });

  test(
    'note keep-both preserves both independent entry IDs and converges',
    () async {
      a.settings.tokens['deviceId'] = 'a' * 32;
      b.settings.tokens['deviceId'] = 'b' * 32;
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.addValue(id, today, 10);
      await b.controller.addValue(id, today, 20);
      final sourceByEntry = {
        a.controller.habitById(id)!.entries.single.id: 'a' * 32,
        b.controller.habitById(id)!.entries.single.id: 'b' * 32,
      };
      final entryIds = {
        a.controller.habitById(id)!.entries.single.id,
        b.controller.habitById(id)!.entries.single.id,
      };
      await a.controller.setNote(id, today, '远端备注');
      await b.controller.setNote(id, today, '本机备注');
      await a.sync();
      expect((await b.sync()).conflicts, [id]);
      final decision = await b.engine.conflicts();
      expect(decision.items.single.isNote, true);
      await b.engine.resolveItems(decision, {
        decision.items.single.id: const SyncSelection(SyncChoice.both),
      });
      await b.controller.load();
      expect(
        b.controller.habitById(id)!.entries.map((e) => e.id).toSet(),
        entryIds,
      );
      expect(b.controller.habitById(id)!.notes.values.single, '本机备注\n\n远端备注');
      await b.sync();
      await a.sync();
      // Historical digest declarations may remain in one device's bounded
      // source cache. Every business field and the displayed current sources
      // must converge, without uploading annotation-only differences.
      expect(
        SyncEntities.encodeFacts(a.controller.exportJson()),
        SyncEntities.encodeFacts(b.controller.exportJson()),
      );
      for (final device in [a, b]) {
        final facts = SyncEntities.encode(device.controller.exportJson());
        final noteKey = facts.keys.singleWhere((key) => key.startsWith('n/'));
        expect(SyncOrigins.sources(facts, noteKey, facts[noteKey]), ['b' * 32]);
        for (final entry in sourceByEntry.entries) {
          final key = 'r/${entry.key}';
          expect(SyncOrigins.sources(facts, key, facts[key]), [entry.value]);
        }
      }
      final operations = relay.changes.length;
      expect((await a.sync()).complete, true);
      expect((await b.sync()).complete, true);
      expect(relay.changes.length, operations);
      final protections = await b.repository.database
          .customSelect('SELECT payload FROM sync_protections')
          .get();
      expect(protections.last.read<String>('payload'), contains('远端备注'));
    },
  );

  test(
    'manual note merge retries failed persistence and rejects stale candidates',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.setNote(id, today, '甲');
      await b.controller.setNote(id, today, '乙');
      await a.sync();
      await b.sync();
      final decision = await b.engine.conflicts();
      final choices = {
        decision.items.single.id: const SyncSelection(
          SyncChoice.manual,
          text: '共同编辑的备注',
        ),
      };
      b.repository.database.beforeSyncCommit = () async =>
          throw const FileSystemException('disk full');
      await expectLater(
        b.engine.resolveItems(decision, choices),
        throwsA(isA<FileSystemException>()),
      );
      expect(b.controller.habitById(id)!.notes.values.single, '乙');
      b.repository.database.beforeSyncCommit = null;
      await b.engine.resolveItems(decision, choices);
      await b.controller.load();
      expect(b.controller.habitById(id)!.notes.values.single, '共同编辑的备注');
      await expectLater(
        b.engine.resolveItems(decision, choices),
        throwsFormatException,
      );
    },
  );

  test('field-level choice preserves independent habit fields', () async {
    final id = await a.add();
    await a.sync();
    await b.sync();
    Future<void> update(
      Device device,
      String title,
      String category,
      int color,
    ) async {
      final h = device.controller.habitById(id)!;
      expect(
        await device.controller.updateHabit(
          habitId: id,
          title: title,
          emoji: h.emoji,
          colorValue: color,
          weekdays: h.weekdays,
          category: category,
        ),
        true,
      );
    }

    await update(a, '远端名称', '远端分类', 0xff223344);
    await update(b, '本机名称', '未分类', 0xff556677);
    await a.sync();
    expect((await b.sync()).conflicts, [id]);
    final decision = await b.engine.conflicts();
    expect(decision.items.map((e) => e.field), ['title']);
    await b.engine.resolveItems(decision, {
      decision.items.single.id: const SyncSelection(SyncChoice.local),
    });
    await b.controller.load();
    final habit = b.controller.habitById(id)!;
    expect(habit.title, '本机名称');
    expect(habit.category, '远端分类');
    expect(habit.colorValue, 0xff556677);
  });

  test(
    'conflicting numeric record versions keep original ID and explicit duplicate',
    () async {
      final id = await a.add();
      await a.controller.addValue(id, today, 10);
      await a.sync();
      await b.sync();
      final entryId = a.controller.habitById(id)!.entries.single.id;
      Future<void> correct(Device device, int value) async {
        final snapshot =
            jsonDecode(device.controller.exportJson()) as Map<String, dynamic>;
        final record =
            ((snapshot['habits'] as List).single['entries'] as List).single
                as Map;
        record['value'] = value;
        record['revision'] = (record['revision'] as int) + 1;
        await device.repository.save(jsonEncode(snapshot));
        await device.controller.load();
      }

      await correct(a, 20);
      await correct(b, 30);
      await a.sync();
      await b.sync();
      final decision = await b.engine.conflicts();
      expect(decision.items.single.canKeepBoth, true);
      await b.engine.resolveItems(decision, {
        decision.items.single.id: const SyncSelection(SyncChoice.both),
      });
      await b.controller.load();
      final entries = b.controller.habitById(id)!.entries;
      expect(entries.length, 2);
      expect(entries.map((e) => e.id), contains(entryId));
      expect(entries.map((e) => e.id).toSet().length, 2);
      expect(entries.map((e) => e.value).toSet(), {20, 30});
      await b.sync();
      await a.sync();
      expect(a.controller.habitById(id)!.valueOn(today), 50);
    },
  );

  test(
    'export restore new-service pairing preserves full facts and leaves old service unchanged',
    () async {
      await a.engine.session.store.save(a.settings);
      final id = await a.add();
      await a.controller.addValue(id, today, 15);
      await a.controller.setNote(id, today, '迁出备注');
      await a.sync();
      await b.sync();
      await a.controller.addValue(
        id,
        today,
        25,
      ); // Includes the unsent local intention.
      final before = a.controller.exportJson();
      final originalObjects = jsonEncode(relay.objects);
      final originalHighWater = relay.changes.length;
      final backup = await BackupCodec.encrypt(
        before,
        'synthetic migration backup password',
      );
      final restored = await BackupCodec.decrypt(
        backup,
        'synthetic migration backup password',
      );
      expect(
        SyncEntities.encodeFacts(restored),
        SyncEntities.encodeFacts(before),
      );
      final nextRelay = TestSyncRelay(vaultId: 'n' * 32, epochId: 'f' * 32);
      final nextKeys = await SyncKeyring.create(nextRelay.vaultId);
      final c = Device(
        await Directory('${root.path}/migrated').create(),
        nextKeys,
        nextRelay,
      );
      SyncKeyring? peerKeys;
      Device? peer;
      await c.open(first: true);
      try {
        expect(await c.controller.importJson(restored), true);
        final restoredVault =
            jsonDecode(c.controller.exportJson())['vaultId'] as String;
        expect(restoredVault, isNot(a.settings.localVault));
        c.settings = SyncSettings(
          id: const Uuid().v4(),
          endpoint: 'https://second.example.test',
          localVault: restoredVault,
          keys: nextKeys,
          tokens: {...c.settings.tokens, 'vaultId': nextKeys.vault},
          recoveryExported: true,
        );
        c.engine = SyncEngine(
          c.repository,
          SyncSession(
            c.settings,
            SyncSettingsStore(MemorySecrets()),
            nextRelay,
          ),
        );
        final preview = (await c.engine.run()).preview!;
        expect(preview.remote, isEmpty);
        expect(nextRelay.changes, isEmpty);
        await c.engine.confirmInitialSync(preview);
        expect((await c.sync()).complete, true);
        final recovery = await SyncRecoveryCodec.encrypt(
          nextKeys,
          'synthetic new pairing password',
        );
        peerKeys = await SyncRecoveryCodec.decrypt(
          recovery,
          'synthetic new pairing password',
        );
        peer = Device(
          await Directory('${root.path}/new-peer').create(),
          peerKeys,
          nextRelay,
        );
        await peer.open(first: true);
        expect((await peer.sync()).complete, true);
        expect(
          SyncEntities.encodeFacts(peer.controller.exportJson()),
          SyncEntities.encodeFacts(before),
        );
        expect(nextKeys.idKey, isNot(keys.idKey));
        expect(
          nextRelay.objects.keys.toSet().intersection(
            relay.objects.keys.toSet(),
          ),
          isEmpty,
        );
        expect(jsonEncode(relay.objects), originalObjects);
        expect(
          peer.controller.habitById(id)!.entries.map((e) => e.value).toSet(),
          {15, 25},
        );
        expect(await a.engine.session.store.load(), isNotNull);
        await a.engine.session.store.disconnect();
        expect(await a.engine.session.store.load(), isNull);
        final existingIds = a.controller
            .habitById(id)!
            .entries
            .map((e) => e.id)
            .toSet();
        expect(await a.controller.addValue(id, today, 35), true);
        expect(
          await a.controller.setNote(id, today, '迁出备注\n断开旧服务后仍可本地记录'),
          true,
        );
        final newId = a.controller
            .habitById(id)!
            .entries
            .map((e) => e.id)
            .toSet()
            .difference(existingIds)
            .single;
        final offlineSnapshot = a.controller.exportJson();
        final offlineFile = File('${root.path}/disconnected-local.hgbak');
        await offlineFile.writeAsBytes(
          await BackupCodec.encrypt(
            offlineSnapshot,
            'synthetic offline backup password',
          ),
          flush: true,
        );
        final offlineContents = await BackupCodec.decryptWithMetadata(
          await offlineFile.readAsBytes(),
          'synthetic offline backup password',
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
        expect(offlineFacts['r/$newId']['data']['value'], 35);
        expect(
          offlineFacts.entries
              .singleWhere((e) => e.key.startsWith('n/'))
              .value['text'],
          '迁出备注\n断开旧服务后仍可本地记录',
        );
        expect(jsonEncode(relay.objects), originalObjects);
        expect(relay.changes.length, originalHighWater);
      } finally {
        await c.close();
        await peer?.close();
        peerKeys?.dispose();
        nextKeys.dispose();
      }
    },
  );
  test(
    'overlength note combination keeps both originals until valid manual merge',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.setNote(id, today, '甲' * 2000);
      await b.controller.setNote(id, today, '乙' * 2000);
      await a.sync();
      await b.sync();
      final decision = await b.engine.conflicts();
      await expectLater(
        b.engine.resolveItems(decision, {
          decision.items.single.id: const SyncSelection(SyncChoice.both),
        }),
        throwsFormatException,
      );
      expect(b.controller.habitById(id)!.notes.values.single, '乙' * 2000);
      expect((await b.engine.conflicts()).remote, decision.remote);
      await b.engine.resolveItems(decision, {
        decision.items.single.id: const SyncSelection(
          SyncChoice.manual,
          text: '双方核对后的摘要',
        ),
      });
      await b.controller.load();
      expect(b.controller.habitById(id)!.notes.values.single, '双方核对后的摘要');
    },
  );

  test(
    'identical initial join clears full review after explicit confirmation',
    () async {
      b.settings = SyncSettings(
        id: b.settings.id,
        endpoint: b.settings.endpoint,
        localVault: b.settings.localVault,
        keys: keys,
        tokens: b.settings.tokens,
        initialReview: true,
      );
      b.engine = SyncEngine(
        b.repository,
        SyncSession(b.settings, SyncSettingsStore(MemorySecrets()), relay),
      );
      expect((await b.sync()).complete, true);
      expect((await b.repository.readSyncFrame()).state!['reviewAll'], false);
      final id = await a.add();
      await a.sync();
      expect((await b.sync()).complete, true);
      expect(b.controller.habitById(id), isNotNull);
    },
  );
  test(
    'conflict shows authenticated source declarations and resolution does not echo metadata',
    () async {
      a.settings.tokens['deviceId'] = 'a' * 32;
      b.settings.tokens['deviceId'] = 'b' * 32;
      final id = await a.add();
      await a.sync();
      await b.sync();
      await a.controller.setNote(id, today, '远端新备注');
      await b.controller.setNote(id, today, '本机新备注');
      await a.sync();
      await b.sync();
      final decision = await b.engine.conflicts();
      final item = decision.items.single;
      expect(decision.sources(item, remoteSide: true), ['a' * 32]);
      expect(decision.sources(item, remoteSide: false), ['b' * 32]);
      await b.engine.resolveItems(decision, {
        item.id: const SyncSelection(SyncChoice.remote),
      });
      final before = relay.changes.length;
      await b.sync();
      await b.sync();
      expect(relay.changes.length, before);
      expect((await b.engine.conflicts()).sources(item, remoteSide: true), [
        'a' * 32,
      ]);
    },
  );

  test(
    'same server revision cannot substitute different authenticated source annotations',
    () async {
      final id = await a.add();
      await a.sync();
      await b.sync();
      final entityId = keys.opaqueId('h/$id');
      final original = relay.objects[entityId]!;
      final context = SyncObjectContext(
        vault: keys.vault,
        epoch: original['encryptionEpoch'] as String,
        entityId: entityId,
        baseRevision: original['baseRevision'] as int,
        deleted: false,
      );
      final decoded = await SyncCrypto.decrypt(
        keys,
        context,
        original['ciphertext'] as String,
      );
      final payload = Map<String, dynamic>.from(decoded.payload as Map);
      final origins = [
        for (final row in payload[SyncOrigins.field] as List)
          Map<String, dynamic>.from(row as Map),
      ];
      origins.first['deviceId'] = 'x' * 32;
      payload[SyncOrigins.field] = origins;
      final substituted = {
        ...original,
        'ciphertext': await SyncCrypto.encrypt(keys, context, 'h/$id', payload),
      };
      relay.changes.add(substituted);
      final before = (await b.repository.readSyncFrame()).state!['cursor'];
      await expectLater(b.engine.run(), throwsFormatException);
      expect((await b.repository.readSyncFrame()).state!['cursor'], before);
      expect(b.controller.habitById(id), isNotNull);
    },
  );
}
