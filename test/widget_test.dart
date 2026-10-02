import 'support/legacy_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';

void main() {
  late HabitController controller;

  setUp(() async {
    controller = HabitController(
      MemoryHabitRepository(legacyFixture(DateTime(2026, 7, 15, 10, 30))),
      clock: () => DateTime(2026, 7, 15, 10, 30),
    );
    await controller.load();
  });

  testWidgets('今日页可以完成并撤销习惯', (tester) async {
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('阅读 20 分钟'), findsOneWidget);
    expect(find.text('0/3'), findsOneWidget);
    expect(find.byKey(const Key('today-category-学习')), findsOneWidget);
    expect(find.byKey(const Key('today-category-健康')), findsOneWidget);

    await tester.tap(find.byKey(const Key('complete-seed-reading-false')));
    await tester.pumpAndSettle();
    expect(find.text('1/3'), findsOneWidget);

    await tester.tap(find.byKey(const Key('complete-seed-reading-true')));
    await tester.pumpAndSettle();
    expect(find.text('0/3'), findsOneWidget);
  });

  testWidgets('保存失败保留创建输入，重试后才关闭面板', (tester) async {
    final repository = _FailOnceRepository(
      legacyFixture(DateTime(2026, 7, 15)),
    );
    final local = HabitController(
      repository,
      clock: () => DateTime(2026, 7, 15),
    );
    await local.load();
    await tester.pumpWidget(HabitApp(controller: local));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-habit-button')));
    await tester.pumpAndSettle();
    await tester.enterText(
      find.byKey(const Key('habit-title-field')),
      '不能丢失的输入',
    );
    repository.failNext = true;
    final save = find.byKey(const Key('save-habit-button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('habit-title-field')), findsOneWidget);
    expect(find.text('不能丢失的输入'), findsOneWidget);
    expect(local.habits.any((h) => h.title == '不能丢失的输入'), isFalse);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('habit-title-field')), findsNothing);
    expect(local.habits.where((h) => h.title == '不能丢失的输入'), hasLength(1));
  });

  testWidgets('损坏启动进入恢复界面且不自动清空', (tester) async {
    final repository = MemoryHabitRepository('{broken');
    final local = HabitController(repository);
    await local.load();
    await tester.pumpWidget(HabitApp(controller: local));
    await tester.pumpAndSettle();
    expect(find.text('重新检查'), findsOneWidget);
    expect(find.text('查看原始数据'), findsOneWidget);
    expect(find.byKey(const Key('add-habit-button')), findsNothing);
    expect(repository.value, '{broken');
  });

  testWidgets('可以通过底部面板创建新习惯', (tester) async {
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-habit-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('habit-title-field')), '睡前拉伸');
    final saveButton = find.byKey(const Key('save-habit-button'));
    await tester.ensureVisible(saveButton);
    await tester.tap(saveButton);
    await tester.pumpAndSettle();

    expect(find.byKey(const Key('habit-title-field')), findsNothing);
    expect(controller.habits.any((habit) => habit.title == '睡前拉伸'), isTrue);
  });

  testWidgets('今日和习惯页的分类都可以独立折叠', (tester) async {
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();

    final todayToggle = find.byKey(const Key('today-category-toggle-学习'));
    expect(
      find.byKey(const Key('complete-seed-reading-false')),
      findsOneWidget,
    );
    await tester.tap(todayToggle);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('complete-seed-reading-false')), findsNothing);
    expect(controller.isTodayCategoryCollapsed('学习'), isTrue);

    await tester.tap(find.byIcon(Icons.checklist_rounded));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manage-habit-seed-reading')), findsOneWidget);
    await tester.tap(find.byKey(const Key('habits-category-toggle-学习')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manage-habit-seed-reading')), findsNothing);
    expect(controller.isHabitCategoryCollapsed('学习'), isTrue);
    expect(controller.isTodayCategoryCollapsed('学习'), isTrue);
  });

  testWidgets('奖惩和心愿设置默认收起，开启后展开', (tester) async {
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('add-habit-button')));
    await tester.pumpAndSettle();
    expect(find.text('每次完成奖励'), findsNothing);
    expect(find.text('达成后想实现的心愿'), findsNothing);

    final effortSwitch = find.byKey(const Key('effort-enabled-switch'));
    await tester.ensureVisible(effortSwitch);
    await tester.tap(effortSwitch);
    await tester.pumpAndSettle();
    expect(find.text('每次完成奖励'), findsOneWidget);

    final wishSwitch = find.byKey(const Key('wish-enabled-switch'));
    await tester.ensureVisible(wishSwitch);
    await tester.tap(wishSwitch);
    await tester.pumpAndSettle();
    expect(find.text('达成后想实现的心愿'), findsOneWidget);
  });

  testWidgets('回顾里的习惯可以进入并查看每日备注', (tester) async {
    final noteDay = DateTime(2026, 7, 14);
    await controller.setNote('seed-reading', noteDay, '读完后更容易专注');
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.insights_outlined));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const PageStorageKey<String>('review-scroll')),
      const Offset(0, -700),
    );
    await tester.pumpAndSettle();
    final insight = find.byKey(const Key('review-habit-seed-reading'));
    await tester.tap(insight);
    await tester.pumpAndSettle();

    await tester.drag(
      find.byKey(const Key('habit-detail-scroll')),
      const Offset(0, -900),
    );
    await tester.pumpAndSettle();
    final noteHistory = find.byKey(const Key('habit-note-history'));
    expect(noteHistory, findsOneWidget);
    expect(find.text('读完后更容易专注'), findsOneWidget);
    expect(
      find.descendant(of: noteHistory, matching: find.text('7月')),
      findsOneWidget,
    );
    expect(
      find.descendant(of: noteHistory, matching: find.text('14')),
      findsOneWidget,
    );
  });
}

class _FailOnceRepository extends MemoryHabitRepository {
  _FailOnceRepository(super.value);
  bool failNext = false;
  @override
  Future<void> save(String value) async {
    if (failNext) {
      failNext = false;
      throw StateError('simulated disk full');
    }
    await super.save(value);
  }
}
