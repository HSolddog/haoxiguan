import 'dart:convert';

import 'package:crypto/crypto.dart';

import '../data/sqlite_habit_repository.dart';
import 'backup_settings.dart';
import 'sync_client.dart';
import 'sync_entities.dart';

class DataServiceStatus {
  const DataServiceStatus({required this.backup, required this.sync});
  final String backup, sync;
}

/// Reads persisted evidence only. No network request or credential mutation is
/// required to open settings; a last success never promises current connectivity.
class DataStatusReader {
  DataStatusReader({SecretStore? secrets, this.readSyncFrame})
    : secrets = secrets ?? DeviceSecretStore();
  final SecretStore secrets;
  final Future<SyncFrame> Function()? readSyncFrame;
  static const _fileStatus = 'backup.file.last-verified.v1';

  Future<void> recordFileBackup(String snapshot, String name) => secrets.write(
    _fileStatus,
    jsonEncode({
      'name': name,
      'createdAt': DateTime.now().toUtc().toIso8601String(),
      'sourceDigest': sha256.convert(utf8.encode(snapshot)).toString(),
      'vault': (jsonDecode(snapshot) as Map)['vaultId'],
    }),
  );

  Future<DataServiceStatus> read(String snapshot) async => DataServiceStatus(
    backup: await _backup(snapshot),
    sync: await _sync(snapshot),
  );

  Future<String> _backup(String snapshot) async {
    final parts = <String>[];
    final vault = (jsonDecode(snapshot) as Map)['vaultId'];
    final digest = sha256.convert(utf8.encode(snapshot)).toString();
    try {
      final fileRaw = await secrets.read(_fileStatus);
      if (fileRaw == null) {
        parts.add('文件备份：尚无本机校验成功记录');
      } else {
        final file = jsonDecode(fileRaw) as Map;
        parts.add('文件备份：最近校验 ${file['createdAt']}\n${file['name']}');
        if (file['vault'] != vault) {
          parts.add('此文件属于恢复前空间；当前空间尚未记录文件备份');
        } else if (file['sourceDigest'] != digest) {
          parts.add('文件备份后本机已有更改');
        }
        parts.add('文件之后是否被移动或删除，需在保存位置核实');
      }
    } on Object {
      parts.add('文件备份状态读取失败，无法确认最近成功时间');
    }
    try {
      final store = BackupSettingsStore(secrets);
      final settings = await store.load();
      if (settings == null) {
        parts.add('WebDAV：未配置');
      } else {
        final status = await store.status(settings.id);
        parts.add('WebDAV：${settings.automatic ? '已启用自动尝试' : '自动尝试已关闭'}');
        parts.add('最近校验成功：${status['lastSuccess'] ?? '尚未完成'}');
        if (settings.vault != vault) {
          parts.add('本机空间已变化，自动备份已停止；请重新配置');
        } else if (status['sourceDigest'] == null) {
          parts.add('未记录内容摘要，当前数据是否已备份需重新核对');
        } else if (status['sourceDigest'] != digest) {
          parts.add('最近备份尚未包含当前本机更改');
        }
        if (status['warning'] case final String warning) parts.add(warning);
      }
    } on Object {
      parts.add('WebDAV 状态读取失败；请检查设备安全存储后重试');
    }
    return parts.join('\n');
  }

  Future<String> _sync(String snapshot) async {
    SyncSettings? settings;
    try {
      settings = await SyncSettingsStore(secrets).load();
      if (settings == null) return '未连接；本机仍可正常使用和升级';
      if ((jsonDecode(snapshot) as Map)['vaultId'] != settings.localVault) {
        return '已保留原服务配置；本机空间已变化，同步已停止，需重新连接';
      }
      final frame = readSyncFrame != null
          ? await readSyncFrame!()
          : await _deviceSyncFrame();
      return describeSync(
        snapshot,
        settings.id,
        frame.state,
        recoveryExported: settings.recoveryExported,
      );
    } on Object {
      return '状态读取失败，无法确认最近同步；请检查设备安全存储后重试';
    } finally {
      settings?.keys.dispose();
    }
  }

  static Future<SyncFrame> _deviceSyncFrame() async {
    final repository = await SqliteHabitRepository.open();
    try {
      await repository.load();
      return await repository.readSyncFrame();
    } finally {
      await repository.close();
    }
  }

  static String describeSync(
    String snapshot,
    String binding,
    Map<String, dynamic>? state, {
    required bool recoveryExported,
  }) {
    if (state == null || state['binding'] != binding) {
      return recoveryExported
          ? '已配置，尚未完成首次同步核对；远端状态尚未检查'
          : '已配置，须先保存恢复文件；尚未完成首次同步';
    }
    final base = (state['base'] as Map?) ?? const {};
    final current = SyncEntities.encode(snapshot);
    final changed = {...base.keys, ...current.keys}
        .where(
          (key) =>
              !SyncEntities.sameFacts(key as String, base[key], current[key]),
        )
        .length;
    final pending = (state['pending'] as List?)?.length ?? 0;
    final conflicts = (state['conflicts'] as List?)?.length ?? 0;
    final failure = switch (state['lastFailureCode']) {
      'unauthorized' => '设备授权失效，请重新授权',
      'epoch_changed' || 'device_stale' => '服务器基线已变化，请核对后恢复同步',
      'maintenance_read_only' => '服务正在维护，暂不能写入',
      'quota_exceeded' => '服务存储配额不足',
      'rate_limited' => '服务请求受限，请稍后重试',
      'invalid_data' => '数据核对未通过，原数据保留',
      null => null,
      _ => '连接或服务不可用，请检查后重试',
    };
    return '最近完整同步：${state['lastSuccess'] ?? '尚未完成'}\n'
        '${failure == null ? '' : '最近同步失败：$failure（${state['lastFailureAt'] ?? '时间未知'}）\n'}'
        '待发送 $pending 个操作；本机待核对 $changed 项；待处理 $conflicts 个习惯\n'
        '${state['previewRequired'] == true ? '等待首次同步预览确认\n' : ''}'
        '远端新更改及当前授权需运行同步检查；同步不能替代历史备份';
  }
}
