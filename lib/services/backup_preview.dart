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
    this.oversizedTitles = 0,
    this.longestTitle = 0,
    this.oversizedNotes = 0,
    this.longestNote = 0,
  });

  factory BackupPreview.fromSnapshot(String raw, {DateTime? createdAtUtc}) =>
      _fromDocument(
        SnapshotCodec.decodeImport(raw),
        createdAtUtc: createdAtUtc,
      );

  /// Restore previews report legacy text limits instead of rejecting otherwise
  /// compatible facts. Restoring them requires a separate explicit confirmation.
  factory BackupPreview.forRestore(String raw, {DateTime? createdAtUtc}) =>
      _fromDocument(SnapshotCodec.decode(raw), createdAtUtc: createdAtUtc);

  static BackupPreview _fromDocument(
    Map<String, Object?> document, {
    DateTime? createdAtUtc,
  }) {
    final habits = (document['habits']! as List)
        .map((h) => Habit.fromJson((h as Map).cast<String, Object?>()))
        .toList();
    var records = 0, notes = 0, deletedRecords = 0;
    var oversizedTitles = 0, longestTitle = 0;
    var oversizedNotes = 0, longestNote = 0;
    final dates = <String>[];
    for (final habit in habits) {
      if (habit.title.length > 80) {
        oversizedTitles++;
        if (habit.title.length > longestTitle) {
          longestTitle = habit.title.length;
        }
      }
      for (final note in habit.notes.values) {
        if (note.length > 2000) {
          oversizedNotes++;
          if (note.length > longestNote) longestNote = note.length;
        }
      }
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
      oversizedTitles: oversizedTitles,
      longestTitle: longestTitle,
      oversizedNotes: oversizedNotes,
      longestNote: longestNote,
    );
  }

  final int habits, records, notes, deletedRecords;
  final int oversizedTitles, longestTitle, oversizedNotes, longestNote;
  bool get requiresCompatibilityConfirmation =>
      oversizedTitles > 0 || oversizedNotes > 0;

  String get compatibilitySummary => [
    if (oversizedTitles > 0)
      '$oversizedTitles 个标题超过 80 个字符，最长 $longestTitle 个字符。',
    if (oversizedNotes > 0) '$oversizedNotes 条备注超过 2000 字，最长 $longestNote 字。',
  ].join('\n');
  final DateTime? createdAtUtc;
  final String? firstDate, lastDate;
  String get summary =>
      '创建于：${createdAtUtc?.toLocal().toString() ?? '旧文件未提供'}\n'
      '$habits 个习惯 · $records 条记录 · $notes 条备注\n'
      '${deletedRecords > 0 ? '另含 $deletedRecords 条已撤销记录\n' : ''}'
      '${requiresCompatibilityConfirmation ? '待确认超长文本' : '校验通过'} · ${firstDate == null ? '暂无记录或备注日期' : '记录与备注日期 $firstDate 至 $lastDate'}';
}
