import 'dart:async';
import 'dart:convert';
import 'dart:io';
import '../data/sqlite_habit_repository.dart';
import '../data/snapshot_codec.dart';
import 'device_task_lock.dart';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_10y.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../models/habit.dart';
import 'reminder_access.dart';
import 'reminder_plan.dart';

export 'reminder_access.dart';

enum ReminderActionType { complete, snooze }

class ReminderAction {
  const ReminderAction(this.type, this.habitId, {this.localDate});

  final ReminderActionType type;
  final String habitId;
  final String? localDate;
}

abstract class ReminderScheduler {
  Stream<ReminderAction> get actions;
  Future<bool> requestPermission();
  Future<void> syncHabit(Habit habit);
  Future<void> syncAll(Iterable<Habit> habits);
  Future<void> snooze(Habit habit, {DateTime? forDate});
}

class NoopReminderScheduler implements ReminderScheduler {
  @override
  Stream<ReminderAction> get actions => const Stream<ReminderAction>.empty();

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> snooze(Habit habit, {DateTime? forDate}) async {}

  @override
  Future<void> syncAll(Iterable<Habit> habits) async {}

  @override
  Future<void> syncHabit(Habit habit) async {}
}

class LocalReminderService implements ReminderScheduler, ReminderDiagnostics {
  LocalReminderService({this.handleLaunchActions = true});
  final bool handleLaunchActions;
  static const _channelId = DeviceReminderDiagnostics.channelId;
  static const _channelName = '习惯提醒';
  static const _channelDescription = '在设定的时间提醒你完成习惯';
  static const _categoryId = 'habit_actions';
  static const _completeAction = 'complete';
  static const _snoozeAction = 'snooze';

  final FlutterLocalNotificationsPlugin _plugin =
      FlutterLocalNotificationsPlugin();
  late final _diagnostics = DeviceReminderDiagnostics(_plugin);
  final StreamController<ReminderAction> _actions =
      StreamController<ReminderAction>.broadcast();
  Future<void>? _initializing;
  Future<void>? _scheduleQueue;
  List<Habit> _knownHabits = [];

  @override
  Stream<ReminderAction> get actions => _actions.stream;

  Future<void> _ensureInitialized() =>
      _initializing ??= _initialize().catchError((Object error) {
        _initializing = null;
        throw error;
      });

