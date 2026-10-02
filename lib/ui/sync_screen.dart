import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:uuid/uuid.dart';

import '../data/sqlite_habit_repository.dart';
import '../services/backup_files.dart';
import '../services/backup_settings.dart';
import '../services/device_task_lock.dart';
import '../services/sync_client.dart';
import '../services/sync_crypto.dart';
import '../services/sync_engine.dart';
import '../services/sync_entities.dart';
import '../services/sync_recovery.dart';
import '../state/habit_controller.dart';

class SyncScreen extends StatefulWidget {
  const SyncScreen({super.key, required this.controller});
  final HabitController controller;
  @override
  State<SyncScreen> createState() => _SyncScreenState();
}

class _SyncScreenState extends State<SyncScreen> {
  final _store = SyncSettingsStore(DeviceSecretStore());
  final _files = PlatformBackupFiles();
  final _endpoint = TextEditingController();
  final _invite = TextEditingController();
  final _name = TextEditingController(text: '我的安卓设备');
  final _recoveryPassword = TextEditingController();
  SyncSettings? _settings;
  bool _busy = false, _join = false;
  String? _message, _lastSuccess;
  int _conflicts = 0, _pending = 0;
  @override
  void initState() {
    super.initState();
    _run(() async {
      _settings = await _store.load();
      await _readStatus();
    });
  }

  @override
  void dispose() {
    _endpoint.dispose();
    _invite.dispose();
    _name.dispose();
    _recoveryPassword.dispose();
    _settings?.keys.dispose();
    super.dispose();
  }

