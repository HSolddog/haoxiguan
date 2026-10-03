import 'dart:convert';

import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/models/category.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/models/plan.dart';
import 'package:haoxiguan/models/record_entry.dart';
import 'package:haoxiguan/services/sync_entities.dart';

import 'protocol.dart';

const nativeSyncCountHabit = 'native-sync-count';
const nativeSyncDay = '2026-07-13';
const nativeSyncInitialNote = 'synthetic initial shared note';
const nativeSyncMergedNote = 'synthetic device A + device B manually merged';
final nativeSyncClock = DateTime.utc(2026, 7, 13, 10, 30);

RecordEntry nativeSyncNewEntry(
  String role, {
  bool offline = false,
}) => RecordEntry(
  id: 'native-sync-${role.toLowerCase()}-${offline ? 'offline' : 'same-day'}',
  date: nativeSyncDay,
  value: offline
      ? 7
      : role == 'A'
      ? 40
      : 60,
  recordedAtUtc: nativeSyncClock.toIso8601String(),
  recordedLocalDate: nativeSyncDay,
  timezoneId: 'UTC',
  utcOffsetMinutes: 0,
);

/// The same synthetic boolean/count/duration facts used by native acceptance,
/// with stable IDs and additional plan/entry revisions for exhaustive comparison.
/// B derives the expected facts; it never receives A's SQLite file or key store.
String nativeSyncBaseline() {
  final habits = <Habit>[];
  for (final type in ['boolean', 'count', 'duration']) {
    final id = 'native-sync-$type';
    final target = type == 'count'
        ? 300
        : type == 'duration'
        ? 90
        : 1;
    RecordEntry entry(String suffix, int value, {bool deleted = false}) =>
        RecordEntry(
          id: '$id-$suffix',
          date: nativeSyncDay,
          value: value,
          recordedAtUtc: '2026-07-13T02:30:00.000Z',
          recordedLocalDate: nativeSyncDay,
          timezoneId: 'Asia/Shanghai',
          utcOffsetMinutes: 480,
          deleted: deleted,
          revision: deleted ? 4 : 2,
        );
    habits.add(
      Habit(
        id: id,
        title: 'acceptance-$type',
        emoji: '\u{1F331}',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        createdAt: DateTime(2026, 7, 1),
        reminderTime: type == 'boolean' ? '23:59' : null,
        recordType: type,
        scale: type == 'count' ? 1000 : 1,
        dailyTarget: target,
        unit: type == 'duration' ? 'seconds' : 'units',
        category: 'synthetic native acceptance',
        entries: [
          if (type == 'count') ...[
            entry('first', 100),
            entry('second', 200),
          ] else
            entry('first', target),
          entry('withdrawn', 1, deleted: true),
        ],
        notes: type == 'count'
            ? {nativeSyncDay: nativeSyncInitialNote, '2026-07-12': 'older note'}
            : {'2026-07-12': 'synthetic $type note'},
        plans: [
          PlanVersion(
            id: '$id-initial-plan',
            from: DateTime.utc(2026, 7, 1),
            kind: 'daily',
            weekdays: {1, 2, 3, 4, 5, 6, 7},
            periodTarget: 1,
            dailyTarget: target,
          ),
          PlanVersion(
            id: '$id-future-plan',
            from: DateTime.utc(2026, 7, 15),
            kind: 'weekdays',
            weekdays: {1, 3, 5},
            periodTarget: 1,
            dailyTarget: type == 'boolean' ? 1 : target + 10,
          ),
        ],
        extensions: const {
          'syntheticExtension': {'retained': true, 'revision': 3},
        },
      ),
    );
  }
  final raw = jsonEncode(
    CategoryMetadata.normalize({
      ...SnapshotCodec.decode(SnapshotCodec.empty()),
      'habits': habits.map((h) => h.toJson()).toList(),
    }),
  );
  SnapshotCodec.decode(raw);
  return raw;
}

String nativeSyncExpected({bool merged = false, String? offlineRole}) {
  final facts = SyncEntities.encodeFacts(nativeSyncBaseline());
  if (merged) {
    for (final role in ['A', 'B']) {
      final entry = nativeSyncNewEntry(role);
      facts['r/${entry.id}'] = {
        'habitId': nativeSyncCountHabit,
        'data': entry.toJson(),
      };
    }
    final note =
        facts.values.singleWhere(
              (v) =>
                  v is Map &&
                  v['habitId'] == nativeSyncCountHabit &&
                  v['date'] == nativeSyncDay,
            )
            as Map;
    note['text'] = nativeSyncMergedNote;
  }
  if (offlineRole != null) {
    final entry = nativeSyncNewEntry(offlineRole, offline: true);
    facts['r/${entry.id}'] = {
      'habitId': nativeSyncCountHabit,
      'data': entry.toJson(),
    };
  }
  return syncAcceptanceCanonical(facts);
}

bool nativeSyncFactsMatch(
  String snapshot, {
  bool merged = false,
  String? offlineRole,
}) =>
    syncAcceptanceCanonical(SyncEntities.encodeFacts(snapshot)) ==
    nativeSyncExpected(merged: merged, offlineRole: offlineRole);
