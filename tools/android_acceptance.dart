import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:workmanager/workmanager.dart';
import 'package:path_provider/path_provider.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/services/background_tasks.dart';
import 'package:haoxiguan/services/device_task_lock.dart';
import 'package:haoxiguan/services/reminder_service.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/backup_restore_dialog.dart';

final acceptanceNavigator = GlobalKey<NavigatorState>();

// Built ONLY with a separate acceptance application ID by the CI workflow.
// Never install this entrypoint over a user's normal application.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  // This isolated fixture is driven through Android's accessibility hierarchy.
  // Keep Flutter semantics active even without a physical accessibility service.
  final acceptanceSemantics = WidgetsBinding.instance.ensureSemantics();
  runApp(
    MaterialApp(
      navigatorKey: acceptanceNavigator,
      home: const Scaffold(body: Center(child: Text('好习惯隔离验收正在运行'))),
    ),
  );
  final directory = await getApplicationSupportDirectory();
  final report = File('${directory.path}/acceptance-report.json');
  final baseline = File('${directory.path}/acceptance-baseline.json');
  SqliteHabitRepository? repository;
  HabitController? controller;
  final result = <String, Object?>{
    'build': const String.fromEnvironment('ACCEPTANCE_BUILD'),
    'status': 'running',
    'runId': DateTime.now().toUtc().microsecondsSinceEpoch.toString(),
  };
  await report.writeAsString(jsonEncode(result), flush: true);
  try {
    repository = await SqliteHabitRepository.open();
    final date = DateTime(2026, 7, 13, 10, 30);
    controller = HabitController(
      repository,
      clock: () => date,
      timezoneId: () => 'Asia/Shanghai',
    );
    await controller.load();
    check(controller.loaded, 'open');
    const secrets = FlutterSecureStorage(
      aOptions: AndroidOptions(
        resetOnError: false,
        migrateWithBackup: true,
        storageNamespace: 'acceptance_only',
      ),
    );
    if (!await baseline.exists()) {
      check(controller.habits.isEmpty, 'fresh installation must be empty');
      for (final type in ['boolean', 'count', 'duration']) {
        check(
          await controller.addHabit(
            title: 'acceptance-$type',
            emoji: '🌱',
            colorValue: 0xff5f8068,
            weekdays: {1, 2, 3, 4, 5, 6, 7},
            recordType: type,
            reminderTime: type == 'boolean' ? '23:59' : null,
            scale: type == 'count' ? 1000 : 1,
            dailyTarget: type == 'count'
                ? 300
                : type == 'duration'
                ? 90
                : 1,
            unit: type == 'duration' ? '秒' : '次',
          ),
          'create $type',
        );
      }
      final habits = controller.habits;
      check(await controller.markCompleted(habits[0].id, date), 'complete');
      check(await controller.addValue(habits[1].id, date, 100), 'count first');
      check(await controller.addValue(habits[1].id, date, 200), 'count second');
      check(await controller.addValue(habits[2].id, date, 90), 'duration');
      check(
        await controller.setNote(habits[1].id, date, '离线验收：更新和重开必须保留'),
        'note',
      );
      await secrets.write(
        key: 'retained',
        value: 'synthetic-keystore-upgrade-fixture',
      );
      await baseline.writeAsString(
        canonical(jsonDecode(controller.exportJson())),
        flush: true,
      );
      result['phase'] = 'create';
    } else {
      check(
        canonical(jsonDecode(controller.exportJson())) ==
            await baseline.readAsString(),
        'all business data survived reopening/upgrade',
      );
      check(
        await secrets.read(key: 'retained') ==
            'synthetic-keystore-upgrade-fixture',
        'Keystore survived reopening/upgrade',
      );
      result['phase'] = 'reopen';
    }
    final habits = controller.habits;
    check(habits.length == 3, 'habit count');
    check(
      habits.firstWhere((h) => h.recordType == 'boolean').isCompletedOn(date),
      'boolean preserved',
    );
    check(
      habits.firstWhere((h) => h.recordType == 'count').valueOn(date) == 300,
      'exact count preserved',
    );
    check(
      habits.firstWhere((h) => h.recordType == 'duration').valueOn(date) == 90,
      'duration preserved',
    );
    final raw = controller.exportJson();
    final encrypted = await BackupCodec.encrypt(
      raw,
      'public synthetic native test password',
    );
    final restored = await BackupCodec.decrypt(
      encrypted,
      'public synthetic native test password',
    );
    check(
      canonical(jsonDecode(restored)) == canonical(jsonDecode(raw)),
      'native crypto round trip',
    );
    if (result['build'] == '10002') {
      final name = 'hgw-${result['runId']}.hgb';
      final files = PlatformBackupFiles();
      result.addAll({'stage': 'awaitingDocumentSave', 'documentName': name});
      await report.writeAsString(jsonEncode(result), flush: true);
      check(await files.save(encrypted, name), 'SAF export and readback');
      result['stage'] = 'awaitingDocumentOpen';
      await report.writeAsString(jsonEncode(result), flush: true);
      final picked = await files.open();
      check(picked != null, 'SAF selected encrypted backup');
      final document = await BackupCodec.decryptWithMetadata(
        picked!,
        'public synthetic native test password',
      );
      final fromDocument = document.snapshot;
      check(
        canonical(jsonDecode(fromDocument)) == canonical(jsonDecode(raw)),
        'SAF opened backup decrypted to the complete original data',
      );
      await verifyNativeRestore(directory, report, result, document, date);
      check(
        canonical(jsonDecode(controller.exportJson())) ==
            canonical(jsonDecode(raw)),
        'independent restore did not change the upgrade fixture',
      );
      final oversizedName = 'hgw-oversize-${result['runId']}.hgb';
      result.addAll({
        'safExportReadback': true,
        'safOpenDecrypt': true,
        'stage': 'awaitingOversizeSave',
        'documentName': oversizedName,
      });
      await report.writeAsString(jsonEncode(result), flush: true);
      // Register the synthetic document through SAF even on Android 7, whose
      // Downloads provider does not list arbitrary adb-created files. The driver
      // then expands the same file without trusting the provider's old SIZE.
      check(
        await files.save(encrypted, oversizedName),
        'SAF oversized fixture placeholder',
      );
      result['stage'] = 'awaitingOversizeOpen';
      await report.writeAsString(jsonEncode(result), flush: true);
      var rejected = false;
      try {
        await files.open();
      } on FormatException catch (error) {
        rejected = error.message == '文件超过 50 MiB';
      }
      check(rejected, 'oversized SAF document rejected before Dart allocation');
      check(
        canonical(jsonDecode(controller.exportJson())) ==
            canonical(jsonDecode(raw)),
        'failed file import left application data unchanged',
      );
      result['safSizeLimit'] = true;
      final reminders = LocalReminderService(handleLaunchActions: false);
      await reminders.syncAll(controller.habits);
      final notifications = FlutterLocalNotificationsPlugin();
      check(
        await notifications
                .resolvePlatformSpecificImplementation<
                  AndroidFlutterLocalNotificationsPlugin
                >()!
                .areNotificationsEnabled() ==
            true,
        'native notification permission',
      );
      final scheduled = await notifications.pendingNotificationRequests();
      check(scheduled.isNotEmpty, 'native notification schedule');
      for (final item in scheduled) {
        final payload = jsonDecode(item.payload!) as Map;
        check(
          payload['v'] == 1 &&
              payload['habitId'] == habits.first.id &&
              DateTime.tryParse(payload['date'] as String) != null,
          'native reminders carry an explicit behavior date',
        );
      }
      result['nativeReminderScheduling'] = true;
      await verifyNativeReminderAccess(
        directory,
        report,
        result,
        repository,
        reminders,
        raw,
        date,
      );
      await controller.load();
      check(
        canonical(jsonDecode(controller.exportJson())) ==
            await baseline.readAsString(),
        'permission scenarios preserved the original upgrade baseline',
      );
      await reminders.syncAll(controller.habits);
      await Workmanager().initialize(backgroundDispatcher);
      // A forced JobScheduler job cannot bypass WorkManager's own periodic
      // clock. Use a real one-off system task with the production dispatcher.
      // Cancel the isolated fixture's previous work before clearing reminders.
      await Workmanager().cancelAll();
      final cancelled = DateTime.now().add(const Duration(seconds: 10));
      while (await Workmanager().isScheduledByUniqueName(
            'haoxiguan-reminders-v1',
          ) ||
          await Workmanager().isScheduledByUniqueName('haoxiguan-backup-v1')) {
        check(DateTime.now().isBefore(cancelled), 'fixture work cancelled');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      await DeviceTaskLock.run('reminders', notifications.cancelAll);
      result['stage'] = 'awaitingBackgroundReschedule';
      await report.writeAsString(jsonEncode(result), flush: true);
      await Workmanager().registerOneOffTask(
        'acceptance-reminders-${result['runId']}',
        'reminders',
      );
      final deadline = DateTime.now().add(const Duration(seconds: 75));
      var renewed = false;
      while (DateTime.now().isBefore(deadline)) {
        await Future<void>.delayed(const Duration(milliseconds: 500));
        if ((await notifications.pendingNotificationRequests()).isNotEmpty) {
          renewed = true;
          break;
        }
      }
      check(renewed, 'real WorkManager isolate rebuilt pending reminders');
      result['workManagerRenewal'] = true;
      await initializeBackgroundTasks();
      final registered = DateTime.now().add(const Duration(seconds: 10));
      while (!(await Workmanager().isScheduledByUniqueName(
            'haoxiguan-reminders-v1',
          )) ||
          !(await Workmanager().isScheduledByUniqueName(
            'haoxiguan-backup-v1',
          ))) {
        check(DateTime.now().isBefore(registered), 'periodic tasks registered');
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
      result['periodicTasksRegistered'] = true;
      result.remove('stage');
    }
    final version = await repository.database
        .customSelect('PRAGMA user_version')
        .getSingle();
    result.addAll({
      'status': 'passed',
      'habits': habits.length,
      'schema': version.data.values.single,
      'nativeCrypto': true,
      'keystore': true,
      'backupConfigured': false,
      'syncConfigured': false,
    });
  } catch (error, stack) {
    result.addAll({
      'status': 'failed',
      'error': error.toString(),
      'stack': stack.toString(),
    });
  } finally {
    controller?.dispose();
    await repository?.close();
    acceptanceSemantics.dispose();
  }
  await report.writeAsString(
    const JsonEncoder.withIndent('  ').convert(result),
    flush: true,
  );
  runApp(
    MaterialApp(
      home: Scaffold(
        body: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(24),
            child: Text(const JsonEncoder.withIndent('  ').convert(result)),
          ),
        ),
      ),
    ),
  );
}

