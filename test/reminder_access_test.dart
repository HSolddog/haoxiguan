import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/reminder_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const notifications = MethodChannel(
    'dexterous.com/flutter/local_notifications',
  );
  late DeviceReminderDiagnostics diagnostics;
  bool? appEnabled;
  List<Map<String, Object?>>? channels;
  var unavailable = false;
  final notificationCalls = <MethodCall>[];

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    AndroidFlutterLocalNotificationsPlugin.registerWith();
    appEnabled = true;
    channels = [];
    unavailable = false;
    notificationCalls.clear();
    diagnostics = DeviceReminderDiagnostics(FlutterLocalNotificationsPlugin());
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifications, (call) async {
          notificationCalls.add(call);
          if (unavailable) throw PlatformException(code: 'unavailable');
          switch (call.method) {
            case 'initialize':
              return true;
            case 'getNotificationAppLaunchDetails':
            case 'cancelAll':
            case 'zonedSchedule':
              return null;
            case 'pendingNotificationRequests':
              return <Map<String, Object?>>[];
            case 'areNotificationsEnabled':
              return appEnabled;
            case 'getNotificationChannels':
              return channels;
          }
          throw UnimplementedError(call.method);
        });
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_timezone'),
          (call) async => 'Etc/UTC',
        );
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(notifications, null);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          DeviceReminderDiagnostics.settingsChannel,
          null,
        );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel('flutter_timezone'),
          null,
        );
  });

  test('应用拒权与提醒渠道关闭分别诊断，应用拒权优先', () async {
    channels = [_channel(Importance.none.value)];
    appEnabled = false;
    expect(await diagnostics.readAccess(), ReminderAccess.appPermissionDenied);
    appEnabled = true;
    expect(await diagnostics.readAccess(), ReminderAccess.channelDisabled);
    channels = [_channel(Importance.high.value)];
    expect(await diagnostics.readAccess(), ReminderAccess.ready);
  });

  test('尚未创建渠道不视为关闭，不把其他渠道关闭误判为提醒关闭', () async {
    expect(await diagnostics.readAccess(), ReminderAccess.ready);
    channels = [_channel(Importance.none.value, id: 'other_channel')];
    expect(await diagnostics.readAccess(), ReminderAccess.ready);
  });

  test('无法读取系统状态不能显示为已开启', () async {
    appEnabled = null;
    expect(await diagnostics.readAccess(), ReminderAccess.unavailable);
    appEnabled = true;
    channels = null;
    expect(await diagnostics.readAccess(), ReminderAccess.unavailable);
    unavailable = true;
    expect(await diagnostics.readAccess(), ReminderAccess.unavailable);
  });

  test('修复入口选择应用设置或现有提醒渠道，不修改系统权限', () async {
    final calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(DeviceReminderDiagnostics.settingsChannel, (
          call,
        ) async {
          calls.add(call);
          return true;
        });
    expect(await diagnostics.openSettings(), isTrue);
    expect(await diagnostics.openSettings(channel: true), isTrue);
    expect(calls.map((c) => c.method), ['open', 'open']);
    expect(calls[0].arguments, {'channelId': null});
    expect(calls[1].arguments, {'channelId': 'habit_reminders'});
  });

  test('系统设置不可用时提供失败结果供界面说明', () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          DeviceReminderDiagnostics.settingsChannel,
          (call) async => throw PlatformException(code: 'unavailable'),
        );
    expect(await diagnostics.openSettings(), isFalse);
  });

  test('真实调度服务拒权不排提醒，修复后重建，归档后取消', () async {
    final service = LocalReminderService(handleLaunchActions: false);
    final habit = Habit(
      id: 'read',
      title: '阅读',
      emoji: '📖',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      createdAt: DateTime.now(),
      reminderTime: '21:00',
    );
    appEnabled = false;
    await expectLater(
      service.syncAll([habit]),
      throwsA(
        isA<ReminderUnavailable>().having(
          (e) => e.access,
          'access',
          ReminderAccess.appPermissionDenied,
        ),
      ),
    );
    expect(
      notificationCalls.where((c) => c.method == 'zonedSchedule'),
      isEmpty,
    );
    appEnabled = true;
    channels = [_channel(Importance.none.value)];
    await expectLater(
      service.syncAll([habit]),
      throwsA(
        isA<ReminderUnavailable>().having(
          (e) => e.access,
          'access',
          ReminderAccess.channelDisabled,
        ),
      ),
    );
    expect(
      notificationCalls.where((c) => c.method == 'zonedSchedule'),
      isEmpty,
    );
    channels = [_channel(Importance.high.value)];
    await service.syncAll([habit]);
    expect(
      notificationCalls.where((c) => c.method == 'zonedSchedule'),
      isNotEmpty,
    );
    notificationCalls.clear();
    await service.syncAll([habit.copyWith(archived: true)]);
    expect(
      notificationCalls.where((c) => c.method == 'cancelAll'),
      hasLength(1),
    );
    expect(
      notificationCalls.where((c) => c.method == 'zonedSchedule'),
      isEmpty,
    );
  });
}

Map<String, Object?> _channel(
  int importance, {
  String id = 'habit_reminders',
}) => {
  'id': id,
  'name': '习惯提醒',
  'description': '提醒',
  'importance': importance,
  'playSound': true,
  'enableVibration': true,
  'showBadge': true,
  'enableLights': false,
  'ledColor': 0,
  'bypassDnd': false,
  'audioAttributesUsage': AudioAttributesUsage.notification.value,
};
