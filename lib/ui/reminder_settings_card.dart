import 'dart:async';

import 'package:flutter/material.dart';

import '../services/reminder_access.dart';
import '../state/habit_controller.dart';

class ReminderSettingsCard extends StatefulWidget {
  const ReminderSettingsCard({super.key, required this.controller});
  final HabitController controller;

  @override
  State<ReminderSettingsCard> createState() => _ReminderSettingsCardState();
}

class _ReminderSettingsCardState extends State<ReminderSettingsCard>
    with WidgetsBindingObserver {
  ReminderAccess? _access;
  String? _result;
  bool _busy = false;
  bool _returningFromSettings = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_check());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      if (_returningFromSettings) {
        _returningFromSettings = false;
        unawaited(_rebuild());
      } else {
        // Settings may have been changed from the system app switcher. Main's
        // resume handler rebuilds reminders; refresh the visible diagnosis too.
        unawaited(_check(clearResult: true));
      }
    }
  }

  Future<void> _check({bool clearResult = false}) async {
    final access = await widget.controller.readReminderAccess();
    if (mounted) {
      setState(() {
        _access = access;
        if (clearResult) _result = null;
      });
    }
  }

  Future<void> _request() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await widget.controller.requestReminderPermission();
      await _check();
      if (mounted) {
        setState(() => _result = widget.controller.reminderError);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openSettings() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _returningFromSettings = true;
    });
    final opened = await widget.controller.openReminderSettings(
      channel: _access == ReminderAccess.channelDisabled,
    );
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!opened) {
        _returningFromSettings = false;
        _result = '无法打开系统设置。请在系统“应用 → 好习惯 → 通知”中检查后，返回重建提醒。';
      } else {
        _result = '在系统设置中开启通知后返回，将重新检查并重建提醒。';
      }
    });
  }

  Future<void> _rebuild() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _check();
      if (_access != ReminderAccess.ready) {
        if (mounted) setState(() => _result = _access?.message);
        return;
      }
      final rebuilt = await widget.controller.rebuildReminders();
      if (mounted) {
        setState(
          () => _result = rebuilt
              ? '已按当前习惯和记录重建提醒。'
              : widget.controller.reminderError ?? '提醒重建失败，请重试。',
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: widget.controller,
    builder: (context, _) => _buildStatus(context),
  );

  Widget _buildStatus(BuildContext context) {
    final access = _access;
    // Scheduling can fail during startup/resume or after any saved record, even
    // with permission granted. Do not hide that failure behind the access check.
    final result = widget.controller.reminderError ?? _result;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('提醒状态', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(access?.message ?? '正在检查通知权限与提醒渠道…'),
          if (result != null && result != access?.message) ...[
            const SizedBox(height: 8),
            Semantics(liveRegion: true, child: Text(result)),
          ],
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (access == ReminderAccess.appPermissionDenied)
                TextButton(
                  style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                  onPressed: _busy ? null : _request,
                  child: const Text('申请通知权限'),
                ),
              TextButton(
                key: const Key('reminder-system-settings'),
                style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
                onPressed: _busy ? null : _openSettings,
                child: Text(
                  access == ReminderAccess.channelDisabled
                      ? '开启提醒渠道'
                      : '打开通知设置',
                ),
              ),
              OutlinedButton(
                key: const Key('reminder-rebuild'),
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size(48, 48),
                ),
                onPressed: _busy ? null : _rebuild,
                child: Text(_busy ? '正在检查…' : '检查并重建提醒'),
              ),
            ],
          ),
        ],
      ),
    );
  }
}
