import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/record_editor.dart';

final _today = DateTime(2026, 10, 3, 12);
final _history = DateTime(2026, 10, 1);

class _PendingRepository extends MemoryHabitRepository {
  Completer<void>? pending;
  bool reject = false;
  int writes = 0;
  @override
  Future<void> save(String value) async {
    writes++;
    await pending?.future;
    if (reject) throw StateError('synthetic write failed');
    await super.save(value);
  }
}

class _Editor {
  _Editor(
    this.repository,
    this.controller,
    this.navigator,
    this.route,
    this.original,
  );
  final _PendingRepository repository;
  final HabitController controller;
  final GlobalKey<NavigatorState> navigator;
  final ModalRoute<Object?> route;
  final Habit original;
}

Future<_Editor> _open(WidgetTester tester, String type) async {
  final repository = _PendingRepository();
  final controller = HabitController(repository, clock: () => _today);
  addTearDown(controller.dispose);
  await controller.load();
  expect(
    await controller.addHabit(
      title: 'covered editor sentinel',
      emoji: 'x',
      startDate: _history,
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: type,
      unit: type == 'duration' ? 'seconds' : 'units',
      scale: type == 'duration' ? 1 : 1000,
      dailyTarget: type == 'duration' ? 600 : 1000,
    ),
    isTrue,
  );
  final id = controller.habits.single.id;
  expect(
    await controller.addValue(id, _history, type == 'duration' ? 90 : 1500),
    isTrue,
  );
  expect(
    await controller.addValue(id, _today, type == 'duration' ? 60 : 1000),
    isTrue,
  );
  expect(await controller.setNote(id, _history, 'history note'), isTrue);
  expect(await controller.setNote(id, _today, 'today note'), isTrue);
  repository.writes = 0;
  final original = controller.habits.single;
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                showRecordEditor(context, controller, original, _today),
            child: const Text('open editor'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open editor'));
  await tester.pumpAndSettle();
  final route = ModalRoute.of(
    tester.element(find.byKey(const Key('record-value-field'))),
  )!;
  return _Editor(repository, controller, navigator, route, original);
}

TextField _value(WidgetTester tester) =>
    tester.widget<TextField>(find.byKey(const Key('record-value-field')));
TextField _seconds(WidgetTester tester) =>
    tester.widgetList<TextField>(find.byType(TextField)).last;
SegmentedButton<bool> _mode(WidgetTester tester) =>
    tester.widget<SegmentedButton<bool>>(find.byType(SegmentedButton<bool>));
FilledButton _save(WidgetTester tester) =>
    tester.widget<FilledButton>(find.byKey(const Key('save-record-button')));

Future<void> _draft(
  WidgetTester tester,
  String type, {
  bool replace = false,
}) async {
  await tester.enterText(find.byKey(const Key('record-value-field')), '2');
  if (type == 'duration') {
    final field = find.byType(TextField).last;
    await tester.ensureVisible(field);
    await tester.enterText(field, '15');
  }
  if (replace) _mode(tester).onSelectionChanged!({true});
  await tester.pump();
}

Future<MaterialPageRoute<void>> _coverPending(
  WidgetTester tester,
  _Editor editor,
) async {
  editor.repository.pending = Completer<void>();
  final button = find.byKey(const Key('save-record-button'));
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.idle();
  expect(editor.repository.writes, 1);
  final cover = MaterialPageRoute<void>(
    builder: (_) => const Scaffold(body: Text('cover sentinel')),
  );
  editor.navigator.currentState!.push(cover);
  await tester.pumpAndSettle();
  expect(cover.isCurrent, isTrue);
  expect(editor.route.isActive, isTrue);
  expect(editor.route.isCurrent, isFalse);
  return cover;
}

Future<void> _return(
  WidgetTester tester,
  _Editor editor,
  MaterialPageRoute<void> cover,
) async {
  expect(cover.isCurrent, isTrue);
  expect(find.text('cover sentinel'), findsOneWidget);
  editor.navigator.currentState!.pop();
  await tester.pumpAndSettle();
  expect(editor.route.isCurrent, isTrue);
  expect(find.byKey(const Key('record-value-field')), findsOneWidget);
  expect(_value(tester).enabled, isTrue);
  expect(_save(tester).onPressed, isNotNull);
}

Future<void> _reopenedEquals(_Editor editor, Habit saved) async {
  final reopened = HabitController(editor.repository, clock: () => _today);
  addTearDown(reopened.dispose);
  await reopened.load();
  expect(reopened.habits.single.toJson(), saved.toJson());
  expect(saved.notes, editor.original.notes);
  for (final old in editor.original.entries.where(
    (e) => e.date == dateKey(_history),
  )) {
    expect(
      saved.entries.singleWhere((e) => e.id == old.id).toJson(),
      old.toJson(),
    );
  }
}

void main() {
  for (final type in ['count', 'duration']) {
    testWidgets(
      '$type covered successful save clears committed draft and permits a distinct next record',
      (tester) async {
        final editor = await _open(tester, type);
        await _draft(tester, type, replace: type == 'duration');
        final cover = await _coverPending(tester, editor);
        editor.repository.pending!.complete();
        await tester.pumpAndSettle();
        expect(editor.repository.writes, 1);
        final saved = editor.controller.habits.single;
        expect(saved.valueOn(_today), type == 'duration' ? 135 : 3000);
        await _reopenedEquals(editor, saved);
        await _return(tester, editor, cover);
        expect(_value(tester).controller!.text, isEmpty);
        expect(_mode(tester).selected, {false});
        if (type == 'duration') expect(_seconds(tester).controller!.text, '0');
        expect(find.byKey(const Key('record-save-success')), findsOneWidget);
        // A second click cannot repeat the already committed increment or replacement.
        _save(tester).onPressed!();
        await tester.pumpAndSettle();
        expect(editor.repository.writes, 1);
        expect(editor.controller.habits.single.toJson(), saved.toJson());
        expect(editor.route.isCurrent, isTrue);
        editor.repository.pending = null;
        await tester.enterText(
          find.byKey(const Key('record-value-field')),
          '1',
        );
        final button = find.byKey(const Key('save-record-button'));
        await tester.ensureVisible(button);
        await tester.tap(button);
        await tester.pumpAndSettle();
        expect(editor.repository.writes, 2);
        final next = editor.controller.habits.single;
        expect(next.valueOn(_today), type == 'duration' ? 195 : 4000);
        await _reopenedEquals(editor, next);
        expect(editor.route.isActive, isFalse);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'covered failed save retains both inputs and mode then retries once',
    (tester) async {
      final editor = await _open(tester, 'duration');
      final originalExport = editor.controller.exportJson();
      final stored = editor.repository.value;
      await _draft(tester, 'duration', replace: true);
      final cover = await _coverPending(tester, editor);
      editor.repository.reject = true;
      editor.repository.pending!.complete();
      await tester.pumpAndSettle();
      expect(editor.controller.exportJson(), originalExport);
      expect(editor.repository.value, stored);
      await _return(tester, editor, cover);
      expect(_value(tester).controller!.text, '2');
      expect(_seconds(tester).controller!.text, '15');
      expect(_mode(tester).selected, {true});
      expect(_value(tester).decoration!.errorText, isNotEmpty);
      expect(find.byKey(const Key('record-save-success')), findsNothing);
      editor.repository.pending = null;
      editor.repository.reject = false;
      final button = find.byKey(const Key('save-record-button'));
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      expect(editor.repository.writes, 2);
      final saved = editor.controller.habits.single;
      expect(saved.valueOn(_today), 135);
      await _reopenedEquals(editor, saved);
      expect(editor.route.isActive, isFalse);
      expect(tester.takeException(), isNull);
    },
  );
}
