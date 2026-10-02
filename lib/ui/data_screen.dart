import 'dart:convert';
import 'webdav_screen.dart';
import 'sync_screen.dart';

import 'package:flutter/material.dart';

import '../data/snapshot_codec.dart';
import '../models/habit.dart';
import '../services/backup_codec.dart';
import '../services/backup_files.dart';
import '../state/habit_controller.dart';

class DataScreen extends StatefulWidget {
  const DataScreen({
    super.key,
    required this.controller,
    required this.onTheme,
    required this.onReview,
    required this.onLegacyRestore,
    this.files,
  });
  final HabitController controller;
  final VoidCallback onTheme;
  final VoidCallback onReview;
  final VoidCallback onLegacyRestore;
  final BackupFiles? files;
  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> {
  bool _busy = false;
  String? _result;
  BackupFiles get _files => widget.files ?? PlatformBackupFiles();
  Future<void> _run(Future<String?> Function() action) async {
    setState(() {
      _busy = true;
      _result = null;
    });
    try {
      final result = await action();
      if (mounted) setState(() => _result = result);
    } on FormatException catch (error) {
      if (mounted) setState(() => _result = error.message);
    } on Object {
      if (mounted) {
        setState(() => _result = '操作未完成，应用里的数据没有被清空。请检查文件权限和存储空间后重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _exportEncrypted() => _run(() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _PasswordDialog(creating: true),
    );
    if (password == null) return null;
    final snapshot = widget.controller.exportJson();
    final bytes = await BackupCodec.encrypt(snapshot, password);
    // Verify the file format and password before asking the OS to save it.
    await BackupCodec.decrypt(bytes, password);
    final saved = await _files.save(
      bytes,
      'haoxiguan-${DateTime.now().toUtc().millisecondsSinceEpoch}.hgb',
    );
    return saved ? '加密备份已保存，并已读回校验。请妥善保存密码。' : null;
  });

  Future<void> _exportPlain() => _run(() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出可读 JSON？'),
        content: const Text('这个文件没有密码，拿到文件的人可以读取记录。请选择你信任的位置。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('导出明文'),
          ),
        ],
      ),
    );
    if (confirm != true) return null;
    final bytes = utf8.encode(
      jsonEncode({
        'format': BackupCodec.format,
        'formatVersion': 1,
        'encrypted': false,
        'data': jsonDecode(widget.controller.exportJson()),
      }),
    );
    final saved = await _files.save(
      bytes,
      'haoxiguan-${DateTime.now().toUtc().millisecondsSinceEpoch}.json',
    );
    return saved ? 'JSON 已保存，并已读回校验。' : null;
  });

  Future<void> _restore() => _run(() async {
    final bytes = await _files.open();
    if (bytes == null) return null;
    final envelope = jsonDecode(utf8.decode(bytes));
    String raw;
    if (envelope is Map && envelope['format'] == BackupCodec.format) {
      if (envelope['formatVersion'] != 1) {
        throw const FormatException('不支持的备份版本');
      }
      if (envelope['encrypted'] == true) {
        if (!mounted) return null;
        final password = await showDialog<String>(
          context: context,
          builder: (_) => const _PasswordDialog(creating: false),
        );
        if (password == null) return null;
        raw = await BackupCodec.decrypt(bytes, password);
      } else if (envelope['encrypted'] == false) {
        raw = jsonEncode(envelope['data']);
      } else {
        throw const FormatException('备份格式无效');
      }
    } else {
      raw = utf8.decode(bytes);
    }
    final document = SnapshotCodec.decode(raw);
    final habits = (document['habits']! as List)
        .map((h) => Habit.fromJson((h as Map).cast<String, Object?>()))
        .toList();
    final records = habits.fold<int>(
      0,
      (sum, h) => sum + h.entries.where((e) => !e.deleted).length,
    );
    if (!mounted) return null;
    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认恢复这份数据？'),
        content: Text(
          '文件包含 ${habits.length} 个习惯、$records 条记录。\n\n将替换本机 ${widget.controller.habits.length} 个习惯，恢复前自动保护当前数据。恢复为空间副本，默认不连接原同步服务。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('保护当前数据并恢复'),
          ),
        ],
      ),
    );
    if (confirm != true) return null;
    return await widget.controller.importJson(raw)
        ? '数据恢复成功。'
        : widget.controller.saveError;
  });

  @override
  Widget build(BuildContext context) {
    final controller = widget.controller;
    return SafeArea(
      child: ListView(
        key: const PageStorageKey<String>('data-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        children: [
          Text(
            '数据与设置',
            style: Theme.of(
              context,
            ).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          const Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Icon(Icons.storage_outlined, size: 32),
                  SizedBox(height: 12),
                  Text(
                    '保存在本机，离线也能使用',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  SizedBox(height: 8),
                  Text('日常保存和更新不需要账号或云备份。独立备份用于换机、设备丢失等情况。'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_busy) const LinearProgressIndicator(),
          if (_result != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_result!, key: const Key('data-result')),
            ),
          Card(
            child: Column(
              children: [
                ListTile(
                  leading: const Icon(Icons.lock_outline),
                  title: const Text('创建加密备份'),
                  subtitle: const Text('文件由你选择保存位置，密码由你保管'),
                  onTap: _busy ? null : _exportEncrypted,
                ),
                ListTile(
                  leading: const Icon(Icons.restore),
                  title: const Text('从文件恢复'),
                  subtitle: const Text('先校验和预览，再保护原数据并恢复'),
                  onTap: _busy ? null : _restore,
                ),
                ListTile(
                  leading: const Icon(Icons.description_outlined),
                  title: const Text('导出可读 JSON'),
                  subtitle: const Text('完整数据，不加密'),
                  onTap: _busy ? null : _exportPlain,
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('自己的 WebDAV 备份'),
                  subtitle: const Text('远端加密快照、自动尝试和换机恢复'),
                  onTap: _busy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) =>
                                WebDavScreen(controller: controller),
                          ),
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('自有同步服务'),
                  subtitle: const Text('实验性端到端加密同步、设备与冲突'),
                  onTap: _busy
                      ? null
                      : () => Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => SyncScreen(controller: controller),
                          ),
                        ),
                ),
                ListTile(
                  leading: const Icon(Icons.history),
                  title: const Text('粘贴旧版 JSON'),
                  onTap: _busy ? null : widget.onLegacyRestore,
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),
          Card(
            child: Column(
              children: [
                SwitchListTile(
                  title: const Text('深色模式'),
                  value: controller.darkMode,
                  onChanged: controller.setDarkMode,
                ),
                ListTile(
                  title: const Text('主题颜色'),
                  leading: Icon(
                    Icons.palette_outlined,
                    color: Color(controller.themeColorValue),
                  ),
                  onTap: widget.onTheme,
                ),
                ListTile(
                  title: const Text('默认回顾周期'),
                  subtitle: Text('${controller.reviewDays} 天'),
                  onTap: widget.onReview,
                ),
                ListTile(
                  title: const Text('检查通知权限'),
                  subtitle: Text(controller.reminderError ?? '提醒失败不会影响记录保存'),
                  onTap: () async {
                    final granted = await controller
                        .requestReminderPermission();
                    if (mounted) {
                      setState(
                        () => _result = granted
                            ? '已获得通知权限。'
                            : '请在系统设置中允许通知；不影响本地记录。',
                      );
                    }
                  },
                ),
              ],
            ),
          ),
          if (controller.habits.any((h) => h.legacyRewardBalance != null)) ...[
            const SizedBox(height: 20),
            ExpansionTile(
              key: const PageStorageKey<String>('legacy-rewards-expanded'),
              title: const Text('旧版奖励（只读）'),
              subtitle: const Text('保留迁移时的余额和心愿，不再重新扣分'),
              children: [
                for (final habit in controller.habits.where(
                  (h) => h.legacyRewardBalance != null,
                ))
                  ListTile(
                    title: Text(habit.title),
                    subtitle: Text(
                      '${habit.legacyRewardBalance} 努力值${habit.wishTitle.isEmpty ? '' : ' · ${habit.wishTitle}'}',
                    ),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          const Text(
            '好习惯 · MIT 开源\n本地数据受系统沙箱和设备存储保护；加密备份与本地存储是独立能力。',
            style: TextStyle(fontSize: 12),
          ),
        ],
      ),
    );
  }
}

class _PasswordDialog extends StatefulWidget {
  const _PasswordDialog({required this.creating});
  final bool creating;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  String? _error;
  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: Text(widget.creating ? '设置备份密码' : '输入备份密码'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            widget.creating
                ? '至少 12 个字符，建议多个随机词。密码无法由服务器或维护者找回，请另行妥善保存。'
                : '使用创建这份文件时的备份密码。',
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _password,
            autofocus: true,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: InputDecoration(labelText: '备份密码', errorText: _error),
          ),
          if (widget.creating)
            TextField(
              controller: _confirm,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: const InputDecoration(labelText: '再次输入密码'),
            ),
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed: () {
          if (widget.creating &&
              (_password.text.runes.length < 12 ||
                  _password.text != _confirm.text)) {
            setState(() => _error = '密码至少 12 个字符，且两次输入一致');
            return;
          }
          Navigator.pop(context, _password.text);
        },
        child: const Text('继续'),
      ),
    ],
  );
}
