import 'dart:async';
import 'dart:convert';
import 'dart:io' show SocketException, TlsException;
import 'dart:math';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:xml/xml.dart';

import 'backup_codec.dart';

class DavFailure implements Exception {
  const DavFailure(this.message, {this.status});
  final String message;
  final int? status;
  @override
  String toString() => message;
}

class DavResponse {
  const DavResponse(this.status, this.bytes, this.headers);
  final int status;
  final Uint8List bytes;
  final Map<String, String> headers;
}

class RemoteBackup {
  const RemoteBackup({
    required this.vault,
    required this.device,
    required this.id,
    required this.created,
    required this.digest,
    required this.size,
  });
  final String vault, device, id, digest;
  final DateTime created;
  final int size;
  String get relativePath => 'haoxiguan/$vault/$device/$id';
  Map<String, Object?> toJson() => {
    'format': 'haoxiguan-complete',
    'version': 1,
    'vault': vault,
    'device': device,
    'snapshot': id,
    'createdAtUtc': created.toUtc().toIso8601String(),
    'sha256': digest,
    'bytes': size,
  };
  factory RemoteBackup.fromJson(Map<String, dynamic> json) {
    if (json['format'] != 'haoxiguan-complete' ||
        json['version'] != 1 ||
        json.length != 8) {
      throw const FormatException('备份完成标记无效');
    }
    final result = RemoteBackup(
      vault: json['vault'] as String,
      device: json['device'] as String,
      id: json['snapshot'] as String,
      created: DateTime.parse(json['createdAtUtc'] as String),
      digest: json['sha256'] as String,
      size: json['bytes'] as int,
    );
    for (final id in [result.vault, result.device, result.id]) {
      requireUuid(id);
    }
    if (!result.created.isUtc ||
        !RegExp(r'^[0-9a-f]{64}$').hasMatch(result.digest) ||
        result.size < 1 ||
        result.size > BackupCodec.maxFileBytes) {
      throw const FormatException('备份完成标记无效');
    }
    return result;
  }
}

void requireUuid(String id) {
  if (!RegExp(
    r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  ).hasMatch(id)) {
    throw const FormatException('备份空间标识无效');
  }
}

class WebDavClient {
  WebDavClient(
    String endpoint,
    String username,
    String password, {
    http.Client? client,
  }) : base = validateEndpoint(endpoint),
       _authorization =
           'Basic ${base64Encode(utf8.encode('$username:$password'))}',
       _client = client ?? http.Client() {
    if (username.contains(':') || username.contains('\n') || username.isEmpty) {
      throw const FormatException('WebDAV 用户名无效');
    }
  }
  final Uri base;
  final String _authorization;
  final http.Client _client;
  static Uri validateEndpoint(String endpoint) {
    final uri = Uri.parse(endpoint.trim());
    if (uri.scheme != 'https' ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty ||
        uri.hasQuery ||
        uri.hasFragment) {
      throw const FormatException('请输入不含密码、查询参数或片段的 HTTPS WebDAV 目录');
    }
    return uri.path.endsWith('/') ? uri : uri.replace(path: '${uri.path}/');
  }

  void close() => _client.close();
  Uri _uri(String relative) {
    // All paths are generated from fixed names and validated UUIDs. Never follow a DAV href.
    if (relative.startsWith('/') ||
        relative.contains('..') ||
        relative.contains('%') ||
        relative.contains('\\')) {
      throw const FormatException('备份路径无效');
    }
    return base.resolve(relative);
  }

