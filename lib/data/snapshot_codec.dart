import 'dart:convert';

import '../models/habit.dart';
import '../models/category.dart';

/// Logical format is independent from the SQLite schema and the app version.
class SnapshotCodec {
  static const currentVersion = 7;
  static const maxBytes = 50 * 1024 * 1024;

  static Map<String, Object?> decode(String raw) {
    if (utf8.encode(raw).length > maxBytes) {
      throw const FormatException('数据超过 50 MiB，未修改原数据');
    }
    final value = jsonDecode(raw);
    if (value is! Map<String, dynamic>) {
      throw const FormatException('数据根节点应为对象');
    }
    final version = value['version'] ?? 1;
    if (version is! int || version < 1) {
      throw const FormatException('数据版本无效');
    }
    if (version > currentVersion) throw UnsupportedSnapshotVersion(version);
    final items = value['habits'];
    if (items is! List || items.length > 10000) {
      throw const FormatException('习惯列表无效');
    }
    final ids = <String>{};
    final allRecordIds = <String>{};
    final allPlanIds = <String>{};
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('习惯格式无效');
      }
      if (item['plans'] case final List plans) {
        for (final plan in plans) {
          requireDate((plan as Map)['from'] as String);
        }
      }
      final habit = Habit.fromJson(item);
      if (version >= 7 && habit.plans.isEmpty) {
        throw const FormatException('计划历史缺失，未修改原数据');
      }
      final createdAt = item['createdAt'] as String;
      if (createdAt.length < 10) throw const FormatException('创建日期无效');
      requireDate(createdAt.substring(0, 10));
      if (!const {'boolean', 'count', 'duration'}.contains(habit.recordType) ||
          !const {1, 10, 100, 1000}.contains(habit.scale) ||
          habit.dailyTarget <= 0 ||
          habit.dailyTarget > 1000000000000 ||
          (habit.recordType != 'count' && habit.scale != 1) ||
          (habit.recordType == 'boolean' && habit.dailyTarget != 1) ||
          habit.unit.isEmpty ||
          habit.unit.length > 20) {
        throw const FormatException('记录类型或目标无效');
      }
      final planIds = <String>{};
      DateTime? previousPlan;
      for (final plan in habit.plans) {
        requireDate(plan.toJson()['from']! as String);
        if (!planIds.add(plan.id) ||
            !allPlanIds.add(plan.id) ||
            plan.id.isEmpty ||
            (previousPlan != null && !plan.from.isAfter(previousPlan)) ||
            (previousPlan == null &&
                dateKey(plan.from) != dateKey(habit.createdAt)) ||
            !const {'daily', 'weekdays', 'week', 'month'}.contains(plan.kind) ||
            plan.weekdays.isEmpty ||
            plan.weekdays.any((d) => d < 1 || d > 7) ||
            plan.periodTarget < 1 ||
            plan.periodTarget > (plan.kind == 'week' ? 7 : 31) ||
            plan.dailyTarget <= 0 ||
            plan.dailyTarget > 1000000000000 ||
            (habit.recordType == 'boolean' && plan.dailyTarget != 1)) {
          throw const FormatException('计划版本无效或时间区间重叠');
        }
        previousPlan = plan.from;
      }
      final recordIds = <String>{};
      final booleanDates = <String>{};
      for (final entry in habit.entries) {
        final date = requireDate(entry.date);
        requireDate(entry.recordedLocalDate);
        if (!recordIds.add(entry.id) ||
            !allRecordIds.add(entry.id) ||
            entry.id.isEmpty ||
            date.isBefore(dateOnly(habit.createdAt)) ||
            entry.value <= 0 ||
            entry.value > 1000000000000 ||
            entry.revision < 1 ||
            (habit.recordType == 'boolean' &&
                (entry.value != 1 ||
                    (!entry.deleted && !booleanDates.add(entry.date)))) ||
            (entry.recordedAtUtc == null &&
                (entry.source != 'legacy' || entry.legacyTimestamp == null)) ||
            (entry.recordedAtUtc != null &&
                DateTime.tryParse(entry.recordedAtUtc!)?.isUtc != true) ||
            (entry.legacyTimestamp != null &&
                DateTime.tryParse(entry.legacyTimestamp!) == null) ||
            (entry.utcOffsetMinutes != null &&
                entry.utcOffsetMinutes!.abs() > 24 * 60)) {
          throw const FormatException('记录数据无效或重复');
        }
      }
      if (habit.id.isEmpty || !ids.add(habit.id)) {
        throw const FormatException('习惯 ID 为空或重复');
      }
      if (habit.title.trim().isEmpty || habit.title.length > 1000) {
        throw const FormatException('习惯名称无效');
      }
      if (habit.weekdays.any((day) => day < 1 || day > 7) ||
          habit.weekdays.isEmpty ||
          !const {
            'daily',
            'weekdays',
            'week',
            'month',
          }.contains(habit.scheduleType) ||
          habit.scheduleCount < 1 ||
          habit.scheduleCount > 31) {
        throw const FormatException('习惯计划无效');
      }
      if (habit.reminderTime != null &&
          !RegExp(
            r'^(?:[01]\d|2[0-3]):[0-5]\d$',
          ).hasMatch(habit.reminderTime!)) {
        throw const FormatException('提醒时间无效');
      }
      for (final day in {...habit.notes.keys, ...habit.exemptions}) {
        requireDate(day);
      }
      // Legacy completions are converted to entries by Habit.fromJson and are
      // checked above. Rebuilding the completion projection twice here repeats
      // calendar calculations for the full history without validating new facts.
    }
    if (value['appearanceMode'] != null &&
        !const {'system', 'light', 'dark'}.contains(value['appearanceMode'])) {
      throw const FormatException('外观设置无效');
    }
    for (final key in ['darkMode']) {
      if (value[key] != null && value[key] is! bool) {
        throw FormatException('$key 设置无效');
      }
    }
    for (final key in ['themeColorValue', 'reviewDays']) {
      if (value[key] != null && value[key] is! int) {
        throw FormatException('$key 设置无效');
      }
    }
    for (final key in [
      'collapsedTodayCategories',
      'collapsedHabitCategories',
    ]) {
      if (value[key] != null &&
          (value[key] is! List ||
              (value[key] as List).any((item) => item is! String))) {
        throw FormatException('$key 设置无效');
      }
    }
    final document = Map<String, Object?>.from(value);
    CategoryMetadata.validate(document);
    return document;
  }

  static DateTime requireDate(String value) {
    final parsed = DateTime.tryParse(value);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
        parsed == null ||
        dateKey(parsed) != value) {
      throw const FormatException('日期无效');
    }
    return dateOnly(parsed);
  }

  static String empty() =>
      jsonEncode({'version': currentVersion, 'habits': <Object>[]});
}

class UnsupportedSnapshotVersion implements Exception {
  const UnsupportedSnapshotVersion(this.version);
  final int version;
  @override
  String toString() => '数据版本 $version 高于此应用支持的版本，请更新应用；原数据已保留。';
}

class DataRecoveryRequired implements Exception {
  const DataRecoveryRequired(this.message);
  final String message;
  @override
  String toString() => message;
}
