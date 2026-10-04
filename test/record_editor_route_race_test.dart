import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/record_editor.dart';

final _today = DateTime(2026, 10, 3, 12);
final _historyDay = DateTime(2026, 10, 1);

class _GatedRepository extends MemoryHabitRepository {
  Completer<void>? pending;
  int writes = 0;

  @override
  Future<void> save(String value) async {
    writes++;
    await pending?.future;
    await super.save(value);
  }
}

class _Fixture {
  _Fixture(this.repository, this.controller)
    : original = controller.habits.single,
      export = controller.exportJson(),
      stored = repository.value;

  final _GatedRepository repository;
  final HabitController controller;
  final Habit original;
  final String export;
  final String? stored;
}

class _OpenedEditor {
  _OpenedEditor(this.navigator, this.baseRoute, this.editorRoute, this.context);
  final GlobalKey<NavigatorState> navigator;
  final Route<void> baseRoute;
  final ModalRoute<Object?> editorRoute;
  final BuildContext context;
}

Future<_Fixture> _seed({String type = 'count'}) async {
  final repository = _GatedRepository();
  final controller = HabitController(repository, clock: () => _today);
  addTearDown(controller.dispose);
  await controller.load();
  expect(
    await controller.addHabit(
      startDate: _historyDay,
      title: 'record route sentinel',
      emoji: '📖',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: type,
      unit: type == 'duration' ? '分钟' : '杯',
      scale: type == 'duration' ? 1 : 1000,
      dailyTarget: type == 'duration' ? 600 : 1000,
    ),
    isTrue,
  );
  final id = controller.habits.single.id;
  expect(
    await controller.addValue(id, _historyDay, type == 'duration' ? 90 : 1500),
    isTrue,
  );
  expect(
    await controller.addValue(id, _today, type == 'duration' ? 60 : 1000),
    isTrue,
  );
  expect(await controller.setNote(id, _historyDay, '旧日期备注 sentinel'), isTrue);
  expect(await controller.setNote(id, _today, '今日备注 sentinel'), isTrue);
  repository.writes = 0;
  return _Fixture(repository, controller);
}

Future<_OpenedEditor> _open(WidgetTester tester, _Fixture fixture) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('root route sentinel')),
    ),
  );
  final baseRoute = MaterialPageRoute<void>(
    builder: (context) => Scaffold(
      body: Column(
        children: [
          const Text('base route sentinel'),
          TextButton(
            onPressed: () => showRecordEditor(
              context,
              fixture.controller,
              fixture.controller.habits.single,
              _today,
            ),
            child: const Text('open record'),
          ),
        ],
      ),
    ),
  );
  navigator.currentState!.push(baseRoute);
  await tester.pumpAndSettle();
  await tester.tap(find.text('open record'));
  await tester.pumpAndSettle();
  final context = tester.element(find.byKey(const Key('record-value-field')));
  return _OpenedEditor(navigator, baseRoute, ModalRoute.of(context)!, context);
}

VoidCallback _save(WidgetTester tester) => tester
    .widget<FilledButton>(find.byKey(const Key('save-record-button')))
    .onPressed!;

Future<VoidCallback> _delete(WidgetTester tester, _Fixture fixture) async {
  await tester.tap(find.byKey(const Key('record-facts')));
  await tester.pumpAndSettle();
  final entry = fixture.original.entries.singleWhere(
    (entry) => entry.date == dateKey(_today),
  );
  final button = find.byKey(Key('delete-entry-${entry.id}'));
  await tester.ensureVisible(button);
  await tester.pumpAndSettle();
  return tester.widget<IconButton>(button).onPressed!;
}

VoidCallback _confirmDelete(WidgetTester tester) => tester
    .widget<FilledButton>(find.widgetWithText(FilledButton, '撤销这条记录'))
    .onPressed!;

Future<Habit> _reopen(_Fixture fixture) async {
  final controller = HabitController(fixture.repository, clock: () => _today);
  addTearDown(controller.dispose);
  await controller.load();
  expect(controller.loaded, isTrue);
  return controller.habits.single;
}

Future<void> _expectUnchanged(_Fixture fixture) async {
  expect(fixture.repository.writes, 0);
  expect(fixture.repository.value, fixture.stored);
  expect(fixture.controller.exportJson(), fixture.export);
  expect(fixture.controller.habits.single.toJson(), fixture.original.toJson());
  expect((await _reopen(fixture)).toJson(), fixture.original.toJson());
}

Future<void> _expectOnlyTargetDeleted(_Fixture fixture) async {
  final target = fixture.original.entries.singleWhere(
    (entry) => entry.date == dateKey(_today),
  );
  final expected = fixture.original.copyWith(
    entries: fixture.original.entries
        .map(
          (entry) =>
              entry.id == target.id ? entry.copyWith(deleted: true) : entry,
        )
        .toList(),
  );
  expect(fixture.repository.writes, 1);
  expect(fixture.controller.habits.single.toJson(), expected.toJson());
  expect((await _reopen(fixture)).toJson(), expected.toJson());
}

