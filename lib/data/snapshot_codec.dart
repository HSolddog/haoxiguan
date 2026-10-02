import 'dart:convert';

import '../models/habit.dart';

/// Logical format is independent from the SQLite schema and the app version.
class SnapshotCodec {
  static const currentVersion = 6;
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
    for (final item in items) {
      if (item is! Map<String, dynamic>) {
        throw const FormatException('习惯格式无效');
      }
      final habit = Habit.fromJson(item);
      final createdAt = item['createdAt'] as String;
      if (createdAt.length < 10) throw const FormatException('创建日期无效');
      requireDate(createdAt.substring(0, 10));
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
      for (final day in {
        ...habit.completions.keys,
        ...habit.notes.keys,
        ...habit.exemptions,
      }) {
        requireDate(day);
      }
      for (final timestamp in habit.completions.values) {
        if (DateTime.tryParse(timestamp) == null) {
          throw const FormatException('记录时间无效');
        }
      }
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
    return Map<String, Object?>.from(value);
  }

  static DateTime requireDate(String value) {
    final parsed = DateTime.tryParse(value);
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value) ||
        parsed == null ||
        dateKey(parsed) != value) {
      throw const FormatException('日期无效');
    }
    return parsed;
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
