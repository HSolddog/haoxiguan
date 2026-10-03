import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';
import '../services/backup_preview.dart';
import '../services/backup_manager.dart';
import '../services/backup_settings.dart';
import '../services/webdav_client.dart';
import '../state/habit_controller.dart';
import 'backup_restore_dialog.dart';
import 'unsaved_changes_guard.dart';

class WebDavScreen extends StatefulWidget {
  const WebDavScreen({super.key, required this.controller, this.settingsStore});
  final HabitController controller;
  final BackupSettingsStore? settingsStore;
  @override
  State<WebDavScreen> createState() => _WebDavScreenState();
}

class _WebDavScreenState extends State<WebDavScreen> {
  late final BackupSettingsStore _store =
      widget.settingsStore ?? BackupSettingsStore(DeviceSecretStore());
  final _endpoint = TextEditingController(),
      _user = TextEditingController(),
      _appPassword = TextEditingController(),
      _backupPassword = TextEditingController(),
      _confirm = TextEditingController();
  BackupSettings? _settings;
  bool _busy = false, _automatic = true, _wifi = true;
  String? _message;
  Map<String, dynamic> _status = {};
  List<RemoteBackup> _remote = [];
  bool get _dirty =>
      _endpoint.text != (_settings?.endpoint ?? '') ||
      _user.text != (_settings?.username ?? '') ||
      _appPassword.text != (_settings?.appPassword ?? '') ||
      _backupPassword.text != (_settings?.backupPassword ?? '') ||
      _confirm.text != (_settings?.backupPassword ?? '') ||
      _automatic != (_settings?.automatic ?? true) ||
      _wifi != (_settings?.wifiOnly ?? true);
  @override
  void initState() {
    super.initState();
    for (final c in [
      _endpoint,
      _user,
      _appPassword,
      _backupPassword,
      _confirm,
    ]) {
      c.addListener(_draftChanged);
    }
    _run(_load);
  }

  void _draftChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    for (final c in [
      _endpoint,
      _user,
      _appPassword,
      _backupPassword,
      _confirm,
    ]) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _load() async {
    _settings = await _store.load();
    final s = _settings;
    if (s == null) return;
    _endpoint.text = s.endpoint;
    _user.text = s.username;
    _appPassword.text = s.appPassword;
    _backupPassword.text = s.backupPassword;
    _confirm.text = s.backupPassword;
    _automatic = s.automatic;
    _wifi = s.wifiOnly;
    _status = await _store.status(s.id);
  }

