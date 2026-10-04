import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/reminder_service.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/reminder_settings_card.dart';

class _StatusReminders implements ReminderScheduler, ReminderDiagnostics {
  ReminderAccess access = ReminderAccess.ready;
  bool failScheduling = false;
  @override
  Stream<ReminderAction> get actions => const Stream.empty();
  @override
  Future<ReminderAccess> readAccess() async => access;
  @override
  Future<bool> openSettings({bool channel = false}) async => true;
  @override
  Future<bool> requestPermission() async => access == ReminderAccess.ready;
  @override
  Future<void> syncAll(Iterable<Habit> habits) async {
    if (failScheduling) throw StateError('scheduling failed');
  }

  @override
  Future<void> syncHabit(Habit habit) => syncAll([habit]);
  @override
  Future<void> snooze(Habit habit, {DateTime? forDate}) async {}
}

void main() {
  testWidgets('权限正常仍显示自动调度失败，重建成功后移除过期错误', (tester) async {
    final reminders = _StatusReminders();
    final controller = HabitController(
      MemoryHabitRepository(),
      reminderScheduler: reminders,
    );
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReminderSettingsCard(controller: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    reminders.failScheduling = true;
    expect(await controller.rebuildReminders(), isFalse);
    await tester.pumpAndSettle();
    expect(find.textContaining('通知权限可用'), findsOneWidget);
    expect(find.textContaining('提醒未能更新'), findsOneWidget);
    reminders.failScheduling = false;
    expect(await controller.rebuildReminders(), isTrue);
    await tester.pumpAndSettle();
    expect(find.textContaining('提醒未能更新'), findsNothing);
  });

  testWidgets('从系统外部改变通知权限返回应用也刷新可见状态', (tester) async {
    final reminders = _StatusReminders()
      ..access = ReminderAccess.appPermissionDenied;
    final controller = HabitController(
      MemoryHabitRepository(),
      reminderScheduler: reminders,
    );
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: ReminderSettingsCard(controller: controller),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.textContaining('提醒未获权限'), findsOneWidget);
    reminders.access = ReminderAccess.ready;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(find.textContaining('提醒未获权限'), findsNothing);
    expect(find.textContaining('通知权限可用'), findsOneWidget);
  });
}
