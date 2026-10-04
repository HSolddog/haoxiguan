import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/accessible_controls.dart';
import 'package:haoxiguan/ui/data_screen.dart';
import 'package:haoxiguan/ui/habit_app.dart';
import 'package:haoxiguan/ui/note_editor.dart';
import 'package:haoxiguan/ui/theme_color_dialog.dart';

final _today = DateTime(2026, 10, 3, 12);
final _history = DateTime(2026, 10, 1);
const _draftTitle = 'edited habit sentinel';
const _draftNote = 'edited today note sentinel';
const _preset = 0xff397d6d;

enum _Editor { create, edit, note, theme, preset }

class _Repository extends MemoryHabitRepository {
  _Repository([super.value, super.backupValue]);
  Completer<void>? pending;
  bool failNext = false;
  int writes = 0;
  int replacements = 0;

  @override
  Future<void> save(String value) async {
    writes++;
    if (failNext) {
      failNext = false;
      throw StateError('synthetic write failure');
    }
    await pending?.future;
    await super.save(value);
  }

  @override
  Future<void> replace(String value) async {
    replacements++;
    await super.replace(value);
  }
}

class _Fixture {
  _Fixture(this.repository, this.controller)
    : original = controller.habits.single,
      snapshot = controller.exportJson(),
      stored = repository.value,
      theme = controller.themeColorValue;
  final _Repository repository;
  final HabitController controller;
  final Habit original;
  final String snapshot;
  final String? stored;
  final int theme;
}

class _Opened {
  _Opened(this.navigator, this.baseRoute, this.ownerRoute, this.context);
  final GlobalKey<NavigatorState> navigator;
  final Route<void> baseRoute;
  final ModalRoute<Object?> ownerRoute;
  final BuildContext context;
}

Future<_Fixture> _seed() async {
  final repository = _Repository();
  final controller = HabitController(repository, clock: () => _today);
  addTearDown(controller.dispose);
  await controller.load();
  expect(
    await controller.addHabit(
      title: 'original habit sentinel',
      emoji: '📚',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      startDate: _history,
      recordType: 'count',
      unit: 'pages',
      scale: 1000,
      dailyTarget: 1000,
    ),
    isTrue,
  );
  final id = controller.habits.single.id;
  expect(await controller.addValue(id, _history, 1500), isTrue);
  expect(await controller.addValue(id, _today, 1000), isTrue);
  expect(
    await controller.setNote(id, _history, 'history note sentinel'),
    isTrue,
  );
  expect(await controller.setNote(id, _today, 'today note sentinel'), isTrue);
  repository.writes = 0;
  return _Fixture(repository, controller);
}

Key _field(_Editor kind) => Key(switch (kind) {
  _Editor.create || _Editor.edit => 'habit-title-field',
  _Editor.note => 'note-text-field',
  _Editor.theme || _Editor.preset => 'theme-hex-field',
});

Future<_Opened> _open(
  WidgetTester tester,
  _Fixture fixture,
  _Editor kind,
) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('root route sentinel')),
    ),
  );
  final base = MaterialPageRoute<void>(
    builder: (context) => Scaffold(
      body: Column(
        children: [
          const Text('base route sentinel'),
          TextButton(
            onPressed: () => switch (kind) {
              _Editor.create => showAddHabitSheet(context, fixture.controller),
              _Editor.edit => showAddHabitSheet(
                context,
                fixture.controller,
                habit: fixture.original,
              ),
              _Editor.note => showNoteEditor(
                context,
                fixture.controller,
                fixture.original,
                _today,
              ),
              _Editor.theme || _Editor.preset => showThemeColorDialog(
                context,
                fixture.controller,
              ),
            },
            child: const Text('open editor'),
          ),
        ],
      ),
    ),
  );
  navigator.currentState!.push(base);
  await tester.pumpAndSettle();
  await tester.tap(find.text('open editor'));
  await tester.pumpAndSettle();
  final context = tester.element(find.byKey(_field(kind)));
  return _Opened(navigator, base, ModalRoute.of(context)!, context);
}

VoidCallback _save(WidgetTester tester, _Editor kind) {
  if (kind == _Editor.preset) {
    return tester
        .widget<ColorChoice>(
          find.byKey(const ValueKey('theme-preset-$_preset')),
        )
        .onSelected;
  }
  final key = Key(switch (kind) {
    _Editor.create || _Editor.edit => 'save-habit-button',
    _Editor.note => 'save-note-button',
    _Editor.theme => 'save-theme-button',
    _Editor.preset => throw StateError('preset handled above'),
  });
  return tester.widget<FilledButton>(find.byKey(key)).onPressed!;
}

