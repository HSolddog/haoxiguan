import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';

import '../tools/android_acceptance.dart'
    show
        SettingsCheckpoint,
        FailedCheckpointConflict,
        readSettingsCheckpoint,
        verifyCheckpointStorage,
        nativeDatabaseEvidence,
        notificationStages,
        writeAtomic;

Map<String, Object?> _result(
  String stage,
  String original,
  Map<String, Object?> stored,
  String created,
  Map<String, Object?> createdStored,
) {
  final step = notificationStages.indexOf(stage);
  return {
    'build': '10002',
    'phase': 'reopen',
    'status': 'running',
    'runId': '123456',
    'stage': stage,
    'notificationCheckpointVersion': 1,
    for (final flag in [
      'safExportReadback',
      'safOpenDecrypt',
      'safSizeLimit',
      'nativeRestorePreviewCancel',
      'nativeRestoreProtection',
      'nativeRestoreConfirm',
      'nativeRestoreReopen',
      'nativeReminderScheduling',
      'nativeReminderCheckpointInitialReady',
    ])
      flag: true,
    if (step > 0) ...{
      'notificationApiLevel': 35,
      'nativeDeniedHabitSaved': true,
      'nativeAppPermissionDiagnosis': true,
    },
    if (step > 1) ...{
      'nativeAppPermissionRecovery': true,
      'nativeChannelInitialEnabled': true,
    },
    if (step > 2) 'nativeChannelDiagnosis': true,
    'nativeReminderStorageEvidence': {
      'originalControllerRaw': original,
      'originalStored': stored,
      if (step > 0) ...{
        'createdControllerRaw': created,
        'createdStored': createdStored,
        'freshControllerRaw': created,
      },
    },
  };
}

SettingsCheckpoint _synthetic(String stage) {
  const original = '{"habits":[{"id":"first","notes":{"2026-07-13":"keep"}}]}';
  const created =
      '{"habits":[{"id":"first","notes":{"2026-07-13":"keep"}},{"id":"second"}]}';
  final originalStored = <String, Object?>{
    'snapshotRaw': original,
    'tables': {
      'sqlite_sequence': [
        {'name': 'local_changes', 'seq': 1},
      ],
    },
  };
  final createdStored = <String, Object?>{
    'snapshotRaw': created,
    'tables': {
      'sqlite_sequence': [
        {'name': 'local_changes', 'seq': 2},
      ],
    },
  };
  final isOriginal = stage == notificationStages.first;
  return SettingsCheckpoint.create(
    _result(stage, original, originalStored, created, createdStored),
    isOriginal ? originalStored : createdStored,
    isOriginal ? original : created,
    original,
    processId: 101,
    deadline: DateTime.utc(2026, 10, 3, 23, 59),
  );
}

