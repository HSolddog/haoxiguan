import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/models/category.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_entities.dart';

import 'support/sync_relay.dart';
import 'sync_engine_test.dart' as fixture;

void main() {
  late Directory directory;
  late SyncKeyring keys;
  late fixture.Device a, b;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hgw-category-sync-');
    final relay = TestSyncRelay();
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
  });
  tearDown(() async {
    await a.close();
    await b.close();
    keys.dispose();
    await directory.delete(recursive: true);
  });

  Future<String> add(
    fixture.Device device,
    String name,
    String category,
  ) async {
    expect(
      await device.controller.addHabit(
        title: name,
        emoji: '🌱',
        colorValue: 0xff123456,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        category: category,
      ),
      true,
    );
    return device.controller.habits.last.id;
  }

  test(
    'group member movement across interleaved categories converges on peers',
    () async {
      final a1 = await add(a, 'A1', 'A');
      final b1 = await add(a, 'B1', 'B');
      final a2 = await add(a, 'A2', 'A');
      await a.controller.toggleCompletion(a1, fixture.today);
      await a.controller.setNote(a1, fixture.today, 'keep this note');
      await a.sync();
      await b.sync();
      final group = a.controller.habitById(a1)!.categoryId!;
      final before = a.controller.habitById(a1)!;
      expect(await b.controller.reorderInCategory(a2, -1), true);
      await b.sync();
      await a.sync();
      await b.sync();
      for (final device in [a, b]) {
        expect(device.controller.habitsInCategory(group).map((h) => h.id), [
          a2,
          a1,
        ]);
        expect(device.controller.habits.map((h) => h.id), [a2, b1, a1]);
        final after = device.controller.habitById(a1)!;
        expect(
          after.entries.map((e) => e.toJson()),
          before.entries.map((e) => e.toJson()),
        );
        expect(after.notes, before.notes);
        expect(
          after.plans.map((p) => p.toJson()),
          before.plans.map((p) => p.toJson()),
        );
      }
      expect(
        SyncEntities.encodeFacts(a.controller.exportJson()),
        SyncEntities.encodeFacts(b.controller.exportJson()),
      );
    },
  );

  test(
    'partially received category descriptors keep the newest category revision',
    () async {
      final a1 = await add(a, 'A1', 'A');
      final a2 = await add(a, 'A2', 'A');
      final b1 = await add(a, 'B1', 'B');
      final oldSnapshot = a.controller.exportJson();
      final base = SyncEntities.encode(oldSnapshot);
      final groupA = a.controller.habitById(a1)!.categoryId!;
      final groupB = a.controller.habitById(b1)!.categoryId!;
      expect(await a.controller.reorderCategory(groupB, -1), true);
      final updated = SyncEntities.encode(a.controller.exportJson());
      // A pull can include one updated member before the other members of the
      // same category. The still-old member must not overwrite the new descriptor.
      final partial = {
        ...base,
        'h/$a1': updated['h/$a1'],
        'h/$b1': updated['h/$b1'],
      };
      final decision = SyncEntities.merge(oldSnapshot, base, partial);
      expect(decision.conflicts, isEmpty);
      final assembled = SyncEntities.assemble(oldSnapshot, decision.entities);
      final document = jsonDecode(assembled) as Map<String, dynamic>;
      expect(CategoryMetadata.categories(document).map((c) => c.id), [
        groupB,
        groupA,
      ]);
      final normalized = SyncEntities.encode(assembled);
      expect(
        normalized['h/$a1']['categoryInfo'],
        updated['h/$a1']['categoryInfo'],
      );
      expect(
        normalized['h/$a2']['categoryInfo'],
        updated['h/$a2']['categoryInfo'],
      );
      expect(
        normalized['h/$a2']['categoryInfo']['revision'],
        greaterThan(base['h/$a2']['categoryInfo']['revision'] as int),
      );
      final finalDecision = SyncEntities.merge(assembled, partial, updated);
      expect(finalDecision.conflicts, isEmpty);
      final finished = SyncEntities.assemble(assembled, finalDecision.entities);
      expect(
        CategoryMetadata.categories(jsonDecode(finished)).map((c) => c.id),
        [groupB, groupA],
      );
      expect(
        SyncEntities.encodeFacts(finished),
        SyncEntities.encodeFacts(a.controller.exportJson()),
      );
    },
  );

  test(
    'independently created categories with the same name retain distinct identities',
    () async {
      final aid = await add(a, 'from A', '同名');
      final bid = await add(b, 'from B', '同名');
      final groupA = a.controller.habitById(aid)!.categoryId!;
      final groupB = b.controller.habitById(bid)!.categoryId!;
      expect(groupA, isNot(groupB));
      await a.sync();
      await b.sync();
      await a.sync();
      await b.sync();
      for (final device in [a, b]) {
        expect(device.controller.categoryGroups.map((c) => c.id).toSet(), {
          groupA,
          groupB,
        });
        expect(device.controller.categoryGroups.map((c) => c.name), [
          '同名',
          '同名',
        ]);
        expect(device.controller.habitsInCategory(groupA).single.id, aid);
        expect(device.controller.habitsInCategory(groupB).single.id, bid);
      }
      expect(
        SyncEntities.encodeFacts(a.controller.exportJson()),
        SyncEntities.encodeFacts(b.controller.exportJson()),
      );
    },
  );
}
