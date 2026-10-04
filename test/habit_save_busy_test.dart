import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/reminder_service.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';

final _today = DateTime(2026, 10, 3, 12);
const _title = 'single committed habit';

class _Repository extends MemoryHabitRepository {
  Completer<void>? pending;
  bool fail = false;
  int writes = 0;

  @override
  Future<void> save(String value) async {
    writes++;
    await pending?.future;
    if (fail) {
      fail = false;
      throw StateError('synthetic write failure');
    }
    await super.save(value);
  }
}

class _Reminders extends NoopReminderScheduler {
  int permissions = 0;
  int persistedAtPermission = 0;
  bool granted = false;
  bool failRebuild = false;
  _Repository? repository;

  @override
  Future<bool> requestPermission() async {
    permissions++;
    persistedAtPermission =
        (jsonDecode(repository!.value!) as Map)['habits'].length as int;
    return granted;
  }

  @override
  Future<void> syncAll(Iterable<Habit> habits) async {
    if (failRebuild) throw StateError('synthetic scheduling failure');
  }
}

class _Opened {
  _Opened(
    this.repository,
    this.controller,
    this.navigator,
    this.base,
    this.owner,
    this.original,
  );
  final _Repository repository;
  final HabitController controller;
  final GlobalKey<NavigatorState> navigator;
  final Route<void> base;
  final ModalRoute<Object?> owner;
  final String original;
}

Future<_Opened> _open(WidgetTester tester, {_Reminders? reminders}) async {
  tester.view.physicalSize = const Size(1200, 2400);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.resetPhysicalSize);
  addTearDown(tester.view.resetDevicePixelRatio);
  final repository = _Repository();
  reminders?.repository = repository;
  final controller = HabitController(
    repository,
    clock: () => _today,
    reminderScheduler: reminders,
  );
  addTearDown(controller.dispose);
  await controller.load();
  expect(
    await controller.addHabit(
      title: 'existing fact',
      emoji: 'A',
      colorValue: 0xff397d6d,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: 'count',
      unit: 'pages',
      scale: 1000,
      dailyTarget: 1000,
    ),
    isTrue,
  );
  final original = controller.habits.single;
  expect(await controller.addValue(original.id, _today, 1000), isTrue);
  expect(
    await controller.setNote(original.id, _today, 'retained note'),
    isTrue,
  );
  final originalJson = jsonEncode(controller.habitById(original.id)!.toJson());
  repository.writes = 0;
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('root')),
    ),
  );
  final base = MaterialPageRoute<void>(
    builder: (context) => Scaffold(
      body: TextButton(
        onPressed: () => showAddHabitSheet(context, controller),
        child: const Text('open create'),
      ),
    ),
  );
  navigator.currentState!.push(base);
  await tester.pumpAndSettle();
  await tester.tap(find.text('open create'));
  await tester.pumpAndSettle();
  await tester.enterText(find.byKey(const Key('habit-title-field')), _title);
  await tester.tap(find.byKey(const Key('habit-advanced-options')));
  await tester.pumpAndSettle();
  final owner = ModalRoute.of(
    tester.element(find.byKey(const Key('habit-title-field'))),
  )!;
  return _Opened(repository, controller, navigator, base, owner, originalJson);
}

