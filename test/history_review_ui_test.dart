import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_history.dart';

void main() {
  late HabitController controller;
  setUp(() async {
    controller = HabitController(
      MemoryHabitRepository(),
      clock: () => DateTime(2026, 10, 3),
    );
    await controller.load();
    await controller.addHabit(
      title: '校正',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      scheduleType: 'week',
      scheduleCount: 3,
    );
  });
  tearDown(() => controller.dispose());

  testWidgets('零分母显示暂无已结算，进行中逐周期显示实际目标和连续单位', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: HabitHistorySummary(
            controller: controller,
            habit: controller.habits.single,
            days: 30,
          ),
        ),
      ),
    );
    expect(find.textContaining('暂无已结算计划'), findsOneWidget);
    expect(find.textContaining('完成 0 天 / 实际目标 2 天'), findsOneWidget);
    expect(find.textContaining('进行中（未结算）'), findsOneWidget);
    expect(find.text('当前连续 0 周'), findsOneWidget);
    expect(find.text('历史最佳 0 周'), findsOneWidget);
    expect(find.textContaining('0%'), findsNothing);
  });

  testWidgets('历史校正UI必须经影响预览确认，取消不修改', (tester) async {
    final id = controller.habits.single.id;
    await controller.markCompleted(id, controller.today);
    await controller.setNote(id, controller.today, '原备注');
    final entry = controller.habits.single.entries.single;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showStartDateCorrection(
                context,
                controller,
                controller.habits.single,
              ),
              child: const Text('历史校正'),
            ),
          ),
        ),
      ),
    );
    for (final confirm in [false, true]) {
      await tester.tap(find.text('历史校正'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(find.text('历史校正影响预览'), findsOneWidget);
      expect(find.textContaining('2026-10-03 → 2026-10-02'), findsOneWidget);
      expect(find.textContaining('完成 1 天 / 实际目标 3 天'), findsOneWidget);
      expect(controller.habits.single.createdAt, DateTime.utc(2026, 10, 3));
      await tester.tap(
        confirm
            ? find.byKey(const Key('confirm-start-correction'))
            : find.text('取消'),
      );
      await tester.pumpAndSettle();
    }
    expect(controller.habits.single.createdAt, DateTime.utc(2026, 10, 2));
    expect(controller.habits.single.entries.single.toJson(), entry.toJson());
    expect(controller.habits.single.noteOn(controller.today), '原备注');
  });
}
