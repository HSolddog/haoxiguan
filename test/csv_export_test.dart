import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/csv_export.dart';
import 'package:haoxiguan/state/habit_controller.dart';

void main() {
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
