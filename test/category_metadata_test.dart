import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/models/category.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/state/habit_controller.dart';

Map<String, Object?> _habit(String id, String category) => Habit(
  id: id,
  title: id,
  emoji: '🌱',
  colorValue: 0xff000000,
  weekdays: {1},
  createdAt: DateTime(2026, 10, 1),
  category: category,
  completions: {'2026-10-02': '2026-10-02T09:00:00Z'},
  notes: {'2026-10-02': '原备注'},
  extensions: {'customUserField': '保留'},
).toJson();

void main() {
  test(
    'category descriptors retain unknown fields through copy, migration and reordering',
    () async {
      final group = HabitCategory.fromJson({
        'id': 'future-category',
        'name': 'A',
        'sortKey': 0,
        'revision': 1,
        'futureField': {
          'preserve': [1, 2, 3],
        },
      });
      expect(
        group.copyWith(sortKey: 1024, revision: 2).toJson()['futureField'],
        {
          'preserve': [1, 2, 3],
        },
      );
      final c = HabitController(
        MemoryHabitRepository(
          jsonEncode({
            'version': 6,
            'categories': [group.toJson()],
            'habits': [
              {
                ..._habit('a', 'A'),
                'categoryId': group.id,
                'categoryInfo': group.toJson(),
              },
              _habit('b', 'B'),
            ],
          }),
        ),
      );
      await c.load();
      await c.reorderCategory(c.habitById('b')!.categoryId!, -1);
      expect(c.habitById('a')!.categoryInfo!.toJson()['futureField'], {
        'preserve': [1, 2, 3],
      });
      c.dispose();
    },
  );

  test(
    'new installations share the logical unclassified ID without conflating explicit categories',
    () async {
      final a = HabitController(MemoryHabitRepository());
      final b = HabitController(MemoryHabitRepository());
      await a.load();
      await b.load();
      for (final c in [a, b]) {
        await c.addHabit(
          title: '默认分类',
          emoji: '🌱',
          colorValue: 0xff000000,
          weekdays: {1},
        );
        await c.addHabit(
          title: '显式分类',
          emoji: '🌱',
          colorValue: 0xff000000,
          weekdays: {1},
          category: '相同显示名称',
        );
      }
      expect(a.habits.first.categoryId, b.habits.first.categoryId);
      expect(a.habits.last.categoryId, isNot(b.habits.last.categoryId));
      a.dispose();
      b.dispose();
    },
  );
  test(
    'legacy category migration preserves facts, unknown fields, IDs and original order on reopen',
    () async {
      final before = jsonEncode({
        'version': 6,
        'customSetting': 42,
        'collapsedTodayCategories': ['学习'],
        'habits': [_habit('a', '学习'), _habit('b', '健康'), _habit('c', '学习')],
      });
      final repo = MemoryHabitRepository(before);
      final c = HabitController(repo, clock: () => DateTime(2026, 10, 3));
      await c.load();
      expect(c.loadError, isNull);
      expect(c.habits.map((h) => h.id), ['a', 'b', 'c']);
      final group = c.habitById('a')!.categoryId!;
      expect(group, c.habitById('c')!.categoryId);
      expect(group, isNot(c.habitById('b')!.categoryId));
      expect(c.isTodayCategoryCollapsed(group), true);
      expect(c.isTodayCategoryCollapsed('学习'), true);
      expect(c.habitById('a')!.extensions['customUserField'], '保留');
      expect(jsonDecode(c.exportJson())['customSetting'], 42);
      expect(repo.backupValue, before);
      final saved = repo.value;
      final reopened = HabitController(repo);
      await reopened.load();
      expect(repo.value, saved);
      expect(
        reopened.habits.map((h) => h.categoryId),
        c.habits.map((h) => h.categoryId),
      );
      expect(
        reopened.habits.map((h) => h.entries.single.toJson()),
        c.habits.map((h) => h.entries.single.toJson()),
      );
      reopened.dispose();
      c.dispose();
    },
  );

  test(
    'same-name categories retain separate membership and collapse identities',
    () async {
      const a = HabitCategory(id: 'cat-a', name: '同名', sortKey: 0);
      const b = HabitCategory(id: 'cat-b', name: '同名', sortKey: 1024);
      final c = HabitController(
        MemoryHabitRepository(
          jsonEncode({
            'version': 6,
            'categories': [a.toJson(), b.toJson()],
            'habits': [
              {
                ..._habit('a', '同名'),
                'categoryId': a.id,
                'categoryInfo': a.toJson(),
              },
              {
                ..._habit('b', '同名'),
                'categoryId': b.id,
                'categoryInfo': b.toJson(),
              },
            ],
          }),
        ),
      );
      await c.load();
      expect(c.categoryGroups.map((c) => c.id), [a.id, b.id]);
      await c.toggleHabitCategory(a.id);
      expect(c.isHabitCategoryCollapsed(a.id), true);
      expect(c.isHabitCategoryCollapsed(b.id), false);
      await c.addHabit(
        title: '同名新成员',
        emoji: '🌱',
        colorValue: 0xff000000,
        weekdays: {1},
        category: '同名',
        categoryId: b.id,
      );
      expect(c.habits.last.categoryId, b.id);
      c.dispose();
    },
  );

  test(
    'category and member reordering persists without rewriting facts',
    () async {
      final repo = MemoryHabitRepository(
        jsonEncode({
          'version': 6,
          'habits': [_habit('a1', 'A'), _habit('b1', 'B'), _habit('a2', 'A')],
        }),
      );
      final c = HabitController(repo);
      await c.load();
      final facts = {for (final h in c.habits) h.id: h.entries.single.toJson()};
      final a = c.habitById('a1')!.categoryId!,
          b = c.habitById('b1')!.categoryId!;
      await c.reorderInCategory('a2', -1);
      expect(c.habitsInCategory(a).map((h) => h.id), ['a2', 'a1']);
      await c.reorderCategory(b, -1);
      expect(c.categoryGroups.map((c) => c.id), [b, a]);
      final reopened = HabitController(repo);
      await reopened.load();
      expect(reopened.categoryGroups.map((c) => c.id), [b, a]);
      expect(reopened.habitsInCategory(a).map((h) => h.id), ['a2', 'a1']);
      expect({
        for (final h in reopened.habits) h.id: h.entries.single.toJson(),
      }, facts);
      reopened.dispose();
      c.dispose();
    },
  );

  test(
    'partial replicated category descriptors use newer revision and deterministic ID tie-break',
    () {
      const old = HabitCategory(id: 'same', name: 'A', sortKey: 0);
      const newer = HabitCategory(
        id: 'same',
        name: 'A',
        sortKey: 1024,
        revision: 2,
      );
      final result = CategoryMetadata.normalize({
        'version': 6,
        'categories': [old.toJson()],
        'habits': [
          {
            ..._habit('b', 'A'),
            'categoryId': old.id,
            'categoryInfo': old.toJson(),
            'sortKey': 5,
          },
          {
            ..._habit('a', 'A'),
            'categoryId': newer.id,
            'categoryInfo': newer.toJson(),
            'sortKey': 5,
          },
        ],
      });
      expect((result['habits'] as List).map((h) => h['id']), ['a', 'b']);
      for (final habit in result['habits'] as List) {
        expect((habit as Map)['categoryInfo'], newer.toJson());
      }
      expect(SnapshotCodec.decode(jsonEncode(result))['categories'], [
        newer.toJson(),
      ]);
    },
  );

  test(
    'older app label edit is reassignment, preserving original category identity',
    () {
      const original = HabitCategory(id: 'old', name: '原分类', sortKey: 0);
      final result = CategoryMetadata.normalize({
        'version': 6,
        'categories': [original.toJson()],
        'habits': [
          {
            ..._habit('habit', '旧端新分类'),
            'categoryId': original.id,
            'categoryInfo': original.toJson(),
          },
        ],
      });
      final habit = (result['habits'] as List).single as Map;
      expect(habit['categoryId'], isNot(original.id));
      expect(habit['category'], '旧端新分类');
      expect(
        CategoryMetadata.categories(
          result,
        ).firstWhere((c) => c.id == original.id).name,
        '原分类',
      );
    },
  );
}