  Future<DavResponse> request(
    String method,
    String relative, {
    List<int>? body,
    Map<String, String> headers = const {},
    int maxBytes = 1024 * 1024,
    Set<int> allowed = const {200, 201, 204, 207, 404, 405, 412},
  }) async {
    for (var attempt = 0; attempt < 3; attempt++) {
      final request = http.Request(method, _uri(relative))
        ..followRedirects = false
        ..headers.addAll({'Authorization': _authorization, ...headers})
        // Compression can change an ETag used by a later conditional write or
        // delete. Request the stored representation and preserve its exact tag.
        ..headers['Accept-Encoding'] = 'identity';
      if (body != null) request.bodyBytes = body;
      DavResponse result;
      try {
        result = await (() async {
          final response = await _client.send(request);
          if (response.contentLength != null &&
              response.contentLength! > maxBytes) {
            await response.stream.listen((_) {}).cancel();
            throw const DavFailure('服务器返回内容过大');
          }
          final output = BytesBuilder(copy: false);
          await for (final chunk in response.stream) {
            if (output.length + chunk.length > maxBytes) {
              throw const DavFailure('服务器返回内容过大');
            }
            output.add(chunk);
          }
          return DavResponse(
            response.statusCode,
            output.takeBytes(),
            response.headers,
          );
        })().timeout(const Duration(seconds: 45));
      } on TimeoutException {
        throw const DavFailure('连接超时，本机记录不受影响');
      } on TlsException {
        throw const DavFailure('HTTPS 证书或安全连接验证失败，请检查服务器证书及主机信任设置。本机记录不受影响。');
      } on SocketException {
        throw const DavFailure('无法连接 WebDAV 服务器，请检查网络。本机记录不受影响。');
      } on http.ClientException {
        throw const DavFailure('WebDAV 连接未完成，请检查网络后重试。本机记录不受影响。');
      }
      if ((result.status == 429 || result.status >= 500) && attempt < 2) {
        await Future<void>.delayed(Duration(seconds: 1 << attempt));
        continue;
      }
      if (!allowed.contains(result.status)) {
        final message = switch (result.status) {
          401 || 403 => '登录失败或没有目录权限，请检查应用密码',
          429 => '服务器请求过多，请稍后重试',
          507 => '远端空间不足，原有备份未清理',
          >= 300 && < 400 => '服务器要求跳转，请直接填写最终 HTTPS WebDAV 地址',
          _ => 'WebDAV 操作失败（${result.status}），本机记录不受影响',
        };
        throw DavFailure(message, status: result.status);
      }
      return result;
    }
    throw const DavFailure('远端请求失败');
  }

  Future<void> _ensureDirectory(String relative) async {
    final result = await request('MKCOL', relative, allowed: {201, 405});
    if (result.status == 405) {
      await children(relative); // Existing path must be a readable collection.
    }
  }

  /// Tests this device's directory with a new, non-business file. Conditional
  /// writes/deletes and exact read-back avoid touching existing or changed files.
  Future<void> verifyAccess(String vault, String device) async {
    requireUuid(vault);
    requireUuid(device);
    for (final directory in [
      'haoxiguan/',
      'haoxiguan/$vault/',
      'haoxiguan/$vault/$device/',
    ]) {
      await _ensureDirectory(directory);
    }
    final path = 'haoxiguan/$vault/$device/access-${const Uuid().v4()}.probe';
    final random = Random.secure();
    final bytes = Uint8List.fromList(
      List.generate(32, (_) => random.nextInt(256)),
    );
    var mayRemain = false;
    try {
      // A lost response can still leave this inert probe on the server.
      mayRemain = true;
      final written = await request(
        'PUT',
        path,
        body: bytes,
        headers: {
          'If-None-Match': '*',
          'Content-Type': 'application/octet-stream',
        },
        allowed: {201, 204, 412},
      );
      if (written.status == 412) {
        mayRemain = false;
        throw const DavFailure('测试文件名已存在，未覆盖或删除，请重试');
      }
      final read = await request('GET', path, maxBytes: 1024, allowed: {200});
      final tag = read.headers['etag'];
      var sameBytes = read.bytes.length == bytes.length;
      for (var i = 0; sameBytes && i < bytes.length; i++) {
        sameBytes = read.bytes[i] == bytes[i];
      }
      if (!sameBytes || sha256.convert(read.bytes) != sha256.convert(bytes)) {
        throw const DavFailure('测试文件读回内容不一致，未删除远端文件');
      }
      if (tag == null ||
          !RegExp(r'^"[\x21\x23-\x7e\x80-\xff]*"$').hasMatch(tag)) {
        throw const DavFailure('服务器未提供有效的强 ETag，无法安全验证删除权限');
      }
      await request(
        'DELETE',
        path,
        headers: {'If-Match': tag},
        allowed: {200, 204},
      );
      final removed = await request(
        'GET',
        path,
        maxBytes: 1024,
        allowed: {200, 404},
      );
      if (removed.status != 404) {
        throw const DavFailure('服务器报告删除成功，但测试文件仍存在');
      }
      mayRemain = false;
    } on DavFailure catch (e) {
      if (!mayRemain) rethrow;
      throw DavFailure(
        '${e.message}\n验证未通过，本次配置未保存。目录内可能残留不含习惯数据的 access-*.probe 测试文件，可手动清理后重试。',
        status: e.status,
      );
    }
  }

