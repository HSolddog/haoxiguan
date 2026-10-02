import 'dart:convert';
import 'dart:io';
import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:workmanager/workmanager.dart';
import '../data/snapshot_codec.dart';
import '../data/sqlite_habit_repository.dart';
import '../models/habit.dart';
import 'backup_manager.dart';
import 'backup_settings.dart';
import 'reminder_service.dart';

@pragma('vm:entry-point')
void backgroundDispatcher() {
  Workmanager().executeTask((task, input) async {
    // No controller and no automatic logical migration from a background engine.
    // Read a consistent snapshot; the foreground app owns business mutations.
    SqliteHabitRepository? repository;
    try {
      repository = await SqliteHabitRepository.open();
      final raw = await repository.load();
      if (raw == null) return true;
      final document = SnapshotCodec.decode(raw);
      if (task == 'reminders') {
        final habits = (document['habits'] as List)
            .map((h) => Habit.fromJson((h as Map).cast<String, Object?>()))
            .toList();
        await LocalReminderService(handleLaunchActions: false).syncAll(habits);
      } else if (task == 'backup') {
        final connectivity = await Connectivity().checkConnectivity();
        await BackupManager(BackupSettingsStore(DeviceSecretStore())).run(
          jsonEncode(document),
          automatic: true,
          wifi: connectivity.contains(ConnectivityResult.wifi),
        );
      }
    } on Object {
      // A periodic task will try again at the next window. Do not trigger an
      // unbounded immediate retry loop or log data/credentials from exceptions.
    } finally {
      await repository?.close();
    }
    return true;
  });
}

Future<void> initializeBackgroundTasks() async {
  if (!Platform.isAndroid) return;
  await Workmanager().initialize(backgroundDispatcher);
  await Workmanager().registerPeriodicTask(
    'haoxiguan-reminders-v1',
    'reminders',
    frequency: const Duration(hours: 12),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
  );
  await Workmanager().registerPeriodicTask(
    'haoxiguan-backup-v1',
    'backup',
    frequency: const Duration(hours: 12),
    existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    constraints: Constraints(networkType: NetworkType.connected),
  );
}

Future<void> attemptForegroundBackup(String snapshot) async {
  try {
    // Connectivity inspection is unnecessary while no target is configured.
    final store = BackupSettingsStore(DeviceSecretStore());
    if (await store.load() == null) return;
    final connections = await Connectivity().checkConnectivity();
    await BackupManager(store).run(
      snapshot,
      automatic: true,
      wifi: connections.contains(ConnectivityResult.wifi),
    );
  } on Object {
    /* Device-specific status is shown in the data screen. */
  }
}