  Future<void> _run(Future<void> Function() operation) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await operation();
    } on DavFailure catch (e) {
      _message = e.message;
    } on FormatException catch (e) {
      _message = e.message;
    } on Object {
      _message = '操作未完成，请检查连接、权限或系统安全存储。本机记录仍保留。';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final endpoint = WebDavClient.validateEndpoint(_endpoint.text).toString();
    if (_backupPassword.text.runes.length < 12 ||
        _backupPassword.text != _confirm.text) {
      throw const FormatException('备份密码至少 12 个字符，且两次输入一致');
    }
    final raw = widget.controller.exportJson();
    final vault = (jsonDecode(raw) as Map)['vaultId'] as String;
    final s = BackupSettings(
      id: const Uuid().v4(),
      endpoint: endpoint,
      username: _user.text.trim(),
      appPassword: _appPassword.text,
      backupPassword: _backupPassword.text,
      vault: vault,
      device: await _store.deviceId(),
      automatic: _automatic,
      wifiOnly: _wifi,
    );
    final client = WebDavClient(s.endpoint, s.username, s.appPassword);
    try {
      // Complete one real encrypted upload and restore before enabling automation.
      final item = await client.upload(
        raw,
        s.backupPassword,
        s.vault,
        s.device,
      );
      await client.restore(item, s.backupPassword);
      await _store.save(s);
      await _store.writeStatus(s.id, {
        'lastSuccess': item.created.toIso8601String(),
        'sourceDigest': sha256.convert(utf8.encode(raw)).toString(),
        'owned': [item.toJson()],
      });
      _settings = s;
      _status = await _store.status(s.id);
      _message = '配置已保存，第一份加密备份已上传并验证可恢复。请另行妥善保管备份密码。';
    } finally {
      client.close();
    }
  }

  Future<void> _backup() async {
    await BackupManager(_store).run(widget.controller.exportJson());
    _status = await _store.status(_settings!.id);
    _message = '备份已上传并通过读回校验。';
  }

  Future<void> _list() async {
    final s = _settings!;
    final client = WebDavClient(s.endpoint, s.username, s.appPassword);
    try {
      final items = <RemoteBackup>[];
      for (final vault in await client.children('haoxiguan/')) {
        try {
          requireUuid(vault);
        } on FormatException {
          continue;
        }
        items.addAll(await client.list(vault));
      }
      items.sort((a, b) => b.created.compareTo(a.created));
      _remote = items;
      _message = items.isEmpty ? '暂未找到具有完成标记的备份。' : '选择备份后会解密、预览，再确认恢复。';
    } finally {
      client.close();
    }
  }

  Future<void> _restore(RemoteBackup item) async {
    final s = _settings!;
    final client = WebDavClient(s.endpoint, s.username, s.appPassword);
    try {
      // Use the currently entered backup password so old-password snapshots remain recoverable.
      final raw = await client.restore(item, _backupPassword.text);
      final preview = BackupPreview.fromSnapshot(
        raw,
        createdAtUtc: item.created.toUtc(),
      );
      if (!mounted) return;
      final restored = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (context) => BackupRestoreDialog(
          controller: widget.controller,
          raw: raw,
          preview: preview,
        ),
      );
      if (restored == true) {
        _message = '恢复完成。原 WebDAV 配置不再自动备份这个新空间；远端副本保留。';
      }
    } finally {
      client.close();
    }
  }

  @override
  Widget build(BuildContext context) => UnsavedChangesGuard(
    dirty: _dirty,
    isDirty: () => _dirty,
    saving: _busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('自己的 WebDAV 备份')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('远端只接收加密文件。WebDAV 是历史备份，不会自动合并多台设备的记录。'),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(_message!),
            ),
          if (_settings != null)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('最近验证成功：${_status['lastSuccess'] ?? '暂无'}'),
                    if (_status['warning'] != null)
                      Text(_status['warning'] as String),
                    const Text('系统可能推迟后台任务，打开应用会补做。设备强制停止后需重新打开。'),
                    Wrap(
                      spacing: 8,
                      children: [
                        FilledButton(
                          onPressed: _busy ? null : () => _run(_backup),
                          child: const Text('立即备份'),
                        ),
                        OutlinedButton(
                          onPressed: _busy ? null : () => _run(_list),
                          child: const Text('查看远端备份'),
                        ),
                        TextButton(
                          onPressed: _busy
                              ? null
                              : () => _run(() async {
                                  await _store.disconnect();
                                  _settings = null;
                                  _remote = [];
                                  _status = {};
                                  _appPassword.clear();
                                  _backupPassword.clear();
                                  _confirm.clear();
                                  _message = '已断开，远端文件和本机记录保留。已发出的请求可能仍会完成。';
                                }),
                          child: const Text('断开'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          const SizedBox(height: 16),
          TextField(
            controller: _endpoint,
            enabled: !_busy,
            keyboardType: TextInputType.url,
            decoration: const InputDecoration(
              labelText: 'HTTPS WebDAV 目录',
              hintText: 'https://example.org/remote.php/dav/files/user/',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _user,
            enabled: !_busy,
            decoration: const InputDecoration(labelText: '用户名'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _appPassword,
            enabled: !_busy,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: 'WebDAV 应用密码'),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _backupPassword,
            enabled: !_busy,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(
              labelText: '独立备份密码',
              helperText: '恢复旧文件时，可在此输入当时使用的备份密码',
            ),
          ),
          const SizedBox(height: 12),
          TextField(
            controller: _confirm,
            enabled: !_busy,
            obscureText: true,
            enableSuggestions: false,
            autocorrect: false,
            decoration: const InputDecoration(labelText: '再次输入备份密码（保存配置时）'),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('有变化时每天自动尝试备份'),
            value: _automatic,
            onChanged: _busy ? null : (v) => setState(() => _automatic = v),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('自动备份仅使用 Wi-Fi'),
            value: _wifi,
            onChanged: _busy ? null : (v) => setState(() => _wifi = v),
          ),
          const Text(
            '默认保留最近 7 个每日、4 个每周、6 个每月副本；不支持安全条件删除的服务器会保留更多。账号密码不能代替备份密码解密。',
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: _busy ? null : () => _run(_save),
            child: const Text('验证并保存配置'),
          ),
          for (final item in _remote)
            ListTile(
              title: Text(item.created.toLocal().toString()),
              subtitle: Text(
                '${item.size} 字节 · 设备 ${item.device.substring(0, 8)} · 空间 ${item.vault.substring(0, 8)}',
              ),
              trailing: const Icon(Icons.restore),
              onTap: _busy ? null : () => _run(() => _restore(item)),
            ),
          const SizedBox(height: 32),
        ],
      ),
    ),
  );
}