  Future<void> _run(Future<void> Function() action) async {
    setState(() {
      _busy = true;
      _message = null;
    });
    try {
      await action();
    } on FormatException catch (e) {
      _message = e.message;
    } on SyncApiException catch (e) {
      _message = e.toString();
    } on Object {
      _message = '操作未完成，本地记录仍保留。请检查网络、授权或设备存储后重试。';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<T> _withEngine<T>(Future<T> Function(SyncEngine engine) action) =>
      widget.controller.runExternalUpdate(
        () => DeviceTaskLock.run('sync', () async {
          final settings = _settings;
          if (settings == null) throw const FormatException('尚未连接同步服务');
          final repository = await SqliteHabitRepository.open();
          final transport = HttpSyncTransport(settings.endpoint);
          try {
            await repository.load();
            return await action(
              SyncEngine(repository, SyncSession(settings, _store, transport)),
            );
          } finally {
            transport.close();
            await repository.close();
          }
        }),
      );

  Future<void> _readStatus() async {
    if (_settings == null) {
      _lastSuccess = null;
      _conflicts = 0;
      _pending = 0;
      return;
    }
    final repository = await SqliteHabitRepository.open();
    try {
      await repository.load();
      final state = (await repository.readSyncFrame()).state;
      if (state?['binding'] == _settings!.id) {
        _lastSuccess = state?['lastSuccess'] as String?;
        _conflicts = (state?['conflicts'] as List?)?.length ?? 0;
        _pending = (state?['pending'] as List?)?.length ?? 0;
      }
    } finally {
      await repository.close();
    }
  }

  Future<bool> _confirm(String title, String message, String action) async =>
      await showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text(title),
          content: SingleChildScrollView(child: Text(message)),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: Text(action),
            ),
          ],
        ),
      ) ??
      false;

  Future<void> _connect() => _run(() async {
    final endpoint = HttpSyncTransport.validateEndpoint(
      _endpoint.text,
    ).toString();
    if (_invite.text.trim().isEmpty || _name.text.trim().isEmpty) {
      throw const FormatException('请填写邀请码和设备名称');
    }
    SyncKeyring? keys;
    var adopted = false;
    final transport = HttpSyncTransport(endpoint);
    try {
      if (_join) {
        final bytes = await _files.open();
        if (bytes == null) return;
        keys = await SyncRecoveryCodec.decrypt(bytes, _recoveryPassword.text);
      }
      final tokens = await transport.request(
        'POST',
        '/v1/auth/enroll',
        body: {'invite': _invite.text.trim(), 'deviceName': _name.text.trim()},
      );
      SyncSettings.validateTokens(tokens);
      keys ??= await SyncKeyring.create(tokens['vaultId'] as String);
      if (keys.vault != tokens['vaultId']) {
        throw const FormatException('恢复文件与邀请码所属空间不同，请使用匹配的授权');
      }
      final settings = SyncSettings(
        id: const Uuid().v4(),
        endpoint: endpoint,
        localVault:
            jsonDecode(widget.controller.exportJson())['vaultId'] as String,
        keys: keys,
        tokens: tokens,
        recoveryExported: _join,
        initialReview: _join,
      );
      await _store.save(settings);
      _settings = settings;
      adopted = true;
      _invite.clear();
      _recoveryPassword.clear();
      _message = _join ? '已授权。点击“立即同步”核对并合并数据。' : '已建立设备授权。请先导出加密恢复文件，再开始同步。';
      await _readStatus();
    } finally {
      transport.close();
      if (!adopted) keys?.dispose();
    }
  });

  Future<void> _exportRecovery() => _run(() async {
    final password = await showDialog<String>(
      context: context,
      builder: (_) => const _RecoveryPasswordDialog(),
    );
    if (password == null) return;
    final bytes = await SyncRecoveryCodec.encrypt(_settings!.keys, password);
    final verified = await SyncRecoveryCodec.decrypt(bytes, password);
    verified.dispose();
    if (!await _files.save(
      bytes,
      'haoxiguan-sync-recovery-${DateTime.now().millisecondsSinceEpoch}.hgr',
    )) {
      return;
    }
    _settings!.recoveryExported = true;
    await _store.save(_settings!);
    _message = '恢复文件已保存并读回校验。请将文件和密码分别保管；其中不含登录令牌，也不包含习惯数据。';
  });

  Future<void> _sync() => _run(() async {
    if (!_settings!.recoveryExported) {
      throw const FormatException('请先保存加密恢复文件，避免换机后无法解密');
    }
    try {
      final result = await _withEngine(
        (engine) => engine.run(
          onProgress: (count) {
            if (mounted) setState(() => _message = '已确认上传 $count 个变更，正在继续核对…');
          },
        ),
      );
      _message = result.conflicts.isNotEmpty
          ? '${result.conflicts.length} 个习惯需要处理冲突，本机内容尚未被替换。'
          : result.complete
          ? '同步完成。断开网络后仍可继续记录。'
          : '本轮进度已保存，仍有变更待同步，请再次运行。';
    } finally {
      await _readStatus();
    }
  });

  Future<void> _resolve() => _run(() async {
    final decision = await _withEngine((engine) => engine.conflicts());
    if (!mounted) return;
    if (decision.conflicts.isEmpty) {
      _message = '当前没有需要处理的冲突。';
      return;
    }
    final choices = <String, bool>{};
    final allowed = <String, bool>{};
    for (final id in decision.conflicts) {
      final candidate = Map<String, dynamic>.from(decision.local);
      SyncEntities.chooseHabit(candidate, decision.remote, id, [
        decision.local,
        decision.remote,
      ]);
      try {
        SyncEntities.assemble(widget.controller.exportJson(), candidate);
        allowed[id] = true;
      } on Object {
        allowed[id] = false;
      }
    }
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('选择每个习惯保留的版本'),
          content: SizedBox(
            width: 500,
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    '独立新增记录已自动合并；这里包含相互冲突的修改。选择以整个习惯为单位，本机原数据和远端候选都会先保留副本。',
                  ),
                  for (final id in decision.conflicts)
                    Padding(
                      padding: const EdgeInsets.only(top: 20),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            _title(id, decision.local, decision.remote),
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          Text('本机：${_summary(id, decision.local)}'),
                          Text('远端：${_summary(id, decision.remote)}'),
                          if (allowed[id] == false)
                            const Text('远端结构尚不完整，可保留本机版本，或取消并等待其他设备完成同步。'),
                          DropdownButtonFormField<bool>(
                            initialValue: choices[id],
                            isExpanded: true,
                            decoration: const InputDecoration(
                              labelText: '请选择保留的版本',
                            ),
                            items: [
                              const DropdownMenuItem(
                                value: false,
                                child: Text('保留本机整个习惯'),
                              ),
                              DropdownMenuItem(
                                value: true,
                                enabled: allowed[id]!,
                                child: const Text('采用远端整个习惯'),
                              ),
                            ],
                            onChanged: (v) =>
                                setDialogState(() => choices[id] = v!),
                          ),
                          TextButton(
                            onPressed: () => showDialog<void>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: const Text('冲突内容详情'),
                                content: SingleChildScrollView(
                                  child: SelectableText(
                                    const JsonEncoder.withIndent('  ').convert({
                                      '本机': _subset(id, decision.local),
                                      '远端': _subset(id, decision.remote),
                                    }),
                                  ),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () => Navigator.pop(context),
                                    child: const Text('关闭'),
                                  ),
                                ],
                              ),
                            ),
                            child: const Text('查看完整候选内容'),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('稍后处理'),
            ),
            FilledButton(
              onPressed: choices.length == decision.conflicts.length
                  ? () => Navigator.pop(context, true)
                  : null,
              child: const Text('保护副本并应用选择'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true) return;
    await _withEngine((engine) => engine.resolve(choices));
    await _readStatus();
    _message = '选择已保存，原内容已保护。请再次同步以提交选择并检查其他设备的新变更。';
  });

  Future<void> _reauthorize() => _run(() async {
    if (_invite.text.trim().isEmpty) {
      throw const FormatException('请先填写管理员新发出的一次性邀请码');
    }
    final transport = HttpSyncTransport(_settings!.endpoint);
    try {
      final tokens = await transport.request(
        'POST',
        '/v1/auth/enroll',
        body: {'invite': _invite.text.trim(), 'deviceName': _name.text.trim()},
      );
      SyncSettings.validateTokens(tokens);
      if (tokens['vaultId'] != _settings!.keys.vault) {
        throw const FormatException('新邀请属于另一个空间，未替换现有授权');
      }
      final oldEpoch = _settings!.tokens['epoch'];
      _settings!.tokens = tokens;
      await _store.save(_settings!);
      _invite.clear();
      if (tokens['epoch'] != oldEpoch) {
        if (!mounted) return;
        final confirmed = await _confirm(
          '服务器数据已恢复',
          '服务器基线已经改变。将保护本地数据，并重新下载核对；所有不同的习惯都需要你选择版本，不把旧服务器缺少的记录当作删除。',
          '保护并重新核对',
        );
        if (!confirmed) {
          _message = '新授权已保存，尚未重新核对基线。可通过下方“重新核对基线”继续。';
          return;
        }
        await _withEngine((engine) => engine.resetBaselineForReview());
      }
      _message = '设备已重新授权，请再次同步。';
    } finally {
      transport.close();
    }
  });

  Future<void> _resetBaseline() => _run(() async {
    if (!await _confirm(
      '重新核对远端基线？',
      '本地内容会先保留副本，重新下载后，每个不同的习惯都需要明确选择版本。请先获得当前服务器的有效授权。',
      '保护并核对',
    )) {
      return;
    }
    await _withEngine((engine) => engine.resetBaselineForReview());
    _message = '基线已准备，请点击立即同步。';
  });

  Future<void> _prepareRotation() => _run(() async {
    final result = await _withEngine((engine) => engine.prepareRotation());
    await _readStatus();
    _message = result.complete
        ? '轮换前核对完成，本机包含完整远端内容和本机未发送记录。请返回数据页导出并验证完整加密备份，再让管理员轮换空间。'
        : '轮换前发现冲突，请先处理冲突，再次执行只读核对。';
  });

  Future<void> _devices() => _run(() async {
    final response = await _withEngine(
      (engine) => engine.session.request('GET', '/v1/devices'),
    );
    if (!mounted) return;
    final devices = response['devices'] as List;
    final target = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('已授权设备'),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  '撤销会阻止未来的服务器访问，无法擦除设备已经下载的数据。需要更新未来内容的密钥时，请由管理员执行维护式空间轮换。当前同步仍属实验验收版本。',
                ),
                for (final device in devices)
                  ListTile(
                    title: Text(device['name'] as String),
                    subtitle: Text(
                      device['revoked'] == true
                          ? '已撤销'
                          : device['id'] == _settings!.tokens['deviceId']
                          ? '当前设备'
                          : '已授权',
                    ),
                    trailing: device['revoked'] == true
                        ? null
                        : TextButton(
                            onPressed: () =>
                                Navigator.pop(context, device['id'] as String),
                            child: const Text('撤销'),
                          ),
                  ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
    if (target == null ||
        !mounted ||
        !await _confirm(
          '撤销设备授权？',
          '该设备之后不能读写服务器；其本地习惯仍保留。重新连接需要新的邀请。',
          '撤销授权',
        )) {
      return;
    }
    if (!RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(target)) {
      throw const FormatException('设备身份无效');
    }
    await _withEngine(
      (engine) => engine.session.request('POST', '/v1/devices/$target/revoke'),
    );
    _message = '设备服务器访问权限已撤销。';
  });

  Future<void> _archives() => _run(() async {
    final rows = await _withEngine(
      (engine) => engine.repository.database
          .customSelect(
            'SELECT sequence,payload,created_at FROM sync_protections ORDER BY sequence DESC LIMIT 20',
          )
          .get(),
    );
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('最近保留的同步冲突副本'),
        content: SizedBox(
          width: 600,
          child: SingleChildScrollView(
            child: SelectableText(
              rows.isEmpty
                  ? '尚无冲突副本。'
                  : const JsonEncoder.withIndent('  ').convert([
                      for (final row in rows)
                        {
                          '时间': row.read<String>('created_at'),
                          '内容': jsonDecode(row.read<String>('payload')),
                        },
                    ]),
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  });

  Future<void> _deleteRemoteAccount() => _run(() async {
    if (!await _confirm(
      '永久删除远端账户？',
      '将删除该服务器上此账户的全部密文、同步历史和轮换归档，并撤销所有设备。不会删除本机习惯。管理员离线备份仍按其保存政策处理。此操作不能撤销。',
      '永久删除远端账户',
    )) {
      return;
    }
    await _withEngine(
      (engine) => engine.session.request(
        'DELETE',
        '/v1/account',
        headers: {'X-Confirm-Delete': 'delete-remote-account'},
      ),
    );
    await _store.disconnect();
    _settings?.keys.dispose();
    _settings = null;
    await _readStatus();
    _message = '远端账户及在线密文已删除，本机记录仍完整保留。';
  });

  Future<void> _disconnect() => _run(() async {
    if (!await _confirm(
      '断开本机同步？',
      '保留本机所有习惯、远端数据和已保存的恢复材料。服务器上的设备授权可在“已授权设备”中另外撤销。',
      '断开本机',
    )) {
      return;
    }
    await _store.disconnect();
    _settings?.keys.dispose();
    _settings = null;
    await _readStatus();
    _message = '已断开。本机继续独立保存记录。';
  });

  static String _title(String id, EntityMap local, EntityMap remote) =>
      (local['h/$id'] as Map?)?['title'] as String? ??
      (remote['h/$id'] as Map?)?['title'] as String? ??
      '已删除的习惯';
  static EntityMap _subset(String id, EntityMap map) => {
    for (final e in map.entries)
      if (SyncEntities.habitId(e.key, e.value) == id) e.key: e.value,
  };
  static String _summary(String id, EntityMap map) {
    final h = map['h/$id'];
    final records = _subset(
      id,
      map,
    ).entries.where((e) => e.key.startsWith('r/') && e.value != null).length;
    final notes = _subset(id, map).entries
        .where((e) => e.key.startsWith('n/') && e.value != null)
        .map((e) => (e.value as Map)['text'])
        .join('；');
    return '${h == null ? '习惯已删除' : h['title']}，$records 条事实${notes.isEmpty ? '' : '；备注：$notes'}';
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(title: const Text('自有同步服务')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text('实验性同步', style: TextStyle(fontWeight: FontWeight.bold)),
          const Text(
            '所有习惯先保存在本机，手动同步到你指定的服务器。支持维护式密钥轮换，仍在进行规模和系统验收；请同时保留独立加密备份。',
          ),
          const SizedBox(height: 16),
          if (_busy) const LinearProgressIndicator(),
          if (_message != null)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: SelectableText(_message!),
            ),
          if (_settings == null) ...[
            TextField(
              controller: _endpoint,
              enabled: !_busy,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'HTTPS 服务地址',
                hintText: 'https://sync.example.com',
              ),
            ),
            TextField(
              controller: _name,
              enabled: !_busy,
              maxLength: 40,
              decoration: const InputDecoration(labelText: '设备名称'),
            ),
            TextField(
              controller: _invite,
              enabled: !_busy,
              obscureText: true,
              autocorrect: false,
              enableSuggestions: false,
              decoration: const InputDecoration(labelText: '管理员提供的一次性邀请码'),
            ),
            SwitchListTile(
              title: const Text('加入已有数据空间'),
              subtitle: Text(_join ? '需要已有设备导出的 .hgr 恢复文件' : '首台设备将创建新的内容密钥'),
              value: _join,
              onChanged: _busy ? null : (v) => setState(() => _join = v),
            ),
            if (_join)
              TextField(
                controller: _recoveryPassword,
                enabled: !_busy,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: '恢复文件密码'),
              ),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy ? null : _connect,
              child: Text(_join ? '选择恢复文件并授权' : '授权此设备'),
            ),
          ] else ...[
            SelectableText(_settings!.endpoint),
            Text('最近完整同步：${_lastSuccess ?? '尚未完成'}'),
            Text('待发送：$_pending 个操作；待处理：$_conflicts 个习惯'),
            const SizedBox(height: 16),
            FilledButton(
              onPressed: _busy || !_settings!.recoveryExported ? null : _sync,
              child: const Text('立即同步'),
            ),
            if (!_settings!.recoveryExported) const Text('首次同步前，请先保存下方恢复文件。'),
            OutlinedButton(
              onPressed: _busy ? null : _exportRecovery,
              child: const Text('导出加密恢复文件'),
            ),
            OutlinedButton(
              onPressed: _busy ? null : _resolve,
              child: const Text('检查与处理冲突'),
            ),
            TextButton(
              onPressed: _busy ? null : _devices,
              child: const Text('已授权设备'),
            ),
            ExpansionTile(
              title: const Text('重新授权与基线恢复'),
              children: [
                const Text('邀请码只控制服务器访问，无法替代恢复密钥。授权过期或服务器从旧备份恢复后，请向管理员申请新邀请。'),
                TextField(
                  controller: _invite,
                  enabled: !_busy,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  decoration: const InputDecoration(labelText: '新的邀请码'),
                ),
                TextButton(
                  onPressed: _busy ? null : _reauthorize,
                  child: const Text('重新授权'),
                ),
                TextButton(
                  onPressed: _busy ? null : _resetBaseline,
                  child: const Text('重新核对基线'),
                ),
                TextButton(
                  onPressed: _busy ? null : _prepareRotation,
                  child: const Text('轮换前只读核对'),
                ),
              ],
            ),
            TextButton(
              onPressed: _busy ? null : _archives,
              child: const Text('查看已保留的冲突副本'),
            ),
            TextButton(
              onPressed: _busy ? null : _disconnect,
              child: const Text('断开本机同步'),
            ),
            TextButton(
              onPressed: _busy ? null : _deleteRemoteAccount,
              child: const Text('删除远端账户'),
            ),
          ],
        ],
      ),
    ),
  );
}

class _RecoveryPasswordDialog extends StatefulWidget {
  const _RecoveryPasswordDialog();
  @override
  State<_RecoveryPasswordDialog> createState() =>
      _RecoveryPasswordDialogState();
}

class _RecoveryPasswordDialogState extends State<_RecoveryPasswordDialog> {
  final first = TextEditingController(), second = TextEditingController();
  String? error;
  @override
  void dispose() {
    first.dispose();
    second.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('保护同步恢复文件'),
    content: SingleChildScrollView(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Text('至少 12 个字符。遗失密码和所有已授权设备后，服务器无法帮你解密记录。'),
          TextField(
            controller: first,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '恢复密码'),
          ),
          TextField(
            controller: second,
            obscureText: true,
            autocorrect: false,
            enableSuggestions: false,
            decoration: const InputDecoration(labelText: '再次输入'),
          ),
          if (error != null) Text(error!),
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
          if (first.text.runes.length < 12 || first.text != second.text) {
            setState(() => error = '密码至少 12 个字符，两次输入需一致');
            return;
          }
          Navigator.pop(context, first.text);
        },
        child: const Text('加密并保存'),
      ),
    ],
  );
}
