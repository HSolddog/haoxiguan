import 'package:flutter/material.dart';

import 'data/habit_repository.dart';
import 'services/reminder_service.dart';
import 'state/habit_controller.dart';
import 'ui/habit_app.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final controller = HabitController(
    SharedPreferencesHabitRepository(),
    reminderScheduler: LocalReminderService(),
  );
  await controller.load();
  runApp(HabitApp(controller: controller));
}