Future<void> _draft(WidgetTester tester, _Editor kind) =>
    tester.enterText(find.byKey(_field(kind)), switch (kind) {
      _Editor.create || _Editor.edit => _draftTitle,
      _Editor.note => _draftNote,
      _Editor.theme || _Editor.preset => '#123456',
    });

VoidCallback _cancel(WidgetTester tester, _Editor kind) {
  if (kind == _Editor.create || kind == _Editor.edit) {
    return tester
        .widget<IconButton>(
          find.byWidgetPredicate(
            (widget) => widget is IconButton && widget.tooltip == '关闭',
          ),
        )
        .onPressed!;
  }
  return tester
      .widget<TextButton>(
        find.byKey(
          Key(
            kind == _Editor.note ? 'cancel-note-button' : 'cancel-theme-button',
          ),
        ),
      )
      .onPressed!;
}

Future<void> _discard(WidgetTester tester, _Editor kind) async {
  _cancel(tester, kind)();
  await tester.pumpAndSettle();
  tester
      .widget<TextButton>(find.byKey(const Key('discard-changes-button')))
      .onPressed!();
  // Resolve the real confirmation without rendering away the owner's exit.
  await tester.idle();
}

Future<void> _unchanged(_Fixture fixture) async {
  expect(fixture.repository.writes, 0);
  expect(fixture.repository.value, fixture.stored);
  expect(fixture.controller.exportJson(), fixture.snapshot);
  final reopened = HabitController(fixture.repository, clock: () => _today);
  addTearDown(reopened.dispose);
  await reopened.load();
  expect(reopened.habits.single.toJson(), fixture.original.toJson());
  expect(reopened.themeColorValue, fixture.theme);
}

void _retainedEntries(_Fixture fixture, {bool changedNote = false}) {
  final current = fixture.controller.habitById(fixture.original.id)!;
  expect(
    current.entries.map((e) => e.toJson()).toList(),
    fixture.original.entries.map((e) => e.toJson()).toList(),
  );
  expect(current.noteOn(_history), fixture.original.noteOn(_history));
  expect(
    current.noteOn(_today),
    changedNote ? _draftNote : fixture.original.noteOn(_today),
  );
}

Future<void> _saved(_Fixture fixture, _Editor kind) async {
  _retainedEntries(fixture, changedNote: kind == _Editor.note);
  switch (kind) {
    case _Editor.create:
      expect(fixture.controller.habits.length, 2);
      expect(fixture.controller.habits.last.title, _draftTitle);
    case _Editor.edit:
      expect(fixture.controller.habits.single.title, _draftTitle);
    case _Editor.note:
      expect(fixture.controller.habits.single.noteOn(_today), _draftNote);
    case _Editor.theme:
      expect(fixture.controller.themeColorValue, 0xff123456);
    case _Editor.preset:
      expect(fixture.controller.themeColorValue, _preset);
  }
  final reopened = HabitController(fixture.repository, clock: () => _today);
  addTearDown(reopened.dispose);
  await reopened.load();
  expect(reopened.exportJson(), fixture.controller.exportJson());
}

void _observe(
  String name,
  Map<String, Object?> expected,
  Map<String, Object?> actual,
) {
  // Synthetic fixture facts stay in memory; logs contain only outcomes/counts.
  // ignore: avoid_print
  print(jsonEncode({'case': name, 'expected': expected, 'actual': actual}));
  expect(actual, expected);
}

Route<void> _upper(_Opened opened) {
  final route = MaterialPageRoute<void>(
    builder: (_) => const Scaffold(body: Text('new upper route sentinel')),
  );
  opened.navigator.currentState!.push(route);
  return route;
}

Future<_Opened> _review(WidgetTester tester, _Fixture fixture) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('root route sentinel')),
    ),
  );
  final base = MaterialPageRoute<void>(
    builder: (_) =>
        Scaffold(body: SettingsScreen(controller: fixture.controller)),
  );
  navigator.currentState!.push(base);
  await tester.pumpAndSettle();
  final context = tester.element(find.byType(SettingsScreen));
  tester.widget<DataScreen>(find.byType(DataScreen)).onReview();
  await tester.pumpAndSettle();
  return _Opened(navigator, base, ModalRoute.of(context)!, context);
}

VoidCallback _reviewChoice(WidgetTester tester) =>
    tester.widget<ListTile>(find.widgetWithText(ListTile, '近 1 季度')).onTap!;

