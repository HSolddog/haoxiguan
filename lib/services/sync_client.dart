import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:uuid/uuid.dart';

import 'backup_settings.dart';
import 'sync_crypto.dart';

class SyncApiException implements Exception {
  const SyncApiException(this.code, [this.status = 0]);
  final String code;
  final int status;
  @override
  String toString() => switch (code) {
    'unauthorized' => '设备授权失效，请申请新邀请；本地记录和密钥仍保留。',
    'epoch_changed' => '服务器已恢复到另一代数据，需要重新授权并核对本地与远端内容。',
    'device_stale' => '此设备离线超过服务端保留期，需要重新核对同步基线。',
    'quota_exceeded' => '服务器存储额度不足，本地记录已保留。',
    'rate_limited' => '服务器请求过于频繁，请稍后重试。',
    _ => '同步请求未完成，请检查网络和服务器后重试（$status）。',
  };
}

abstract interface class SyncTransport {
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    Map<String, String>? headers,
  });
  void close();
}

class HttpSyncTransport implements SyncTransport {
  HttpSyncTransport(String endpoint, {HttpClient? client})
    : endpoint = validateEndpoint(endpoint),
      _client = client ?? HttpClient();
  final Uri endpoint;
  final HttpClient _client;
  static Uri validateEndpoint(String value) {
    final uri = Uri.parse(value.trim());
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment ||
        (uri.path != '' && uri.path != '/')) {
      throw const FormatException('同步地址必须是 HTTPS 根地址，不含账号、路径或查询参数');
    }
    return uri.replace(path: '/');
  }

  @override
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    String? token,
    Map<String, String>? headers,
  }) async {
    if (!path.startsWith('/v1/') || path.startsWith('//')) {
      throw const FormatException('同步路径无效');
    }
    final raw = body == null ? null : utf8.encode(jsonEncode(body));
    if (raw != null && raw.length > 2 * 1024 * 1024) {
      throw const FormatException('同步批次过大');
    }
    HttpClientRequest? req;
    try {
      return await (() async {
        req = await _client.openUrl(method, endpoint.resolve(path));
        req!.followRedirects = false;
        req!.headers.set(HttpHeaders.acceptHeader, 'application/json');
        if (token != null) {
          req!.headers.set(HttpHeaders.authorizationHeader, 'Bearer $token');
        }
        headers?.forEach((k, v) => req!.headers.set(k, v));
        if (raw != null) {
          req!.headers.contentType = ContentType.json;
          req!.contentLength = raw.length;
          req!.add(raw);
        }
        final response = await req!.close();
        final bytes = <int>[];
        await for (final chunk in response) {
          if (bytes.length + chunk.length > 8 * 1024 * 1024) {
            throw const FormatException('服务器响应过大');
          }
          bytes.addAll(chunk);
        }
        if (response.statusCode >= 300 && response.statusCode < 400) {
          throw const FormatException('同步地址发生重定向，已停止发送凭据');
        }
        final value = jsonDecode(utf8.decode(bytes));
        if (value is! Map<String, dynamic>) {
          throw const FormatException('服务器响应格式无效');
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final code = value['error'];
          // Do not reflect arbitrary server-supplied text (which may contain secrets).
          throw SyncApiException(
            code is String && RegExp(r'^[a-z_]{1,40}$').hasMatch(code)
                ? code
                : 'server_error',
            response.statusCode,
          );
        }
        return value;
      })().timeout(const Duration(seconds: 45));
    } on TimeoutException {
      req?.abort();
      throw const SyncApiException('timeout');
    }
  }

  @override
  void close() => _client.close(force: true);
}

