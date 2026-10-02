import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:uuid/uuid.dart';
import 'package:haoxiguan/services/webdav_client.dart';

// Explicitly provisioned disposable services only. No global TLS bypass.
void main() {
  const endpoint = String.fromEnvironment('TEST_DAV_ENDPOINT');
  const cert = String.fromEnvironment('TEST_DAV_CERT');
  const username = String.fromEnvironment(
    'TEST_DAV_USER',
    defaultValue: 'testuser',
  );
  const credential = String.fromEnvironment(
    'TEST_DAV_PASSWORD',
    defaultValue: 'public-synthetic-test-password',
  );
  test(
    '真实 TLS WebDAV：上传读回、目录遍历、跨设备读取和恢复',
    () async {
      final context = SecurityContext(withTrustedRoots: true);
      if (cert.isNotEmpty) context.setTrustedCertificates(cert);
      final client = WebDavClient(
        endpoint,
        username,
        credential,
        client: IOClient(HttpClient(context: context)),
      );
      const password = 'public recovery phrase for synthetic integration test';
      final vault = const Uuid().v4(), device = const Uuid().v4();
      final raw = jsonEncode({'version': 7, 'vaultId': vault, 'habits': []});
      try {
        final item = await client.upload(raw, password, vault, device);
        final listed = await client.list(vault);
        expect(listed.map((b) => b.id), contains(item.id));
        expect(
          jsonDecode(await client.restore(item, password)),
          jsonDecode(raw),
        );
        final another = await client.upload(
          raw,
          password,
          vault,
          const Uuid().v4(),
        );
        expect(
          (await client.list(vault)).map((b) => b.id),
          containsAll([item.id, another.id]),
        );
        // These two IDs were created by this test in its random namespace.
        for (final b in [item, another]) {
          await client.request(
            'DELETE',
            '${b.relativePath}.hgb',
            allowed: {200, 204},
          );
          await client.request(
            'DELETE',
            '${b.relativePath}.complete.json',
            allowed: {200, 204},
          );
        }
        expect(await client.list(vault), isEmpty);
      } finally {
        client.close();
      }
    },
    skip: endpoint.isEmpty ? '需要显式指定可写的隔离 WebDAV 测试目录' : false,
  );
}