  Future<List<String>> children(String relative) async {
    final result = await request(
      'PROPFIND',
      relative,
      headers: {'Depth': '1', 'Content-Type': 'application/xml; charset=utf-8'},
      body: utf8.encode(
        '<?xml version="1.0"?><d:propfind xmlns:d="DAV:"><d:prop><d:resourcetype/></d:prop></d:propfind>',
      ),
      allowed: {207, 404},
    );
    if (result.status == 404) return [];
    final xml = XmlDocument.parse(utf8.decode(result.bytes));
    final directory = _uri(relative);
    final values = <String>{};
    for (final response in xml.findAllElements(
      'response',
      namespaceUri: 'DAV:',
    )) {
      final href = response
          .findElements('href', namespaceUri: 'DAV:')
          .firstOrNull
          ?.innerText;
      if (href == null) continue;
      final child = directory.resolve(href);
      if (child.origin != directory.origin ||
          child.hasQuery ||
          child.hasFragment) {
        continue;
      }
      final prefix = directory.path.endsWith('/')
          ? directory.path
          : '${directory.path}/';
      if (!child.path.startsWith(prefix)) continue;
      var name = child.path.substring(prefix.length);
      if (name.endsWith('/')) name = name.substring(0, name.length - 1);
      if (name.isEmpty || name.contains('/') || name.contains('%')) continue;
      values.add(name);
    }
    if (values.length > 5000) throw const DavFailure('远端目录条目过多，请使用独立的备份目录');
    return values.toList()..sort();
  }

  Future<RemoteBackup> upload(
    String raw,
    String password,
    String vault,
    String device,
  ) async {
    requireUuid(vault);
    requireUuid(device);
    final bytes = await BackupCodec.encrypt(raw, password);
    await BackupCodec.decrypt(bytes, password);
    final item = RemoteBackup(
      vault: vault,
      device: device,
      id: const Uuid().v4(),
      created: DateTime.now().toUtc(),
      digest: sha256.convert(bytes).toString(),
      size: bytes.length,
    );
    for (final directory in [
      'haoxiguan/',
      'haoxiguan/$vault/',
      'haoxiguan/$vault/$device/',
    ]) {
      await _ensureDirectory(directory);
    }
    await _putImmutable('${item.relativePath}.hgb', bytes);
    final read = await request(
      'GET',
      '${item.relativePath}.hgb',
      maxBytes: BackupCodec.maxFileBytes,
      allowed: {200},
    );
    if (read.bytes.length != item.size ||
        sha256.convert(read.bytes).toString() != item.digest) {
      throw const DavFailure('远端读回校验失败，未标记为可恢复备份');
    }
    await BackupCodec.decrypt(read.bytes, password);
    final marker = utf8.encode(jsonEncode(item.toJson()));
    await _putImmutable('${item.relativePath}.complete.json', marker);
    final check = await request(
      'GET',
      '${item.relativePath}.complete.json',
      maxBytes: 4096,
      allowed: {200},
    );
    if (sha256.convert(check.bytes) != sha256.convert(marker)) {
      throw const DavFailure('完成标记读回失败，未报告备份成功');
    }
    return item;
  }

  Future<void> _putImmutable(String path, List<int> bytes) async {
    final result = await request(
      'PUT',
      path,
      body: bytes,
      headers: {
        'If-None-Match': '*',
        'Content-Type': 'application/octet-stream',
      },
      allowed: {201, 204, 412},
    );
    if (result.status == 412) {
      final existing = await request(
        'GET',
        path,
        maxBytes: BackupCodec.maxFileBytes,
        allowed: {200},
      );
      if (sha256.convert(existing.bytes) != sha256.convert(bytes)) {
        throw const DavFailure('远端存在不同文件，未覆盖');
      }
    }
  }