Future<void> _click(WidgetTester tester, Finder target) async {
  await tester.ensureVisible(target);
  await tester.pump(const Duration(milliseconds: 100));
  expect(target.hitTestable(), findsOneWidget);
  await tester.tap(target);
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _begin(WidgetTester tester, _Opened opened) async {
  opened.repository.pending = Completer<void>();
  await _click(tester, find.byKey(const Key('save-habit-button')));
  await tester.idle();
  expect(opened.repository.writes, 1);
}

Future<void> _release(WidgetTester tester, _Opened opened) async {
  opened.repository.pending!.complete();
  await tester.pump(const Duration(milliseconds: 500));
  await tester.idle();
}

void _observe(
  String name,
  Map<String, Object?> expected,
  Map<String, Object?> actual,
) {
  // Only public synthetic outcomes/counts, with no user text or private storage.
  // ignore: avoid_print
  print(jsonEncode({'case': name, 'expected': expected, 'actual': actual}));
  expect(actual, expected);
}

void _retained(_Opened opened) {
  expect(jsonEncode(opened.controller.habits.first.toJson()), opened.original);
}

void main() {
  for (final picker in ['date', 'time']) {
    testWidgets(
      'slow create blocks $picker picker before persistence completes',
      (tester) async {
        final opened = await _open(tester);
        await _begin(tester, opened);
        final target = picker == 'date'
            ? find.byKey(const Key('habit-start-date'))
            : find.widgetWithText(ListTile, '提醒时间');
        await _click(tester, target);
        final openedPicker = picker == 'date'
            ? find.byType(DatePickerDialog).evaluate().isNotEmpty
            : find.byType(TimePickerDialog).evaluate().isNotEmpty;
        await _release(tester, opened);
        if (openedPicker) {
          opened.navigator.currentState!.pop();
          await tester.pumpAndSettle();
          await _click(tester, find.byKey(const Key('save-habit-button')));
          await tester.pumpAndSettle();
        }
        _retained(opened);
        _observe(
          'busy_${picker}_picker',
          {'pickerOpened': false, 'writes': 1, 'newHabits': 1},
          {
            'pickerOpened': openedPicker,
            'writes': opened.repository.writes,
            'newHabits': opened.controller.habits.length - 1,
          },
        );
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('slow create blocks keyboard input and record type menu', (
    tester,
  ) async {
    final opened = await _open(tester);
    await _begin(tester, opened);
    final title = find.byKey(const Key('habit-title-field'));
    await _click(tester, title);
    final inputAccepted = tester.testTextInput.hasAnyClients;
    if (inputAccepted) {
      tester.testTextInput.enterText('changed while committing');
    }
    await tester.pump();
    final titleUnchanged =
        tester.widget<TextField>(title).controller!.text == _title;
    final fieldDisabled = tester.widget<TextField>(title).enabled == false;
    await _click(tester, find.byKey(const Key('record-type-field')));
    final menuOpened =
        find.byType(DropdownMenuItem<String>).hitTestable().evaluate().length >
        3;
    final dropdownDisabled =
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const Key('record-type-field')),
            )
            .onChanged ==
        null;
    if (menuOpened) opened.navigator.currentState!.pop();
    await _release(tester, opened);
    await tester.pumpAndSettle();
    _retained(opened);
    _observe(
      'busy_keyboard_and_dropdown',
      {
        'inputAccepted': false,
        'titleUnchanged': true,
        'fieldDisabled': true,
        'dropdownDisabled': true,
        'writes': 1,
      },
      {
        'inputAccepted': inputAccepted,
        'titleUnchanged': titleUnchanged,
        'fieldDisabled': fieldDisabled,
        'dropdownDisabled': dropdownDisabled,
        'writes': opened.repository.writes,
      },
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets(
    'covered successful create returns to completion without a second habit',
    (tester) async {
      final opened = await _open(tester);
      await _begin(tester, opened);
      final upper = MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('external upper route')),
      );
      opened.navigator.currentState!.push(upper);
      await tester.pump(const Duration(milliseconds: 500));
      await _release(tester, opened);
      expect(upper.isCurrent, isTrue);
      expect(opened.owner.isActive, isTrue);
      opened.navigator.currentState!.pop();
      await tester.pumpAndSettle();
      await _click(tester, find.byKey(const Key('save-habit-button')));
      await tester.pumpAndSettle();
      _retained(opened);
      _observe(
        'covered_success_returns_once',
        {
          'writes': 1,
          'newHabits': 1,
          'ownerActive': false,
          'baseCurrent': true,
        },
        {
          'writes': opened.repository.writes,
          'newHabits': opened.controller.habits.length - 1,
          'ownerActive': opened.owner.isActive,
          'baseCurrent': opened.base.isCurrent,
        },
      );
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'failed slow create unlocks inputs and retries once with original facts retained',
    (tester) async {
      final opened = await _open(tester);
      opened.repository.fail = true;
      await _begin(tester, opened);
      await _release(tester, opened);
      await tester.pumpAndSettle();
      expect(opened.owner.isCurrent, isTrue);
      expect(opened.controller.habits.length, 1);
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('habit-title-field')))
            .enabled,
        isNot(false),
      );
      expect(
        tester
            .widget<DropdownButtonFormField<String>>(
              find.byKey(const Key('record-type-field')),
            )
            .onChanged,
        isNotNull,
      );
      await tester.enterText(
        find.byKey(const Key('habit-title-field')),
        'retry committed habit',
      );
      await _click(tester, find.byKey(const Key('save-habit-button')));
      await tester.pumpAndSettle();
      _retained(opened);
      _observe(
        'failed_create_retry',
        {
          'writes': 2,
          'newHabits': 1,
          'ownerActive': false,
          'baseCurrent': true,
        },
        {
          'writes': opened.repository.writes,
          'newHabits': opened.controller.habits.length - 1,
          'ownerActive': opened.owner.isActive,
          'baseCurrent': opened.base.isCurrent,
        },
      );
      expect(tester.takeException(), isNull);
    },
  );

  for (final rebuildFailure in [false, true]) {
    testWidgets(
      'covered create requests permission once after save and reports ${rebuildFailure ? 'rebuild failure' : 'denial'}',
      (tester) async {
        final reminders = _Reminders()..granted = rebuildFailure;
        final opened = await _open(tester, reminders: reminders);
        await _click(tester, find.widgetWithText(ListTile, '提醒时间'));
        await tester.pumpAndSettle();
        expect(find.byType(TimePickerDialog), findsOneWidget);
        await tester.tap(find.widgetWithText(TextButton, 'OK'));
        await tester.pumpAndSettle();
        reminders.failRebuild = rebuildFailure;
        await _begin(tester, opened);
        final beforeSavePermissions = reminders.permissions;
        final upper = MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('permission upper route')),
        );
        opened.navigator.currentState!.push(upper);
        await tester.pump(const Duration(milliseconds: 500));
        await _release(tester, opened);
        expect(upper.isCurrent, isTrue);
        final afterSavePermissions = reminders.permissions;
        final errorShown =
            opened.controller.reminderError != null &&
            find
                .text(opened.controller.reminderError!, skipOffstage: false)
                .evaluate()
                .isNotEmpty;
        opened.navigator.currentState!.pop();
        await tester.pumpAndSettle();
        await _click(tester, find.byKey(const Key('save-habit-button')));
        await tester.pumpAndSettle();
        _retained(opened);
        _observe(
          'covered_permission_${rebuildFailure ? 'rebuild' : 'denial'}',
          {
            'beforeSavePermissions': 0,
            'afterSavePermissions': 1,
            'finalPermissions': 1,
            'persistedAtPermission': 2,
            'errorShown': true,
            'writes': 1,
            'newHabits': 1,
          },
          {
            'beforeSavePermissions': beforeSavePermissions,
            'afterSavePermissions': afterSavePermissions,
            'finalPermissions': reminders.permissions,
            'persistedAtPermission': reminders.persistedAtPermission,
            'errorShown': errorShown,
            'writes': opened.repository.writes,
            'newHabits': opened.controller.habits.length - 1,
          },
        );
        expect(tester.takeException(), isNull);
      },
    );
  }
}
