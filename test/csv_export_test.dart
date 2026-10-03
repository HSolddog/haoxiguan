import 'dart:convert';
import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/csv_export.dart';
import 'package:haoxiguan/state/habit_controller.dart';

void main() {
  test('CSV preserves unknown legacy time separately from confirmed UTC', () {
    final snapshot = jsonEncode({
      'version': 6,
      'habits': [
        {
          'id': 'legacy-habit',
          'title': '旧记录',
          'emoji': '🌱',
          'colorValue': 0xff000000,
          'weekdays': [1],
          'createdAt': '2026-09-01',
          'completions': {'2026-09-02': '2026-09-02T09:00:00'},
        },
      ],
    });
    final records = utf8.decode(CsvExport.tables(snapshot)['records.csv']!);
    expect(records, contains('"recorded_at_utc"'));
    expect(records, contains('"legacy_timestamp"'));
    expect(
      records,
      contains(
        '"1","","2026-09-02","unknownLegacy","","legacy","2026-09-02T09:00:00"',
      ),
    );
  });
  test(
    'CSV archive splits all plans, records and notes with stable join IDs',
    () async {
      final c = HabitController(
        MemoryHabitRepository(),
        clock: () => DateTime(2026, 10, 3),
      );
      await c.load();
      await c.addHabit(
        title: '喝水',
        emoji: '💧',
        colorValue: 0xff000000,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        recordType: 'count',
        unit: '杯',
        scale: 1000,
        dailyTarget: 8000,
      );
      final h = c.habits.single;
      await c.addValue(h.id, c.today, 1500, entryId: 'independent-entry');
      await c.setNote(h.id, c.today, '@保留,备注\n第二行');
      await c.updateHabit(
        habitId: h.id,
        title: h.title,
        emoji: h.emoji,
        colorValue: h.colorValue,
        weekdays: h.weekdays,
        scheduleType: 'week',
        scheduleCount: 3,
        dailyTarget: 9000,
      );
      final tables = CsvExport.tables(c.exportJson());
      expect(tables.keys, [
        'habits.csv',
        'plans.csv',
        'records.csv',
        'notes.csv',
        'categories.csv',
      ]);
      final plans = utf8.decode(tables['plans.csv']!);
      expect(
        utf8.decode(tables['categories.csv']!),
        contains('"${h.categoryId}"'),
      );
      expect(
        utf8.decode(tables['habits.csv']!),
        contains('"category_id","sort_key"'),
      );
      for (final plan in c.habits.single.plans) {
        expect(plans, contains('"${plan.id}"'));
      }
      expect(plans, contains('"2026-10-03","2026-10-04","daily"'));
      expect(plans, contains('"2026-10-04","","week"'));
      expect(plans, contains('"3","9","9000","1000","杯","false"'));
      final records = utf8.decode(tables['records.csv']!);
      expect(
        records,
        contains('"independent-entry","${h.id}","${h.plans.first.id}"'),
      );
      expect(records, contains('"1.5","1500","1000","杯"'));
      expect(utf8.decode(tables['notes.csv']!), contains('"\'@保留,备注\n第二行"'));
      expect(utf8.decode(CsvExport.encode(c.exportJson())), contains('"plan"'));
      final archive = ZipDecoder().decodeBytes(
        CsvExport.encodeArchive(c.exportJson()),
      );
      expect(archive.files.map((f) => f.name), [...tables.keys, 'README.txt']);
      for (final name in tables.keys) {
        expect(archive.findFile(name)!.content, tables[name]);
      }
      c.dispose();
    },
  );

  test(
    'CSV marks duration values and targets as seconds without rounding',
    () async {
      final c = HabitController(MemoryHabitRepository());
      await c.load();
      await c.addHabit(
        title: '阅读',
        emoji: '📖',
        colorValue: 0xff000000,
        weekdays: {1},
        recordType: 'duration',
        unit: '分钟',
        dailyTarget: 1200,
      );
      await c.addValue(c.habits.single.id, c.today, 61);
      final tables = CsvExport.tables(c.exportJson());
      expect(
        utf8.decode(tables['records.csv']!),
        contains('"61","61","1","second"'),
      );
      expect(
        utf8.decode(tables['plans.csv']!),
        contains('"1200","1200","1","second"'),
      );
      c.dispose();
    },
  );
  test(
    'CSV preserves exact values, Unicode, multiline quotes, empty habits and deleted facts',
    () async {
      final c = HabitController(MemoryHabitRepository());
      await c.load();
      await c.addHabit(
        title: '=SUM(1,2)',
        emoji: '🌱',
        colorValue: 0xff000000,
        weekdays: {1},
        recordType: 'count',
        scale: 1000,
        dailyTarget: 1000,
      );
      final id = c.habits.single.id;
      await c.addValue(id, c.today, 123);
      await c.setNote(id, c.today, '中文,"引号"\n第二行');
      await c.deleteEntry(id, c.habits.single.entries.single.id);
      await c.addHabit(
        title: '空习惯',
        emoji: '🌱',
        colorValue: 0xff000000,
        weekdays: {1},
      );
      final bytes = CsvExport.encode(c.exportJson());
      expect(bytes.take(3), [0xef, 0xbb, 0xbf]);
      final csv = utf8.decode(bytes);
      expect(csv.startsWith('"row_type"'), true);
      expect(csv, contains('"\'=SUM(1,2)"'));
      expect(csv, contains('"0.123","123","1000","true"'));
      expect(csv, contains('"中文,""引号""\n第二行"'));
      expect(csv, contains('"空习惯"'));
      expect(csv.endsWith('\r\n'), true);
      c.dispose();
    },
  );
  test(
    'appearance follows system for a new install and preserves explicit legacy choices',
    () async {
      final fresh = HabitController(MemoryHabitRepository());
      await fresh.load();
      expect(fresh.appearanceMode, 'system');
      final legacy = MemoryHabitRepository(
        jsonEncode({'version': 7, 'habits': [], 'darkMode': true}),
      );
      final c = HabitController(legacy);
      await c.load();
      expect(c.appearanceMode, 'dark');
      expect(await c.setAppearanceMode('system'), true);
      final reopened = HabitController(legacy);
      await reopened.load();
      expect(reopened.appearanceMode, 'system');
      expect(await reopened.setAppearanceMode('invalid'), false);
      expect(reopened.appearanceMode, 'system');
      fresh.dispose();
      c.dispose();
      reopened.dispose();
    },
  );
}