  Future<List<RemoteBackup>> list(String vault) async {
    requireUuid(vault);
    final result = <RemoteBackup>[];
    for (final device in await children('haoxiguan/$vault/')) {
      try {
        requireUuid(device);
      } on FormatException {
        continue;
      }
      for (final file in await children('haoxiguan/$vault/$device/')) {
        if (!file.endsWith('.complete.json')) continue;
        final id = file.substring(0, file.length - '.complete.json'.length);
        try {
          requireUuid(id);
        } on FormatException {
          continue;
        }
        final response = await request(
          'GET',
          'haoxiguan/$vault/$device/$file',
          maxBytes: 4096,
          allowed: {200, 404},
        );
        if (response.status == 404) continue;
        try {
          final item = RemoteBackup.fromJson(
            jsonDecode(utf8.decode(response.bytes)) as Map<String, dynamic>,
          );
          if (item.vault == vault && item.device == device && item.id == id) {
            result.add(item);
          }
        } on FormatException {
          continue;
        } on TypeError {
          continue;
        }
      }
    }
    result.sort((a, b) => b.created.compareTo(a.created));
    return result;
  }

  Future<String> restore(RemoteBackup item, String password) async {
    final response = await request(
      'GET',
      '${item.relativePath}.hgb',
      maxBytes: BackupCodec.maxFileBytes,
      allowed: {200},
    );
    if (response.bytes.length != item.size ||
        sha256.convert(response.bytes).toString() != item.digest) {
      throw const DavFailure('备份摘要不匹配，原数据未修改');
    }
    final raw = await BackupCodec.decrypt(response.bytes, password);
    if ((jsonDecode(raw) as Map)['vaultId'] != item.vault) {
      throw const DavFailure('备份空间与完成标记不一致，未恢复');
    }
    return raw;
  }

  /// Only IDs recorded by this device after successful upload are eligible.
  /// Conditional deletes avoid removing user-replaced files; without ETags, retain.
  Future<void> prune(
    List<RemoteBackup> owned,
    RemoteBackup newest,
    String password,
  ) async {
    await restore(
      newest,
      password,
    ); // Last known good copy must remain readable.
    final eligible = owned
        .where((b) => b.vault == newest.vault && b.device == newest.device)
        .toList();
    final keep = retainedBackupIds([...eligible, newest]);
    for (final item in eligible.where((b) => !keep.contains(b.id))) {
      final marker = await request(
        'GET',
        '${item.relativePath}.complete.json',
        maxBytes: 4096,
        allowed: {200, 404},
      );
      if (marker.status == 404) continue;
      final expected = utf8.encode(jsonEncode(item.toJson()));
      if (sha256.convert(marker.bytes) != sha256.convert(expected)) continue;
      final data = await request(
        'GET',
        '${item.relativePath}.hgb',
        maxBytes: BackupCodec.maxFileBytes,
        allowed: {200, 404},
      );
      final markerTag = marker.headers['etag'], dataTag = data.headers['etag'];
      if (data.status == 404 ||
          markerTag == null ||
          dataTag == null ||
          markerTag.startsWith('W/') ||
          dataTag.startsWith('W/') ||
          sha256.convert(data.bytes).toString() != item.digest) {
        continue;
      }
      // Remove visibility first; an interrupted cleanup can leave an inert file,
      // never a completed marker pointing at a file we already removed.
      final removed = await request(
        'DELETE',
        '${item.relativePath}.complete.json',
        headers: {'If-Match': markerTag},
        allowed: {200, 204, 404, 412},
      );
      if (removed.status == 412) continue;
      await request(
        'DELETE',
        '${item.relativePath}.hgb',
        headers: {'If-Match': dataTag},
        allowed: {200, 204, 404, 412},
      );
    }
  }
}

Set<String> retainedBackupIds(List<RemoteBackup> backups) {
  final sorted = [...backups]..sort((a, b) => b.created.compareTo(a.created));
  final days = <String>{},
      weeks = <String>{},
      months = <String>{},
      keep = <String>{};
  for (final item in sorted) {
    final date = item.created.toUtc();
    final day = '${date.year}-${date.month}-${date.day}';
    final monday = DateTime.utc(
      date.year,
      date.month,
      date.day - (date.weekday - 1),
    );
    final week = monday.toIso8601String(), month = '${date.year}-${date.month}';
    if (days.length < 7 && days.add(day)) keep.add(item.id);
    if (weeks.length < 4 && weeks.add(week)) keep.add(item.id);
    if (months.length < 6 && months.add(month)) keep.add(item.id);
  }
  return keep;
}