/// The settings driver acknowledges only navigation. All permission/channel
/// assertions below read Android through the production notification plugin.
int? controlApiLevel(
  String raw, {
  required String runId,
  required String stage,
}) {
  final value = jsonDecode(raw);
  if (value is! Map || value['runId'] != runId || value['stage'] != stage) {
    return null;
  }
  final api = value['apiLevel'];
  return api is int && api >= 24 && api < 1000 ? api : null;
}

Future<int> settingsStage(
  Directory directory,
  File report,
  Map<String, Object?> result,
  HabitController controller,
  String stage, {
  bool channel = false,
}) async {
  check(
    await controller.openReminderSettings(channel: channel),
    'production settings navigation for $stage',
  );
  result['stage'] = stage;
  await report.writeAsString(jsonEncode(result), flush: true);
  final control = File('${directory.path}/acceptance-control.json');
  final deadline = DateTime.now().add(const Duration(seconds: 120));
  while (DateTime.now().isBefore(deadline)) {
    try {
      final api = controlApiLevel(
        await control.readAsString(),
        runId: result['runId']! as String,
        stage: stage,
      );
      if (api != null) return api;
    } on FileSystemException {
      // Missing control is expected before the first driver acknowledgement.
    } on FormatException {
      // A partially written acknowledgement is never treated as completion.
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  throw StateError('settings driver did not acknowledge $stage');
}

Future<void> expectReminderAccess(
  HabitController controller,
  ReminderAccess expected,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 15));
  var actual = await controller.readReminderAccess();
  while (actual != expected && DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 250));
    actual = await controller.readReminderAccess();
  }
  check(
    actual == expected,
    'native reminder access: $actual, expected $expected',
  );
}

