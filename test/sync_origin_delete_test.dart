import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_entities.dart';

import 'support/sync_relay.dart';
import 'sync_engine_test.dart' as fixture;

void main() {
  late Directory directory;
  late TestSyncRelay relay;
  late SyncKeyring keys;
  late fixture.Device a, b;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hgw-origin-delete-');
    relay = TestSyncRelay();
    keys = await SyncKeyring.create(TestSyncRelay.vault);
    a = fixture.Device(
      await Directory('${directory.path}/a').create(),
      keys,
      relay,
    );
    b = fixture.Device(
      await Directory('${directory.path}/b').create(),
      keys,
      relay,
    );
    await a.open(first: true);
    await b.open(first: true);
    a.settings.tokens['deviceId'] = 'a' * 32;
    b.settings.tokens['deviceId'] = 'b' * 32;
  });
  tearDown(() async {
    await a.close();
    await b.close();
    keys.dispose();
    await directory.delete(recursive: true);
  });

  Future<String> sameFactsWithDifferentOrigins() async {
    final id = await a.add();
    await a.sync();
    await b.sync();
    await a.controller.setNote(id, fixture.today, '双方独立输入相同内容');
    await b.controller.setNote(id, fixture.today, '双方独立输入相同内容');
    // Capture B's old pull page, then let A publish before B freezes and pushes.
    // B's CAS conflict therefore leaves its own authenticated source declaration
    // locally while the remote baseline contains only A's declaration.
    relay.afterNextPull = () async {
      expect((await a.sync()).complete, true);
    };
    expect((await b.sync()).complete, true);
    final frame = await b.repository.readSyncFrame();
    final local = SyncEntities.encode(frame.snapshot);
    final base = (frame.state!['base'] as Map).cast<String, dynamic>();
    expect(
      SyncEntities.sameFacts('h/$id', local['h/$id'], base['h/$id']),
      true,
    );
    expect(SyncEntities.same(local['h/$id'], base['h/$id']), false);
    final noteKey = local.keys.singleWhere((key) => key.startsWith('n/'));
    expect(SyncOrigins.sources(local, noteKey, local[noteKey]), [
      'a' * 32,
      'b' * 32,
    ]);
    return id;
  }

  test(
    'remote whole-habit deletion ignores source-cache-only local drift',
    () async {
      final id = await sameFactsWithDifferentOrigins();
      expect(await a.controller.deleteHabit(id), true);
      expect(await a.controller.permanentlyDeleteHabit(id), true);
      expect((await a.sync()).complete, true);
      final changes = relay.changes.length;
      final outcome = await b.sync();
      expect(outcome.complete, true);
      expect(outcome.conflicts, isEmpty);
      expect(b.controller.habitById(id), isNull);
      expect(SyncEntities.encodeFacts(b.controller.exportJson()), isEmpty);
      expect(relay.changes.length, changes);
    },
  );

  test(
    'local whole-habit deletion ignores source-cache-only remote drift',
    () async {
      final id = await sameFactsWithDifferentOrigins();
      final frame = await b.repository.readSyncFrame();
      final base = (frame.state!['base'] as Map).cast<String, dynamic>();
      final metadataOnlyRemote = SyncEntities.encode(frame.snapshot);
      expect(await b.controller.deleteHabit(id), true);
      expect(await b.controller.permanentlyDeleteHabit(id), true);
      final decision = SyncEntities.merge(
        b.controller.exportJson(),
        base,
        metadataOnlyRemote,
      );
      expect(decision.conflicts, isEmpty);
      final assembled = SyncEntities.assemble(
        b.controller.exportJson(),
        decision.entities,
      );
      expect(SyncEntities.encodeFacts(assembled), isEmpty);
    },
  );

  test(
    'real local edits remain protected against deletion despite source-cache drift',
    () async {
      final id = await sameFactsWithDifferentOrigins();
      final habit = b.controller.habitById(id)!;
      expect(
        await b.controller.updateHabit(
          habitId: id,
          title: '本机实际修改的标题',
          emoji: habit.emoji,
          colorValue: habit.colorValue,
          weekdays: habit.weekdays,
        ),
        true,
      );
      expect(await b.controller.addValue(id, fixture.today, 25), true);
      final before = SyncEntities.encodeFacts(b.controller.exportJson());
      expect(await a.controller.deleteHabit(id), true);
      expect(await a.controller.permanentlyDeleteHabit(id), true);
      expect((await a.sync()).complete, true);
      final changes = relay.changes.length;
      final outcome = await b.sync();
      expect(outcome.complete, false);
      expect(outcome.conflicts, [id]);
      expect(SyncEntities.encodeFacts(b.controller.exportJson()), before);
      expect(b.controller.habitById(id)!.title, '本机实际修改的标题');
      expect(b.controller.habitById(id)!.entries.single.value, 25);
      expect(relay.changes.length, changes);
      expect((await b.engine.conflicts()).items, isNotEmpty);
    },
  );
}
