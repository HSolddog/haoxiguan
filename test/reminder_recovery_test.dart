import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/reminder_service.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';
import 'package:haoxiguan/ui/reminder_settings_card.dart';

void main() {
  testWidgets('创建提醒被拒绝后关闭表单并当场说明，保存内容可重开', (tester) async {
    final repository = MemoryHabitRepository();
    final controller = HabitController(
      repository,
      reminderScheduler: _Reminders(ReminderAccess.appPermissionDenied),
    );
    addTearDown(controller.dispose);
    await controller.load();
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('add-habit-button')));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '拒权仍保存的阅读');
    final reminder = find.text('提醒时间');
    await tester.ensureVisible(reminder);
    await tester.tap(reminder);
    await tester.pumpAndSettle();
    final confirmLabel = MaterialLocalizations.of(
      tester.element(find.byType(TimePickerDialog)),
    ).okButtonLabel;
    await tester.tap(find.text(confirmLabel));
    await tester.pumpAndSettle();
    final save = find.byKey(const Key('save-habit-button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('save-habit-button')), findsNothing);
    expect(find.textContaining('提醒未获权限'), findsOneWidget);
    expect(controller.habits.single.reminderTime, '21:30');
    final reopened = HabitController(repository);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.habits.single.title, '拒权仍保存的阅读');
    expect(reopened.habits.single.reminderTime, '21:30');
  });

  test('拒权仍持久保存习惯与提醒选择，重开可读，授权后重建', () async {
    final repository = MemoryHabitRepository();
    final reminders = _Reminders(ReminderAccess.appPermissionDenied);
    final controller = HabitController(
      repository,
      clock: () => DateTime(2026, 10, 3, 12),
      reminderScheduler: reminders,
    );
    addTearDown(controller.dispose);
    await controller.load();
    expect(
      await controller.addHabit(
        title: '阅读',
        emoji: '📖',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        reminderTime: '21:00',
      ),
      isTrue,
    );
    expect(await controller.requestReminderPermission(), isFalse);
    expect(controller.saveError, isNull);
    expect(controller.reminderError, contains('提醒未获权限'));
    final reopened = HabitController(repository);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.habits.single.title, '阅读');
    expect(reopened.habits.single.reminderTime, '21:00');
    reminders.access = ReminderAccess.ready;
    expect(await controller.rebuildReminders(), isTrue);
    expect(controller.reminderError, isNull);
    expect(reminders.scheduled.single.id, controller.habits.single.id);
  });

  test('渠道关闭不能仅因应用权限已获准而报告提醒正常', () async {
    final reminders = _Reminders(ReminderAccess.channelDisabled);
    final controller = HabitController(
      MemoryHabitRepository(),
      reminderScheduler: reminders,
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.addHabit(
      title: '喝水',
      emoji: '💧',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      reminderTime: '21:00',
    );
    await controller.requestReminderPermission();
    expect(controller.reminderError, contains('习惯提醒渠道已关闭'));
    expect(await controller.rebuildReminders(), isFalse);
    expect(controller.habits.single.title, '喝水');
    expect(reminders.scheduled, isEmpty);
  });

  testWidgets('200%字号渠道修复返回后重新检查并重建，按钮至少48dp', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final reminders = _Reminders(ReminderAccess.channelDisabled);
    final controller = HabitController(
      MemoryHabitRepository(),
      reminderScheduler: reminders,
    );
    addTearDown(controller.dispose);
    await controller.load();
    await controller.addHabit(
      title: '阅读',
      emoji: '📖',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      reminderTime: '21:00',
    );
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
    expect(find.textContaining('习惯提醒渠道已关闭'), findsOneWidget);
    final settings = find.byKey(const Key('reminder-system-settings'));
    final rebuild = find.byKey(const Key('reminder-rebuild'));
    expect(tester.getSize(settings).height, greaterThanOrEqualTo(48));
    expect(tester.getSize(rebuild).height, greaterThanOrEqualTo(48));
    await tester.ensureVisible(settings);
    await tester.tap(settings);
    await tester.pumpAndSettle();
    expect(reminders.openedChannel, isTrue);
    reminders.access = ReminderAccess.ready;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(reminders.scheduled.single.title, '阅读');
    expect(find.text('已按当前习惯和记录重建提醒。'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('未修复与设置打开失败均显示实际原因', (tester) async {
    final reminders = _Reminders(ReminderAccess.appPermissionDenied)
      ..canOpenSettings = false;
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
    await tester.tap(find.byKey(const Key('reminder-system-settings')));
    await tester.pumpAndSettle();
    expect(find.textContaining('无法打开系统设置'), findsOneWidget);
    await tester.tap(find.byKey(const Key('reminder-rebuild')));
    await tester.pumpAndSettle();
    expect(find.textContaining('提醒未获权限'), findsNWidgets(2));
    expect(find.text('已按当前习惯和记录重建提醒。'), findsNothing);
  });
}

class _Reminders implements ReminderScheduler, ReminderDiagnostics {
  _Reminders(this.access);
  ReminderAccess access;
  bool? openedChannel;
  bool canOpenSettings = true;
  List<Habit> scheduled = [];
  @override
  Stream<ReminderAction> get actions => const Stream.empty();
  @override
  Future<ReminderAccess> readAccess() async => access;
  @override
  Future<bool> openSettings({bool channel = false}) async {
    openedChannel = channel;
    return canOpenSettings;
  }

  @override
  Future<bool> requestPermission() async =>
      access != ReminderAccess.appPermissionDenied;
  @override
  Future<void> syncAll(Iterable<Habit> habits) async {
    final enabled = habits.where((h) => h.reminderTime != null).toList();
    if (enabled.isNotEmpty && access != ReminderAccess.ready) {
      throw ReminderUnavailable(access);
    }
    scheduled = enabled;
  }

  @override
  Future<void> syncHabit(Habit habit) => syncAll([habit]);
  @override
  Future<void> snooze(Habit habit, {DateTime? forDate}) async {}
}