/// Synthetic CI evidence keeps the full stored representation and every table.
/// Comparing these observations also detects same-content rewrites of revision,
/// journal or protection rows. It never compares SQL storage with a model export.
Future<Map<String, Object?>> nativeDatabaseEvidence(
  SqliteHabitRepository repository,
) => repository.database.transaction(() async {
  final raw = await repository.load();
  check(raw != null, 'native SQLite snapshot exists');
  final names = await repository.database
      .customSelect(
        "SELECT name FROM sqlite_master WHERE type='table' ORDER BY name",
      )
      .get();
  final tables = <String, Object?>{};
  for (final row in names) {
    final name = row.read<String>('name');
    check(
      RegExp(r'^[A-Za-z_][A-Za-z0-9_]*$').hasMatch(name),
      'known SQLite table identifier',
    );
    tables[name] =
        (await repository.database
                .customSelect('SELECT * FROM $name ORDER BY rowid')
                .get())
            .map((row) => row.data)
            .toList();
  }
  return {'snapshotRaw': raw, 'tables': tables};
});

/// Report exact field paths without ignoring, deleting or normalizing values.
List<String> nativeSnapshotDifferencePaths(
  Object? before,
  Object? after, [
  String path = '',
]) {
  if (before is Map && after is Map) {
    final keys = {
      ...before.keys.cast<String>(),
      ...after.keys.cast<String>(),
    }.toList()..sort();
    return [
      for (final key in keys)
        if (!before.containsKey(key) || !after.containsKey(key))
          '$path/$key'
        else
          ...nativeSnapshotDifferencePaths(
            before[key],
            after[key],
            '$path/$key',
          ),
    ];
  }
  if (before is List && after is List) {
    return [
      if (before.length != after.length) '$path/length',
      for (var i = 0; i < before.length && i < after.length; i++)
        ...nativeSnapshotDifferencePaths(before[i], after[i], '$path/$i'),
    ];
  }
  return canonical(before) == canonical(after) ? [] : [path];
}

