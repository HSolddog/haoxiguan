import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import '../data/snapshot_codec.dart';
import '../models/habit.dart';
import '../models/record_entry.dart';

/// Readable analysis export, not a restorable backup. IDs join the tables;
/// raw integer values and scale avoid a spreadsheet rounding the source facts.
class CsvExport {
  static const _headers = [
    'row_type',
    'habit_id',
    'habit_title',
    'category',
    'record_type',
    'unit',
    'date',
    'record_id',
    'value',
    'raw_value',
    'scale',
    'deleted',
    'recorded_at_utc',
    'recorded_local_date',
    'timezone',
    'utc_offset_minutes',
    'source',
    'note',
    'archived',
    'in_trash',
    'start_date',
    'paused_from',
    'archived_from',
    'deleted_at',
    'rest_dates',
    'reminder_time',
    'plan_id',
    'effective_from',
    'effective_until_exclusive',
    'plan_kind',
    'weekdays',
    'period_target_days',
    'daily_target',
    'daily_target_raw',
    'value_unit',
    'legacy_inferred',
    'record_revision',
    'legacy_timestamp',
  ];

  /// Kept for callers needing one rectangular CSV. Plan rows are explicit.
  static Uint8List encode(String snapshot) => _csv(_headers, _rows(snapshot));

  static Map<String, Uint8List> tables(String snapshot) {
    final rows = _rows(snapshot);
    const schemas = {
      'habits.csv': [
        'habit_id',
        'habit_title',
        'category',
        'record_type',
        'unit',
        'scale',
        'start_date',
        'paused_from',
        'archived',
        'archived_from',
        'in_trash',
        'deleted_at',
        'rest_dates',
        'reminder_time',
      ],
      'plans.csv': [
        'plan_id',
        'habit_id',
        'effective_from',
        'effective_until_exclusive',
        'plan_kind',
        'weekdays',
        'period_target_days',
        'daily_target',
        'daily_target_raw',
        'scale',
        'value_unit',
        'legacy_inferred',
      ],
      'records.csv': [
        'record_id',
        'habit_id',
        'plan_id',
        'date',
        'value',
        'raw_value',
        'scale',
        'value_unit',
        'deleted',
        'record_revision',
        'recorded_at_utc',
        'recorded_local_date',
        'timezone',
        'utc_offset_minutes',
        'source',
        'legacy_timestamp',
      ],
      'notes.csv': ['habit_id', 'date', 'note'],
    };
    const types = {
      'habits.csv': 'habit',
      'plans.csv': 'plan',
      'records.csv': 'record',
      'notes.csv': 'note',
    };
    return {
      for (final schema in schemas.entries)
        schema.key: _csv(
          schema.value,
          rows.where((row) => row['row_type'] == types[schema.key]),
        ),
    };
  }

