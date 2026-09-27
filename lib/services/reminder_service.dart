import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_10y.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/habit.dart';

enum ReminderActionType { complete, snooze }

class ReminderAction {
  const ReminderAction(this.type, this.habitId);

  final ReminderActionType type;
  final String habitId;
}

abstract class ReminderScheduler {
  Stream<ReminderAction> get actions;
  Future<bool> requestPermission();
  Future<void> syncHabit(Habit habit);
  Future<void> syncAll(Iterable<Habit> habits);
  Future<void> snooze(Habit habit);
}

class NoopReminderScheduler implements ReminderScheduler {
  @override
  Stream<ReminderAction> get actions => const Stream<ReminderAction>.empty();

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> snooze(Habit habit) async {}

  @override
  Future<void> syncAll(Iterable<Habit> habits) async {}

  @override
  Future<void> syncHabit(Habit habit) async {}
}

class LocalReminderService implements ReminderScheduler {
  static const _channelId = 'habit_reminders';
  static const _channelName = '习惯提醒';
  static const _channelDescription = '在设定的时间提醒你完成习惯';
  static const _categoryId = 'habit_actions';
  static const _completeAction = 'complete';
  static const _snoozeAction = 'snooze';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  final StreamController<ReminderAction> _actions =
      StreamController<ReminderAction>.broadcast();
  Future<void>? _initializing;

  @override
  Stream<ReminderAction> get actions => _actions.stream;

  Future<void> _ensureInitialized() =>
      _initializing ??= _initialize().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> _initialize() async {
    tz_data.initializeTimeZones();
    try {
      final timezone = await FlutterTimezone.getLocalTimezone();
      tz.setLocalLocation(tz.getLocation(timezone.identifier));
    } on Object {
      tz.setLocalLocation(tz.UTC);
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: <DarwinNotificationCategory>[
        DarwinNotificationCategory(
          _categoryId,
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.plain(_completeAction, '完成'),
            DarwinNotificationAction.plain(_snoozeAction, '稍后提醒'),
          ],
        ),
      ],
    );
    await _plugin.initialize(
      settings: InitializationSettings(android: android, iOS: darwin),
      onDidReceiveNotificationResponse: _handleResponse,
    );
  }

  void _handleResponse(NotificationResponse response) {
    final habitId = response.payload;
    if (habitId == null || habitId.isEmpty) return;
    if (response.actionId == _completeAction) {
      _actions.add(ReminderAction(ReminderActionType.complete, habitId));
    } else if (response.actionId == _snoozeAction) {
      _actions.add(ReminderAction(ReminderActionType.snooze, habitId));
    }
  }

  @override
  Future<bool> requestPermission() async {
    await _ensureInitialized();
    final android = _plugin
        .resolvePlatformSpecificImplementation<
          AndroidFlutterLocalNotificationsPlugin
        >();
    if (android != null) {
      return await android.requestNotificationsPermission() ?? true;
    }
    final ios = _plugin
        .resolvePlatformSpecificImplementation<
          IOSFlutterLocalNotificationsPlugin
        >();
    if (ios != null) {
      return await ios.requestPermissions(
            alert: true,
            badge: true,
            sound: true,
          ) ??
          true;
    }
    return true;
  }

  @override
  Future<void> syncAll(Iterable<Habit> habits) async {
    await _ensureInitialized();
    await _plugin.cancelAll();
    for (final habit in habits) {
      await syncHabit(habit);
    }
  }

  @override
  Future<void> syncHabit(Habit habit) async {
    await _ensureInitialized();
    await _cancelHabit(habit.id);
    final time = _parseTime(habit.reminderTime);
    if (time == null || habit.archived || habit.isPaused) return;

    for (var weekday = 1; weekday <= 7; weekday++) {
      await _plugin.zonedSchedule(
        id: _notificationId(habit.id, weekday),
        title: '${habit.emoji} ${habit.title}',
        body: '${executionLabel(habit)}，现在做一点就很好。完成后可以直接打卡。',
        scheduledDate: _nextWeekday(weekday, time.$1, time.$2),
        notificationDetails: _notificationDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        matchDateTimeComponents: DateTimeComponents.dayOfWeekAndTime,
        payload: habit.id,
      );
    }
  }

  @override
  Future<void> snooze(Habit habit) async {
    await _ensureInitialized();
    await _plugin.zonedSchedule(
      id: _notificationId(habit.id, 8),
      title: '${habit.emoji} ${habit.title}',
      body: '十分钟过去了，要不要现在完成一点？',
      scheduledDate: tz.TZDateTime.now(
        tz.local,
      ).add(const Duration(minutes: 10)),
      notificationDetails: _notificationDetails,
      androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
      payload: habit.id,
    );
  }

  Future<void> _cancelHabit(String habitId) async {
    for (var slot = 1; slot <= 8; slot++) {
      await _plugin.cancel(id: _notificationId(habitId, slot));
    }
  }

  (int, int)? _parseTime(String? value) {
    if (value == null) return null;
    final parts = value.split(':');
    if (parts.length != 2) return null;
    final hour = int.tryParse(parts[0]);
    final minute = int.tryParse(parts[1]);
    if (hour == null || minute == null) return null;
    return (hour, minute);
  }

  tz.TZDateTime _nextWeekday(int weekday, int hour, int minute) {
    final now = tz.TZDateTime.now(tz.local);
    var candidate = tz.TZDateTime(
      tz.local,
      now.year,
      now.month,
      now.day,
      hour,
      minute,
    );
    while (candidate.weekday != weekday || !candidate.isAfter(now)) {
      candidate = candidate.add(const Duration(days: 1));
    }
    return candidate;
  }

  int _notificationId(String habitId, int slot) =>
      (_stableHash(habitId) % 100000) * 10 + slot;

  int _stableHash(String value) {
    var hash = 0x811C9DC5;
    for (final unit in value.codeUnits) {
      hash ^= unit;
      hash = (hash * 0x01000193) & 0x7FFFFFFF;
    }
    return hash;
  }

  NotificationDetails get _notificationDetails => const NotificationDetails(
    android: AndroidNotificationDetails(
      _channelId,
      _channelName,
      channelDescription: _channelDescription,
      importance: Importance.high,
      priority: Priority.high,
      actions: <AndroidNotificationAction>[
        AndroidNotificationAction(
          _completeAction,
          '完成',
          showsUserInterface: true,
        ),
        AndroidNotificationAction(
          _snoozeAction,
          '十分钟后',
          showsUserInterface: true,
        ),
      ],
    ),
    iOS: DarwinNotificationDetails(categoryIdentifier: _categoryId),
  );
}
