import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/category.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';

void main() {
  final now = DateTime(2026, 10, 3);
  Future<HabitController> open(MemoryHabitRepository repository) async {
    final controller = HabitController(repository, clock: () => now);
    await controller.load();
    addTearDown(controller.dispose);
    return controller;
  }

  void roomyScreen(WidgetTester tester) {
    // Keep both groups visible so geometric order assertions cannot pass on an
    // unbuilt sliver, while small-screen accessibility has its own coverage.
    tester.view.physicalSize = const Size(800, 1800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<String> create(
    HabitController controller,
    String name,
    String category,
  ) async {
    expect(
      await controller.addHabit(
        title: name,
        emoji: '🌱',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        category: category,
      ),
      isTrue,
    );
    return controller.habits.singleWhere((h) => h.title == name).id;
  }

  Future<void> manage(WidgetTester tester) async {
    await tester.tap(find.byIcon(Icons.checklist_rounded));
    await tester.pumpAndSettle();
  }

  Future<void> restartApp(
    WidgetTester tester,
    HabitController controller,
  ) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpAndSettle();
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
  }

  Finder habitMenu(String id) => find.descendant(
    of: find.byKey(Key('manage-habit-$id')),
    matching: find.byType(PopupMenuButton<String>),
  );

  void expectAbove(WidgetTester tester, String firstKey, String secondKey) {
    final first = find.byKey(Key(firstKey));
    final second = find.byKey(Key(secondKey));
    expect(first, findsOneWidget);
    expect(second, findsOneWidget);
    expect(tester.getTopLeft(first).dy, lessThan(tester.getTopLeft(second).dy));
  }

  testWidgets('全局A1 B1 A2交错时，同组A2上移真正先于A1并持久保存', (tester) async {
    roomyScreen(tester);
    final repository = MemoryHabitRepository();
    final controller = await open(repository);
    final a1 = await create(controller, 'A1', 'A');
    final b1 = await create(controller, 'B1', 'B');
    final a2 = await create(controller, 'A2', 'A');
    expect(controller.activeHabits.map((h) => h.id), [a1, b1, a2]);
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    await manage(tester);
    expectAbove(tester, 'manage-habit-$a1', 'manage-habit-$a2');
    await tester.ensureVisible(habitMenu(a2));
    await tester.tap(habitMenu(a2));
    await tester.pumpAndSettle();
    expect(find.text('上移'), findsOneWidget);
    expect(find.text('下移'), findsNothing);
    await tester.tap(find.text('上移'));
    await tester.pumpAndSettle();
    expect(
      controller.activeHabits.where((h) => h.category == 'A').map((h) => h.id),
      [a2, a1],
    );
    expectAbove(tester, 'manage-habit-$a2', 'manage-habit-$a1');
    expect(controller.habitById(b1)!.title, 'B1');

    final reopened = await open(repository);
    expect(
      reopened.activeHabits.where((h) => h.category == 'A').map((h) => h.id),
      [a2, a1],
    );
    await restartApp(tester, reopened);
    await manage(tester);
    expectAbove(tester, 'manage-habit-$a2', 'manage-habit-$a1');
    expect(tester.takeException(), isNull);
  });

  testWidgets('单习惯分类的习惯菜单不显示无意义上移或下移', (tester) async {
    roomyScreen(tester);
    final controller = await open(MemoryHabitRepository());
    await create(controller, 'A1', 'A');
    final only = await create(controller, 'B1', 'B');
    await create(controller, 'A2', 'A');
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    await manage(tester);
    await tester.tap(habitMenu(only));
    await tester.pumpAndSettle();
    expect(find.text('编辑'), findsOneWidget);
    expect(find.text('删除'), findsOneWidget);
    expect(find.text('上移'), findsNothing);
    expect(find.text('下移'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('分类移动在今日和习惯页一致，重开保持分类顺序', (tester) async {
    roomyScreen(tester);
    final repository = MemoryHabitRepository();
    final controller = await open(repository);
    await create(controller, 'A1', 'A');
    await create(controller, 'B1', 'B');
    final a = controller.categoryGroups.singleWhere((g) => g.name == 'A').id;
    final b = controller.categoryGroups.singleWhere((g) => g.name == 'B').id;
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    expectAbove(tester, 'today-category-$a', 'today-category-$b');
    await manage(tester);
    expectAbove(tester, 'habits-category-$a', 'habits-category-$b');
    await tester.tap(find.byKey(Key('category-order-$a')));
    await tester.pumpAndSettle();
    expect(find.text('分类上移'), findsNothing);
    await tester.tap(find.text('分类下移'));
    await tester.pumpAndSettle();
    expect(controller.categoryGroups.map((g) => g.id), [b, a]);
    expectAbove(tester, 'habits-category-$b', 'habits-category-$a');
    await tester.tap(find.byIcon(Icons.today_outlined));
    await tester.pumpAndSettle();
    expectAbove(tester, 'today-category-$b', 'today-category-$a');

    final reopened = await open(repository);
    expect(reopened.categoryGroups.map((g) => g.id), [b, a]);
    await restartApp(tester, reopened);
    expectAbove(tester, 'today-category-$b', 'today-category-$a');
    await manage(tester);
    expectAbove(tester, 'habits-category-$b', 'habits-category-$a');
    expect(tester.takeException(), isNull);
  });

  testWidgets('同名不同ID分类不合并，两个页面按身份独立分组与折叠', (tester) async {
    roomyScreen(tester);
    final source = await open(MemoryHabitRepository());
    await create(source, '左组习惯', '同名分类');
    await create(source, '右组习惯', '同名分类');
    const left = HabitCategory(id: 'category-left', name: '同名分类', sortKey: 0);
    const right = HabitCategory(
      id: 'category-right',
      name: '同名分类',
      sortKey: 1024,
    );
    final document = jsonDecode(source.exportJson()) as Map<String, dynamic>;
    document['categories'] = [left.toJson(), right.toJson()];
    final habits = document['habits'] as List;
    for (var i = 0; i < habits.length; i++) {
      final group = i == 0 ? left : right;
      final habit = habits[i] as Map;
      habit['categoryId'] = group.id;
      habit['categoryInfo'] = group.toJson();
      habit['sortKey'] = i * 1024;
    }
    final controller = await open(MemoryHabitRepository(jsonEncode(document)));
    expect(controller.categoryGroups.map((g) => g.id), [left.id, right.id]);
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    expectAbove(
      tester,
      'today-category-${left.id}',
      'today-category-${right.id}',
    );
    await tester.tap(find.byKey(Key('today-category-toggle-${left.id}')));
    await tester.pumpAndSettle();
    expect(find.text('左组习惯'), findsNothing);
    expect(find.text('右组习惯'), findsOneWidget);
    await manage(tester);
    expectAbove(
      tester,
      'habits-category-${left.id}',
      'habits-category-${right.id}',
    );
    // Today collapse does not collapse management, nor the same-named peer.
    expect(find.text('左组习惯'), findsOneWidget);
    expect(find.text('右组习惯'), findsOneWidget);
    await tester.tap(find.byKey(Key('habits-category-toggle-${left.id}')));
    await tester.pumpAndSettle();
    expect(find.text('左组习惯'), findsNothing);
    expect(find.text('右组习惯'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
