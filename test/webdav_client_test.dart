import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:haoxiguan/services/backup_manager.dart';
import 'package:haoxiguan/services/backup_settings.dart';
import 'package:haoxiguan/services/webdav_client.dart';

const vault = '11111111-1111-4111-8111-111111111111';
const device = '22222222-2222-4222-8222-222222222222';
const password = 'correct horse battery staple';
final raw = jsonEncode({'version': 7, 'vaultId': vault, 'habits': []});
void main() {
  test('只接受 HTTPS，无 URL 密码、查询或片段', () {
    for (final bad in [
      'http://server/dav',
      'https://user:password@server/dav',
      'https://server/dav?token=secret',
      'https://server/#x',
    ]) {
      expect(() => WebDavClient.validateEndpoint(bad), throwsFormatException);
    }
    expect(
      WebDavClient.validateEndpoint('https://server/dav').toString(),
      'https://server/dav/',
    );
  });
  test('认证不跟随跳转或恶意 href 离开用户配置目录', () async {
    var calls = 0;
    final client = WebDavClient(
      'https://server/dav/',
      'user',
      'secret',
      client: MockClient((request) async {
        calls++;
        expect(request.followRedirects, isFalse);
        expect(request.url.host, 'server');
        return http.Response(
          '',
          302,
          headers: {'location': 'https://attacker/'},
        );
      }),
    );
    await expectLater(
      client.children('haoxiguan/'),
      throwsA(isA<DavFailure>()),
    );
    expect(calls, 1);
    final hrefs = WebDavClient(
      'https://server/dav/',
      'user',
      'secret',
      client: MockClient(
        (_) async => http.Response('''<d:multistatus xmlns:d="DAV:">
      <d:response><d:href>https://attacker/dav/haoxiguan/evil/</d:href></d:response>
      <d:response><d:href>/outside/evil/</d:href></d:response>
      <d:response><d:href>/dav/haoxiguan/$vault/</d:href></d:response>
      </d:multistatus>''', 207),
      ),
    );
    expect(await hrefs.children('haoxiguan/'), [vault]);
  });
  test('上传读回并解密成功后才写完成标记，可列出恢复', () async {
    final server = _Dav();
    final client = server.client();
    final item = await client.upload(raw, password, vault, device);
    expect(server.files.keys.where((p) => p.endsWith('.hgb')), hasLength(1));
    expect(
      server.files.keys.where((p) => p.endsWith('.complete.json')),
      hasLength(1),
    );
    expect(
      server.events.indexWhere(
        (e) => e.startsWith('GET:') && e.endsWith('.hgb'),
      ),
      lessThan(
        server.events.indexWhere(
          (e) => e.startsWith('PUT:') && e.endsWith('.complete.json'),
        ),
      ),
    );
    expect((await client.list(vault)).single.id, item.id);
    expect(jsonDecode(await client.restore(item, password)), jsonDecode(raw));
    await expectLater(
      client.restore(item, 'wrong password'),
      throwsFormatException,
    );
  });
  test('读回损坏、无标记半文件和用户文件不会伪装为有效备份', () async {
    final server = _Dav()..corruptRead = true;
    final client = server.client();
    await expectLater(
      client.upload(raw, password, vault, device),
      throwsA(isA<DavFailure>()),
    );
    expect(server.files.keys.any((p) => p.endsWith('.complete.json')), isFalse);
    server.files['/dav/haoxiguan/$vault/$device/user.txt'] = utf8.encode(
      'user',
    );
    server.corruptRead = false;
    expect(await client.list(vault), isEmpty);
    expect(server.events.any((e) => e.startsWith('DELETE:')), isFalse);
  });
  test('401 直接终止，不无限重试，不写完成标记', () async {
    var calls = 0;
    final client = WebDavClient(
      'https://server/dav/',
      'user',
      'wrong',
      client: MockClient((_) async {
        calls++;
        return http.Response('', 401);
      }),
    );
    await expectLater(
      client.children('haoxiguan/'),
      throwsA(isA<DavFailure>().having((e) => e.status, 'status', 401)),
    );
    expect(calls, 1);
  });
  test('保留 7 日 4 周 6 月且始终保留最新，不以小时重复占据每日配额', () {
    final items = List.generate(
      250,
      (i) => RemoteBackup(
        vault: vault,
        device: device,
        id: 'id$i',
        created: DateTime.utc(2026, 10, 2).subtract(Duration(days: i)),
        digest: 'a' * 64,
        size: 1,
      ),
    );
    final kept = retainedBackupIds(items);
    expect(kept.contains('id0'), isTrue);
    for (var i = 0; i < 7; i++) {
      expect(kept.contains('id$i'), isTrue);
    }
    expect(kept.length, lessThanOrEqualTo(17));
    expect(kept.contains('id200'), isFalse);
  });
  test('清理只处理确认归属对象，保护其他设备和被替换文件', () async {
    final server = _Dav();
    final client = server.client();
    final newest = await client.upload(raw, password, vault, device);
    final owned = <RemoteBackup>[];
    for (var i = 0; i < 210; i++) {
      final id = '33333333-3333-4333-8333-${i.toString().padLeft(12, '0')}';
      final bytes = utf8.encode('old$i');
      final item = RemoteBackup(
        vault: vault,
        device: device,
        id: id,
        created: DateTime.utc(2025, 1, 1).add(Duration(days: i)),
        digest: sha256.convert(bytes).toString(),
        size: bytes.length,
      );
      owned.add(item);
      server.files['/dav/${item.relativePath}.hgb'] = bytes;
      server.files['/dav/${item.relativePath}.complete.json'] = utf8.encode(
        jsonEncode(item.toJson()),
      );
    }
    final replaced = '/dav/${owned.first.relativePath}.hgb';
    server.files[replaced] = utf8.encode('user replaced');
    server.files['/dav/haoxiguan/$vault/44444444-4444-4444-8444-444444444444/user.txt'] =
        utf8.encode('other device');
    await client.prune(owned, newest, password);
    expect(server.files.containsKey(replaced), isTrue);
    expect(server.files.containsKey('/dav/${newest.relativePath}.hgb'), isTrue);
    expect(server.files.keys.any((p) => p.endsWith('user.txt')), isTrue);
    expect(server.events.where((e) => e.startsWith('DELETE:')), isNotEmpty);
  });
  test('配置保存中断不会替换有效指针，密钥读取失败不自动删除', () async {
    final secrets = _Secrets();
    final store = BackupSettingsStore(secrets);
    final old = _settings('55555555-5555-4555-8555-555555555555');
    await store.save(old);
    secrets.failWrite = 'webdav.active.v1';
    await expectLater(
      store.save(_settings('66666666-6666-4666-8666-666666666666')),
      throwsStateError,
    );
    expect((await store.load())!.id, old.id);
    secrets.failRead = true;
    await expectLater(store.load(), throwsStateError);
    expect(secrets.values.containsKey('webdav.active.v1'), isTrue);
  });
  test('恢复为空间副本后旧配置不会自动上传，离线模式未配置不联网', () async {
    final secrets = _Secrets();
    final store = BackupSettingsStore(secrets);
    var connections = 0;
    final manager = BackupManager(
      store,
      clientFactory: (_) {
        connections++;
        return _Dav().client();
      },
    );
    expect(await manager.run(raw, automatic: true, wifi: true), isNull);
    await store.save(_settings('55555555-5555-4555-8555-555555555555'));
    expect(
      await manager.run(
        raw.replaceAll(vault, '99999999-9999-4999-8999-999999999999'),
        automatic: true,
        wifi: true,
      ),
      isNull,
    );
    expect(connections, 0);
  });
}

