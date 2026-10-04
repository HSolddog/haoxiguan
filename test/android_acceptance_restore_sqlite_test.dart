import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/backup_restore_dialog.dart';

import '../tools/android_acceptance.dart'
    show canonical, nativeDatabaseEvidence, nativeSnapshotDifferencePaths;

final _date = DateTime(2026, 7, 13, 10, 30);

Future<({SqliteHabitRepository repository, HabitController controller})> _open(
  File databaseFile,
) async {
  final repository = SqliteHabitRepository(
    HabitDatabase(NativeDatabase(databaseFile)),
  );
  final controller = HabitController(
    repository,
    clock: () => _date,
    timezoneId: () => 'Asia/Shanghai',
  );
  await controller.load();
  expect(controller.loaded, isTrue);
  return (repository: repository, controller: controller);
}

Future<Directory> _directory(String name) async {
  final configured = Platform.environment['HAOXIGUAN_ACCEPTANCE_HOST_EVIDENCE'];
  if (configured == null) {
    return Directory.systemTemp.createTemp('haoxiguan-$name-');
  }
  final root = Directory(configured);
  await root.create(recursive: true);
  return root.createTemp('$name-');
}

Future<void> _writeEvidence(
  Directory directory,
  Map<String, Object?> evidence,
) async {
  final file = File('${directory.path}/evidence.json');
  await file.writeAsString(
    const JsonEncoder.withIndent('  ').convert(evidence),
    flush: true,
  );
  // Synthetic test snapshots are retained for independent diagnosis.
  debugPrint('SQLITE_ACCEPTANCE_EVIDENCE=${file.path}');
}

Future<void> _sentinel(HabitController controller) async {
  expect(
    await controller.addHabit(
      title: 'acceptance-before-restore',
      emoji: '📚',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    ),
    isTrue,
  );
  expect(
    await controller.setNote(
      controller.habits.single.id,
      _date,
      'must survive in the protected snapshot',
    ),
    isTrue,
  );
}