Future<void> verifyNativeReminderAccess(
  Directory directory,
  File report,
  Map<String, Object?> result,
  SqliteHabitRepository repository,
  LocalReminderService reminders,
  String original,
  DateTime date,
) async {
  final controller = HabitController(
    repository,
    clock: () => date,
    reminderScheduler: reminders,
    timezoneId: () => 'Asia/Shanghai',
  );
  final plugin = FlutterLocalNotificationsPlugin();
  final android = plugin
      .resolvePlatformSpecificImplementation<
        AndroidFlutterLocalNotificationsPlugin
      >()!;
  final originalDocument = jsonDecode(original) as Map;
  final originalHabits = originalDocument['habits'] as List;
  final originalIds = originalHabits
      .map((habit) => (habit as Map)['id'])
      .toSet();
  try {
    await controller.load();
    check(controller.loaded, 'notification fixture opens real SQLite');
    check(
      canonical(jsonDecode(controller.exportJson())) ==
          canonical(originalDocument),
      'notification fixture reads the complete original model snapshot',
    );
    final originalStored = await nativeDatabaseEvidence(repository);
    final storageEvidence = <String, Object?>{
      'originalControllerRaw': original,
      'originalStored': originalStored,
    };
    result['nativeReminderStorageEvidence'] = storageEvidence;
    check(await controller.rebuildReminders(), 'initial notifications ready');
    final api = await settingsStage(
      directory,
      report,
      result,
      controller,
      'awaitingNotificationDeny',
    );
    result['notificationApiLevel'] = api;
    await expectReminderAccess(controller, ReminderAccess.appPermissionDenied);
    check(
      await android.areNotificationsEnabled() == false,
      'Android independently reports app notifications denied',
    );
    check(
      await controller.addHabit(
        title: 'acceptance-denied-${result['runId']}',
        emoji: '🌱',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        reminderTime: '23:59',
      ),
      'habit creation succeeds while app notifications are denied',
    );
    final added = controller.habits.singleWhere(
      (habit) => !originalIds.contains(habit.id),
    );
    final createdSnapshot = controller.exportJson();
    final createdStored = await nativeDatabaseEvidence(repository);
    storageEvidence.addAll({
      'createdControllerRaw': createdSnapshot,
      'createdStored': createdStored,
      'representationDifferencePaths': nativeSnapshotDifferencePaths(
        jsonDecode(createdStored['snapshotRaw']! as String),
        jsonDecode(createdSnapshot),
      ),
    });
    check(
      !await controller.rebuildReminders(),
      'denied rebuild is unsuccessful',
    );
    check(
      controller.reminderError == ReminderAccess.appPermissionDenied.message,
      'denied notification explains the real cause and retained data',
    );
    check(
      (await plugin.pendingNotificationRequests()).isEmpty,
      'denied notification leaves no pending reminder',
    );
    // Read with a fresh native SQLite executor, not the controller's cache.
    final reopened = await SqliteHabitRepository.open();
    final reopenedController = HabitController(
      reopened,
      clock: () => date,
      timezoneId: () => 'Asia/Shanghai',
    );
    try {
      await reopenedController.load();
      check(reopenedController.loaded, 'fresh SQLite controller opened');
      final savedRaw = reopenedController.exportJson();
      storageEvidence['freshControllerRaw'] = savedRaw;
      final saved = jsonDecode(savedRaw) as Map;
      final savedHabits = saved['habits'] as List;
      check(
        canonical(saved) == canonical(jsonDecode(createdSnapshot)),
        'fresh SQLite controller preserves the complete committed model snapshot',
      );
      check(
        canonical(
              savedHabits.singleWhere((habit) => habit['id'] == added.id),
            ) ==
            canonical(added.toJson()),
        'denied habit and reminder preference were committed to SQLite',
      );
      check(
        canonical(
              savedHabits
                  .where((habit) => originalIds.contains(habit['id']))
                  .toList(),
            ) ==
            canonical(originalHabits),
        'denied creation preserves all prior habits, records and notes',
      );
    } finally {
      reopenedController.dispose();
      await reopened.close();
    }
    result['nativeDeniedHabitSaved'] = true;
    result['nativeAppPermissionDiagnosis'] = true;

    check(
      await settingsStage(
            directory,
            report,
            result,
            controller,
            'awaitingNotificationGrant',
          ) ==
          api,
      'consistent Android SDK across settings stages',
    );
    await expectReminderAccess(controller, ReminderAccess.ready);
    check(await controller.rebuildReminders(), 'regrant rebuild succeeds');
    check(controller.reminderError == null, 'regrant clears prior denial');
    check(
      (await plugin.pendingNotificationRequests()).any(
        (item) => (jsonDecode(item.payload!) as Map)['habitId'] == added.id,
      ),
      'regrant rebuild includes the habit saved under denial',
    );
    result['nativeAppPermissionRecovery'] = true;

    if (api >= 26) {
      final before = await android.getNotificationChannels();
      check(
        before?.any(
              (channel) =>
                  channel.id == DeviceReminderDiagnostics.channelId &&
                  channel.importance != Importance.none,
            ) ==
            true,
        'the existing real reminder channel is enabled before user disables it',
      );
      check(
        await settingsStage(
              directory,
              report,
              result,
              controller,
              'awaitingChannelDisable',
              channel: true,
            ) ==
            api,
        'consistent channel Android SDK',
      );
      await expectReminderAccess(controller, ReminderAccess.channelDisabled);
      check(
        await android.areNotificationsEnabled() == true,
        'app permission remains granted when only channel is disabled',
      );
      final blocked = await android.getNotificationChannels();
      check(
        blocked?.any(
              (channel) =>
                  channel.id == DeviceReminderDiagnostics.channelId &&
                  channel.importance == Importance.none,
            ) ==
            true,
        'Android independently reports reminder channel disabled',
      );
      check(
        !await controller.rebuildReminders(),
        'disabled channel blocks rebuild',
      );
      check(
        controller.reminderError == ReminderAccess.channelDisabled.message,
        'channel-specific explanation retained',
      );
      check(
        (await plugin.pendingNotificationRequests()).isEmpty,
        'blocked channel clears pending reminders',
      );
      result['nativeChannelDiagnosis'] = true;
      check(
        await settingsStage(
              directory,
              report,
              result,
              controller,
              'awaitingChannelEnable',
              channel: true,
            ) ==
            api,
        'consistent channel repair Android SDK',
      );
      await expectReminderAccess(controller, ReminderAccess.ready);
      check(
        await controller.rebuildReminders(),
        'user-enabled channel rebuild succeeds',
      );
      check(
        controller.reminderError == null,
        'channel repair clears prior error',
      );
      check(
        (await plugin.pendingNotificationRequests()).any(
          (item) => (jsonDecode(item.payload!) as Map)['habitId'] == added.id,
        ),
        'channel repair rebuilds the saved habit reminder',
      );
      result['nativeChannelRecovery'] = true;
    } else {
      result['nativeChannelDiagnosis'] = 'notApplicable';
      result['nativeChannelRecovery'] = 'notApplicable';
    }
    final afterSettings = await nativeDatabaseEvidence(repository);
    storageEvidence.addAll({
      'afterSettings': afterSettings,
      'settingsSnapshotDifferencePaths': nativeSnapshotDifferencePaths(
        jsonDecode(createdStored['snapshotRaw']! as String),
        jsonDecode(afterSettings['snapshotRaw']! as String),
      ),
      'settingsTableDifferencePaths': nativeSnapshotDifferencePaths(
        createdStored['tables'],
        afterSettings['tables'],
      ),
    });
    await report.writeAsString(jsonEncode(result), flush: true);
    check(
      canonical(jsonDecode(afterSettings['snapshotRaw']! as String)) ==
          canonical(jsonDecode(createdStored['snapshotRaw']! as String)),
      'all facts and metadata remain unchanged during settings repairs',
    );
    check(
      canonical(afterSettings) == canonical(createdStored),
      'settings repairs do not rewrite SQLite revision, journal or protection rows',
    );
    // This only removes the synthetic extra habit after every assertion passed.
    // The original baseline file is never rewritten or recomputed.
    await repository.replace(originalStored['snapshotRaw']! as String);
    final afterCleanup = await nativeDatabaseEvidence(repository);
    storageEvidence['afterCleanup'] = afterCleanup;
    check(
      canonical(jsonDecode(afterCleanup['snapshotRaw']! as String)) ==
          canonical(jsonDecode(originalStored['snapshotRaw']! as String)),
      'permission fixture returns to the exact original snapshot',
    );
  } finally {
    controller.dispose();
  }
}

