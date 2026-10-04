import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';

// Real screens and persisted facts exercise custom colors after both theme
// generation and habit rendering. Passing these host checks is not a substitute
// for the separate physical Android TalkBack/200% workflow acceptance.
void main() {
  for (final scenario in const [
    (mode: 'light', seed: 0xffffffff, habitColor: 0xffffffff),
    (mode: 'light', seed: 0xff000000, habitColor: 0xffffff00),
    (mode: 'dark', seed: 0xff000000, habitColor: 0xff000000),
    (mode: 'dark', seed: 0xffffff00, habitColor: 0xff151515),
  ]) {
    final description =
        '${scenario.mode}, seed ${scenario.seed.toRadixString(16)}, '
        'habit ${scenario.habitColor.toRadixString(16)}';

    testWidgets('今日和回顾的极端颜色文本可读：$description', (tester) async {
      _smallScreen(tester);
      final controller = await _fixture(
        mode: scenario.mode,
        seed: scenario.seed,
        habitColor: scenario.habitColor,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(HabitApp(controller: controller));
      await tester.pumpAndSettle();

      await expectLater(
        tester,
        meetsGuideline(textContrastGuideline),
        reason: '今日页，$description',
      );
      await tester.tap(find.byIcon(Icons.insights_outlined));
      await tester.pumpAndSettle();
      await expectLater(
        tester,
        meetsGuideline(textContrastGuideline),
        reason: '回顾总览，$description',
      );
      await tester.scrollUntilVisible(
        find.byKey(Key('review-habit-${controller.habits.single.id}')),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await expectLater(
        tester,
        meetsGuideline(textContrastGuideline),
        reason: '单习惯历史，$description',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('日历完成日的极端颜色文本可读：$description', (tester) async {
      _smallScreen(tester);
      final controller = await _fixture(
        mode: scenario.mode,
        seed: scenario.seed,
        habitColor: scenario.habitColor,
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(HabitApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.text('喝水'));
      await tester.pumpAndSettle();
      final completedDay = _calendarDay('1');
      expect(completedDay, findsOneWidget);
      await Scrollable.ensureVisible(
        tester.element(completedDay),
        alignment: 0.5,
      );
      await tester.pumpAndSettle();
      expect(
        completedDay.hitTestable(),
        findsOneWidget,
        reason: '水平和垂直滚动后，待检查的完成日必须实际可见',
      );
      await expectLater(
        tester,
        meetsGuideline(textContrastGuideline),
        reason: '已完成的10月1日文字必须仍然可见，$description',
      );
      // The general guideline cannot match a custom semantic date label to its
      // numeric Text. Check this exact painted date as well, so white-on-white
      // text cannot pass merely because its semantic label is more descriptive.
      await expectLater(
        tester,
        meetsGuideline(
          CustomMinimumContrastGuideline(finder: completedDay.hitTestable()),
        ),
        reason: '日历数字的实际绘制对比度，$description',
      );
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('小屏今日与详情日历的操作至少48dp且有标签', (tester) async {
    _smallScreen(tester);
    final controller = await _fixture(
      mode: 'light',
      seed: 0xff5f8068,
      habitColor: 0xff5f8068,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));

    await tester.tap(find.text('喝水'));
    await tester.pumpAndSettle();
    final date = _calendarDay('1');
    expect(date, findsOneWidget);
    await Scrollable.ensureVisible(tester.element(date), alignment: 0.5);
    await tester.pumpAndSettle();
    expect(date.hitTestable(), findsOneWidget);
    final dayAction = find.ancestor(of: date, matching: find.byType(InkWell));
    expect(dayAction, findsOneWidget);
    expect(dayAction.hitTestable(), findsOneWidget);
    final daySize = tester.getSize(dayAction);
    expect(daySize.width, greaterThanOrEqualTo(48));
    expect(daySize.height, greaterThanOrEqualTo(48));
    await expectLater(
      tester,
      meetsGuideline(androidTapTargetGuideline),
      reason: '360dp屏幕上七列日历也不能挤小日期触控区域',
    );
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });

  testWidgets('创建习惯的颜色选择至少48dp且有语义标签', (tester) async {
    _smallScreen(tester);
    final controller = await _fixture(
      mode: 'light',
      seed: 0xff5f8068,
      habitColor: 0xff5f8068,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-habit-button')));
    await tester.pumpAndSettle();
    final advanced = find.byKey(const Key('habit-advanced-options'));
    await tester.ensureVisible(advanced);
    await tester.tap(advanced);
    await tester.pumpAndSettle();
    await Scrollable.ensureVisible(
      tester.element(find.text('主题颜色')),
      alignment: 0.1,
    );
    await tester.pumpAndSettle();
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });

  testWidgets('设置的主题颜色选择至少48dp且有语义标签', (tester) async {
    _smallScreen(tester);
    final controller = await _fixture(
      mode: 'dark',
      seed: 0xff5f8068,
      habitColor: 0xff5f8068,
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(NavigationDestination).last);
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('主题颜色'),
      300,
      scrollable: find.byType(Scrollable).first,
    );
    await Scrollable.ensureVisible(
      tester.element(find.text('主题颜色')),
      alignment: 0.5,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('主题颜色'));
    await tester.pumpAndSettle();
    expect(find.text('选择主题颜色'), findsOneWidget);
    await expectLater(tester, meetsGuideline(androidTapTargetGuideline));
    await expectLater(tester, meetsGuideline(labeledTapTargetGuideline));
    expect(tester.takeException(), isNull);
  });
}

Finder _calendarDay(String day) => find.descendant(
  of: find.descendant(
    of: find.byType(HabitDetailSheet),
    matching: find.byType(GridView),
  ),
  matching: find.text(day),
);

void _smallScreen(WidgetTester tester) {
  tester.view.physicalSize = const Size(360, 800);
  tester.view.devicePixelRatio = 1;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
  });
}

Future<HabitController> _fixture({
  required String mode,
  required int seed,
  required int habitColor,
}) async {
  var now = DateTime(2026, 10, 1, 10);
  final controller = HabitController(MemoryHabitRepository(), clock: () => now);
  await controller.load();
  await controller.setAppearanceMode(mode);
  await controller.setThemeColor(seed);
  await controller.addHabit(
    title: '喝水',
    emoji: '💧',
    colorValue: habitColor,
    weekdays: {1, 2, 3, 4, 5, 6, 7},
    recordType: 'count',
    unit: '杯',
    dailyTarget: 8,
  );
  final id = controller.habits.single.id;
  await controller.addValue(id, controller.today, 8);
  now = DateTime(2026, 10, 3, 10);
  await controller.addValue(id, controller.today, 1);
  return controller;
}