Future<void> _source(HabitController controller) async {
  for (final type in ['boolean', 'count', 'duration']) {
    expect(
      await controller.addHabit(
        title: 'acceptance-$type',
        emoji: '📚',
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
      isTrue,
    );
  }
  final habits = controller.habits;
  expect(await controller.markCompleted(habits[0].id, _date), isTrue);
  expect(await controller.addValue(habits[1].id, _date, 100), isTrue);
  expect(await controller.addValue(habits[1].id, _date, 200), isTrue);
  expect(await controller.addValue(habits[2].id, _date, 90), isTrue);
  expect(
    await controller.setNote(habits[1].id, _date, 'preserved source note'),
    isTrue,
  );
}

void main() {
  testWidgets(
    'real SQLite cancellation preserves every stored row despite export-only completions',
    (tester) async {
      late Directory directory;
      late SqliteHabitRepository repository;
      late HabitController controller;
      late String controllerBefore;
      late Map<String, Object?> before;
      await tester.runAsync(() async {
        directory = await _directory('cancel');
        final opened = await _open(File('${directory.path}/restore.sqlite'));
        repository = opened.repository;
        controller = opened.controller;
        await _sentinel(controller);
        controllerBefore = controller.exportJson();
        before = await nativeDatabaseEvidence(repository);
      });
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      final disk = jsonDecode(before['snapshotRaw']! as String);
      final memory = jsonDecode(controllerBefore);
      final storedTables = before['tables']! as Map;
      expect(storedTables.containsKey('sqlite_sequence'), isTrue);
      expect(
        (storedTables['sqlite_sequence'] as List).where(
          (row) => row['name'] == 'local_changes',
        ),
        isNotEmpty,
      );
      expect(nativeSnapshotDifferencePaths(disk, memory), [
        '/habits/0/completions',
      ]);
      expect((memory['habits'] as List).single['completions'], isEmpty);
      expect(
        (disk['habits'] as List).single.containsKey('completions'),
        isFalse,
      );
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      );
      final result = showDialog<bool>(
        context: navigator.currentContext!,
        builder: (_) => BackupRestoreDialog(
          controller: controller,
          raw: controllerBefore,
          preview: BackupPreview.fromSnapshot(controllerBefore),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(await result, isFalse);
      late Map<String, Object?> after;
      await tester.runAsync(() async {
        after = await nativeDatabaseEvidence(repository);
        await _writeEvidence(directory, {
          'controllerBeforeRaw': controllerBefore,
          'before': before,
          'afterCancel': after,
          'representationDifferencePaths': nativeSnapshotDifferencePaths(
            disk,
            memory,
          ),
          'cancelDifferencePaths': nativeSnapshotDifferencePaths(before, after),
          'controllerAfterCancelRaw': controller.exportJson(),
        });
      });
      expect(after, before);
      expect(nativeSnapshotDifferencePaths(before, after), isEmpty);
      expect(controller.exportJson(), controllerBefore);
    },
  );

  test(
    'fresh file SQLite controller preserves all saved reminder facts and original habits',
    () async {
      final directory = await _directory('reminder-storage');
      final file = File('${directory.path}/reminders.sqlite');
      final opened = await _open(file);
      final repository = opened.repository;
      final controller = opened.controller;
      addTearDown(() async {
        controller.dispose();
        await repository.close();
      });
      await _source(controller);
      final original = controller.exportJson();
      final originalDocument = jsonDecode(original) as Map;
      final originalHabits = originalDocument['habits'] as List;
      final originalIds = originalHabits
          .map((habit) => (habit as Map)['id'])
          .toSet();
      final originalStored = await nativeDatabaseEvidence(repository);
      expect(
        await controller.addHabit(
          title: 'acceptance-denied-synthetic',
          emoji: '📚',
          colorValue: 0xff5f8068,
          weekdays: {1, 2, 3, 4, 5, 6, 7},
          reminderTime: '23:59',
        ),
        isTrue,
      );
      final added = controller.habits.singleWhere(
        (habit) => !originalIds.contains(habit.id),
      );
      final created = controller.exportJson();
      final createdStored = await nativeDatabaseEvidence(repository);
      final fresh = await _open(file);
      late String freshExport;
      try {
        freshExport = fresh.controller.exportJson();
        final savedHabits = (jsonDecode(freshExport) as Map)['habits'] as List;
        expect(
          canonical(
            savedHabits.singleWhere((habit) => habit['id'] == added.id),
          ),
          canonical(added.toJson()),
        );
        expect(
          canonical(
            savedHabits
                .where((habit) => originalIds.contains(habit['id']))
                .toList(),
          ),
          canonical(originalHabits),
        );
        expect(
          canonical(jsonDecode(freshExport)),
          canonical(jsonDecode(created)),
        );
      } finally {
        fresh.controller.dispose();
        await fresh.repository.close();
      }
      final afterRead = await nativeDatabaseEvidence(repository);
      expect(afterRead, createdStored);
      await repository.replace(originalStored['snapshotRaw']! as String);
      final restoredRaw = (await repository.load())!;
      expect(
        canonical(jsonDecode(restoredRaw)),
        canonical(jsonDecode(originalStored['snapshotRaw']! as String)),
      );
      await _writeEvidence(directory, {
        'originalControllerRaw': original,
        'originalStored': originalStored,
        'createdControllerRaw': created,
        'createdStored': createdStored,
        'freshControllerRaw': freshExport,
        'afterRead': afterRead,
        'restoredSnapshotRaw': restoredRaw,
        'representationDifferencePaths': nativeSnapshotDifferencePaths(
          jsonDecode(createdStored['snapshotRaw']! as String),
          jsonDecode(created),
        ),
      });
    },
  );

  testWidgets(
    'real SQLite restore protects stored snapshot and survives file reopening',
    (tester) async {
      late Directory directory;
      late File targetFile;
      late SqliteHabitRepository targetRepository;
      late HabitController targetController;
      late SqliteHabitRepository sourceRepository;
      late HabitController sourceController;
      late Map<String, Object?> before;
      late String raw;
      await tester.runAsync(() async {
        directory = await _directory('confirm-reopen');
        targetFile = File('${directory.path}/target.sqlite');
        final target = await _open(targetFile);
        targetRepository = target.repository;
        targetController = target.controller;
        final source = await _open(File('${directory.path}/source.sqlite'));
        sourceRepository = source.repository;
        sourceController = source.controller;
        await _sentinel(targetController);
        await _source(sourceController);
        before = await nativeDatabaseEvidence(targetRepository);
        raw = sourceController.exportJson();
      });
      addTearDown(() async {
        targetController.dispose();
        await targetRepository.close();
        sourceController.dispose();
        await sourceRepository.close();
      });
      final navigator = GlobalKey<NavigatorState>();
      await tester.pumpWidget(
        MaterialApp(navigatorKey: navigator, home: const Scaffold()),
      );
      final result = showDialog<bool>(
        context: navigator.currentContext!,
        builder: (_) => BackupRestoreDialog(
          controller: targetController,
          raw: raw,
          preview: BackupPreview.fromSnapshot(raw),
        ),
      );
      await tester.pumpAndSettle();
      bool? confirmed;
      var completed = false;
      result.then((value) {
        confirmed = value;
        completed = true;
      });
      await tester.tap(find.text('保护当前数据并恢复'));
      for (var attempt = 0; attempt < 100 && !completed; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump(const Duration(milliseconds: 50));
        expect(find.byKey(const Key('restore-error')), findsNothing);
      }
      await tester.pumpAndSettle();
      expect(
        completed,
        isTrue,
        reason:
            'native file SQLite import must complete within bounded pumping',
      );
      expect(confirmed, isTrue);
      await tester.runAsync(() async {
        final importedRaw = targetController.exportJson();
        final imported = jsonDecode(importedRaw) as Map;
        final source = jsonDecode(raw) as Map;
        expect(imported['vaultId'], isNot(source['vaultId']));
        expect(imported['restoredFromVaultId'], source['vaultId']);
        final expected = Map<String, Object?>.from(source)
          ..['vaultId'] = imported['vaultId']
          ..['restoredFromVaultId'] = source['vaultId']
          ..['firstRecordBackupSuggestion'] = 'dismissed';
        expect(canonical(imported), canonical(expected));
        final protectedRaw = (await targetRepository.loadBackup())!;
        expect(
          canonical(jsonDecode(protectedRaw)),
          canonical(jsonDecode(before['snapshotRaw']! as String)),
        );
        targetController.dispose();
        await targetRepository.close();
        final reopened = await _open(targetFile);
        targetRepository = reopened.repository;
        targetController = reopened.controller;
        expect(
          canonical(jsonDecode(targetController.exportJson())),
          canonical(imported),
        );
        expect(
          canonical(jsonDecode((await targetRepository.loadBackup())!)),
          canonical(jsonDecode(before['snapshotRaw']! as String)),
        );
        await _writeEvidence(directory, {
          'before': before,
          'sourceControllerRaw': raw,
          'importedControllerRaw': importedRaw,
          'protectedSnapshotRaw': protectedRaw,
          'reopenedControllerRaw': targetController.exportJson(),
          'reopenedStored': await nativeDatabaseEvidence(targetRepository),
        });
      });
    },
  );
}