BackupSettings _settings(String id) => BackupSettings(
  id: id,
  endpoint: 'https://server/dav/',
  username: 'user',
  appPassword: 'secret',
  backupPassword: password,
  vault: vault,
  device: device,
);

class _Secrets implements SecretStore {
  final values = <String, String>{};
  String? failWrite;
  bool failRead = false;
  @override
  Future<String?> read(String key) async {
    if (failRead) throw StateError('keystore failed');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    if (key == failWrite) throw StateError('write failed');
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    values.remove(key);
  }
}

class _Dav {
  final files = <String, List<int>>{}, directories = <String>{'/dav/'};
  final events = <String>[];
  bool corruptRead = false;
  WebDavClient client() => WebDavClient(
    'https://server/dav/',
    'user',
    'secret',
    client: MockClient(handle),
  );
  Future<http.Response> handle(http.Request r) async {
    final path = r.url.path;
    events.add('${r.method}:$path');
    expect(
      r.headers['Authorization'] ?? r.headers['authorization'],
      'Basic ${base64Encode(utf8.encode('user:secret'))}',
    );
    switch (r.method) {
      case 'MKCOL':
        return http.Response('', directories.add(path) ? 201 : 405);
      case 'PROPFIND':
        if (!directories.contains(path)) return http.Response('', 404);
        final names = {...files.keys, ...directories}
            .where((p) => p.startsWith(path) && p != path)
            .where(
              (p) => !p
                  .substring(path.length)
                  .replaceFirst(RegExp(r'/$'), '')
                  .contains('/'),
            );
        return http.Response(
          '<d:multistatus xmlns:d="DAV:">${names.map((p) => '<d:response><d:href>$p</d:href></d:response>').join()}</d:multistatus>',
          207,
        );
      case 'PUT':
        expect(r.headers['If-None-Match'] ?? r.headers['if-none-match'], '*');
        if (files.containsKey(path)) return http.Response('', 412);
        files[path] = r.bodyBytes;
        return http.Response('', 201);
      case 'GET':
        final bytes = files[path];
        if (bytes == null) return http.Response('', 404);
        return http.Response.bytes(
          corruptRead && path.endsWith('.hgb') ? [1, 2, 3] : bytes,
          200,
          headers: {'etag': '"${sha256.convert(bytes)}"'},
        );
      case 'DELETE':
        final bytes = files[path];
        if (bytes == null) return http.Response('', 404);
        expect(
          r.headers['If-Match'] ?? r.headers['if-match'],
          '"${sha256.convert(bytes)}"',
        );
        files.remove(path);
        return http.Response('', 204);
      default:
        throw StateError(r.method);
    }
  }
}