class SyncSettings {
  SyncSettings({
    required this.id,
    required this.endpoint,
    required this.localVault,
    required this.keys,
    required this.tokens,
    this.recoveryExported = false,
  });
  final String id, endpoint, localVault;
  final SyncKeyring keys;
  Map<String, dynamic> tokens;
  bool recoveryExported;
  Map<String, Object?> toJson() => {
    'version': 1,
    'id': id,
    'endpoint': endpoint,
    'localVault': localVault,
    'keys': keys.toJson(),
    'tokens': tokens,
    'recoveryExported': recoveryExported,
  };
  factory SyncSettings.fromJson(Map<String, dynamic> raw) {
    if (raw['version'] is! int || raw['version'] != 1 || raw.length != 7) {
      throw const FormatException('同步配置版本不支持');
    }
    final settings = SyncSettings(
      id: raw['id'] as String,
      endpoint: raw['endpoint'] as String,
      localVault: raw['localVault'] as String,
      keys: SyncKeyring.fromJson(raw['keys'] as Map<String, dynamic>),
      tokens: Map<String, dynamic>.from(raw['tokens'] as Map),
      recoveryExported: raw['recoveryExported'] as bool,
    );
    HttpSyncTransport.validateEndpoint(settings.endpoint);
    validateTokens(settings.tokens);
    if (settings.tokens['vaultId'] != settings.keys.vault) {
      throw const FormatException('同步密钥与账户空间不匹配');
    }
    return settings;
  }
  static void validateTokens(Map<String, dynamic> t) {
    for (final k in ['accessToken', 'refreshToken']) {
      if (t[k] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{43}$').hasMatch(t[k] as String)) {
        throw const FormatException('设备授权格式无效');
      }
    }
    for (final k in ['deviceId', 'vaultId', 'epoch']) {
      if (t[k] is! String ||
          !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(t[k] as String)) {
        throw const FormatException('设备空间格式无效');
      }
    }
    if (t['accessExpiresAt'] is! int) throw const FormatException('设备授权有效期无效');
  }
}

class SyncSettingsStore {
  SyncSettingsStore(this.secrets);
  final SecretStore secrets;
  static const _active = 'sync.active.v1';
  Future<SyncSettings?> load() async {
    final pointer = await secrets.read(_active);
    if (pointer == null) return null;
    final raw = await secrets.read('sync.config.$pointer');
    if (raw == null) throw StateError('同步配置缺失，停止联网；原数据未修改');
    return SyncSettings.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  Future<void> save(SyncSettings settings) async {
    final old = await secrets.read(_active), next = const Uuid().v4();
    await secrets.write('sync.config.$next', jsonEncode(settings.toJson()));
    await secrets.write(_active, next);
    if (old != null) await secrets.delete('sync.config.$old');
  }

  Future<void> disconnect() async {
    // Keep recovery keys in protected local storage. Explicit app deletion erases
    // them; reconnect can use an exported password-protected recovery file.
    await secrets.delete(_active);
  }
}

class SyncSession {
  SyncSession(this.settings, this.store, this.transport);
  final SyncSettings settings;
  final SyncSettingsStore store;
  final SyncTransport transport;
  Future<Map<String, dynamic>> request(
    String method,
    String path, {
    Map<String, Object?>? body,
    Map<String, String>? headers,
  }) async {
    if ((settings.tokens['accessExpiresAt'] as int) <=
        DateTime.now().millisecondsSinceEpoch ~/ 1000 + 30) {
      // Never retry a rotating refresh automatically: a lost response requires
      // a fresh operator invitation, not reuse that could hide token theft.
      final tokens = await transport.request(
        'POST',
        '/v1/auth/refresh',
        body: {'refreshToken': settings.tokens['refreshToken']},
      );
      SyncSettings.validateTokens(tokens);
      if (tokens['vaultId'] != settings.keys.vault ||
          tokens['deviceId'] != settings.tokens['deviceId']) {
        throw const FormatException('刷新授权空间发生变化');
      }
      settings.tokens = tokens;
      await store.save(settings);
    }
    return transport.request(
      method,
      path,
      body: body,
      headers: headers,
      token: settings.tokens['accessToken'] as String,
    );
  }
}
