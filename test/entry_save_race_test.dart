import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/reminder_service.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_history.dart';
import 'package:haoxiguan/ui/record_editor.dart';
import 'package:haoxiguan/ui/reminder_settings_card.dart';

class _SaveGateRepository extends MemoryHabitRepository {
  Completer<void>? pending;
  bool failNext = false;
  int saveCalls = 0;

  @override
  Future<void> save(String value) async {
    saveCalls++;
    await pending?.future;
    if (failNext) {
      failNext = false;
      throw StateError('synthetic storage failure');
    }
    await super.save(value);
  }
}

class _ReminderGate implements ReminderScheduler, ReminderDiagnostics {
  ReminderAccess access = ReminderAccess.appPermissionDenied;
  Completer<bool>? permission;
  Completer<bool>? settings;
  int permissionCalls = 0;
  int settingsCalls = 0;
  final openedChannels = <bool>[];

  @override
  Stream<ReminderAction> get actions => const Stream.empty();
  @override
  Future<ReminderAccess> readAccess() async => access;
  @override
  Future<bool> requestPermission() async {
    permissionCalls++;
    return await permission!.future;
  }

  @override
  Future<bool> openSettings({bool channel = false}) async {
    settingsCalls++;
    openedChannels.add(channel);
    return await settings!.future;
  }

  @override
  Future<void> syncAll(Iterable<Habit> habits) async {}
  @override
  Future<void> syncHabit(Habit habit) async {}
  @override
  Future<void> snooze(Habit habit, {DateTime? forDate}) async {}
}

Future<HabitController> _controller(
  MemoryHabitRepository repository, {
  String type = 'count',
  ReminderScheduler? reminders,
}) async {
  final controller = HabitController(
    repository,
    clock: () => DateTime(2026, 10, 3, 12),
    reminderScheduler: reminders,
  );
  await controller.load();
  expect(
    await controller.addHabit(
      title: 'synthetic first-frame race',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: type,
      unit: type == 'duration'
          ? '分钟'
          : type == 'count'
          ? '杯'
          : '次',
      scale: type == 'count' ? 1000 : 1,
      dailyTarget: type == 'duration'
          ? 600
          : type == 'count'
          ? 1000
          : 1,
    ),
    isTrue,
  );
  return controller;
}