Future<void> verifyNativeRestore(
  Directory directory,
  File report,
  Map<String, Object?> result,
  BackupContents document,
  DateTime date,
) async {
  final databaseFile = File(
    '${directory.path}/acceptance-restore-${result['runId']}.sqlite',
  );
  SqliteHabitRepository openRepository() => SqliteHabitRepository(
    HabitDatabase(NativeDatabase.createInBackground(databaseFile)),
  );
  var repository = openRepository();
  HabitController? controller = HabitController(repository, clock: () => date);
  try {
    await controller.load();
    check(
      controller.loaded && controller.habits.isEmpty,
      'independent restore scope starts empty',
    );
    check(
      await controller.addHabit(
        title: 'acceptance-before-restore',
        emoji: '🌱',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
      ),
      'create pre-restore sentinel',
    );
    check(
      await controller.setNote(
        controller.habits.single.id,
        date,
        'must survive in the protected snapshot',
      ),
      'create protected note',
    );
    final beforeController = controller.exportJson();
    final beforeStored = await nativeDatabaseEvidence(repository);
    final before = beforeStored['snapshotRaw']! as String;
    final storageEvidence = <String, Object?>{
      'controllerBeforeRaw': beforeController,
      'before': beforeStored,
      'representationDifferencePaths': nativeSnapshotDifferencePaths(
        jsonDecode(before),
        jsonDecode(beforeController),
      ),
    };
    result['nativeRestoreStorageEvidence'] = storageEvidence;
    final preview = BackupPreview.fromSnapshot(
      document.snapshot,
      createdAtUtc: document.createdAtUtc,
    );
    check(
      preview.createdAtUtc != null &&
          preview.habits == 3 &&
          preview.records == 4 &&
          preview.notes == 1 &&
          preview.firstDate == '2026-07-13' &&
          preview.lastDate == '2026-07-13',
      'authenticated SAF preview has creation time, counts and behavior date range',
    );
    Future<bool?> showRestore(String stage) async {
      await WidgetsBinding.instance.endOfFrame;
      final future = showDialog<bool>(
        context: acceptanceNavigator.currentContext!,
        builder: (_) => BackupRestoreDialog(
          controller: controller!,
          raw: document.snapshot,
          preview: preview,
        ),
      );
      result['stage'] = stage;
      await report.writeAsString(jsonEncode(result), flush: true);
      return future.timeout(const Duration(seconds: 120));
    }

    check(
      await showRestore('awaitingRestoreCancel') == false,
      'real preview was explicitly cancelled',
    );
    final afterCancel = await nativeDatabaseEvidence(repository);
    final afterCancelController = controller.exportJson();
    storageEvidence.addAll({
      'afterCancel': afterCancel,
      'controllerAfterCancelRaw': afterCancelController,
      'cancelSnapshotDifferencePaths': nativeSnapshotDifferencePaths(
        jsonDecode(before),
        jsonDecode(afterCancel['snapshotRaw']! as String),
      ),
      'cancelTableDifferencePaths': nativeSnapshotDifferencePaths(
        beforeStored['tables'],
        afterCancel['tables'],
      ),
    });
    // Save observations before an assertion can fail; later success cannot
    // replace this run's original before/after native database evidence.
    await report.writeAsString(jsonEncode(result), flush: true);
    check(
      canonical(jsonDecode(afterCancel['snapshotRaw']! as String)) ==
          canonical(jsonDecode(before)),
      'cancel leaves real SQLite snapshot unchanged',
    );
    check(
      canonical(afterCancel) == canonical(beforeStored),
      'cancel does not rewrite SQLite revision, journal or protection rows',
    );
    check(
      canonical(jsonDecode(afterCancelController)) ==
          canonical(jsonDecode(beforeController)),
      'cancel preserves the complete controller snapshot',
    );
    result['nativeRestorePreviewCancel'] = true;
    check(
      await showRestore('awaitingRestoreConfirm') == true,
      'real preview confirmed and controller import completed',
    );
    final importedRaw = controller.exportJson();
    storageEvidence['importedControllerRaw'] = importedRaw;
    storageEvidence['afterConfirm'] = await nativeDatabaseEvidence(repository);
    final imported = jsonDecode(importedRaw) as Map;
    final source = jsonDecode(document.snapshot) as Map;
    check(
      imported['vaultId'] is String &&
          imported['vaultId'] != source['vaultId'] &&
          imported['restoredFromVaultId'] == source['vaultId'],
      'restore forks space identity and records source space',
    );
    final expected = Map<String, Object?>.from(source)
      ..['vaultId'] = imported['vaultId']
      ..['restoredFromVaultId'] = source['vaultId']
      ..['firstRecordBackupSuggestion'] = 'dismissed';
    check(
      canonical(imported) == canonical(expected),
      'restore preserves every fact and setting except documented restored-space fields',
    );
    final protectedRaw = (await repository.loadBackup())!;
    storageEvidence['protectedSnapshotRaw'] = protectedRaw;
    check(
      canonical(jsonDecode(protectedRaw)) == canonical(jsonDecode(before)),
      'native replacement protected the complete previous snapshot',
    );
    result['nativeRestoreProtection'] = true;
    result['nativeRestoreConfirm'] = true;
    controller.dispose();
    controller = null;
    await repository.close();
    repository = openRepository();
    controller = HabitController(repository, clock: () => date);
    await controller.load();
    storageEvidence['reopenedControllerRaw'] = controller.exportJson();
    storageEvidence['afterReopen'] = await nativeDatabaseEvidence(repository);
    check(
      controller.loaded &&
          canonical(jsonDecode(controller.exportJson())) == canonical(imported),
      'native restore survives closing and reopening SQLite',
    );
    check(
      canonical(jsonDecode((await repository.loadBackup())!)) ==
          canonical(jsonDecode(before)),
      'protection survives SQLite reopening',
    );
    result['nativeRestoreReopen'] = true;
  } finally {
    controller?.dispose();
    await repository.close();
  }
}

void check(bool condition, String step) {
  if (!condition) throw StateError(step);
}

String canonical(Object? value) => jsonEncode(normalize(value));
Object? normalize(Object? value) {
  if (value is Map) {
    final keys = value.keys.cast<String>().toList()..sort();
    return {for (final key in keys) key: normalize(value[key])};
  }
  if (value is List) {
    final items = value.map(normalize).toList();
    if (items.isNotEmpty && items.every((x) => x is Map && x['id'] is String)) {
      items.sort(
        (a, b) =>
            ((a as Map)['id'] as String).compareTo((b as Map)['id'] as String),
      );
    }
    return items;
  }
  return value;
}
