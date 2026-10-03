import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/reminder_service.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/reminder_settings_card.dart';

final _today = DateTime(2026, 10, 3, 12);

class _Repository extends MemoryHabitRepository {
  int writes = 0;

  @override
  Future<void> save(String value) async {
    writes++;
    await super.save(value);
  }
}

class _ReminderProbe implements ReminderScheduler, ReminderDiagnostics {
  ReminderAccess access = ReminderAccess.ready;
  Completer<bool>? permission;
  Completer<bool>? settings;
  int reads = 0;
  int permissions = 0;
  int opens = 0;
  int rebuilds = 0;
  final openedChannels = <bool>[];

  void clearCalls() {
    reads = 0;
    permissions = 0;
    opens = 0;
    rebuilds = 0;
    openedChannels.clear();
  }

  Map<String, Object> get calls => {
    'reads': reads,
    'permissions': permissions,
    'opens': opens,
    'rebuilds': rebuilds,
  };

  @override
  Stream<ReminderAction> get actions => const Stream.empty();

  @override
  Future<ReminderAccess> readAccess() async {
    reads++;
    return access;
  }

  @override
  Future<bool> requestPermission() async {
    permissions++;
    return permission == null ? false : await permission!.future;
  }

  @override
  Future<bool> openSettings({bool channel = false}) async {
    opens++;
    openedChannels.add(channel);
    return settings == null ? true : await settings!.future;
  }

  @override
  Future<void> syncAll(Iterable<Habit> habits) async => rebuilds++;

  @override
  Future<void> syncHabit(Habit habit) async {}

  @override
  Future<void> snooze(Habit habit, {DateTime? forDate}) async {}
}

class _Fixture {
  _Fixture(this.repository, this.controller, this.reminders)
    : original = controller.habits.single.toJson(),
      export = controller.exportJson(),
      stored = repository.value;
  final _Repository repository;
  final HabitController controller;
  final _ReminderProbe reminders;
  final Map<String, Object?> original;
  final String export;
  final String? stored;
}

class _OpenedCard {
  _OpenedCard(this.navigator, this.route, this.context);
  final GlobalKey<NavigatorState> navigator;
  final Route<void> route;
  final BuildContext context;
}

Future<_Fixture> _seed(ReminderAccess access) async {
  final repository = _Repository();
  final reminders = _ReminderProbe()..access = access;
  final controller = HabitController(
    repository,
    reminderScheduler: reminders,
    clock: () => _today,
  );
  addTearDown(controller.dispose);
  await controller.load();
  final historicalDay = DateTime(2026, 10, 1);
  expect(
    await controller.addHabit(
      startDate: historicalDay,
      title: 'reminder lifetime sentinel',
      emoji: '📖',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    ),
    isTrue,
  );
  final id = controller.habits.single.id;
  expect(await controller.toggleCompletion(id, historicalDay), isTrue);
  expect(await controller.setNote(id, historicalDay, '历史备注 sentinel'), isTrue);
  repository.writes = 0;
  reminders.clearCalls();
  return _Fixture(repository, controller, reminders);
}

Future<_OpenedCard> _open(WidgetTester tester, _Fixture fixture) async {
  final navigator = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: navigator,
      home: const Scaffold(body: Text('home route sentinel')),
    ),
  );
  final route = MaterialPageRoute<void>(
    builder: (_) =>
        Scaffold(body: ReminderSettingsCard(controller: fixture.controller)),
  );
  navigator.currentState!.push(route);
  await tester.pumpAndSettle();
  expect(fixture.reminders.reads, 1);
  fixture.reminders.clearCalls();
  return _OpenedCard(
    navigator,
    route,
    tester.element(find.byType(ReminderSettingsCard)),
  );
}

VoidCallback _action(WidgetTester tester, String action) => switch (action) {
  'request' =>
    tester
        .widget<TextButton>(find.widgetWithText(TextButton, '申请通知权限'))
        .onPressed!,
  'settings' =>
    tester
        .widget<TextButton>(find.byKey(const Key('reminder-system-settings')))
        .onPressed!,
  _ =>
    tester
        .widget<OutlinedButton>(find.byKey(const Key('reminder-rebuild')))
        .onPressed!,
};

Future<void> _expectFactsUnchanged(_Fixture fixture) async {
  expect(fixture.repository.writes, 0);
  expect(fixture.repository.value, fixture.stored);
  expect(fixture.controller.exportJson(), fixture.export);
  expect(fixture.controller.habits.single.toJson(), fixture.original);
  final reopened = HabitController(fixture.repository, clock: () => _today);
  addTearDown(reopened.dispose);
  await reopened.load();
  expect(reopened.habits.single.toJson(), fixture.original);
}

