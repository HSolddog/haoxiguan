import 'support/legacy_fixture.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';
import 'package:haoxiguan/ui/record_editor.dart';

void main() {
  late HabitController controller;

  setUp(() async {
    controller = HabitController(
      MemoryHabitRepository(legacyFixture(DateTime(2026, 7, 15, 10, 30))),
      clock: () => DateTime(2026, 7, 15, 10, 30),
    );
    await controller.load();
  });

  testWidgets('小屏 200% 字号仍能显示今日、创建和数据入口', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.tap(find.byKey(const Key('add-habit-button')));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });

  testWidgets('今日页可以完成并撤销习惯', (tester) async {
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('0/2'), findsOneWidget);
    for (final category in controller.categoryGroups) {
      await tester.scrollUntilVisible(
        find.byKey(Key('today-category-${category.id}')),
        120,
      );
      expect(find.byKey(Key('today-category-${category.id}')), findsOneWidget);
    }

    await tester.scrollUntilVisible(
      find.byKey(const Key('complete-seed-reading-false')),
      120,
    );
    expect(find.text('阅读 20 分钟'), findsOneWidget);

    await tester.tap(find.byKey(const Key('complete-seed-reading-false')));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(find.text('1/2'), -150);
    expect(find.text('1/2'), findsOneWidget);

    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(find.text('0/2'), findsOneWidget);
  });

  testWidgets('记录明细只撤销选中的一条，保留其他数值和备注', (tester) async {
    await controller.addHabit(
      title: '喝水',
      emoji: '🌱',
      colorValue: 0xff000000,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: 'count',
      dailyTarget: 8,
    );
    final id = controller.habits.last.id;
    await controller.addValue(id, controller.today, 2);
    await controller.addValue(id, controller.today, 3);
    await controller.setNote(id, controller.today, '备注保留');
    final removedId = controller.habitById(id)!.entries.first.id;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRecordEditor(
                context,
                controller,
                controller.habitById(id)!,
                controller.today,
              ),
              child: const Text('记录'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('记录'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('record-facts')));
    await tester.pumpAndSettle();
    final undo = find.byKey(Key('delete-entry-$removedId'));
    await tester.ensureVisible(undo);
    await tester.tap(undo);
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, '撤销这条记录'));
    await tester.pumpAndSettle();
    expect(controller.habitById(id)!.valueOn(controller.today), 3);
    expect(controller.habitById(id)!.noteOn(controller.today), '备注保留');
    expect(find.text('目前 3 次'), findsOneWidget);
    expect(find.byKey(Key('delete-entry-$removedId')), findsNothing);
    expect(tester.takeException(), isNull);
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

    final learningId = controller.habitById('seed-reading')!.categoryId!;
    final todayToggle = find.byKey(Key('today-category-toggle-$learningId'));
    await tester.scrollUntilVisible(
      find.byKey(const Key('complete-seed-reading-false')),
      120,
    );
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
    await tester.tap(find.byKey(Key('habits-category-toggle-$learningId')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('manage-habit-seed-reading')), findsNothing);
    expect(controller.isHabitCategoryCollapsed('学习'), isTrue);
    expect(controller.isTodayCategoryCollapsed('学习'), isTrue);
  });

  testWidgets('新建不显示奖惩开关，旧版奖励在数据页只读保留', (tester) async {
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-habit-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('effort-enabled-switch')), findsNothing);
    expect(find.byKey(const Key('wish-enabled-switch')), findsNothing);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byIcon(Icons.settings_outlined));
    await tester.pumpAndSettle();
    await tester.drag(
      find.byKey(const PageStorageKey<String>('data-scroll')),
      const Offset(0, -1000),
    );
    await tester.pumpAndSettle();
    final legacy = find.text('旧版奖励（只读）');
    await tester.ensureVisible(legacy);
    expect(legacy, findsOneWidget);
  });

  testWidgets('计数记录入口输入实际数值并累加', (tester) async {
    await controller.addHabit(
      title: '喝水计数',
      emoji: '💧',
      colorValue: 0xFF5F8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: 'count',
      unit: '杯',
      scale: 1000,
      dailyTarget: 8000,
    );
    final id = controller.habits.last.id;
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    expect(controller.habitById(id)!.recordType, 'count');
    await tester.drag(
      find.byKey(const PageStorageKey<String>('today-scroll')),
      const Offset(0, -600),
    );
    await tester.pumpAndSettle();
    final record = find.byKey(Key('record-custom-$id'));
    await tester.ensureVisible(record);
    await tester.tap(record);
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const Key('record-value-field')), '2.5');
    await tester.tap(find.byKey(const Key('save-record-button')));
    await tester.pumpAndSettle();
    expect(controller.habitById(id)!.valueOn(controller.today), 2500);
    expect(find.byKey(const Key('record-value-field')), findsNothing);
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
