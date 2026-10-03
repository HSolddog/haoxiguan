import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/reminder_service.dart';
import 'package:haoxiguan/state/habit_controller.dart';

const _notifications = MethodChannel(
  'dexterous.com/flutter/local_notifications',
);
const _timezone = MethodChannel('flutter_timezone');
const _channelId = DeviceReminderDiagnostics.channelId;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _AndroidNotifications android;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    android = _AndroidNotifications();
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_notifications, android.handle);
    messenger.setMockMethodCallHandler(_timezone, (_) async => 'Etc/UTC');
    messenger.setMockMethodCallHandler(
      DeviceReminderDiagnostics.settingsChannel,
      (call) async {
        expect(call.method, 'open');
        final id = (call.arguments as Map)['channelId'];
        return id == null || android.channels.containsKey(id);
      },
    );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(_notifications, null);
    messenger.setMockMethodCallHandler(_timezone, null);
    messenger.setMockMethodCallHandler(
      DeviceReminderDiagnostics.settingsChannel,
      null,
    );
  });

  test(
    'first access registers a settings channel before any delivery',
    () async {
      final service = LocalReminderService(handleLaunchActions: false);
      expect(await service.readAccess(), ReminderAccess.ready);
      expect(await service.openSettings(channel: true), isTrue);
      expect(android.channels.keys, [_channelId]);
      final channel = android.channels[_channelId]!;
      expect(channel['name'], '习惯提醒');
      expect(channel['description'], '在设定的时间提醒你完成习惯');
      expect(channel['importance'], Importance.high.value);
      expect(channel['playSound'], isTrue);
      expect(channel['enableVibration'], isTrue);
      expect(channel['showBadge'], isTrue);
      expect(channel['enableLights'], isFalse);
      expect(channel['bypassDnd'], isFalse);
      expect(android.methods, [
        'initialize',
        'createNotificationChannel',
        'getNotificationAppLaunchDetails',
        'areNotificationsEnabled',
        'getNotificationChannels',
      ]);
      await service.readAccess();
      expect(android.callsTo('createNotificationChannel'), hasLength(1));
    },
  );

  test('scheduled reminders retain the registered channel defaults', () async {
    final service = LocalReminderService(handleLaunchActions: false);
    await service.syncAll([_habit()]);
    final registered = android.channels[_channelId]!;
    final scheduled = android.callsTo('zonedSchedule');
    expect(scheduled, isNotEmpty);
    for (final call in scheduled) {
      final details = (call.arguments as Map)['platformSpecifics'] as Map;
      for (final keys in {
        'id': 'channelId',
        'name': 'channelName',
        'description': 'channelDescription',
        'importance': 'importance',
        'playSound': 'playSound',
        'enableVibration': 'enableVibration',
        'showBadge': 'channelShowBadge',
        'enableLights': 'enableLights',
        'bypassDnd': 'channelBypassDnd',
        'audioAttributesUsage': 'audioAttributesUsage',
      }.entries) {
        expect(details[keys.value], registered[keys.key], reason: keys.key);
      }
    }
    expect(android.callsTo('requestNotificationsPermission'), isEmpty);
    expect(android.callsTo('show'), isEmpty);
  });

  for (final importance in [Importance.none, Importance.low]) {
    test('new service preserves user channel importance $importance', () async {
      final service = LocalReminderService(handleLaunchActions: false);
      expect(await service.readAccess(), ReminderAccess.ready);
      android.channels[_channelId]!.addAll({
        'importance': importance.value,
        'playSound': false,
        'enableVibration': false,
      });
      final chosen = Map<String, Object?>.of(android.channels[_channelId]!);

      final reopened = LocalReminderService(handleLaunchActions: false);
      final access = importance == Importance.none
          ? ReminderAccess.channelDisabled
          : ReminderAccess.ready;
      expect(await reopened.readAccess(), access);
      if (importance == Importance.none) {
        await expectLater(
          reopened.syncAll([_habit()]),
          throwsA(
            isA<ReminderUnavailable>().having(
              (error) => error.access,
              'access',
              ReminderAccess.channelDisabled,
            ),
          ),
        );
        expect(android.callsTo('zonedSchedule'), isEmpty);
      } else {
        await reopened.syncAll([_habit()]);
        expect(android.callsTo('zonedSchedule'), isNotEmpty);
      }
      expect(android.channels[_channelId], chosen);
      expect(android.callsTo('createNotificationChannel'), hasLength(2));
      expect(android.channels.keys, [_channelId]);
      expect(android.callsTo('deleteNotificationChannel'), isEmpty);
      expect(android.callsTo('requestNotificationsPermission'), isEmpty);
    });
  }

  test('registration leaves app notification permission denied', () async {
    android.appEnabled = false;
    final service = LocalReminderService(handleLaunchActions: false);
    expect(await service.readAccess(), ReminderAccess.appPermissionDenied);
    expect(android.channels.keys, [_channelId]);
    expect(android.appEnabled, isFalse);
    expect(android.callsTo('requestNotificationsPermission'), isEmpty);
    await expectLater(
      service.syncAll([_habit()]),
      throwsA(
        isA<ReminderUnavailable>().having(
          (error) => error.access,
          'access',
          ReminderAccess.appPermissionDenied,
        ),
      ),
    );
    expect(android.callsTo('zonedSchedule'), isEmpty);
  });

  test(
    'registration failure is unavailable and initialization retries',
    () async {
      android.failRegistration = true;
      final service = LocalReminderService(handleLaunchActions: false);
      expect(await service.readAccess(), ReminderAccess.unavailable);
      expect(android.channels, isEmpty);
      expect(android.callsTo('getNotificationChannels'), isEmpty);
      android.failRegistration = false;
      expect(await service.readAccess(), ReminderAccess.ready);
      expect(android.callsTo('initialize'), hasLength(2));
      expect(android.callsTo('createNotificationChannel'), hasLength(2));
      expect(await service.openSettings(channel: true), isTrue);
    },
  );

  test(
    'registration failure preserves committed SQLite facts on reopen',
    () async {
      android.failRegistration = true;
      final directory = await Directory.systemTemp.createTemp(
        'haoxiguan-reminder-channel-',
      );
      final file = File('${directory.path}/facts.sqlite');
      final repositories = <SqliteHabitRepository>[];
      final controllers = <HabitController>[];
      final date = DateTime(2026, 10, 3, 12);
      SqliteHabitRepository openRepository() {
        final repository = SqliteHabitRepository(
          HabitDatabase(NativeDatabase(file)),
        );
        repositories.add(repository);
        return repository;
      }

      try {
        final repository = openRepository();
        final service = LocalReminderService(handleLaunchActions: false);
        final controller = HabitController(
          repository,
          clock: () => date,
          reminderScheduler: service,
        );
        controllers.add(controller);
        await controller.load();
        expect(controller.loaded, isTrue);
        expect(
          await controller.addHabit(
            title: 'channel failure keeps reading',
            emoji: '📖',
            colorValue: 0xff5f8068,
            weekdays: {1, 2, 3, 4, 5, 6, 7},
            reminderTime: '23:59',
          ),
          isTrue,
        );
        final habitId = controller.habits.single.id;
        expect(await controller.markCompleted(habitId, date), isTrue);
        expect(
          await controller.setNote(habitId, date, 'committed note'),
          isTrue,
        );
        expect(await controller.rebuildReminders(), isFalse);
        expect(
          await controller.readReminderAccess(),
          ReminderAccess.unavailable,
        );
        expect(controller.saveError, isNull);
        expect(controller.reminderError, contains('记录已保存'));
        expect(android.callsTo('zonedSchedule'), isEmpty);
        final committed = await repository.load();
        controller.dispose();
        controllers.remove(controller);
        await repository.close();
        repositories.remove(repository);

        final reopenedRepository = openRepository();
        final reopened = HabitController(
          reopenedRepository,
          clock: () => date,
          reminderScheduler: service,
        );
        controllers.add(reopened);
        await reopened.load();
        expect(reopened.loaded, isTrue);
        expect(await reopened.rebuildReminders(), isFalse);
        expect(await reopenedRepository.load(), committed);
        final habit = reopened.habitById(habitId)!;
        expect(habit.title, 'channel failure keeps reading');
        expect(habit.reminderTime, '23:59');
        expect(habit.isCompletedOn(date), isTrue);
        expect(habit.noteOn(date), 'committed note');

        android.failRegistration = false;
        expect(await reopened.readReminderAccess(), ReminderAccess.ready);
        expect(await reopened.rebuildReminders(), isTrue);
        expect(reopened.reminderError, isNull);
        expect(android.callsTo('zonedSchedule'), isNotEmpty);
        expect(await reopenedRepository.load(), committed);
      } finally {
        for (final controller in controllers) {
          controller.dispose();
        }
        for (final repository in repositories) {
          await repository.close();
        }
        await directory.delete(recursive: true);
      }
    },
  );
}