Future<(HabitController, _Repository, NavigatorState, BuildContext)> _recovery(
  WidgetTester tester,
  _Fixture fixture,
) async {
  final repository = _Repository('synthetic corrupt primary', fixture.snapshot);
  final controller = HabitController(repository, clock: () => _today);
  addTearDown(controller.dispose);
  await controller.load();
  expect(controller.loaded, isFalse);
  expect(controller.canRecoverBackup, isTrue);
  await tester.pumpWidget(HabitApp(controller: controller));
  await tester.pumpAndSettle();
  final button = find.widgetWithText(TextButton, '从保护副本恢复');
  final context = tester.element(button);
  tester.widget<TextButton>(button).onPressed!();
  await tester.pumpAndSettle();
  return (controller, repository, Navigator.of(context), context);
}

void main() {
  for (final kind in _Editor.values) {
    testWidgets('discarded ${kind.name} ignores cached save in mounted exit', (
      tester,
    ) async {
      final fixture = await _seed();
      final opened = await _open(tester, fixture, kind);
      await _draft(tester, kind);
      final save = _save(tester, kind);
      await _discard(tester, kind);
      expect(opened.ownerRoute.isCurrent, isFalse);
      expect(opened.context.mounted, isTrue);
      save();
      save();
      await tester.pumpAndSettle();
      _observe(
        'discarded_${kind.name}',
        {
          'writes': 0,
          'storedUnchanged': true,
          'snapshotUnchanged': true,
          'baseCurrent': true,
        },
        {
          'writes': fixture.repository.writes,
          'storedUnchanged': fixture.repository.value == fixture.stored,
          'snapshotUnchanged':
              fixture.controller.exportJson() == fixture.snapshot,
          'baseCurrent': opened.baseRoute.isCurrent,
        },
      );
      await _unchanged(fixture);
      expect(tester.takeException(), isNull);
    });

    testWidgets('${kind.name} late success keeps a new upper route open', (
      tester,
    ) async {
      final fixture = await _seed();
      final opened = await _open(tester, fixture, kind);
      await _draft(tester, kind);
      fixture.repository.pending = Completer<void>();
      final save = _save(tester, kind);
      save();
      save();
      await tester.idle();
      expect(fixture.repository.writes, 1);
      final upper = _upper(opened);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      fixture.repository.pending!.complete();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.idle();
      _observe(
        'late_success_${kind.name}',
        {'writes': 1, 'upperCurrent': true, 'ownerActive': true},
        {
          'writes': fixture.repository.writes,
          'upperCurrent': upper.isCurrent,
          'ownerActive': opened.ownerRoute.isActive,
        },
      );
      await _saved(fixture, kind);
      expect(tester.takeException(), isNull);
    });

    testWidgets(
      '${kind.name} current-route failure preserves facts and retries',
      (tester) async {
        final fixture = await _seed();
        final opened = await _open(tester, fixture, kind);
        await _draft(tester, kind);
        fixture.repository.failNext = true;
        _save(tester, kind)();
        await tester.pumpAndSettle();
        expect(fixture.repository.writes, 1);
        expect(fixture.repository.value, fixture.stored);
        expect(fixture.controller.exportJson(), fixture.snapshot);
        expect(opened.ownerRoute.isCurrent, isTrue);
        _retainedEntries(fixture);
        _save(tester, kind)();
        await tester.pumpAndSettle();
        expect(fixture.repository.writes, 2);
        expect(opened.ownerRoute.isActive, isFalse);
        expect(opened.baseRoute.isCurrent, isTrue);
        await _saved(fixture, kind);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final kind in [
    _Editor.edit,
    _Editor.note,
    _Editor.theme,
    _Editor.preset,
  ]) {
    testWidgets('clean cancelled ${kind.name} ignores a cached save', (
      tester,
    ) async {
      final fixture = await _seed();
      final opened = await _open(tester, fixture, kind);
      final save = _save(tester, kind);
      _cancel(tester, kind)();
      await tester.idle();
      expect(opened.ownerRoute.isCurrent, isFalse);
      expect(opened.context.mounted, isTrue);
      save();
      await tester.pumpAndSettle();
      _observe(
        'clean_cancel_${kind.name}',
        {'writes': 0, 'baseCurrent': true},
        {
          'writes': fixture.repository.writes,
          'baseCurrent': opened.baseRoute.isCurrent,
        },
      );
      await _unchanged(fixture);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'discarded related editor ignores its cached replacement action',
    (tester) async {
      final fixture = await _seed();
      final opened = await _open(tester, fixture, _Editor.edit);
      final related = tester
          .widget<TextButton>(find.byKey(const Key('create-related-habit')))
          .onPressed!;
      _cancel(tester, _Editor.edit)();
      await tester.idle();
      expect(opened.context.mounted, isTrue);
      expect(opened.ownerRoute.isCurrent, isFalse);
      related();
      await tester.pumpAndSettle();
      _observe(
        'related_after_cancel',
        {'baseCurrent': true, 'newSheetCount': 0},
        {
          'baseCurrent': opened.baseRoute.isCurrent,
          'newSheetCount': find
              .byKey(const Key('habit-title-field'))
              .evaluate()
              .length,
        },
      );
      await _unchanged(fixture);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('related confirmation does not replace a later upper route', (
    tester,
  ) async {
    final fixture = await _seed();
    final opened = await _open(tester, fixture, _Editor.edit);
    await _draft(tester, _Editor.edit);
    tester
        .widget<TextButton>(find.byKey(const Key('create-related-habit')))
        .onPressed!();
    await tester.pumpAndSettle();
    tester
        .widget<TextButton>(find.byKey(const Key('discard-changes-button')))
        .onPressed!();
    final upper = _upper(opened);
    await tester.pumpAndSettle();
    _observe(
      'related_after_upper',
      {'upperCurrent': true, 'ownerActive': true},
      {
        'upperCurrent': upper.isCurrent,
        'ownerActive': opened.ownerRoute.isActive,
      },
    );
    await _unchanged(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review cancelled dialog ignores its cached selection', (
    tester,
  ) async {
    final fixture = await _seed();
    final opened = await _review(tester, fixture);
    final select = _reviewChoice(tester);
    await tester.binding.handlePopRoute();
    select();
    await tester.pumpAndSettle();
    _observe(
      'review_after_cancel',
      {'writes': 0, 'baseCurrent': true},
      {
        'writes': fixture.repository.writes,
        'baseCurrent': opened.baseRoute.isCurrent,
      },
    );
    await _unchanged(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets('review confirmed selection requires its original owner route', (
    tester,
  ) async {
    final fixture = await _seed();
    final opened = await _review(tester, fixture);
    _reviewChoice(tester)();
    final upper = _upper(opened);
    await tester.pumpAndSettle();
    _observe(
      'review_after_upper',
      {'writes': 0, 'upperCurrent': true},
      {'writes': fixture.repository.writes, 'upperCurrent': upper.isCurrent},
    );
    await _unchanged(fixture);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'review repeated selection saves once without closing its owner',
    (tester) async {
      final fixture = await _seed();
      final opened = await _review(tester, fixture);
      final select = _reviewChoice(tester);
      select();
      select();
      await tester.pumpAndSettle();
      _observe(
        'review_double_selection',
        {'writes': 1, 'baseCurrent': true},
        {
          'writes': fixture.repository.writes,
          'baseCurrent': opened.baseRoute.isCurrent,
        },
      );
      expect(fixture.controller.reviewDays, 90);
      _retainedEntries(fixture);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('cancelled recovery confirmation cannot close a newer route', (
    tester,
  ) async {
    final fixture = await _seed();
    final (controller, repository, navigator, _) = await _recovery(
      tester,
      fixture,
    );
    final confirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '确认恢复'))
        .onPressed!;
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
        .onPressed!();
    final upper = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('recovery upper sentinel')),
    );
    navigator.push(upper);
    confirm();
    await tester.pumpAndSettle();
    _observe(
      'recovery_after_cancel',
      {'replacements': 0, 'upperCurrent': true, 'loaded': false},
      {
        'replacements': repository.replacements,
        'upperCurrent': upper.isCurrent,
        'loaded': controller.loaded,
      },
    );
    expect(repository.value, 'synthetic corrupt primary');
    expect(repository.protectedSources, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'confirmed recovery requires the original owner before replacement',
    (tester) async {
      final fixture = await _seed();
      final (controller, repository, navigator, context) = await _recovery(
        tester,
        fixture,
      );
      final owner = ModalRoute.of(context)!;
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, '确认恢复'))
          .onPressed!();
      final upper = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('recovery upper sentinel')),
      );
      navigator.push(upper);
      await tester.pumpAndSettle();
      _observe(
        'recovery_after_upper',
        {'replacements': 0, 'upperCurrent': true, 'loaded': false},
        {
          'replacements': repository.replacements,
          'upperCurrent': upper.isCurrent,
          'loaded': controller.loaded,
        },
      );
      expect(owner.isCurrent, isFalse);
      expect(repository.value, 'synthetic corrupt primary');
      expect(repository.protectedSources, isEmpty);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('current recovery saves once and protects the corrupt source', (
    tester,
  ) async {
    final fixture = await _seed();
    final (controller, repository, _, _) = await _recovery(tester, fixture);
    final confirm = tester
        .widget<FilledButton>(find.widgetWithText(FilledButton, '确认恢复'))
        .onPressed!;
    confirm();
    await tester.pumpAndSettle();
    expect(repository.replacements, 1);
    expect(repository.protectedSources, ['synthetic corrupt primary']);
    expect(controller.loaded, isTrue);
    expect(controller.habits.single.toJson(), fixture.original.toJson());
    expect(tester.takeException(), isNull);
  });
}
