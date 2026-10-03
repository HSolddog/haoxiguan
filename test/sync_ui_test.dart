import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/models/record_entry.dart';
import 'package:haoxiguan/services/sync_engine.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/ui/sync_screen.dart';

void main() {
  Widget app(WidgetBuilder dialog, {void Function(bool?)? onClosed}) =>
      MaterialApp(
        builder: (context, child) => MediaQuery(
          data: MediaQuery.of(
            context,
          ).copyWith(textScaler: const TextScaler.linear(2)),
          child: child!,
        ),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => onClosed?.call(
                await showDialog<bool>(context: context, builder: dialog),
              ),
              child: const Text('打开同步核对'),
            ),
          ),
        ),
      );

  testWidgets(
    '200% first-sync empty preview can cancel and confirm independently',
    (tester) async {
      tester.view.physicalSize = const Size(420, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      bool? result;
      await tester.pumpWidget(
        app(
          (_) => const InitialSyncPreviewDialog(
            preview: InitialSyncPreview({}, {}, 'preview', []),
          ),
          onClosed: (value) => result = value,
        ),
      );
      await tester.tap(find.text('打开同步核对'));
      await tester.pumpAndSettle();
      expect(find.text('首次同步预览'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(result, false);
      await tester.tap(find.text('打开同步核对'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认并继续同步'));
      await tester.pumpAndSettle();
      expect(result, true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    '200% manual conflict merge keeps text and selection after failed save',
    (tester) async {
      tester.view.physicalSize = const Size(420, 920);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final habit = Habit(
        id: 'test-habit',
        title: '阅读',
        emoji: '📖',
        colorValue: 0xff223344,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        createdAt: DateTime(2026, 10, 2),
        notes: const {'2026-10-02': '原备注'},
      );
      String snapshot(String note) => jsonEncode({
        ...SnapshotCodec.decode(SnapshotCodec.empty()),
        'habits': [
          habit
              .copyWith(notes: {'2026-10-02': note}, plans: [habit.initialPlan])
              .toJson(),
        ],
      });
      final decision = SyncEntities.merge(
        snapshot('本机备注'),
        SyncEntities.encode(snapshot('原备注')),
        SyncEntities.encode(snapshot('远端备注')),
      );
      var attempts = 0;
      bool? closed;
      await tester.pumpWidget(
        app(
          (_) => SyncConflictDialog(
            decision: decision,
            onApply: (selections) async {
              attempts++;
              expect(selections.values.single.choice, SyncChoice.manual);
              expect(selections.values.single.text, '两端共同确认的备注');
              if (attempts == 1) throw const FormatException('模拟存储失败');
            },
          ),
          onClosed: (value) => closed = value,
        ),
      );
      await tester.tap(find.text('打开同步核对'));
      await tester.pumpAndSettle();
      final dropdown = find.byType(DropdownButtonFormField<SyncChoice>);
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('手工合并备注').last);
      await tester.pumpAndSettle();
      final input = find.byType(TextFormField);
      await tester.ensureVisible(input);
      await tester.enterText(input, '两端共同确认的备注');
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.text('保留未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      expect(find.text('两端共同确认的备注'), findsOneWidget);
      await tester.tap(find.text('稍后处理'));
      await tester.pumpAndSettle();
      expect(find.text('保留未保存的修改？'), findsOneWidget);
      await tester.tap(find.text('继续编辑'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('保护副本并应用合并'));
      await tester.pumpAndSettle();
      expect(attempts, 1);
      expect(closed, isNull);
      expect(find.text('两端共同确认的备注'), findsOneWidget);
      expect(find.textContaining('选择与输入仍保留'), findsOneWidget);
      await tester.tap(find.text('保护副本并应用合并'));
      await tester.pumpAndSettle();
      expect(attempts, 2);
      expect(closed, true);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'orphan record conflict reads unit from protected base without crashing',
    (tester) async {
      final habit = Habit(
        id: 'orphan-habit',
        title: '饮水',
        emoji: '💧',
        colorValue: 0xff223344,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        createdAt: DateTime(2026, 10, 2),
        recordType: 'count',
        unit: '杯',
        entries: const [
          RecordEntry(
            id: 'orphan-record',
            date: '2026-10-02',
            value: 1,
            recordedAtUtc: '2026-10-02T00:00:00Z',
            recordedLocalDate: '2026-10-02',
            timezoneId: 'UTC',
            utcOffsetMinutes: 0,
          ),
        ],
      );
      final base = SyncEntities.encode(
        jsonEncode({
          ...SnapshotCodec.decode(SnapshotCodec.empty()),
          'habits': [
            habit.copyWith(plans: [habit.initialPlan]).toJson(),
          ],
        }),
      );
      final remote = <String, dynamic>{for (final key in base.keys) key: null};
      remote['r/orphan-record'] = {
        'habitId': habit.id,
        'data': habit.entries.single.copyWith(value: 2).toJson(),
      };
      final decision = SyncEntities.merge(SnapshotCodec.empty(), base, remote);
      expect(decision.items.single.logicalId, 'r/orphan-record');
      await tester.pumpWidget(
        app(
          (_) => SyncConflictDialog(decision: decision, onApply: (_) async {}),
          onClosed: (_) {},
        ),
      );
      await tester.tap(find.text('打开同步核对'));
      await tester.pumpAndSettle();
      expect(find.textContaining('2 杯'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
