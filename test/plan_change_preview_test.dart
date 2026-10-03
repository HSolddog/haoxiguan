import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';
import 'package:haoxiguan/ui/habit_history.dart';

void main() {
  testWidgets('200%编辑先显示具体生效日与旧新目标，保存后旧事实和首周期缩减说明不变', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final repository = MemoryHabitRepository();
    final controller = HabitController(
      repository,
      clock: () => DateTime(2026, 10, 3),
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(
      await controller.addHabit(
        title: '按周喝水',
        emoji: '💧',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        startDate: DateTime(2026, 9, 30),
        recordType: 'count',
        unit: '杯',
        scale: 1000,
        dailyTarget: 8000,
        scheduleType: 'week',
        scheduleCount: 6,
      ),
      isTrue,
    );
    final id = controller.habits.single.id;
    await controller.addValue(id, DateTime(2026, 10, 2), 8000);
    await controller.addValue(id, controller.today, 8000);
    await controller.setNote(id, DateTime(2026, 10, 2), '旧目标下的原始备注');
    final before = controller.habits.single;
    final beforeJson = before.toJson();
    final beforeRaw = repository.value;
    final oldPlan = before.effectivePlans.single.toJson();
    final entries = before.entries.map((entry) => entry.toJson()).toList();
    final notes = {...before.notes};

    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAddHabitSheet(
                context,
                controller,
                habit: controller.habitById(id),
              ),
              child: const Text('编辑计划'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('编辑计划'));
    await tester.pumpAndSettle();

    Future<void> reveal(Finder finder) async {
      await Scrollable.ensureVisible(tester.element(finder), alignment: 0.5);
      await tester.pumpAndSettle();
      expect(finder.hitTestable(), findsOneWidget);
      expect(tester.takeException(), isNull);
    }

    final target = find.byKey(const Key('daily-target-field'));
    await reveal(target);
    await tester.enterText(target, '6');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    // Use the production frequency dropdown rather than calling its callback.
    final frequency = find.byWidgetPredicate(
      (widget) =>
          widget is DropdownButtonFormField<String> &&
          widget.decoration.labelText == '计划',
    );
    expect(frequency, findsOneWidget);
    // The FormField also includes its floating label/decoration. Tap the
    // visible selected item inside the actual dropdown hit region instead.
    final selectedFrequency = find.descendant(
      of: frequency,
      matching: find.text('每周 N 天'),
    );
    await reveal(selectedFrequency);
    await tester.tap(selectedFrequency);
    await tester.pumpAndSettle();
    await tester.tap(find.text('每天').last);
    await tester.pumpAndSettle();

    final preview = find.byKey(const Key('future-plan-preview'));
    await reveal(preview);
    final previewText = tester.widget<Text>(preview).data!;
    expect(previewText, contains('从 2026-10-05 生效'));
    expect(previewText, contains('每周 6 天、每日 8 杯 → 每天、每日 6 杯'));
    expect(previewText, contains('此前计划和事实保持不变'));
    expect(repository.value, beforeRaw);
    expect(controller.habitById(id)!.toJson(), beforeJson);

    final save = find.byKey(const Key('save-habit-button'));
    await reveal(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('future-plan-preview')), findsNothing);
    expect(tester.takeException(), isNull);

    final saved = controller.habitById(id)!;
    expect(saved.effectivePlans, hasLength(2));
    expect(saved.effectivePlans.first.toJson(), oldPlan);
    final future = saved.effectivePlans.last;
    expect(future.id, isNot(oldPlan['id']));
    expect(future.from, DateTime.utc(2026, 10, 5));
    expect(future.kind, 'daily');
    expect(future.dailyTarget, 6000);
    expect(saved.planOn(DateTime(2026, 10, 4)).toJson(), oldPlan);
    expect(saved.planOn(DateTime(2026, 10, 5)).id, future.id);
    expect(saved.entries.map((entry) => entry.toJson()).toList(), entries);
    expect(saved.notes, notes);
    expect(saved.createdAt, before.createdAt);

    final reopened = HabitController(
      repository,
      clock: () => DateTime(2026, 10, 3),
    );
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.habitById(id)!.toJson(), saved.toJson());
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: HabitHistorySummary(
              controller: reopened,
              habit: reopened.habitById(id)!,
              days: 30,
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    final period = find.textContaining('配置目标 6 天；本周期仅 5 个有效日期');
    await reveal(period);
    final periodText = tester.widget<Text>(period).data!;
    expect(periodText, contains('2026-09-30 至 2026-10-04'));
    expect(periodText, contains('完成 2 天 / 实际目标 5 天'));
    expect(periodText, contains('进行中（未结算）'));
    expect(periodText, contains('开始前、暂停、休息和归档区间均已排除'));
  });
}
