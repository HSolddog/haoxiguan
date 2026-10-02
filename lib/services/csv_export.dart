import 'dart:convert';
import 'dart:typed_data';

import '../data/snapshot_codec.dart';
import '../models/habit.dart';
import '../models/record_entry.dart';

/// Analysis export, not a restorable backup. RFC 4180 quoting and a UTF-8 BOM
/// support common spreadsheet tools. User-controlled formula prefixes are escaped.
class CsvExport {
  static Uint8List encode(String snapshot) {
    final data = SnapshotCodec.decode(snapshot);
    final out = StringBuffer('\ufeff');
    void row(List<Object?> cells) {
      out.writeAll(cells.map(_cell), ',');
      out.write('\r\n');
    }

    row([
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
    ]);
    for (final raw in data['habits']! as List) {
      final h = Habit.fromJson((raw as Map).cast<String, Object?>());
      final common = [h.id, h.title, h.category, h.recordType, h.unit];
      // Keep empty/archived/trashed habits visible in the export.
      row([
        'habit',
        ...common,
        '',
        '',
        '',
        '',
        h.scale,
        '',
        '',
        '',
        '',
        '',
        '',
        '',
        h.archived,
        h.inTrash,
      ]);
      final entries = h.entries.toList()
        ..sort((a, b) {
          final byDate = a.date.compareTo(b.date);
          return byDate == 0 ? a.id.compareTo(b.id) : byDate;
        });
      for (final e in entries) {
        row([
          'record',
          ...common,
          e.date,
          e.id,
          formatFixed(e.value, scale: h.scale),
          e.value,
          h.scale,
          e.deleted,
          e.recordedAtUtc ?? e.legacyTimestamp,
          e.recordedLocalDate,
          e.timezoneId,
          e.utcOffsetMinutes,
          e.source,
          '',
          h.archived,
          h.inTrash,
        ]);
      }
      final dates = h.notes.keys.toList()..sort();
      for (final date in dates) {
        row([
          'note',
          ...common,
          date,
          '',
          '',
          '',
          h.scale,
          '',
          '',
          '',
          '',
          '',
          '',
          h.notes[date],
          h.archived,
          h.inTrash,
        ]);
      }
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
