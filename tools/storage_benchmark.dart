// Diagnostic host benchmark. Run explicitly with flutter test; these JIT numbers
// are not Android release performance claims. Uses only a new temporary DB.
import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/models/record_entry.dart';
import 'package:haoxiguan/state/habit_controller.dart';

void main() {
  test(
    '100 habits / five year range / 100k facts diagnostic',
    () async {
      const count = int.fromEnvironment(
        'BENCHMARK_RECORDS',
        defaultValue: 100000,
      );
      const samples = int.fromEnvironment('BENCHMARK_SAMPLES', defaultValue: 3);
      final directory = await Directory.systemTemp.createTemp(
        'haoxiguan-scale-',
      );
      final file = File('${directory.path}/data.sqlite');
      SqliteHabitRepository open() => SqliteHabitRepository(
        HabitDatabase(
          NativeDatabase.createInBackground(
            file,
            setup: (db) {
              db.execute('PRAGMA journal_mode=WAL');
              db.execute('PRAGMA synchronous=FULL');
              db.execute('PRAGMA foreign_keys=ON');
            },
          ),
        ),
      );
      var repository = open();
      var controller = HabitController(
        repository,
        clock: () => DateTime(2026, 10, 2),
      );
      final report = <String, Object?>{
        'platform': Platform.operatingSystem,
        'dart': Platform.version,
        'execution': 'flutter test / JIT / background SQLite',
        'habits': 100,
        'records': count,
        'samples': samples,
      };
      try {
        await controller.load();
        final root =
            jsonDecode(controller.exportJson()) as Map<String, dynamic>;
        root['habits'] = List.generate(100, (h) {
          final habit = Habit(
            id: 'bench-$h',
            title: '样本 $h',
            emoji: '🌱',
            colorValue: 0xff5f8068,
            weekdays: {1, 2, 3, 4, 5, 6, 7},
            createdAt: DateTime(2021, 10, 2),
            recordType: 'count',
            scale: 1000,
            dailyTarget: 1000,
            entries: List.generate(count ~/ 100, (i) {
              final date = DateTime(
                2021,
                10,
                2,
              ).add(Duration(days: i * 1825 ~/ (count ~/ 100)));
              return RecordEntry(
                id: 'record-$h-$i',
                date: dateKey(date),
                value: 1000,
                recordedAtUtc: '${dateKey(date)}T12:00:00Z',
                recordedLocalDate: dateKey(date),
                timezoneId: 'Asia/Shanghai',
                utcOffsetMinutes: 480,
              );
            }),
            notes: {
              for (var i = 0; i < 20; i++)
                dateKey(DateTime(2021, 10, 2 + i * 90)): '合成样本备注；不含真实用户数据。',
            },
          );
          return habit.copyWith(plans: habit.effectivePlans).toJson();
        });
        final raw = jsonEncode(root);
        report['snapshotBytes'] = utf8.encode(raw).length;
        final watch = Stopwatch()..start();
        expect(await controller.importJson(raw), true);
        report['importMs'] = watch.elapsedMilliseconds;
        final saves = <int>[];
        for (var i = 0; i < samples; i++) {
          watch.reset();
          expect(
            await controller.addValue('bench-0', controller.today, 1),
            true,
          );
          saves.add(watch.elapsedMilliseconds);
        }
        report['saveMs'] = saves;
        final loads = <int>[];
        for (var i = 0; i < samples; i++) {
          controller.dispose();
          await repository.close();
          repository = open();
          controller = HabitController(
            repository,
            clock: () => DateTime(2026, 10, 2),
          );
          watch.reset();
          await controller.load();
          loads.add(watch.elapsedMilliseconds);
          expect(controller.loaded, true);
          expect(controller.habits.length, 100);
          expect(
            controller.habitById('bench-0')!.valueOn(controller.today),
            samples,
          );
        }
        report['reopenMs'] = loads;
        report['databaseBytes'] = await file.length();
        final text = const JsonEncoder.withIndent('  ').convert(report);
        const destination = String.fromEnvironment('BENCHMARK_OUTPUT');
        if (destination.isNotEmpty) {
          await File(destination).writeAsString('$text\n');
        }
        // Synthetic timing and counts only, never habit data.
        // ignore: avoid_print
        print(text);
      } finally {
        controller.dispose();
        await repository.close();
        await directory.delete(recursive: true);
      }
    },
    timeout: const Timeout(Duration(minutes: 10)),
  );
}