  /// One OS save operation delivers all related CSV tables together.
  static Uint8List encodeArchive(String snapshot) {
    final archive = Archive();
    for (final table in tables(snapshot).entries) {
      archive.addFile(ArchiveFile(table.key, table.value.length, table.value));
    }
    final readme = utf8.encode(
      '好习惯 CSV 分表导出（明文，仅供分析，不能替代可恢复备份）\n'
      'habits.csv：习惯、开始日期、暂停/归档/回收站及休息日期。\n'
      'plans.csv：所有计划版本；habit_id 关联习惯，plan_id 关联记录。\n'
      'effective_until_exclusive 是下一版本开始日期，不含当天；空值表示尚无后续版本。\n'
      'records.csv：独立记录 ID、所属日期、实际录入时间/时区及撤销标记。\n'
      'notes.csv：按 habit_id + date 关联的备注。\n'
      'raw_value / daily_target_raw 为原始整数；计数值除以 scale，时长单位为秒。\n'
      'period_target_days 为配置目标；实际周期目标还需按开始、暂停、休息、归档日期计算。\n'
      'legacy_inferred=true 表示从旧版推导的计划，不是原始计划历史。\n'
      'deleted=true 的记录保留用于复核，不计入当前完成值。\n'
      '公式前缀文字以单引号转义；所有 CSV 使用 UTF-8 BOM 和 RFC 4180 引号。\n',
    );
    archive.addFile(ArchiveFile('README.txt', readme.length, readme));
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  static List<Map<String, Object?>> _rows(String snapshot) {
    final data = SnapshotCodec.decode(snapshot);
    final rows = <Map<String, Object?>>[];
    for (final raw in data['habits']! as List) {
      final h = Habit.fromJson((raw as Map).cast<String, Object?>());
      final common = <String, Object?>{
        'habit_id': h.id,
        'habit_title': h.title,
        'category': h.category,
        'record_type': h.recordType,
        'unit': h.unit,
        'scale': h.scale,
        'archived': h.archived,
        'in_trash': h.inTrash,
        'value_unit': h.recordType == 'duration' ? 'second' : h.unit,
      };
      rows.add({
        ...common,
        'row_type': 'habit',
        'start_date': dateKey(h.createdAt),
        'paused_from': h.pausedAt == null ? null : dateKey(h.pausedAt!),
        'archived_from': h.archivedAt == null ? null : dateKey(h.archivedAt!),
        'deleted_at': h.deletedAt?.toIso8601String(),
        'rest_dates': (h.exemptions.toList()..sort()).join(';'),
        'reminder_time': h.reminderTime,
      });
      final plans = h.effectivePlans;
      for (var i = 0; i < plans.length; i++) {
        final plan = plans[i];
        rows.add({
          ...common,
          'row_type': 'plan',
          'plan_id': plan.id,
          'effective_from': dateKey(plan.from),
          'effective_until_exclusive': i + 1 < plans.length
              ? dateKey(plans[i + 1].from)
              : null,
          'plan_kind': plan.kind,
          'weekdays': (plan.weekdays.toList()..sort()).join(';'),
          'period_target_days': plan.periodTarget,
          'daily_target': formatFixed(plan.dailyTarget, scale: h.scale),
          'daily_target_raw': plan.dailyTarget,
          'legacy_inferred': plan.legacyInferred,
        });
      }
      final entries = h.entries.toList()
        ..sort((a, b) {
          final byDate = a.date.compareTo(b.date);
          return byDate == 0 ? a.id.compareTo(b.id) : byDate;
        });
      for (final e in entries) {
        rows.add({
          ...common,
          'row_type': 'record',
          'date': e.date,
          'record_id': e.id,
          'value': formatFixed(e.value, scale: h.scale),
          'raw_value': e.value,
          'deleted': e.deleted,
          'record_revision': e.revision,
          'plan_id': h.planOn(DateTime.parse(e.date)).id,
          'recorded_at_utc': e.recordedAtUtc,
          'legacy_timestamp': e.legacyTimestamp,
          'recorded_local_date': e.recordedLocalDate,
          'timezone': e.timezoneId,
          'utc_offset_minutes': e.utcOffsetMinutes,
          'source': e.source,
        });
      }
      for (final date in h.notes.keys.toList()..sort()) {
        rows.add({
          ...common,
          'row_type': 'note',
          'date': date,
          'note': h.notes[date],
        });
      }
    }
    return rows;
  }

  static Uint8List _csv(
    List<String> headers,
    Iterable<Map<String, Object?>> rows,
  ) {
    final out = StringBuffer('\ufeff');
    void row(Iterable<Object?> cells) {
      out.writeAll(cells.map(_cell), ',');
      out.write('\r\n');
    }

    row(headers);
    for (final values in rows) {
      row(headers.map((header) => values[header]));
    }
    return Uint8List.fromList(utf8.encode(out.toString()));
  }

  static String _cell(Object? value) {
    var text = value?.toString() ?? '';
    if (value is String && RegExp(r'^\s*[=+\-@]').hasMatch(text)) {
      text = "'$text";
    }
    return '"${text.replaceAll('"', '""')}"';
  }
}
