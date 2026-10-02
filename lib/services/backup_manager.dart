import 'dart:convert';
import 'device_task_lock.dart';
import 'package:crypto/crypto.dart';
import 'backup_settings.dart';
import 'webdav_client.dart';

class BackupManager {
  BackupManager(
    this.store, {
    WebDavClient Function(BackupSettings)? clientFactory,
  }) : _clientFactory =
           clientFactory ??
           ((s) => WebDavClient(s.endpoint, s.username, s.appPassword));
  final BackupSettingsStore store;
  final WebDavClient Function(BackupSettings) _clientFactory;
  Future<RemoteBackup?> run(
    String raw, {
    bool automatic = false,
    bool wifi = false,
  }) => DeviceTaskLock.run(
    'backup',
    () => _run(raw, automatic: automatic, wifi: wifi),
  );
  Future<RemoteBackup?> _run(
    String raw, {
    bool automatic = false,
    bool wifi = false,
  }) async {
    final settings = await store.load();
    if (settings == null) return null;
    final document = jsonDecode(raw) as Map<String, dynamic>;
    if (document['vaultId'] != settings.vault) {
      if (automatic) return null;
      throw const DavFailure('本地空间已更换，请重新配置后再备份；原远端副本仍保留');
    }
    final status = await store.status(settings.id);
    final digest = sha256.convert(utf8.encode(raw)).toString();
    final last = DateTime.tryParse(status['lastSuccess'] as String? ?? '');
    if (automatic &&
        (!settings.automatic ||
            (settings.wifiOnly && !wifi) ||
            status['sourceDigest'] == digest ||
            (last != null &&
                DateTime.now().toUtc().difference(last) <
                    const Duration(days: 1)))) {
      return null;
    }
    final client = _clientFactory(settings);
    try {
      final item = await client.upload(
        raw,
        settings.backupPassword,
        settings.vault,
        settings.device,
      );
      final owned = (status['owned'] as List? ?? [])
          .map((v) => RemoteBackup.fromJson((v as Map).cast<String, dynamic>()))
          .toList();
      owned.add(item);
      // Successful backup is reported independently of optional retention cleanup.
      await store.writeStatus(settings.id, {
        'lastSuccess': item.created.toIso8601String(),
        'sourceDigest': digest,
        'owned': owned.map((b) => b.toJson()).toList(),
      });
      try {
        await client.prune(owned, item, settings.backupPassword);
        final retained = retainedBackupIds(owned);
        await store.writeStatus(settings.id, {
          'lastSuccess': item.created.toIso8601String(),
          'sourceDigest': digest,
          'owned': owned
              .where((b) => retained.contains(b.id))
              .map((b) => b.toJson())
              .toList(),
        });
      } on Object {
        await store.writeStatus(settings.id, {
          'lastSuccess': item.created.toIso8601String(),
          'sourceDigest': digest,
          'owned': owned.map((b) => b.toJson()).toList(),
          'warning': '新备份已校验成功，旧副本清理未完成，稍后重试',
        });
      }
      return item;
    } on Object {
      // Do not persist raw errors: URLs, provider responses or credentials may be included.
      await store.writeStatus(settings.id, {
        ...await store.status(settings.id),
        'warning': '备份未完成，请检查连接、权限和空间后重试',
      });
      rethrow;
    } finally {
      client.close();
    }
  }
}
