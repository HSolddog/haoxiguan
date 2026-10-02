import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:path_provider/path_provider.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/state/habit_controller.dart';

// Built ONLY with a separate acceptance application ID by the CI workflow.
// Never install this entrypoint over a user's normal application.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(
    const MaterialApp(
      home: Scaffold(body: Center(child: Text('好习惯隔离验收正在运行'))),
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
      final fromDocument = await BackupCodec.decrypt(
        picked!,
        'public synthetic native test password',
      );
      check(
        canonical(jsonDecode(fromDocument)) == canonical(jsonDecode(raw)),
        'SAF opened backup decrypted to the complete original data',
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
