import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';

void main() {
  for (final recordType in ['count', 'duration']) {
    testWidgets('200%小屏完成$recordType今日快捷记录与安全撤销', (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });

      final duration = recordType == 'duration';
      final repository = MemoryHabitRepository();
      final controller = HabitController(
        repository,
        clock: () => DateTime(2026, 10, 3, 10),
      );
      addTearDown(controller.dispose);
      await controller.load();
      await controller.addHabit(
        title: duration ? '阅读' : '喝水',
        emoji: duration ? '📖' : '💧',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        recordType: recordType,
        unit: duration ? '秒' : '杯',
        scale: duration ? 1 : 1000,
        dailyTarget: duration ? 1200 : 8000,
      );
      final id = controller.habits.single.id;
      final previousValue = duration ? 90 : 2000;
      final laterValue = duration ? 30 : 1000;
      final increment = duration ? 300 : 1000;
      await controller.addValue(id, controller.today, previousValue);
      await controller.setNote(id, controller.today, '原有备注保留');
      final previousEntry = controller.habits.single.entries.single.toJson();

      await tester.pumpWidget(HabitApp(controller: controller));
      await tester.pumpAndSettle();
      final quick = find.byKey(Key('quick-$id'));
      await tester.scrollUntilVisible(
        quick,
        200,
        scrollable: find
            .descendant(
              of: find.byType(TodayScreen),
              matching: find.byType(Scrollable),
            )
            .first,
      );
      await Scrollable.ensureVisible(tester.element(quick), alignment: 0.5);
      await tester.pumpAndSettle();
      expect(find.text(duration ? '＋5 分钟' : '＋1 杯'), findsOneWidget);
      final size = tester.getSize(quick);
      expect(size.width, greaterThanOrEqualTo(48));
      expect(size.height, greaterThanOrEqualTo(48));
      expect(tester.takeException(), isNull);

      await tester.tap(quick);
      await tester.pumpAndSettle();
      expect(
        controller.habits.single.valueOn(controller.today),
        previousValue + increment,
      );
      expect(
        find.textContaining(duration ? '已增加 5分' : '已增加 1 杯'),
        findsOneWidget,
      );
      expect(find.widgetWithText(SnackBarAction, '撤销'), findsOneWidget);
      expect(tester.takeException(), isNull);

      // A distinct action arriving while Undo is visible must not be replaced
      // by an old whole-habit snapshot when the user undoes the quick action.
      await controller.addValue(id, controller.today, laterValue);
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(SnackBarAction, '撤销'));
      await tester.pumpAndSettle();
      final habit = controller.habits.single;
      expect(habit.valueOn(controller.today), previousValue + laterValue);
      expect(habit.noteOn(controller.today), '原有备注保留');
      expect(
        habit.entries
            .singleWhere((entry) => entry.id == previousEntry['id'])
            .toJson(),
        previousEntry,
      );
      expect(habit.entries.where((entry) => !entry.deleted), hasLength(2));
      expect(tester.takeException(), isNull);

      final reopened = HabitController(
        repository,
        clock: () => DateTime(2026, 10, 3, 10),
      );
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(
        reopened.habits.single.valueOn(reopened.today),
        previousValue + laterValue,
      );
      expect(reopened.habits.single.noteOn(reopened.today), '原有备注保留');
    });
  }
}
