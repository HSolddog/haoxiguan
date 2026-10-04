import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/state/habit_controller.dart';

import '../tools/native_sync/facts.dart';
import '../tools/native_sync/protocol.dart';

void main() {
  test(
    'source fixture includes full boolean/count/duration facts and plan history',
    () {
      final baseline = nativeSyncBaseline();
      final facts = SyncEntities.encodeFacts(baseline);
      int count(String prefix) =>
          facts.keys.where((k) => k.startsWith(prefix)).length;
      expect(count('h/'), 3);
      expect(count('p/'), 6);
      expect(count('r/'), 7);
      expect(count('n/'), 4);
      expect(nativeSyncFactsMatch(baseline), isTrue);
      expect(nativeSyncNewEntry('A').id, isNot(nativeSyncNewEntry('B').id));
      expect(nativeSyncNewEntry('A').date, nativeSyncNewEntry('B').date);
    },
  );

  test(
    'fact verification rejects loss or edits to IDs, revision, time, plans or notes',
    () {
      for (final change in <void Function(Map)>[
        (doc) => (doc['habits'] as List).removeLast(),
        (doc) => doc['habits'][0]['entries'][0]['id'] = 'replacement-entry',
        (doc) => doc['habits'][0]['entries'][0]['revision'] = 1,
        (doc) => doc['habits'][0]['entries'][0]['timezoneId'] = 'UTC',
        (doc) => doc['habits'][0]['entries'][0]['utcOffsetMinutes'] = 0,
        (doc) => doc['habits'][0]['entries'][0]['deleted'] = true,
        (doc) => doc['habits'][1]['plans'][1]['dailyTarget'] = 999,
        (doc) =>
            doc['habits'][1]['notes'][nativeSyncDay] = 'lost original note',
        (doc) => doc['habits'][2]['syntheticExtension']['revision'] = 2,
      ]) {
        final changed = jsonDecode(nativeSyncBaseline()) as Map;
        change(changed);
        expect(nativeSyncFactsMatch(jsonEncode(changed)), isFalse);
      }
    },
  );

  test(
    'production controller and SQLite preserve both same-day entries and merged facts',
    () async {
      final repository = SqliteHabitRepository(
        HabitDatabase(NativeDatabase.memory()),
      );
      final controller = HabitController(
        repository,
        clock: () => nativeSyncClock,
        timezoneId: () => 'UTC',
      );
      try {
        await repository.load();
        await repository.save(nativeSyncBaseline());
        await controller.load();
        for (final role in ['A', 'B']) {
          final entry = nativeSyncNewEntry(role);
          expect(
            await controller.addValue(
              nativeSyncCountHabit,
              nativeSyncClock,
              entry.value,
              entryId: entry.id,
            ),
            isTrue,
          );
        }
        expect(
          await controller.setNote(
            nativeSyncCountHabit,
            nativeSyncClock,
            nativeSyncMergedNote,
          ),
          isTrue,
        );
        expect(
          nativeSyncFactsMatch(controller.exportJson(), merged: true),
          isTrue,
        );
        expect(
          controller.habits
              .singleWhere((h) => h.id == nativeSyncCountHabit)
              .valueOn(nativeSyncClock),
          400,
        );
        for (final role in ['A', 'B']) {
          final snapshot = controller.exportJson();
          final entities = SyncEntities.encode(snapshot);
          final offline = nativeSyncNewEntry(role, offline: true);
          entities['r/${offline.id}'] = {
            'habitId': nativeSyncCountHabit,
            'data': offline.toJson(),
          };
          final withOffline = SyncEntities.assemble(snapshot, entities);
          expect(
            nativeSyncFactsMatch(withOffline, merged: true, offlineRole: role),
            isTrue,
          );
          expect(
            nativeSyncFactsMatch(snapshot, merged: true, offlineRole: role),
            isFalse,
          );
        }
        final saved = await repository.readSyncFrame();
        expect(saved.businessRevision, greaterThan(1));
        expect(
          syncAcceptanceCanonical(SyncEntities.encodeFacts(saved.snapshot)),
          nativeSyncExpected(merged: true),
        );
      } finally {
        controller.dispose();
        await repository.close();
      }
    },
  );
}
