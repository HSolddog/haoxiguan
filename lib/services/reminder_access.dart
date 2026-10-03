import 'package:flutter/services.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

enum ReminderAccess { ready, appPermissionDenied, channelDisabled, unavailable }

extension ReminderAccessMessage on ReminderAccess {
  String get message => switch (this) {
    ReminderAccess.ready => '通知权限可用，习惯提醒未被关闭。',
    ReminderAccess.appPermissionDenied => '提醒未获权限，习惯和记录已保存。请在系统通知设置中允许好习惯发送通知。',
    ReminderAccess.channelDisabled => '习惯提醒渠道已关闭，习惯和记录已保存。请在系统设置中开启“习惯提醒”渠道。',
    ReminderAccess.unavailable => '暂时无法检查提醒状态，习惯和记录已保存。请稍后重试或检查系统通知设置。',
  };
}

class ReminderUnavailable implements Exception {
  const ReminderUnavailable(this.access);
  final ReminderAccess access;

  @override
  String toString() => access.message;
}

/// Optional diagnostics, separate from scheduling so non-device schedulers do
/// not need to invent system permission or settings support.
abstract interface class ReminderDiagnostics {
  Future<ReminderAccess> readAccess();
  Future<bool> openSettings({bool channel = false});
}

class DeviceReminderDiagnostics implements ReminderDiagnostics {
  DeviceReminderDiagnostics(this._plugin);
  final FlutterLocalNotificationsPlugin _plugin;
  static const channelId = 'habit_reminders';
  static const settingsChannel = MethodChannel(
    'com.haoxiguan.haoxiguan/notification_settings',
  );

  @override
  Future<ReminderAccess> readAccess() async {
    try {
      final android = _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >();
      if (android != null) {
        final enabled = await android.areNotificationsEnabled();
        if (enabled == false) return ReminderAccess.appPermissionDenied;
        if (enabled == null) return ReminderAccess.unavailable;
        final channels = await android.getNotificationChannels();
        if (channels == null) return ReminderAccess.unavailable;
        final reminder = channels
            .where((channel) => channel.id == channelId)
            .firstOrNull;
        if (reminder?.importance == Importance.none) {
          return ReminderAccess.channelDisabled;
        }
        // A missing channel is normal before the first scheduled reminder and
        // on Android versions predating notification channels.
        return ReminderAccess.ready;
      }
      final ios = _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >();
      if (ios != null) {
        final permissions = await ios.checkPermissions();
        if (permissions == null) return ReminderAccess.unavailable;
        return permissions.isEnabled
            ? ReminderAccess.ready
            : ReminderAccess.appPermissionDenied;
      }
      return ReminderAccess.unavailable;
    } on Object {
      return ReminderAccess.unavailable;
    }
  }

  @override
  Future<bool> openSettings({bool channel = false}) async {
    try {
      return await settingsChannel.invokeMethod<bool>('open', {
            'channelId': channel ? channelId : null,
          }) ??
          false;
    } on Object {
      return false;
    }
  }
}
