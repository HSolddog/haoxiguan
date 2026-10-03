import 'dart:convert';
import 'dart:async';
import 'webdav_screen.dart';
import 'sync_screen.dart';
import 'backup_restore_dialog.dart';
import 'reminder_settings_card.dart';
import 'unsaved_changes_guard.dart';

import 'package:flutter/material.dart';

import '../services/backup_codec.dart';
import '../services/backup_preview.dart';
import '../services/data_status.dart';
import '../services/csv_export.dart';
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
    this.statusReader,
  });
  final HabitController controller;
  final VoidCallback onTheme;
  final VoidCallback onReview;
  final VoidCallback onLegacyRestore;
  final BackupFiles? files;
  final DataStatusReader? statusReader;
  @override
  State<DataScreen> createState() => _DataScreenState();
}

class _DataScreenState extends State<DataScreen> with WidgetsBindingObserver {
  bool _busy = false;
  String? _result;
  DataServiceStatus? _status;
  int _statusGeneration = 0;
  late final _statusReader = widget.statusReader ?? DataStatusReader();
  BackupFiles get _files => widget.files ?? PlatformBackupFiles();
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    widget.controller.addListener(_controllerChanged);
    unawaited(_refreshStatus());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    widget.controller.removeListener(_controllerChanged);
    super.dispose();
  }

  void _controllerChanged() {
    if (mounted) setState(() {});
    unawaited(_refreshStatus());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_refreshStatus());
  }

  Future<void> _refreshStatus() async {
    final generation = ++_statusGeneration;
    final status = await _statusReader.read(widget.controller.exportJson());
    if (mounted && generation == _statusGeneration) {
      setState(() => _status = status);
    }
  }

  Future<void> _openService(Widget screen) async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return;
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => screen));
    if (mounted) await _refreshStatus();
  }

  Future<String> _recordBackup(String raw, String name, String result) async {
    try {
      await _statusReader.recordFileBackup(raw, name);
      return result;
    } on Object {
      return '$result 最近成功状态未能写入设备安全存储，请记住文件位置。';
    }
  }

  Future<void> _run(Future<String?> Function() action) async {
    if (!mounted || _busy || ModalRoute.of(context)?.isCurrent != true) return;
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
      if (mounted) await _refreshStatus();
    }
  }

  Future<void> _exportEncrypted() => _run(() async {
    String? result;
    await showDialog<String>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _PasswordDialog(
        creating: true,
        onContinue: (password) async {
          final snapshot = widget.controller.exportJson();
          final bytes = await BackupCodec.encrypt(snapshot, password);
          await BackupCodec.decrypt(bytes, password);
          final name =
              'haoxiguan-${DateTime.now().toUtc().millisecondsSinceEpoch}.hgb';
          if (!await _files.save(bytes, name)) return false;
          result = await _recordBackup(
            snapshot,
            name,
            '加密备份已保存，并已读回校验。请妥善保存密码。',
          );
          return true;
        },
      ),
    );
    return result;
  });

  Future<void> _exportPlain() => _run(() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return null;
    final origin = ModalRoute.of(context);
    var answered = false;
    void answer(BuildContext dialogContext, bool confirmed) {
      if (answered ||
          !dialogContext.mounted ||
          ModalRoute.of(dialogContext)?.isCurrent != true) {
        return;
      }
      answered = true;
      Navigator.pop(dialogContext, confirmed);
    }

    final confirm = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出可读 JSON？'),
        content: const SingleChildScrollView(
          child: Text('这个文件没有密码，拿到文件的人可以读取记录。请选择你信任的位置。'),
        ),
        actions: [
          TextButton(
            onPressed: () => answer(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => answer(context, true),
            child: const Text('导出明文'),
          ),
        ],
      ),
    );
    if (confirm != true || !mounted || origin?.isCurrent != true) return null;
    final snapshot = widget.controller.exportJson();
    final createdAt = DateTime.now().toUtc();
    final bytes = utf8.encode(
      jsonEncode({
        'format': BackupCodec.format,
        'formatVersion': 1,
        'encrypted': false,
        'createdAtUtc': createdAt.toIso8601String(),
        'data': jsonDecode(snapshot),
      }),
    );
    final name = 'haoxiguan-${createdAt.millisecondsSinceEpoch}.json';
    final saved = await _files.save(bytes, name);
    return saved ? _recordBackup(snapshot, name, 'JSON 已保存，并已读回校验。') : null;
  });

  Future<void> _exportCsv() => _run(() async {
    if (!mounted || ModalRoute.of(context)?.isCurrent != true) return null;
    final origin = ModalRoute.of(context);
    var answered = false;
    void answer(BuildContext dialogContext, bool confirmed) {
      if (answered ||
          !dialogContext.mounted ||
          ModalRoute.of(dialogContext)?.isCurrent != true) {
        return;
      }
      answered = true;
      Navigator.pop(dialogContext, confirmed);
    }

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('导出可读 CSV？'),
        content: const SingleChildScrollView(
          child: Text(
            'ZIP 内含习惯、计划版本、记录、备注、分类五份 CSV 和字段说明，均为明文，适合关联复核与表格分析。CSV 不能代替完整恢复备份。以公式符号开头的文字会加单引号。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => answer(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => answer(context, true),
            child: const Text('导出明文 CSV'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted || origin?.isCurrent != true) return null;
    final saved = await _files.save(
      CsvExport.encodeArchive(widget.controller.exportJson()),
      'haoxiguan-csv-${DateTime.now().toUtc().millisecondsSinceEpoch}.zip',
    );
    return saved ? 'CSV 分表 ZIP 已保存并读回校验。' : null;
  });

  Future<void> _restore() => _run(() async {
    final origin = ModalRoute.of(context);
    final bytes = await _files.open();
    if (!mounted || origin?.isCurrent != true || bytes == null) return null;
    final envelope = jsonDecode(utf8.decode(bytes));
    String? raw;
    DateTime? createdAt;
    if (envelope is Map && envelope['format'] == BackupCodec.format) {
      if (envelope['formatVersion'] != 1) {
        throw const FormatException('不支持的备份版本');
      }
      if (envelope['encrypted'] == true) {
        if (!mounted || origin?.isCurrent != true) return null;
        await showDialog<String>(
          context: context,
          barrierDismissible: false,
          builder: (_) => _PasswordDialog(
            creating: false,
            onContinue: (password) async {
              final contents = await BackupCodec.decryptWithMetadata(
                bytes,
                password,
              );
              raw = contents.snapshot;
              createdAt = contents.createdAtUtc;
              return true;
            },
          ),
        );
        if (!mounted || origin?.isCurrent != true || raw == null) return null;
      } else if (envelope['encrypted'] == false) {
        raw = jsonEncode(envelope['data']);
        if (envelope['createdAtUtc'] case final String value) {
          createdAt = DateTime.tryParse(value);
          if (createdAt?.isUtc != true) throw const FormatException('备份创建时间无效');
        }
      } else {
        throw const FormatException('备份格式无效');
      }
    } else {
      raw = utf8.decode(bytes);
    }
    final restored = raw!;
    final preview = BackupPreview.forRestore(restored, createdAtUtc: createdAt);
    if (!mounted || origin?.isCurrent != true) return null;
    final completed = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (context) => BackupRestoreDialog(
        controller: widget.controller,
        raw: restored,
        preview: preview,
      ),
    );
    return completed == true ? '数据恢复成功。' : null;
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
          Card(
            child: Padding(
              padding: EdgeInsets.all(20),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Icon(Icons.storage_outlined, size: 32),
                  const SizedBox(height: 12),
                  const Text(
                    '保存在本机，离线也能使用',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 18),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    controller.loadError != null
                        ? '本机数据：无法安全打开，原数据已保留'
                        : controller.saveError != null
                        ? '本机数据：上次操作未保存，请重试'
                        : controller.loading
                        ? '本机数据：正在读取'
                        : '本机数据：已保存',
                    key: const Key('local-data-status'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '备份状态\n${_status?.backup ?? '正在读取实际备份状态…'}',
                    key: const Key('backup-data-status'),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '同步状态\n${_status?.sync ?? '正在读取实际同步状态…'}',
                    key: const Key('sync-data-status'),
                  ),
                  const SizedBox(height: 12),
                  const Text('日常保存和更新不需要账号或云备份。独立备份用于换机、设备丢失等情况。'),
                  TextButton(
                    onPressed: _busy ? null : _refreshStatus,
                    child: const Text('刷新状态'),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),
          if (_busy)
            TickerMode(
              enabled: ModalRoute.isCurrentOf(context) ?? true,
              child: const LinearProgressIndicator(),
            ),
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
                  leading: const Icon(Icons.table_chart_outlined),
                  title: const Text('导出可读 CSV'),
                  subtitle: const Text('ZIP 包含习惯、计划、记录、备注、分类五表；不能替代完整备份'),
                  onTap: _busy ? null : _exportCsv,
                ),
                ListTile(
                  leading: const Icon(Icons.cloud_outlined),
                  title: const Text('自己的 WebDAV 备份'),
                  subtitle: const Text('远端加密快照、自动尝试和换机恢复'),
                  onTap: _busy
                      ? null
                      : () =>
                            _openService(WebDavScreen(controller: controller)),
                ),
                ListTile(
                  leading: const Icon(Icons.sync),
                  title: const Text('自有同步服务'),
                  subtitle: const Text('实验性端到端加密同步、设备与冲突'),
                  onTap: _busy
                      ? null
                      : () => _openService(SyncScreen(controller: controller)),
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
                ListTile(
                  title: const Text('外观'),
                  leading: const Icon(Icons.contrast),
                  subtitle: Text(switch (controller.appearanceMode) {
                    'dark' => '深色',
                    'light' => '浅色',
                    _ => '跟随系统',
                  }),
                  trailing: PopupMenuButton<String>(
                    tooltip: '选择外观',
                    initialValue: controller.appearanceMode,
                    onSelected: controller.setAppearanceMode,
                    itemBuilder: (_) => const [
                      PopupMenuItem(value: 'system', child: Text('跟随系统')),
                      PopupMenuItem(value: 'light', child: Text('浅色')),
                      PopupMenuItem(value: 'dark', child: Text('深色')),
                    ],
                  ),
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
                ReminderSettingsCard(controller: controller),
                ListTile(
                  leading: const Icon(Icons.privacy_tip_outlined),
                  title: const Text('隐私与数据'),
                  onTap: () => showDialog<void>(
                    context: context,
                    builder: (context) => AlertDialog(
                      title: const Text('你的数据由你掌握'),
                      content: const SingleChildScrollView(
                        child: Text(
                          '默认不注册、不上传习惯，也没有广告或使用分析。数据保存在应用私有空间，依赖系统存储保护。\n\n'
                          '主动启用 WebDAV 或同步后，所选服务可见账户、设备、连接和密文大小等信息；习惯与备注的传输内容由客户端加密。\n\n'
                          'JSON 和 CSV 导出是明文。加密备份密码和同步恢复文件请自行保管，找回账户不能代替解密材料。\n\n'
                          '断开服务保留本机记录；回收站不会自动清理。普通覆盖更新保留数据，卸载或系统清除存储不属于普通更新。\n\n'
                          '提醒可能在锁屏显示名称，可在系统设置中隐藏敏感内容。',
                        ),
                      ),
                      actions: [
                        TextButton(
                          onPressed: () {
                            if (context.mounted &&
                                ModalRoute.of(context)?.isCurrent == true) {
                              Navigator.pop(context);
                            }
                          },
                          child: const Text('知道了'),
                        ),
                      ],
                    ),
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.code),
                  title: const Text('开源许可证'),
                  subtitle: const Text('好习惯采用 MIT；查看第三方许可'),
                  onTap: () => showLicensePage(
                    context: context,
                    applicationName: '好习惯',
                    applicationLegalese: 'Haoxiguan · MIT License',
                  ),
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
  const _PasswordDialog({required this.creating, this.onContinue});
  final bool creating;
  final Future<bool> Function(String password)? onContinue;
  @override
  State<_PasswordDialog> createState() => _PasswordDialogState();
}

class _PasswordDialogState extends State<_PasswordDialog> {
  final _password = TextEditingController();
  final _confirm = TextEditingController();
  final _guard = GlobalKey<UnsavedChangesGuardState>();
  bool _busy = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    _password.addListener(_changed);
    _confirm.addListener(_changed);
  }

  void _changed() => setState(() {});
  @override
  void dispose() {
    _password.dispose();
    _confirm.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UnsavedChangesGuard(
    key: _guard,
    dirty: _password.text.isNotEmpty || _confirm.text.isNotEmpty,
    isDirty: () => _password.text.isNotEmpty || _confirm.text.isNotEmpty,
    saving: _busy,
    isSaving: () => _busy,
    child: AlertDialog(
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
              enabled: !_busy,
              autofocus: true,
              obscureText: true,
              enableSuggestions: false,
              autocorrect: false,
              decoration: InputDecoration(labelText: '备份密码', errorText: _error),
            ),
            if (widget.creating)
              TextField(
                controller: _confirm,
                enabled: !_busy,
                obscureText: true,
                enableSuggestions: false,
                autocorrect: false,
                decoration: const InputDecoration(labelText: '再次输入密码'),
              ),
            if (_busy) const LinearProgressIndicator(),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _busy ? null : () => _guard.currentState?.leave(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _busy
              ? null
              : () async {
                  if (!context.mounted ||
                      _busy ||
                      ModalRoute.of(context)?.isCurrent != true) {
                    return;
                  }
                  final route = ModalRoute.of(context);
                  if (widget.creating &&
                      (_password.text.runes.length < 12 ||
                          _password.text != _confirm.text)) {
                    setState(() => _error = '密码至少 12 个字符，且两次输入一致');
                    return;
                  }
                  setState(() {
                    _busy = true;
                    _error = null;
                  });
                  try {
                    if (await widget.onContinue?.call(_password.text) ?? true) {
                      if (context.mounted && route?.isCurrent == true) {
                        Navigator.pop(context, _password.text);
                      }
                    }
                  } on FormatException catch (e) {
                    if (mounted) setState(() => _error = e.message);
                  } on Object {
                    if (mounted) {
                      setState(() => _error = '操作未完成，请检查文件权限或存储后重试；输入已保留');
                    }
                  } finally {
                    if (mounted) setState(() => _busy = false);
                  }
                },
          child: const Text('继续'),
        ),
      ],
    ),
  );
}