Future<void> _openRecord(
  WidgetTester tester,
  HabitController controller,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () => showRecordEditor(
              context,
              controller,
              controller.habits.single,
              controller.today,
            ),
            child: const Text('open record'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open record'));
  await tester.pumpAndSettle();
}

VoidCallback _filledCallback(WidgetTester tester, Finder finder) =>
    tester.widget<FilledButton>(finder).onPressed!;

VoidCallback _textCallback(WidgetTester tester, Finder finder) =>
    tester.widget<TextButton>(finder).onPressed!;

void _evidence(String scenario, Map<String, Object> facts) => debugPrint(
  'ENTRY_SAVE_RACE_EVIDENCE=${jsonEncode({'scenario': scenario, ...facts})}',
);

void main() {
  for (final type in ['count', 'duration']) {
    testWidgets('$type save rejects stale callbacks before the first pump', (
      tester,
    ) async {
      final repository = _SaveGateRepository();
      final controller = await _controller(repository, type: type);
      addTearDown(controller.dispose);
      final id = controller.habits.single.id;
      final initial = type == 'duration' ? 300 : 1000;
      final increment = type == 'duration' ? 120 : 2000;
      expect(await controller.addValue(id, controller.today, initial), isTrue);
      expect(
        await controller.setNote(id, controller.today, 'keep note'),
        isTrue,
      );
      final originalEntry = controller.habits.single.entries.single.toJson();
      final before = repository.value;
      await _openRecord(tester, controller);
      await tester.enterText(find.byKey(const Key('record-value-field')), '2');
      final save = _filledCallback(
        tester,
        find.byKey(const Key('save-record-button')),
      );
      final cancel = _textCallback(
        tester,
        find.widgetWithText(TextButton, '取消'),
      );
      repository
        ..saveCalls = 0
        ..pending = Completer<void>();

      // Both callbacks are from the old frame. No pump may refresh the button
      // or PopScope before the second action and system back are delivered.
      save();
      save();
      cancel();
      await tester.binding.handlePopRoute();
      await tester.tapAt(const Offset(5, 5));
      await tester.idle();
      expect(repository.saveCalls, 1);
      expect(repository.value, before);
      expect(controller.habits.single.valueOn(controller.today), initial);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('record-value-field')), findsOneWidget);
      expect(find.byKey(const Key('discard-changes-button')), findsNothing);

      repository.pending!.complete();
      await tester.pumpAndSettle();
      final saved = controller.habits.single;
      expect(saved.entries.where((e) => !e.deleted), hasLength(2));
      expect(saved.valueOn(controller.today), initial + increment);
      expect(saved.entries.first.toJson(), originalEntry);
      expect(saved.noteOn(controller.today), 'keep note');
      expect(repository.saveCalls, 1);
      expect(find.byKey(const Key('record-value-field')), findsNothing);
      final reopened = HabitController(repository);
      addTearDown(reopened.dispose);
      await reopened.load();
      expect(reopened.habits.single.toJson(), saved.toJson());
      expect(tester.takeException(), isNull);
      _evidence('record-$type', {
        'saveCalls': repository.saveCalls,
        'liveEntries': saved.entries.where((e) => !e.deleted).length,
        'value': saved.valueOn(controller.today),
        'reopenedMatches': true,
      });
    });
  }

  testWidgets('record failure retains the draft and permits one retry', (
    tester,
  ) async {
    final repository = _SaveGateRepository();
    final controller = await _controller(repository);
    addTearDown(controller.dispose);
    final before = repository.value;
    await _openRecord(tester, controller);
    await tester.enterText(find.byKey(const Key('record-value-field')), '2');
    repository
      ..saveCalls = 0
      ..failNext = true
      ..pending = Completer<void>();
    var save = _filledCallback(
      tester,
      find.byKey(const Key('save-record-button')),
    );
    save();
    save();
    await tester.idle();
    expect(repository.saveCalls, 1);
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(repository.value, before);
    expect(controller.habits.single.entries, isEmpty);
    expect(find.text('保存未完成，请重试。'), findsOneWidget);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('record-value-field')))
          .controller!
          .text,
      '2',
    );
    repository.pending = Completer<void>();
    save = _filledCallback(tester, find.byKey(const Key('save-record-button')));
    save();
    save();
    await tester.idle();
    expect(repository.saveCalls, 2);
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(controller.habits.single.entries, hasLength(1));
    expect(controller.habits.single.valueOn(controller.today), 2000);
    expect(find.byKey(const Key('record-value-field')), findsNothing);
    expect(tester.takeException(), isNull);
    _evidence('record-failure-retry', {
      'attempts': repository.saveCalls,
      'liveEntries': controller.habits.single.entries.length,
      'value': controller.habits.single.valueOn(controller.today),
    });
  });

  testWidgets('history correction blocks live exit and commits only once', (
    tester,
  ) async {
    final repository = _SaveGateRepository();
    final controller = await _controller(repository, type: 'boolean');
    addTearDown(controller.dispose);
    final id = controller.habits.single.id;
    expect(await controller.markCompleted(id, controller.today), isTrue);
    expect(await controller.setNote(id, controller.today, 'keep note'), isTrue);
    final original = controller.habits.single;
    final before = repository.value;
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showStartDateCorrection(
                context,
                controller,
                controller.habits.single,
              ),
              child: const Text('open correction'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open correction'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    for (final fail in [true, false]) {
      repository
        ..failNext = fail
        ..pending = Completer<void>();
      if (fail) repository.saveCalls = 0;
      final save = _filledCallback(
        tester,
        find.byKey(const Key('confirm-start-correction')),
      );
      final cancel = _textCallback(
        tester,
        find.widgetWithText(TextButton, '取消'),
      );
      save();
      save();
      cancel();
      await tester.binding.handlePopRoute();
      await tester.idle();
      expect(repository.saveCalls, fail ? 1 : 2);
      expect(repository.value, before);
      expect(controller.habits.single.toJson(), original.toJson());
      await tester.pumpAndSettle();
      expect(find.text('历史校正影响预览'), findsOneWidget);
      expect(find.byKey(const Key('discard-changes-button')), findsNothing);
      repository.pending!.complete();
      await tester.pumpAndSettle();
      if (fail) {
        expect(find.text('历史校正影响预览'), findsOneWidget);
        expect(find.text(controller.saveError!), findsOneWidget);
        expect(repository.value, before);
      }
    }
    final saved = controller.habits.single;
    expect(saved.createdAt, DateTime.utc(2026, 10, 2));
    expect(
      saved.entries.map((e) => e.toJson()).toList(),
      original.entries.map((e) => e.toJson()).toList(),
    );
    expect(saved.notes, original.notes);
    expect(find.text('历史校正影响预览'), findsNothing);
    final reopened = HabitController(repository);
    addTearDown(reopened.dispose);
    await reopened.load();
    expect(reopened.habits.single.toJson(), saved.toJson());
    expect(tester.takeException(), isNull);
    _evidence('history-failure-retry', {
      'attempts': repository.saveCalls,
      'start': '2026-10-02',
      'factsPreserved': true,
      'reopenedMatches': true,
    });
  });

  testWidgets(
    'permission rejects old callbacks and remains retryable on failure',
    (tester) async {
      final repository = MemoryHabitRepository();
      final reminders = _ReminderGate();
      final controller = await _controller(repository, reminders: reminders);
      addTearDown(controller.dispose);
      final before = repository.value;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: ReminderSettingsCard(controller: controller)),
        ),
      );
      await tester.pumpAndSettle();
      for (final fail in [true, false]) {
        reminders.permission = Completer<bool>();
        final request = _textCallback(
          tester,
          find.widgetWithText(TextButton, '申请通知权限'),
        );
        final settings = _textCallback(
          tester,
          find.byKey(const Key('reminder-system-settings')),
        );
        request();
        request();
        settings();
        await tester.idle();
        expect(reminders.permissionCalls, fail ? 1 : 2);
        expect(reminders.settingsCalls, 0);
        expect(repository.value, before);
        if (fail) {
          reminders.permission!.completeError(
            StateError('synthetic permission failure'),
          );
        } else {
          reminders.access = ReminderAccess.ready;
          reminders.permission!.complete(true);
        }
        await tester.pumpAndSettle();
        if (fail) {
          expect(find.textContaining('无法申请通知权限'), findsOneWidget);
        }
      }
      expect(find.textContaining('通知权限可用'), findsOneWidget);
      expect(repository.value, before);
      expect(tester.takeException(), isNull);
      _evidence('permission-failure-retry', {
        'permissionCalls': reminders.permissionCalls,
        'settingsCalls': reminders.settingsCalls,
        'factsUnchanged': true,
      });
    },
  );

  testWidgets('settings rejects old callbacks and false results permit retry', (
    tester,
  ) async {
    final repository = MemoryHabitRepository();
    final reminders = _ReminderGate()..access = ReminderAccess.channelDisabled;
    final controller = await _controller(repository, reminders: reminders);
    addTearDown(controller.dispose);
    final before = repository.value;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: ReminderSettingsCard(controller: controller)),
      ),
    );
    await tester.pumpAndSettle();
    for (final opened in [false, true]) {
      reminders.settings = Completer<bool>();
      final settings = _textCallback(
        tester,
        find.byKey(const Key('reminder-system-settings')),
      );
      final rebuild = tester
          .widget<OutlinedButton>(find.byKey(const Key('reminder-rebuild')))
          .onPressed!;
      settings();
      settings();
      rebuild();
      await tester.idle();
      expect(reminders.settingsCalls, opened ? 2 : 1);
      expect(repository.value, before);
      reminders.settings!.complete(opened);
      await tester.pumpAndSettle();
      if (!opened) {
        expect(find.textContaining('无法打开系统设置'), findsOneWidget);
      }
    }
    expect(reminders.openedChannels, [true, true]);
    expect(repository.value, before);
    expect(tester.takeException(), isNull);
    _evidence('settings-failure-retry', {
      'settingsCalls': reminders.settingsCalls,
      'channelArguments': true,
      'factsUnchanged': true,
    });
  });
}
