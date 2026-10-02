import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_timezone/flutter_timezone.dart';

import 'models/habit.dart';
import 'data/habit_repository.dart';
import 'data/sqlite_habit_repository.dart';
import 'services/reminder_service.dart';
import 'services/background_tasks.dart';
import 'state/habit_controller.dart';
import 'ui/habit_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  var timezoneId = 'unknown';
  final controller = HabitController(
    LazyHabitRepository(SqliteHabitRepository.open),
    reminderScheduler: LocalReminderService(),
    timezoneId: () => timezoneId,
  );
  Future<void> refresh() async {
    try {
      timezoneId = (await FlutterTimezone.getLocalTimezone()).identifier;
    } on Object {
      timezoneId = 'unknown';
    }
    controller.refreshCalendar();
    if (controller.loaded) {
      unawaited(attemptForegroundBackup(controller.exportJson()));
    }
  }

  AppLifecycleListener(onResume: () => unawaited(refresh()));
  var lastDate = dateKey(DateTime.now());
  var lastOffset = DateTime.now().timeZoneOffset;
  Timer.periodic(const Duration(seconds: 30), (_) {
    final now = DateTime.now();
    if (dateKey(now) != lastDate || now.timeZoneOffset != lastOffset) {
      lastDate = dateKey(now);
      lastOffset = now.timeZoneOffset;
      unawaited(refresh());
    }
  });
  runApp(HabitApp(controller: controller));
  unawaited(() async {
    try {
      timezoneId = (await FlutterTimezone.getLocalTimezone()).identifier;
    } on Object {
      /* Preserve unknown instead of inventing a timezone. */
    }
    await controller.load();
    try {
      await initializeBackgroundTasks();
    } on Object {
      /* Foreground refresh remains available. */
    }
    if (controller.loaded) {
      unawaited(attemptForegroundBackup(controller.exportJson()));
    }
  }());
}
