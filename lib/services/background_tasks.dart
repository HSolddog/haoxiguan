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
      if (task == 'backup') {
        await attemptAutomaticBackup();
        return true;
      }
      repository = await SqliteHabitRepository.open();
      final raw = await repository.load();
      if (raw == null) return true;
      final document = SnapshotCodec.decode(raw);
      if (task == 'reminders') {
        final habits = (document['habits'] as List)
            .map((h) => Habit.fromJson((h as Map).cast<String, Object?>()))
            .toList();
        await LocalReminderService(handleLaunchActions: false).syncAll(habits);
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

Future<void> attemptAutomaticBackup() async {
  SqliteHabitRepository? repository;
  try {
    // Default local-only use must not serialize the entire history on every
    // resume or background window. Read committed SQLite, not optimistic UI.
    final store = BackupSettingsStore(DeviceSecretStore());
    final settings = await store.load();
    if (settings == null || !settings.automatic) return;
    final connections = await Connectivity().checkConnectivity();
    final wifi = connections.contains(ConnectivityResult.wifi);
    if (settings.wifiOnly && !wifi) return;
    repository = await SqliteHabitRepository.open();
    final snapshot = await repository.load();
    if (snapshot == null) return;
    await BackupManager(store).run(snapshot, automatic: true, wifi: wifi);
  } on Object {
    /* Device-specific status is shown in the data screen. */
  } finally {
    await repository?.close();
  }
}
