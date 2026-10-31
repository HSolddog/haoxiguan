import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';

void main() {
  testWidgets('达标后的周计划留在今日，日历可补卡，不能打的日期会说明原因', (tester) async {
    final today = DateTime(2026, 7, 18, 9);
    final controller = HabitController(
      MemoryHabitRepository(),
      clock: () => today,
    );
    await controller.load();
    expect(
      await controller.addHabit(
        startDate: DateTime(2026, 7, 13),
        title: '灵活运动',
        emoji: '🏃',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        scheduleType: 'week',
        scheduleCount: 3,
      ),
      isTrue,
    );
    final id = controller.habits.single.id;
    for (final day in [13, 14, 15, 17]) {
      expect(
        await controller.markCompleted(id, DateTime(2026, 7, day)),
        isTrue,
      );
    }
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();

    expect(find.text('今天没有安排'), findsNothing);
    expect(find.text('灵活运动'), findsOneWidget);
    final label = find.text('本周已达标 4/3');
    expect(label, findsOneWidget);
    final color = tester.widget<Text>(label).style?.color;
    expect(color, isNotNull);
    expect(color!.g, greaterThan(color.r));
    expect(color.g, greaterThan(color.b));

    await tester.tap(find.text('灵活运动'));
    await tester.pumpAndSettle();
    Future<void> tapDay(int day) async {
      final finder = find.byKey(Key('detail-day-2026-07-${_two(day)}'));
      await tester.ensureVisible(finder);
      await tester.pumpAndSettle();
      await tester.tap(finder);
      await tester.pumpAndSettle();
    }

    await tapDay(19);
    expect(find.text('不能为未来日期打卡'), findsWidgets);
    expect(
      controller.habitById(id)!.isCompletedOn(DateTime(2026, 7, 19)),
      isFalse,
    );
    await tapDay(12);
    expect(find.text('早于开始日期，不能补卡'), findsWidgets);
    expect(
      controller.habitById(id)!.isCompletedOn(DateTime(2026, 7, 12)),
      isFalse,
    );
    await tapDay(16);
    expect(
      controller.habitById(id)!.isCompletedOn(DateTime(2026, 7, 16)),
      isTrue,
    );

    Navigator.of(tester.element(find.byType(HabitDetailSheet))).pop();
    await tester.pumpAndSettle();
    expect(find.text('本周已达标 5/3'), findsOneWidget);

    await tester.tap(find.byTooltip('完成'));
    await tester.pumpAndSettle();
    expect(controller.habitById(id)!.isCompletedOn(today), isTrue);
    expect(find.text('本周已达标 6/3'), findsOneWidget);
  });

  testWidgets('休息日和计划外星期点击时说明原因，不写入打卡', (tester) async {
    final today = DateTime(2026, 7, 14, 9);
    final controller = HabitController(
      MemoryHabitRepository(),
      clock: () => today,
    );
    await controller.load();
    expect(
      await controller.addHabit(
        title: '休息中',
        emoji: '😴',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        scheduleType: 'week',
        scheduleCount: 3,
      ),
      isTrue,
    );
    final rested = controller.habits.single.id;
    expect(await controller.toggleRest(rested, today), isTrue);
    expect(
      await controller.addHabit(
        title: '指定星期',
        emoji: '📅',
        colorValue: 0xff806a9a,
        weekdays: {1, 3, 5},
        scheduleType: 'weekdays',
      ),
      isTrue,
    );
    final weekdays = controller.habits.last.id;
    addTearDown(controller.dispose);
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => Column(
              children: [
                TextButton(
                  onPressed: () => showHabitDetail(context, controller, rested),
                  child: const Text('打开休息'),
                ),
                TextButton(
                  onPressed: () =>
                      showHabitDetail(context, controller, weekdays),
                  child: const Text('打开星期'),
                ),
              ],
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开休息'));
    await tester.pumpAndSettle();
    final todayKey = find.byKey(Key('detail-day-${dateKey(today)}'));
    await tester.ensureVisible(todayKey);
    await tester.tap(todayKey);
    await tester.pumpAndSettle();
    expect(find.text('休息日不能打卡，长按可取消休息'), findsWidgets);
    expect(controller.habitById(rested)!.isCompletedOn(today), isFalse);

    Navigator.of(tester.element(find.byType(HabitDetailSheet))).pop();
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开星期'));
    await tester.pumpAndSettle();
    final offDay = find.byKey(Key('detail-day-${dateKey(today)}'));
    await tester.ensureVisible(offDay);
    await tester.tap(offDay);
    await tester.pumpAndSettle();
    expect(find.text('这一天不在计划星期内'), findsWidgets);
    expect(controller.habitById(weekdays)!.isCompletedOn(today), isFalse);
  });
}

String _two(int day) => day.toString().padLeft(2, '0');
