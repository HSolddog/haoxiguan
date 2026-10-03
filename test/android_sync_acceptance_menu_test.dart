import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/ui/sync_screen.dart';

import '../tools/android_sync_acceptance.dart';
import '../tools/native_sync/facts.dart';

void main() {
  testWidgets(
    'native first review selects the actual remote menu for all 20 candidates',
    (tester) async {
      tester.view.physicalSize = const Size(412, 915);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final empty = SnapshotCodec.empty();
      final remote = SyncEntities.encode(nativeSyncBaseline());
      final decision = SyncEntities.merge(empty, {}, remote);
      for (final key in remote.keys) {
        final habitId = SyncEntities.habitId(key, remote[key]);
        if (habitId != null) decision.reviewHabit(habitId);
      }
      expect(decision.local, isEmpty);
      expect(decision.items, hasLength(20));
      expect(
        decision.items.every(
          (item) => item.local == null && item.remote != null,
        ),
        isTrue,
      );
      Map<String, SyncSelection>? applied;
      String? imported;
      const open = ValueKey('open-production-review');
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (context) => TextButton(
                key: open,
                onPressed: () => showDialog<bool>(
                  context: context,
                  builder: (_) => SyncConflictDialog(
                    decision: decision,
                    onApply: (selections) async {
                      applied = selections;
                      imported = SyncEntities.assemble(
                        empty,
                        decision.select(selections),
                      );
                    },
                  ),
                ),
                child: const Text('Open production review'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byKey(open));
      await tester.pumpAndSettle();
      final apply = find.descendant(
        of: find.byType(SyncConflictDialog),
        matching: find.byType(FilledButton),
      );
      expect(tester.widget<FilledButton>(apply).onPressed, isNull);

      for (final item in decision.items) {
        final dropdown = find.byKey(ValueKey(item.id));
        await tester.ensureVisible(dropdown);
        await tester.pumpAndSettle();
        await tester.tap(dropdown);
        await tester.pump(const Duration(milliseconds: 180));
        final choice = nativeSyncChoiceMenuItem(SyncChoice.remote);
        expect(choice, findsOneWidget);
        expect(
          tester
              .element(choice)
              .findAncestorWidgetOfExactType<DropdownMenuItem<SyncChoice>>()!
              .value,
          SyncChoice.remote,
        );
        await tester.ensureVisible(choice);
        await tester.pump(const Duration(milliseconds: 180));
        await tester.tap(choice);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(applied, isNull);
      }
      expect(tester.widget<FilledButton>(apply).onPressed, isNotNull);
      await tester.tap(apply);
      await tester.pumpAndSettle();
      expect(
        applied!.keys.toSet(),
        decision.items.map((item) => item.id).toSet(),
      );
      expect(applied, hasLength(20));
      expect(
        applied!.values.every(
          (selection) => selection.choice == SyncChoice.remote,
        ),
        isTrue,
      );
      expect(nativeSyncFactsMatch(imported!), isTrue);
      expect(find.byType(SyncConflictDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}
