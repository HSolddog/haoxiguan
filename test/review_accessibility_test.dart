import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';

void main() {
  testWidgets('回顾热图读屏说明日期与计划状态且不重复朗读数字', (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      final controller = HabitController(
        MemoryHabitRepository(),
        clock: () => DateTime(2026, 10, 3),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.setReviewDays(7);
      await controller.addHabit(
        title: '阅读',
        emoji: '📖',
        colorValue: 0xffffffff,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        startDate: DateTime(2026, 10, 1),
      );
      await controller.toggleCompletion(
        controller.habits.single.id,
        DateTime(2026, 10, 1),
      );
      await tester.pumpWidget(HabitApp(controller: controller));
      await tester.pumpAndSettle();
      await tester.tap(find.byIcon(Icons.insights_outlined));
      await tester.pumpAndSettle();
      final current = find.byKey(const Key('review-day-2026-10-03'));
      await tester.scrollUntilVisible(
        current,
        100,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      expect(tester.getSemantics(current).label, '2026年10月3日，进行中，已完成0项，计划1项');
      expect(
        tester
            .getSemantics(find.byKey(const Key('review-day-2026-10-01')))
            .label,
        '2026年10月1日，已完成1项，计划1项',
      );
      expect(
        tester
            .getSemantics(find.byKey(const Key('review-day-2026-09-30')))
            .label,
        '2026年9月30日，暂无已结算计划',
      );
      expect(find.textContaining('✓ 全部完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    } finally {
      semantics.dispose();
    }
  });

  testWidgets('减少动态与200%字号仍能完成创建并读取回顾状态', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    tester.platformDispatcher.accessibilityFeaturesTestValue =
        const FakeAccessibilityFeatures(disableAnimations: true);
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
      tester.platformDispatcher.clearAccessibilityFeaturesTestValue();
    });
    final controller = HabitController(
      MemoryHabitRepository(),
      clock: () => DateTime(2026, 10, 3),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.setReviewDays(7);
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-habit-button')));
    await tester.pumpAndSettle();
    final padding = tester.widget<AnimatedPadding>(
      find.descendant(
        of: find.byType(AddHabitSheet),
        matching: find.byType(AnimatedPadding),
      ),
    );
    expect(padding.duration, Duration.zero);
    await tester.enterText(
      find.byKey(const Key('habit-title-field')),
      '减少动态下创建',
    );
    final save = find.byKey(const Key('save-habit-button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(controller.habits.single.title, '减少动态下创建');
    await tester.tap(find.byIcon(Icons.insights_outlined));
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.byKey(const Key('review-day-2026-10-03')),
      150,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
  });
}