void main() {
  for (final type in ['count', 'duration']) {
    testWidgets('$type discarded editor ignores its same-frame old save', (
      tester,
    ) async {
      final fixture = await _seed(type: type);
      final opened = await _open(tester, fixture);
      await tester.enterText(find.byKey(const Key('record-value-field')), '2');
      final save = _save(tester);
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed!();
      await tester.pumpAndSettle();
      final discard = tester
          .widget<TextButton>(find.byKey(const Key('discard-changes-button')))
          .onPressed!;
      discard();
      await tester.idle();
      // Complete the dialog/guard futures, but do not render a new frame.
      expect(opened.editorRoute.isCurrent, isFalse);
      expect(opened.context.mounted, isTrue);
      save();
      save();
      await tester.pumpAndSettle();
      await _expectUnchanged(fixture);
      expect(opened.baseRoute.isCurrent, isTrue);
      expect(find.text('base route sentinel'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('disposed editor ignores its cached save without an exception', (
    tester,
  ) async {
    final fixture = await _seed();
    final opened = await _open(tester, fixture);
    await tester.enterText(find.byKey(const Key('record-value-field')), '2');
    final save = _save(tester);
    opened.navigator.currentState!.pop();
    await tester.pumpAndSettle();
    expect(opened.context.mounted, isFalse);
    save();
    await tester.pumpAndSettle();
    await _expectUnchanged(fixture);
    expect(opened.baseRoute.isCurrent, isTrue);
    expect(tester.takeException(), isNull);
  });

  for (final dismissal in ['back', 'cancel']) {
    testWidgets('delete $dismissal ignores two cached confirm callbacks', (
      tester,
    ) async {
      final fixture = await _seed();
      final opened = await _open(tester, fixture);
      (await _delete(tester, fixture))();
      await tester.pumpAndSettle();
      final confirm = _confirmDelete(tester);
      if (dismissal == 'back') {
        await tester.binding.handlePopRoute();
      } else {
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消').last)
            .onPressed!();
      }
      confirm();
      confirm();
      await tester.pumpAndSettle();
      await _expectUnchanged(fixture);
      expect(opened.editorRoute.isCurrent, isTrue);
      expect(opened.baseRoute.isActive, isTrue);
      expect(find.byKey(const Key('record-value-field')), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets(
    'two delete entry callbacks open one confirmation and delete once',
    (tester) async {
      final fixture = await _seed();
      final opened = await _open(tester, fixture);
      final remove = await _delete(tester, fixture);
      remove();
      remove();
      await tester.pumpAndSettle();
      expect(find.widgetWithText(FilledButton, '撤销这条记录'), findsOneWidget);
      _confirmDelete(tester)();
      await tester.pumpAndSettle();
      await _expectOnlyTargetDeleted(fixture);
      expect(opened.editorRoute.isCurrent, isTrue);
      expect(opened.baseRoute.isActive, isTrue);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'two valid delete answers remove one entry and retain the editor',
    (tester) async {
      final fixture = await _seed();
      final opened = await _open(tester, fixture);
      (await _delete(tester, fixture))();
      await tester.pumpAndSettle();
      final confirm = _confirmDelete(tester);
      confirm();
      confirm();
      await tester.pumpAndSettle();
      await _expectOnlyTargetDeleted(fixture);
      expect(opened.editorRoute.isCurrent, isTrue);
      expect(opened.baseRoute.isActive, isTrue);
      expect(find.byKey(const Key('record-value-field')), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('late successful save cannot close a replacement route', (
    tester,
  ) async {
    final fixture = await _seed();
    final opened = await _open(tester, fixture);
    await tester.enterText(find.byKey(const Key('record-value-field')), '2');
    fixture.repository.pending = Completer<void>();
    _save(tester)();
    await tester.idle();
    expect(fixture.repository.writes, 1);
    expect(fixture.controller.exportJson(), fixture.export);
    opened.navigator.currentState!.pop();
    final replacement = MaterialPageRoute<void>(
      builder: (_) => const Scaffold(body: Text('replacement route sentinel')),
    );
    opened.navigator.currentState!.push(replacement);
    expect(opened.context.mounted, isTrue);
    expect(opened.editorRoute.isCurrent, isFalse);
    fixture.repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(replacement.isCurrent, isTrue);
    expect(opened.baseRoute.isActive, isTrue);
    expect(find.text('replacement route sentinel'), findsOneWidget);
    final saved = fixture.controller.habits.single;
    expect(fixture.repository.writes, 1);
    expect(saved.valueOn(_today), 3000);
    for (final entry in fixture.original.entries) {
      expect(
        saved.entries.singleWhere((saved) => saved.id == entry.id).toJson(),
        entry.toJson(),
      );
    }
    expect(saved.notes, fixture.original.notes);
    expect((await _reopen(fixture)).toJson(), saved.toJson());
    expect(tester.takeException(), isNull);
  });
}