Habit _habit() => Habit(
  id: 'read',
  title: '阅读',
  emoji: '📖',
  colorValue: 0xff5f8068,
  weekdays: {1, 2, 3, 4, 5, 6, 7},
  createdAt: DateTime.now(),
  reminderTime: '23:59',
);

/// Native transport model for Android's documented existing-channel contract.
/// The real plugin serializes requests and parses diagnostics through this mock;
/// zonedSchedule deliberately only stores pending data, as in plugin 22.0.1.
class _AndroidNotifications {
  final calls = <MethodCall>[];
  final channels = <String, Map<String, Object?>>{};
  bool appEnabled = true;
  bool failRegistration = false;

  Iterable<String> get methods => calls.map((call) => call.method);
  Iterable<MethodCall> callsTo(String method) =>
      calls.where((call) => call.method == method);

  Future<Object?> handle(MethodCall call) async {
    calls.add(call);
    switch (call.method) {
      case 'initialize':
        return true;
      case 'createNotificationChannel':
        if (failRegistration) {
          throw PlatformException(code: 'channel_registration_failed');
        }
        final details = (call.arguments as Map).cast<String, Object?>();
        channels.putIfAbsent(
          details['id']! as String,
          () => {
            ...details,
            // getNotificationChannels uses a packed color, unlike creation.
            'ledColor': 0,
          },
        );
        return null;
      case 'getNotificationAppLaunchDetails':
      case 'cancelAll':
      case 'zonedSchedule':
        return null;
      case 'pendingNotificationRequests':
        return <Map<String, Object?>>[];
      case 'areNotificationsEnabled':
        return appEnabled;
      case 'getNotificationChannels':
        return channels.values.toList();
      default:
        throw UnimplementedError(call.method);
    }
  }
}