void main() {
  test(
    'all four waiting stages round trip their exact identity, prefix and deadline',
    () {
      for (final stage in notificationStages) {
        final checkpoint = _synthetic(stage);
        final decoded = SettingsCheckpoint.decode(
          jsonEncode(checkpoint.data),
          build: '10002',
        );
        expect(decoded.data, checkpoint.data);
        expect(decoded.result['runId'], '123456');
        expect(decoded.processId, 101);
        expect(decoded.deadline, DateTime.utc(2026, 10, 3, 23, 59));
      }
    },
  );

  test('wrong identity, prefix, SQL baseline and full model are rejected', () {
    void rejected(String stage, void Function(Map<String, dynamic>) mutate) {
      final value = (jsonDecode(jsonEncode(_synthetic(stage).data)) as Map)
          .cast<String, dynamic>();
      mutate(value);
      expect(
        () => SettingsCheckpoint.decode(jsonEncode(value), build: '10002'),
        throwsFormatException,
      );
    }

    for (final entry in {
      'version': 1.0,
      'schema': '3',
      'package': 'com.other.app',
      'build': '10001',
      'pid': 0,
      'deadlineMs': true,
      'runId': 'other',
      'stage': 'complete',
    }.entries) {
      rejected(notificationStages.first, (v) => v[entry.key] = entry.value);
    }
    rejected(
      notificationStages.first,
      (v) => v['result']['nativeDeniedHabitSaved'] = true,
    );
    rejected(
      notificationStages[1],
      (v) => v['result'].remove('nativeAppPermissionDiagnosis'),
    );
    rejected(
      notificationStages[2],
      (v) => v['result']['notificationApiLevel'] = 24,
    );
    rejected(
      notificationStages[3],
      (v) => v['result']['nativeChannelRecovery'] = true,
    );
    rejected(
      notificationStages.first,
      (v) => v['result']['notificationCheckpointVersion'] = 1.0,
    );
    rejected(
      notificationStages.first,
      (v) => v['database']['tables']['sqlite_sequence'][0]['seq'] = 42,
    );
    rejected(notificationStages[1], (v) => v['model'] = '{"habits":[]}');
    rejected(
      notificationStages[1],
      (v) =>
          v['result']['nativeReminderStorageEvidence']['freshControllerRaw'] =
              '{"habits":[]}',
    );
    expect(
      () => SettingsCheckpoint.decode('{', build: '10002'),
      throwsFormatException,
    );
  });

  test(
    'atomic waiting continuation refuses missing, corrupted or terminal checkpoint',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'acceptance-checkpoint-protocol-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final report = File('${directory.path}/acceptance-report.json');
      final file = File(
        '${directory.path}/acceptance-settings-checkpoint.json',
      );
      final cp = _synthetic(notificationStages.first);
      await writeAtomic(report, jsonEncode(cp.result));
      await expectLater(
        readSettingsCheckpoint(directory, '10002', report),
        throwsFormatException,
      );
      await File('${file.path}.pending').writeAsString(jsonEncode(cp.data));
      await expectLater(
        readSettingsCheckpoint(directory, '10002', report),
        throwsFormatException,
      );
      await cp.write(file);
      expect(
        (await readSettingsCheckpoint(directory, '10002', report))!.data,
        cp.data,
      );
      // Updating the real target replaces it atomically without extending its deadline.
      await cp.write(file);
      expect(
        (await readSettingsCheckpoint(directory, '10002', report))!.deadline,
        cp.deadline,
      );
      await file.writeAsString('{');
      await expectLater(
        readSettingsCheckpoint(directory, '10002', report),
        throwsFormatException,
      );
      await cp.write(file);
      await writeAtomic(report, jsonEncode({...cp.result, 'status': 'passed'}));
      await expectLater(
        readSettingsCheckpoint(directory, '10002', report),
        throwsFormatException,
      );
      final failure = {
        ...cp.result,
        'status': 'failed',
        'error': 'first real failure',
        'stack': 'original stack',
      };
      await writeAtomic(report, jsonEncode(failure));
      try {
        await readSettingsCheckpoint(directory, '10002', report);
        fail('failed logical run must remain terminal');
      } on FailedCheckpointConflict catch (error) {
        expect(error.previous, failure);
      }
      expect(jsonDecode(await report.readAsString()), failure);
      await file.delete();
      await writeAtomic(
        report,
        jsonEncode({...cp.result, 'stage': 'awaitingBackgroundReschedule'}),
      );
      await expectLater(
        readSettingsCheckpoint(directory, '10002', report),
        throwsFormatException,
      );
      await writeAtomic(
        report,
        jsonEncode({'build': '10002', 'status': 'running', 'runId': '123456'}),
      );
      await expectLater(
        readSettingsCheckpoint(directory, '10002', report),
        throwsFormatException,
      );
      await writeAtomic(
        report,
        jsonEncode({
          'build': '10001',
          'status': 'running',
          'runId': 'previous',
        }),
      );
      expect(await readSettingsCheckpoint(directory, '10002', report), isNull);
      await writeAtomic(report, jsonEncode({...cp.result, 'status': 'passed'}));
      expect(await readSettingsCheckpoint(directory, '10002', report), isNull);
    },
  );

  test(
    'real SQLite closes and resumes original SQL/model without adopting an intervening write',
    () async {
      final configured =
          Platform.environment['HAOXIGUAN_ACCEPTANCE_HOST_EVIDENCE'];
      final root = configured == null
          ? Directory.systemTemp
          : await Directory(configured).create(recursive: true);
      final directory = await root.createTemp('checkpoint-sqlite-');
      final file = File('${directory.path}/checkpoint.sqlite');
      final date = DateTime(2026, 7, 13, 10, 30);
      Future<({SqliteHabitRepository repository, HabitController controller})>
      open() async {
        final repository = SqliteHabitRepository(
          HabitDatabase(NativeDatabase(file)),
        );
        final controller = HabitController(
          repository,
          clock: () => date,
          timezoneId: () => 'Asia/Shanghai',
        );
        await controller.load();
        expect(controller.loaded, isTrue);
        return (repository: repository, controller: controller);
      }

      final first = await open();
      expect(
        await first.controller.addHabit(
          title: 'original retained facts',
          emoji: 'x',
          colorValue: 0xff5f8068,
          weekdays: {1, 2, 3, 4, 5, 6, 7},
        ),
        isTrue,
      );
      final original = first.controller.exportJson();
      final stored = await nativeDatabaseEvidence(first.repository);
      final cp = SettingsCheckpoint.create(
        _result(notificationStages.first, original, stored, original, stored),
        stored,
        original,
        original,
        processId: 101,
        deadline: DateTime.utc(2026, 10, 3, 23, 59),
      );
      await cp.write(
        File('${directory.path}/acceptance-settings-checkpoint.json'),
      );
      first.controller.dispose();
      await first.repository.close();
      var resumed = await open();
      addTearDown(() async {
        resumed.controller.dispose();
        await resumed.repository.close();
      });
      final observation = await verifyCheckpointStorage(
        cp,
        resumed.repository,
        resumed.controller,
      );
      expect(observation['actualDatabase'], stored);
      expect(observation['databaseDifferencePaths'], isEmpty);
      expect(observation['completeModelUnchanged'], isTrue);
      expect((stored['tables']! as Map).containsKey('sqlite_sequence'), isTrue);
      // A commit after the old waiting checkpoint is ambiguous and must fail closed.
      expect(
        await resumed.controller.addHabit(
          title: 'intervening committed habit',
          emoji: 'x',
          colorValue: 0xff5f8068,
          weekdays: {1, 2, 3, 4, 5, 6, 7},
        ),
        isTrue,
      );
      await expectLater(
        verifyCheckpointStorage(cp, resumed.repository, resumed.controller),
        throwsStateError,
      );
      final created = resumed.controller.exportJson();
      final createdStored = await nativeDatabaseEvidence(resumed.repository);
      final grant = SettingsCheckpoint.create(
        _result(
          notificationStages[1],
          original,
          stored,
          created,
          createdStored,
        ),
        createdStored,
        created,
        original,
        processId: 102,
        deadline: cp.deadline,
      );
      resumed.controller.dispose();
      await resumed.repository.close();
      resumed = await open();
      final grantObservation = await verifyCheckpointStorage(
        grant,
        resumed.repository,
        resumed.controller,
      );
      expect(grantObservation['actualDatabase'], createdStored);
      expect(grantObservation['completeModelUnchanged'], isTrue);
      await File('${directory.path}/evidence.json').writeAsString(
        jsonEncode({
          'checkpoint': cp.data,
          'resumedObservation': observation,
          'interveningDatabase': await nativeDatabaseEvidence(
            resumed.repository,
          ),
          'interveningModelRaw': resumed.controller.exportJson(),
          'interveningWriteRejected': true,
          'grantCheckpoint': grant.data,
          'grantResumedObservation': grantObservation,
        }),
        flush: true,
      );
      debugPrint('SQLITE_CHECKPOINT_EVIDENCE=${directory.path}/evidence.json');
    },
  );
}
