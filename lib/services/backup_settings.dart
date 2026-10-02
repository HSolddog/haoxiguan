import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:uuid/uuid.dart';
import 'webdav_client.dart';

abstract interface class SecretStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
  Future<void> delete(String key);
}

class DeviceSecretStore implements SecretStore {
  // A failed key read must never silently erase credentials or encryption keys.
  final _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(
      resetOnError: false,
      migrateWithBackup: true,
      storageNamespace: 'haoxiguan_v1',
    ),
  );
  @override
  Future<String?> read(String key) => _storage.read(key: key);
  @override
  Future<void> write(String key, String value) =>
      _storage.write(key: key, value: value);
  @override
  Future<void> delete(String key) => _storage.delete(key: key);
}

class BackupSettings {
  const BackupSettings({
    required this.id,
    required this.endpoint,
    required this.username,
    required this.appPassword,
    required this.backupPassword,
    required this.vault,
    required this.device,
    this.automatic = true,
    this.wifiOnly = true,
  });
  final String id,
      endpoint,
      username,
      appPassword,
      backupPassword,
      vault,
      device;
  final bool automatic, wifiOnly;
  Map<String, Object?> toJson() => {
    'id': id,
    'endpoint': endpoint,
    'username': username,
    'appPassword': appPassword,
    'backupPassword': backupPassword,
    'vault': vault,
    'device': device,
    'automatic': automatic,
    'wifiOnly': wifiOnly,
  };
  factory BackupSettings.fromJson(Map<String, dynamic> v) => BackupSettings(
    id: v['id'] as String,
    endpoint: v['endpoint'] as String,
    username: v['username'] as String,
    appPassword: v['appPassword'] as String,
    backupPassword: v['backupPassword'] as String,
    vault: v['vault'] as String,
    device: v['device'] as String,
    automatic: v['automatic'] as bool,
    wifiOnly: v['wifiOnly'] as bool,
  );
}

class BackupSettingsStore {
  BackupSettingsStore(this.secrets);
  final SecretStore secrets;
  static const _active = 'webdav.active.v1';
  Future<BackupSettings?> load() async {
    final id = await secrets.read(_active);
    if (id == null) return null;
    final raw = await secrets.read('webdav.config.$id');
    if (raw == null) throw StateError('WebDAV 配置缺失，已停止自动备份');
    return BackupSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(BackupSettings settings) async {
    WebDavClient.validateEndpoint(settings.endpoint);
    requireUuid(settings.id);
    requireUuid(settings.vault);
    requireUuid(settings.device);
    // Commit pointer only after the complete immutable credential document is saved.
    final previous = await secrets.read(_active);
    await secrets.write(
      'webdav.config.${settings.id}',
      jsonEncode(settings.toJson()),
    );
    await secrets.write(_active, settings.id);
    if (previous != null && previous != settings.id) {
      await secrets.delete('webdav.config.$previous');
    }
  }

  Future<String> deviceId() async {
    final old = await secrets.read('device.id.v1');
    if (old != null) {
      requireUuid(old);
      return old;
    }
    final id = const Uuid().v4();
    await secrets.write('device.id.v1', id);
    return id;
  }

  Future<void> disconnect() async {
    final id = await secrets.read(_active);
    await secrets.delete(_active);
    if (id != null) await secrets.delete('webdav.config.$id');
  }

  Future<Map<String, dynamic>> status(String id) async {
    final raw = await secrets.read('webdav.status.$id');
    return raw == null ? {} : jsonDecode(raw) as Map<String, dynamic>;
  }

  Future<void> writeStatus(String id, Map<String, Object?> status) =>
      secrets.write('webdav.status.$id', jsonEncode(status));
}