  Future<void> _initialize() async {
    tz_data.initializeTimeZones();
    await _refreshTimezone();

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
      notificationCategories: <DarwinNotificationCategory>[
        DarwinNotificationCategory(
          _categoryId,
          actions: <DarwinNotificationAction>[
            DarwinNotificationAction.plain(_completeAction, '记录'),
            DarwinNotificationAction.plain(_snoozeAction, '稍后提醒'),
          ],
        ),
      ],
    );
    await _plugin.initialize(
      settings: InitializationSettings(android: android, iOS: darwin),
      onDidReceiveNotificationResponse: _handleResponse,
    );
    final launch = await _plugin.getNotificationAppLaunchDetails();
    if (handleLaunchActions &&
        launch?.didNotificationLaunchApp == true &&
        launch?.notificationResponse != null) {
      _handleResponse(launch!.notificationResponse!);
    }
  }

  Future<void> _refreshTimezone() async {
    final timezone = await FlutterTimezone.getLocalTimezone();
    tz.setLocalLocation(tz.getLocation(timezone.identifier));
  }

  void _handleResponse(NotificationResponse response) {
    try {
      final payload =
          jsonDecode(response.payload ?? '') as Map<String, dynamic>;
      if (payload['v'] != 1 ||
          payload['habitId'] is! String ||
          payload['date'] is! String) {
        return;
      }
      final type = response.actionId == _snoozeAction
          ? ReminderActionType.snooze
          : ReminderActionType.complete;
      // Tapping the notification body only opens the app; an explicit action records.
      if (response.actionId != _completeAction &&
          response.actionId != _snoozeAction) {
        return;
      }
      _actions.add(
        ReminderAction(
          type,
          payload['habitId'] as String,
          localDate: payload['date'] as String,
        ),
      );
    } on Object {
      /* Old undated payloads cannot safely record today's date. */
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
  Future<ReminderAccess> readAccess() async {
    try {
      await _ensureInitialized();
      return await _diagnostics.readAccess();
    } on Object {
      return ReminderAccess.unavailable;
    }
  }

  @override
  Future<bool> openSettings({bool channel = false}) =>
      _diagnostics.openSettings(channel: channel);

  Future<void> _requireAccess() async {
    final access = await readAccess();
    if (access != ReminderAccess.ready) throw ReminderUnavailable(access);
  }

  @override
  Future<void> syncAll(Iterable<Habit> habits) {
    var snapshot = List<Habit>.of(habits);
    Future<void> perform() async {
      await _ensureInitialized();
      await _refreshTimezone();
      if (Platform.isAndroid) {
        final repository = await SqliteHabitRepository.open();
        try {
          final raw = await repository.load();
          if (raw == null) return;
          snapshot = (SnapshotCodec.decode(raw)['habits'] as List)
              .map((h) => Habit.fromJson((h as Map).cast<String, Object?>()))
              .toList();
        } finally {
          await repository.close();
        }
      }
      _knownHabits = snapshot;
      final plan = buildReminderPlan(snapshot, DateTime.now());
      final pending = await _plugin.pendingNotificationRequests();
      final snoozes = <({Habit habit, String date, DateTime at})>[];
      for (final notification in pending) {
        try {
          final payload = jsonDecode(notification.payload ?? '') as Map;
          final at = DateTime.tryParse(payload['snoozeAt'] as String? ?? '');
          final habit = snapshot
              .where((h) => h.id == payload['habitId'])
              .firstOrNull;
          final date = payload['date'] as String;
          if (at != null &&
              at.isAfter(DateTime.now()) &&
              habit != null &&
              !habit.archived &&
              !habit.inTrash &&
              !habit.isPaused &&
              !habit.isCompletedOn(DateTime.parse(date))) {
            snoozes.add((habit: habit, date: date, at: at));
          }
        } on Object {
          /* Only our valid dated snoozes can be preserved. */
        }
      }
      await _plugin.cancelAll();
      if (plan.isNotEmpty || snoozes.isNotEmpty) await _requireAccess();
      for (var index = 0; index < plan.length; index++) {
        final item = plan[index];
        await _plugin.zonedSchedule(
          id: index + 1,
          title: '${item.habit.emoji} ${item.habit.title}',
          body:
              '${dateKey(item.date)} · ${item.habit.recordType == 'boolean' ? '完成后可直接打卡' : '点记录后填写实际数值'}',
          scheduledDate: tz.TZDateTime(
            tz.local,
            item.date.year,
            item.date.month,
            item.date.day,
            item.hour,
            item.minute,
          ),
          notificationDetails: _notificationDetails,
          androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
          payload: jsonEncode({
            'v': 1,
            'habitId': item.habit.id,
            'date': dateKey(item.date),
          }),
        );
      }
      for (var index = 0; index < snoozes.length; index++) {
        final item = snoozes[index];
        await _scheduleSnooze(1000 + index, item.habit, item.date, item.at);
      }
    }

    return _enqueue(perform);
  }

  Future<void> _enqueue(Future<void> Function() perform) {
    final unlocked = perform;
    perform = () => DeviceTaskLock.run('reminders', unlocked);
    final prior = _scheduleQueue;
    final result = prior == null
        ? Future<void>.sync(perform)
        : prior.then((_) => perform());
    late Future<void> tail;
    void release() {
      if (identical(_scheduleQueue, tail)) _scheduleQueue = null;
    }

    tail = result.then(
      (_) => release(),
      onError: (Object _, StackTrace _) => release(),
    );
    _scheduleQueue = tail;
    return result;
  }

  @override
  Future<void> syncHabit(Habit habit) =>
      syncAll([..._knownHabits.where((h) => h.id != habit.id), habit]);

  @override
  Future<void> snooze(Habit habit, {DateTime? forDate}) => _enqueue(() async {
    var current = habit;
    // The callback may have waited behind a newer completion/pause or a
    // background scheduler. Read committed facts only after taking the lock.
    if (Platform.isAndroid) {
      final repository = await SqliteHabitRepository.open();
      try {
        final raw = await repository.load();
        if (raw == null) return;
        final latest = (SnapshotCodec.decode(raw)['habits'] as List)
            .map((h) => Habit.fromJson((h as Map).cast<String, Object?>()))
            .where((h) => h.id == habit.id)
            .firstOrNull;
        if (latest == null) return;
        current = latest;
      } finally {
        await repository.close();
      }
    }
    if (current.archived || current.inTrash || current.isPaused) return;
    await _ensureInitialized();
    await _refreshTimezone();
    final date = dateKey(forDate ?? DateTime.now());
    if (current.isCompletedOn(DateTime.parse(date))) return;
    await _requireAccess();
    final pending = await _plugin.pendingNotificationRequests();
    final ids = pending.map((r) => r.id).toSet();
    for (final item in pending) {
      try {
        final payload = jsonDecode(item.payload ?? '') as Map;
        if (payload['habitId'] == current.id &&
            payload['date'] == date &&
            payload['snoozeAt'] != null) {
          await _plugin.cancel(id: item.id);
          ids.remove(item.id);
        }
      } on Object {
        /* Ignore notifications not owned by this format. */
      }
    }
    var id = 1000;
    while (ids.contains(id)) {
      id++;
    }
    await _scheduleSnooze(
      id,
      current,
      date,
      DateTime.now().add(const Duration(minutes: 10)),
    );
  });

  Future<void> _scheduleSnooze(int id, Habit habit, String date, DateTime at) =>
      _plugin.zonedSchedule(
        id: id,
        title: '${habit.emoji} ${habit.title}',
        body: '$date · 十分钟过去了，可以记录一点进展。',
        scheduledDate: tz.TZDateTime.from(at, tz.local),
        notificationDetails: _notificationDetails,
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: jsonEncode({
          'v': 1,
          'habitId': habit.id,
          'date': date,
          'snoozeAt': at.toUtc().toIso8601String(),
        }),
      );

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
          '记录',
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
