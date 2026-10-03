import '../data/snapshot_codec.dart';
import '../models/habit.dart';

/// Only derive counts and dates after the snapshot has passed validation.
class BackupPreview {
  const BackupPreview({
    required this.habits,
    required this.records,
    required this.notes,
    required this.deletedRecords,
    this.createdAtUtc,
    this.firstDate,
    this.lastDate,
  });

  factory BackupPreview.fromSnapshot(String raw, {DateTime? createdAtUtc}) {
    final document = SnapshotCodec.decode(raw);
    final habits = (document['habits']! as List)
        .map((h) => Habit.fromJson((h as Map).cast<String, Object?>()))
        .toList();
    var records = 0, notes = 0, deletedRecords = 0;
    final dates = <String>[];
    for (final habit in habits) {
      // Span covers dated facts and notes, not future plans or export time.
      for (final entry in habit.entries) {
        if (entry.deleted) {
          deletedRecords++;
        } else {
          records++;
          dates.add(entry.date);
        }
      }
      notes += habit.notes.length;
      dates.addAll(habit.notes.keys);
    }
    dates.sort();
    return BackupPreview(
      habits: habits.length,
      records: records,
      notes: notes,
      deletedRecords: deletedRecords,
      createdAtUtc: createdAtUtc,
      firstDate: dates.firstOrNull,
      lastDate: dates.lastOrNull,
    );
  }

  final int habits, records, notes, deletedRecords;
  final DateTime? createdAtUtc;
  final String? firstDate, lastDate;
  String get summary =>
      '创建于：${createdAtUtc?.toLocal().toString() ?? '旧文件未提供'}\n'
      '$habits 个习惯 · $records 条记录 · $notes 条备注\n'
      '${deletedRecords > 0 ? '另含 $deletedRecords 条已撤销记录\n' : ''}'
      '校验通过 · ${firstDate == null ? '暂无记录或备注日期' : '记录与备注日期 $firstDate 至 $lastDate'}';
}
