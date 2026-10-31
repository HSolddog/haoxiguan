import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/state/habit_controller.dart';

/// Settings → 粘贴旧版 JSON confirms through this branch:
/// preview with [BackupPreview.forRestore], then [HabitController.importJson]
/// unless the file needs the explicit legacy-text confirmation.
Future<bool> importLikeSettingsJson(HabitController controller, String raw) {
  final preview = BackupPreview.forRestore(raw);
  return preview.requiresCompatibilityConfirmation
      ? controller.restoreCompatibleBackup(raw)
      : controller.importJson(raw);
}

void main() {
  test('设置页导入 v5 JSON 不丢失习惯、计划、打卡和备注', () async {
    final raw = File('test/fixtures/legacy_state_v5.json').readAsStringSync();
    final source = jsonDecode(raw) as Map<String, dynamic>;
    final sourceHabits = (source['habits'] as List)
        .map((item) => (item as Map).cast<String, dynamic>())
        .toList();
    expect(source['version'], 5);
    expect(
      {
        for (final habit in sourceHabits)
          habit['title'] as String: (habit['completions'] as Map).length,
      },
      {'阅读': 2, '十一点半前睡觉': 18, '运动': 13, '看书做题目': 24},
    );
    expect(
      {
        for (final habit in sourceHabits)
          habit['title'] as String: (habit['notes'] as Map).length,
      },
      {'阅读': 0, '十一点半前睡觉': 0, '运动': 4, '看书做题目': 3},
    );

    final repository = MemoryHabitRepository();
    final controller = HabitController(
      repository,
      clock: () => DateTime(2026, 10, 31),
    );
    await controller.load();
    expect(controller.habits, isEmpty);

    final preview = BackupPreview.forRestore(raw);
    expect(preview.requiresCompatibilityConfirmation, isFalse);
    expect(preview.habits, 4);
    expect(preview.records, 57);
    expect(preview.notes, 7);
    expect(await importLikeSettingsJson(controller, raw), isTrue);
    expect(controller.saveError, isNull);
    _expectPreserved(controller, source);

    final reloaded = HabitController(
      MemoryHabitRepository(repository.value),
      clock: () => DateTime(2026, 10, 31),
    );
    addTearDown(reloaded.dispose);
    await reloaded.load();
    _expectPreserved(reloaded, source);
    controller.dispose();
  });
}

void _expectPreserved(HabitController controller, Map<String, dynamic> source) {
  expect(controller.darkMode, source['darkMode']);
  expect(controller.themeColorValue, source['themeColorValue']);
  expect(controller.reviewDays, source['reviewDays']);
  expect(controller.habits, hasLength(4));
  expect(controller.categories.toSet(), {'自己', '久久'});

  final byTitle = {for (final habit in controller.habits) habit.title: habit};
  for (final raw in source['habits'] as List) {
    final item = (raw as Map).cast<String, dynamic>();
    final title = item['title'] as String;
    final habit = byTitle[title];
    expect(habit, isNotNull, reason: title);
    final imported = habit!;
    expect(imported.id, item['id']);
    expect(imported.emoji, item['emoji']);
    expect(imported.colorValue, item['colorValue']);
    expect(imported.category, item['category']);
    expect(imported.weekdays, (item['weekdays'] as List).cast<int>().toSet());
    expect(
      dateKey(imported.createdAt),
      (item['createdAt'] as String).substring(0, 10),
    );
    expect(imported.reminderTime, item['reminderTime']);
    expect(imported.pausedAt, isNull);
    expect(imported.archived, isFalse);
    expect(imported.exemptions, isEmpty);
    expect(imported.scheduleType, item['scheduleType']);
    expect(imported.scheduleCount, item['scheduleCount']);
    expect(imported.effortEnabled, item['effortEnabled']);
    expect(imported.rewardPoints, item['rewardPoints']);
    expect(imported.penaltyPoints, item['penaltyPoints']);
    expect(imported.targetCount, item['targetCount']);
    expect(imported.rewardPeriod, item['rewardPeriod']);
    expect(imported.wishEnabled, item['wishEnabled']);
    expect(imported.wishTitle, item['wishTitle']);
    expect(imported.wishTarget, item['wishTarget']);
    expect(
      imported.completions,
      (item['completions'] as Map).cast<String, String>(),
    );
    expect(imported.notes, (item['notes'] as Map).cast<String, String>());
  }
}
