import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/sync_client.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_engine.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/state/habit_controller.dart';

import 'support/sync_relay.dart';

final _today = DateTime(2026, 10, 3);

void main() {
  late Directory directory;
  late SqliteHabitRepository repository;
  late HabitController controller;
  late SyncKeyring keys;
  late SyncEngine engine;
  late TestSyncRelay relay;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hgw-sync-import-');
    repository = SqliteHabitRepository(
      HabitDatabase(NativeDatabase(File('${directory.path}/data.sqlite'))),
    );
    controller = HabitController(repository, clock: () => _today);
    await controller.load();
    expect(controller.loaded, isTrue);
    relay = TestSyncRelay();
    keys = await SyncKeyring.create(TestSyncRelay.vault);
    final settings = SyncSettings(
      id: '7a724eed-18c3-4f09-96d8-c7bc97d34bea',
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
    engine = SyncEngine(
      repository,
      SyncSession(settings, SyncSettingsStore(MemorySecrets()), relay),
    );
    // Establish the durable empty cursor before any untrusted input arrives.
    expect((await engine.run()).preview, isNotNull);
  });

  tearDown(() async {
    controller.dispose();
    await repository.close();
    keys.dispose();
    await directory.delete(recursive: true);
  });

  Future<EntityMap> source() async {
    final other = HabitController(MemoryHabitRepository(), clock: () => _today);
    try {
      await other.load();
      expect(
        await other.addHabit(
          title: '名' * 80,
          emoji: '🌱',
          colorValue: 0xff5f8068,
          weekdays: {1, 2, 3, 4, 5, 6, 7},
        ),
        isTrue,
      );
      expect(
        await other.setNote(other.habits.single.id, _today, '注' * 2000),
        isTrue,
      );
      return SyncEntities.encode(other.exportJson());
    } finally {
      other.dispose();
    }
  }

  Future<Map<String, dynamic>> encryptedObject(
    String logicalId,
    dynamic payload, {
    int baseRevision = 0,
  }) async {
    final entityId = keys.opaqueId(logicalId);
    final context = SyncObjectContext(
      vault: keys.vault,
      epoch: relay.epochId,
      entityId: entityId,
      baseRevision: baseRevision,
      deleted: payload == null,
    );
    return {
      'entityId': entityId,
      'revision': baseRevision + 1,
      'baseRevision': baseRevision,
      'encryptionEpoch': relay.epochId,
      'ciphertext': await SyncCrypto.encrypt(keys, context, logicalId, payload),
      'deleted': payload == null,
    };
  }

  Future<void> receive(
    String id,
    dynamic payload, {
    int baseRevision = 0,
  }) async {
    final object = await encryptedObject(
      id,
      payload,
      baseRevision: baseRevision,
    );
    relay.objects[object['entityId'] as String] = object;
    relay.changes.add(object);
  }

  test(
    'decrypted remote title 80 and note 2000 reach preview without truncation',
    () async {
      final entities = await source();
      for (final entry in entities.entries) {
        await receive(entry.key, entry.value);
      }
      final outcome = await engine.run();
      expect(outcome.preview, isNotNull);
      expect(outcome.preview!.remote, entities);
      final state = (await repository.readSyncFrame()).state!;
      expect(state['cursor'], '${entities.length}');
      expect((state['remote'] as Map).length, entities.length);
      expect(controller.habits, isEmpty);
    },
  );

  for (final type in ['h', 'n']) {
    test(
      'remote $type limit violation preserves the entire page, shadow and cursor',
      () async {
        final entities = await source();
        final entry = entities.entries.singleWhere(
          (e) => e.key.startsWith('$type/'),
        );
        // A valid object earlier in the same page must not leak into durable state.
        final valid = entities.entries.firstWhere((e) => e.key != entry.key);
        await receive(valid.key, valid.value);
        final bad = Map<String, dynamic>.from(entry.value as Map);
        bad[type == 'h' ? 'title' : 'text'] = type == 'h'
            ? '名' * 81
            : '注' * 2001;
        await receive(entry.key, bad);
        final before = await repository.readSyncFrame();
        await expectLater(engine.run(), throwsFormatException);
        final after = await repository.readSyncFrame();
        expect(after.snapshot, before.snapshot);
        expect(after.businessRevision, before.businessRevision);
        expect(_withoutFailure(after.state!), before.state);
        expect(after.state!['lastFailureCode'], 'invalid_data');
        expect(after.state!['cursor'], before.state!['cursor']);
        expect(after.state!['highWater'], before.state!['highWater']);
        expect(after.state!['remote'], before.state!['remote']);
        expect(after.state!['pending'], before.state!['pending']);
      },
    );
  }

  test(
    'null habit and note tombstones stay valid incoming sync objects',
    () async {
      await receive('h/deleted-habit', null);
      await receive('n/deleted-note', null);
      expect((await engine.run()).preview, isNotNull);
      final state = (await repository.readSyncFrame()).state!;
      expect(state['cursor'], '2');
      expect((state['remote'] as Map)['h/deleted-habit']['payload'], isNull);
      expect((state['remote'] as Map)['n/deleted-note']['payload'], isNull);
      expect(controller.habits, isEmpty);
    },
  );

  test(
    'invalid push conflict keeps frozen outbox, acknowledged shadow and business facts',
    () async {
      final preview = (await engine.run()).preview!;
      await engine.confirmInitialSync(preview);
      expect(
        await controller.addHabit(
          title: '本机待发送标题',
          emoji: '🌱',
          colorValue: 0xff5f8068,
          weekdays: {1, 2, 3, 4, 5, 6, 7},
        ),
        isTrue,
      );
      var frame = await repository.readSyncFrame();
      final local = SyncEntities.encode(frame.snapshot);
      final entry = local.entries.singleWhere((e) => e.key.startsWith('h/'));
      final acknowledged = Map<String, dynamic>.from(entry.value as Map)
        ..['title'] = '原远端标题';
      final outgoing = await encryptedObject(
        entry.key,
        entry.value,
        baseRevision: 1,
      );
      final state = frame.state!;
      state['remote'] = {
        entry.key: {'revision': 1, 'payload': acknowledged},
      };
      state['base'] = {entry.key: acknowledged};
      state['pending'] = [
        {
          'operation': {
            'opId': '3f3135ea-dc27-4abc-8499-9fc39d7bf824',
            'entityId': outgoing['entityId'],
            'baseRevision': 1,
            'ciphertext': outgoing['ciphertext'],
            'deleted': false,
          },
          'logicalId': entry.key,
          'payload': entry.value,
        },
      ];
      await repository.commitSyncFrame(frame, state);
      final bad = Map<String, dynamic>.from(acknowledged)..['title'] = '名' * 81;
      final conflicting = await encryptedObject(
        entry.key,
        bad,
        baseRevision: 1,
      );
      relay.objects[conflicting['entityId'] as String] = conflicting;
      frame = await repository.readSyncFrame();
      await expectLater(engine.run(), throwsFormatException);
      final after = await repository.readSyncFrame();
      expect(after.snapshot, frame.snapshot);
      expect(after.businessRevision, frame.businessRevision);
      expect(_withoutFailure(after.state!), frame.state);
      expect(after.state!['pending'], frame.state!['pending']);
      expect(after.state!['base'], frame.state!['base']);
      expect(after.state!['remote'], frame.state!['remote']);
      expect(controller.habits.single.title, '本机待发送标题');
    },
  );
}

Map<String, dynamic> _withoutFailure(Map<String, dynamic> state) =>
    Map<String, dynamic>.from(state)
      ..remove('lastFailureCode')
      ..remove('lastFailureAt');
