import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';

final _today = DateTime(2026, 10, 3);

class _GatedRepository extends MemoryHabitRepository {
  Completer<void>? gate;
  bool failWrite = false;
  int writes = 0;

  @override
  Future<void> save(String value) async {
    writes++;
    await gate?.future;
    if (failWrite) throw const FileSystemException('synthetic disk full');
    await super.save(value);
  }
}

void main() {
  late _GatedRepository repository;
  late HabitController controller;
  late String habitId;

  setUp(() async {
    repository = _GatedRepository();
    controller = HabitController(repository, clock: () => _today);
    await controller.load();
    expect(
      await controller.addHabit(
        startDate: DateTime(2026, 10, 1),
        title: 'detail action sentinel',
        emoji: '📖',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
      ),
      isTrue,
    );
    habitId = controller.habits.single.id;
    repository.writes = 0;
  });

  tearDown(() => controller.dispose());

  Future<void> showDetail(
    WidgetTester tester, {
    GlobalKey<NavigatorState>? navigator,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showHabitDetail(context, controller, habitId),
              child: const Text('open detail'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open detail'));
    await tester.pumpAndSettle();
  }

  Future<VoidCallback> detailAction(WidgetTester tester, String label) async {
    final finder = find.widgetWithText(ListTile, label);
    await tester.scrollUntilVisible(
      finder,
      300,
      scrollable: find
          .descendant(
            of: find.byKey(const Key('habit-detail-scroll')),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    return tester.widget<ListTile>(finder).onTap!;
  }

  Future<VoidCallback> calendarAction(
    WidgetTester tester, {
    bool rest = false,
  }) async {
    final finder = find.byKey(Key('detail-day-${dateKey(_today)}'));
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    final day = tester.widget<InkWell>(finder);
    return rest ? day.onLongPress! : day.onTap!;
  }

  Future<void> release(WidgetTester tester) async {
    repository.gate!.complete();
    repository.gate = null;
    await tester.pumpAndSettle();
  }

  Future<Habit> reopen() async {
    final reopened = HabitController(repository, clock: () => _today);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.loaded, isTrue);
    return reopened.habits.single;
  }

  for (final action in ['archive', 'pause', 'complete']) {
    testWidgets('$action ignores the second stale callback before a frame', (
      tester,
    ) async {
      await showDetail(tester);
      final callback = action == 'complete'
          ? await calendarAction(tester)
          : await detailAction(tester, action == 'pause' ? '暂停习惯' : '归档习惯');
      final before = controller.exportJson();
      repository.gate = Completer<void>();
      callback();
      callback();
      await tester.pump();
      expect(repository.writes, 1);
      expect(controller.exportJson(), before);
      expect(find.byType(HabitDetailSheet), findsOneWidget);
      await release(tester);
      expect(repository.writes, 1);
      final saved = await reopen();
      switch (action) {
        case 'archive':
          expect(saved.archived, isTrue);
          expect(find.byType(HabitDetailSheet), findsNothing);
        case 'pause':
          expect(saved.isPaused, isTrue);
          expect(find.byType(HabitDetailSheet), findsOneWidget);
        case 'complete':
          expect(saved.isCompletedOn(_today), isTrue);
          expect(saved.entries.where((entry) => !entry.deleted), hasLength(1));
          expect(find.byType(HabitDetailSheet), findsOneWidget);
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'failed archive stays visible and retry closes only after commit',
    (tester) async {
      final historicalDay = DateTime(2026, 10, 1);
      expect(await controller.toggleCompletion(habitId, historicalDay), isTrue);
      expect(
        await controller.setNote(habitId, historicalDay, '旧日备注 sentinel'),
        isTrue,
      );
      final history = controller.habits.single;
      final historicalEntries = history.entries
          .map((entry) => entry.toJson())
          .toList();
      final historicalNotes = Map<String, String>.from(history.notes);
      expect(historicalEntries, hasLength(1));
      repository.writes = 0;
      await showDetail(tester);
      final callback = await detailAction(tester, '归档习惯');
      final before = controller.exportJson();
      repository.failWrite = true;
      repository.gate = Completer<void>();
      callback();
      callback();
      await tester.pump();
      expect(repository.writes, 1);
      await release(tester);
      expect(controller.exportJson(), before);
      expect(find.byType(HabitDetailSheet), findsOneWidget);
      expect(
        find.byKey(const Key('detail-action-error')).hitTestable(),
        findsOneWidget,
      );
      final errorRect = tester.getRect(
        find.byKey(const Key('detail-action-error')),
      );
      final sheetRect = tester.getRect(find.byType(HabitDetailSheet));
      debugPrint('ARCHIVE_ERROR_VISIBLE_RECT=$errorRect SHEET_RECT=$sheetRect');
      expect(errorRect.top, greaterThanOrEqualTo(sheetRect.top));
      expect(errorRect.bottom, lessThanOrEqualTo(sheetRect.bottom));
      expect(controller.saveError, isNotNull);
      final afterFailure = await reopen();
      expect(afterFailure.archived, isFalse);
      expect(
        afterFailure.entries.map((entry) => entry.toJson()).toList(),
        historicalEntries,
      );
      expect(afterFailure.notes, historicalNotes);

      repository.failWrite = false;
      repository.gate = Completer<void>();
      final retry = await detailAction(tester, '归档习惯');
      retry();
      retry();
      await tester.pump();
      expect(repository.writes, 2);
      expect(find.byType(HabitDetailSheet), findsOneWidget);
      expect(controller.habits.single.archived, isFalse);
      await release(tester);
      expect(repository.writes, 2);
      expect(find.byType(HabitDetailSheet), findsNothing);
      final afterRetry = await reopen();
      expect(afterRetry.archived, isTrue);
      expect(
        afterRetry.entries.map((entry) => entry.toJson()).toList(),
        historicalEntries,
      );
      expect(afterRetry.notes, historicalNotes);
      expect(tester.takeException(), isNull);
    },
  );

  for (final action in ['archive', 'pause', 'complete']) {
    testWidgets('dismissed detail ignores its stale $action callback', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await showDetail(tester, navigator: navigator);
      final callback = action == 'complete'
          ? await calendarAction(tester)
          : await detailAction(tester, action == 'pause' ? '暂停习惯' : '归档习惯');
      final before = controller.exportJson();
      // No frame passes between dismissal, navigation and the cached callback.
      // The old sheet remains mounted but no longer owns the current route.
      navigator.currentState!.pop();
      navigator.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) =>
              const Scaffold(body: Text('replacement route sentinel')),
        ),
      );
      callback();
      callback();
      await tester.pumpAndSettle();
      expect(repository.writes, 0);
      expect(controller.exportJson(), before);
      expect((await reopen()).toJson(), controller.habits.single.toJson());
      expect(find.text('replacement route sentinel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('late archive completion does not close a replacement route', (
    tester,
  ) async {
    final navigator = GlobalKey<NavigatorState>();
    await showDetail(tester, navigator: navigator);
    final callback = await detailAction(tester, '归档习惯');
    repository.gate = Completer<void>();
    callback();
    // The old sheet is still mounted during its closing transition. A later
    // completion must check its captured route, not pop the new current route.
    navigator.currentState!.pop();
    navigator.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) =>
            const Scaffold(body: Text('replacement route sentinel')),
      ),
    );
    await release(tester);
    expect(find.text('replacement route sentinel'), findsOneWidget);
    expect(controller.habits.single.archived, isTrue);
    expect(repository.writes, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'failed calendar completion shows its error inside the visible sheet',
    (tester) async {
      await showDetail(tester);
      final callback = await calendarAction(tester);
      final before = controller.exportJson();
      repository.failWrite = true;
      repository.gate = Completer<void>();
      callback();
      callback();
      await tester.pump();
      expect(repository.writes, 1);
      await release(tester);
      expect(controller.exportJson(), before);
      expect((await reopen()).isCompletedOn(_today), isFalse);
      final error = find.byKey(const Key('detail-action-error'));
      expect(error.hitTestable(), findsOneWidget);
      final errorRect = tester.getRect(error);
      final sheetRect = tester.getRect(find.byType(HabitDetailSheet));
      debugPrint(
        'CALENDAR_ERROR_VISIBLE_RECT=$errorRect SHEET_RECT=$sheetRect',
      );
      expect(errorRect.top, greaterThanOrEqualTo(sheetRect.top));
      expect(errorRect.bottom, lessThanOrEqualTo(sheetRect.bottom));
      expect(find.byType(SnackBar), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'archived list restore retains one pending intent and can retry',
    (tester) async {
      await controller.toggleArchived(habitId);
      repository.writes = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: AnimatedBuilder(
              animation: controller,
              builder: (_, _) => HabitsScreen(controller: controller),
            ),
          ),
        ),
      );
      await tester.ensureVisible(find.text('已归档 · 1'));
      await tester.tap(find.text('已归档 · 1'));
      await tester.pumpAndSettle();
      await tester.ensureVisible(find.widgetWithText(TextButton, '恢复'));
      final callback = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '恢复'))
          .onPressed!;
      repository.failWrite = true;
      repository.gate = Completer<void>();
      callback();
      callback();
      await tester.pump();
      expect(repository.writes, 1);
      await release(tester);
      expect(controller.habits.single.archived, isTrue);
      expect(find.text('操作尚未保存，请检查存储后重试。'), findsOneWidget);
      repository.failWrite = false;
      repository.gate = Completer<void>();
      final retry = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '恢复'))
          .onPressed!;
      retry();
      retry();
      await tester.pump();
      expect(repository.writes, 2);
      await release(tester);
      expect(repository.writes, 2);
      expect((await reopen()).archived, isFalse);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('rest confirmation is single use and submits one pending write', (
    tester,
  ) async {
    await showDetail(tester);
    final callback = await calendarAction(tester, rest: true);
    callback();
    callback();
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsOneWidget);
    repository.gate = Completer<void>();
    final confirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '确认'))
        .onPressed!;
    confirm();
    confirm();
    await tester.pumpAndSettle();
    expect(repository.writes, 1);
    expect(find.byType(HabitDetailSheet), findsOneWidget);
    expect(controller.habits.single.exemptions, isEmpty);
    await release(tester);
    expect(repository.writes, 1);
    expect((await reopen()).exemptions, contains(dateKey(_today)));
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'cancelled rest and delete confirmations leave facts without error',
    (tester) async {
      await showDetail(tester);
      final before = controller.exportJson();
      final rest = await calendarAction(tester, rest: true);
      rest();
      rest();
      await tester.pumpAndSettle();
      final cancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed!;
      cancel();
      cancel();
      await tester.pumpAndSettle();
      expect(find.byType(HabitDetailSheet), findsOneWidget);
      final delete = await detailAction(tester, '删除习惯');
      delete();
      delete();
      await tester.pumpAndSettle();
      expect(find.byType(AlertDialog), findsOneWidget);
      final cancelDelete = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed!;
      cancelDelete();
      cancelDelete();
      await tester.pumpAndSettle();
      expect(repository.writes, 0);
      expect(controller.exportJson(), before);
      expect(find.byType(HabitDetailSheet), findsOneWidget);
      expect(find.byKey(const Key('detail-action-error')), findsNothing);
      expect(controller.saveError, isNull);
      expect(tester.takeException(), isNull);
    },
  );

  for (final action in ['rest', 'delete']) {
    testWidgets('dismissed $action confirmation ignores its stale button', (
      tester,
    ) async {
      final navigator = GlobalKey<NavigatorState>();
      await showDetail(tester, navigator: navigator);
      final before = controller.exportJson();
      final callback = action == 'rest'
          ? await calendarAction(tester, rest: true)
          : await detailAction(tester, '删除习惯');
      callback();
      await tester.pumpAndSettle();
      final confirm = tester
          .widget<FilledButton>(
            find.widgetWithText(
              FilledButton,
              action == 'rest' ? '确认' : '移入回收站',
            ),
          )
          .onPressed!;
      navigator.currentState!.pop();
      confirm();
      await tester.pumpAndSettle();
      expect(repository.writes, 0);
      expect(controller.exportJson(), before);
      expect(find.byType(HabitDetailSheet), findsOneWidget);
      expect(find.byKey(const Key('detail-action-error')), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}