void main() {
  for (final action in ['request', 'settings', 'rebuild']) {
    for (final disposed in [false, true]) {
      testWidgets(
        '${disposed ? 'disposed' : 'dismissed'} reminder page ignores old $action',
        (tester) async {
          final access = action == 'request'
              ? ReminderAccess.appPermissionDenied
              : action == 'settings'
              ? ReminderAccess.channelDisabled
              : ReminderAccess.ready;
          final fixture = await _seed(access);
          final opened = await _open(tester, fixture);
          final callback = _action(tester, action);
          opened.navigator.currentState!.pop();
          if (disposed) await tester.pumpAndSettle();
          expect(opened.context.mounted, !disposed);
          expect(opened.route.isCurrent, isFalse);
          callback();
          callback();
          await tester.pumpAndSettle();
          debugPrint(
            'REMINDER_ROUTE_CALLS=${jsonEncode({'action': action, 'disposed': disposed, ...fixture.reminders.calls})}',
          );
          expect(fixture.reminders.calls, {
            'reads': 0,
            'permissions': 0,
            'opens': 0,
            'rebuilds': 0,
          });
          await _expectFactsUnchanged(fixture);
          expect(find.text('home route sentinel'), findsOneWidget);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  testWidgets('a live request continues through OS pause and grant on return', (
    tester,
  ) async {
    final fixture = await _seed(ReminderAccess.appPermissionDenied);
    final opened = await _open(tester, fixture);
    addTearDown(() {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    });
    fixture.reminders.permission = Completer<bool>();
    final request = _action(tester, 'request');
    request();
    request();
    await tester.idle();
    expect(fixture.reminders.permissions, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    expect(opened.route.isCurrent, isTrue);
    fixture.reminders.access = ReminderAccess.ready;
    fixture.reminders.permission!.complete(true);
    await tester.idle();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(fixture.reminders.permissions, 1);
    expect(fixture.reminders.rebuilds, 1);
    expect(fixture.reminders.opens, 0);
    expect(opened.route.isCurrent, isTrue);
    expect(find.textContaining('通知权限可用'), findsOneWidget);
    await _expectFactsUnchanged(fixture);
    expect(tester.takeException(), isNull);
  });

  for (final covered in [false, true]) {
    testWidgets(
      'OS settings return rebuilds when the card route is ${covered ? 'covered' : 'current'}',
      (tester) async {
        final fixture = await _seed(ReminderAccess.channelDisabled);
        final opened = await _open(tester, fixture);
        addTearDown(() {
          tester.binding.handleAppLifecycleStateChanged(
            AppLifecycleState.resumed,
          );
        });
        fixture.reminders.settings = Completer<bool>();
        final settings = _action(tester, 'settings');
        settings();
        settings();
        await tester.idle();
        expect(fixture.reminders.opens, 1);
        expect(fixture.reminders.openedChannels, [true]);
        tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
        if (covered) {
          opened.navigator.currentState!.push(
            MaterialPageRoute<void>(
              builder: (_) =>
                  const Scaffold(body: Text('cover route sentinel')),
            ),
          );
        }
        fixture.reminders.access = ReminderAccess.ready;
        fixture.reminders.settings!.complete(true);
        await tester.idle();
        expect(opened.context.mounted, isTrue);
        expect(opened.route.isCurrent, !covered);
        tester.binding.handleAppLifecycleStateChanged(
          AppLifecycleState.resumed,
        );
        await tester.pumpAndSettle();
        expect(fixture.reminders.opens, 1);
        expect(fixture.reminders.rebuilds, 1);
        expect(fixture.reminders.reads, 1);
        expect(fixture.reminders.permissions, 0);
        if (covered) {
          expect(find.text('cover route sentinel'), findsOneWidget);
          opened.navigator.currentState!.pop();
          await tester.pumpAndSettle();
        }
        expect(find.text('已按当前习惯和记录重建提醒。'), findsOneWidget);
        await _expectFactsUnchanged(fixture);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('two live manual rebuild callbacks schedule once', (
    tester,
  ) async {
    final fixture = await _seed(ReminderAccess.ready);
    final opened = await _open(tester, fixture);
    final rebuild = _action(tester, 'rebuild');
    rebuild();
    rebuild();
    await tester.pumpAndSettle();
    expect(fixture.reminders.calls, {
      'reads': 1,
      'permissions': 0,
      'opens': 0,
      'rebuilds': 1,
    });
    expect(opened.route.isCurrent, isTrue);
    expect(find.text('已按当前习惯和记录重建提醒。'), findsOneWidget);
    await _expectFactsUnchanged(fixture);
    expect(tester.takeException(), isNull);
  });
}
