import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  late Map<String, dynamic> vector;
  setUpAll(() async {
    vector =
        jsonDecode(
              await File('test/fixtures/backup-v1-vector.json').readAsString(),
            )
            as Map<String, dynamic>;
  });
  Uint8List bytes(Object value) => utf8.encode(jsonEncode(value));
  Map<String, dynamic> envelope() =>
      jsonDecode(jsonEncode(vector['envelope'])) as Map<String, dynamic>;

  test('跨语言已知答案：Argon2id 派生、AAD 字节和完整备份解密', () async {
    final sodium = await SodiumSumoInit.init();
    final header = envelope();
    final key = sodium.crypto.pwhash(
      outLen: 32,
      password: Int8List.fromList(utf8.encode(vector['password'] as String)),
      salt: base64Decode(header['crypto']['salt'] as String),
      opsLimit: 3,
      memLimit: 65536 * 1024,
      alg: CryptoPwhashAlgorithm.argon2id13,
    );
    try {
      expect(
        key
            .extractBytes()
            .map((b) => b.toRadixString(16).padLeft(2, '0'))
            .join(),
        vector['expectedKdfKeyHex'],
      );
    } finally {
      key.dispose();
    }
    expect(
      BackupCodec.associatedData(
        header,
      ).map((b) => b.toRadixString(16).padLeft(2, '0')).join(),
      vector['aadHex'],
    );
    expect(
      jsonDecode(
        await BackupCodec.decryptHere(
          bytes(header),
          vector['password'] as String,
        ),
      ),
      vector['snapshot'],
    );
  });

  test('文件每次使用独立盐和 nonce，真实加密往返', () async {
    const password = 'a long random backup passphrase';
    final snapshot = SnapshotCodec.empty();
    final first = await BackupCodec.encryptHere(snapshot, password);
    final second = await BackupCodec.encryptHere(snapshot, password);
    final a = jsonDecode(utf8.decode(first));
    final b = jsonDecode(utf8.decode(second));
    expect(a['crypto']['salt'], isNot(b['crypto']['salt']));
    expect(a['crypto']['nonce'], isNot(b['crypto']['nonce']));
    expect(await BackupCodec.decrypt(first, password), snapshot);
  });

  test('错密码不会改动应用数据', () async {
    final repo = MemoryHabitRepository();
    final controller = HabitController(repo);
    await controller.load();
    final before = controller.exportJson();
    await expectLater(
      BackupCodec.decryptHere(bytes(envelope()), 'wrong password'),
      throwsFormatException,
    );
    expect(controller.exportJson(), before);
  });

  test('密文篡改即使重算 SHA256 仍被 AEAD 拒绝', () async {
    final header = envelope();
    final payload = base64Decode(header['payload'] as String);
    payload[0] ^= 1;
    header['payload'] = base64Encode(payload);
    header['payloadSha256'] = sha256.convert(payload).toString();
    await expectLater(
      BackupCodec.decryptHere(bytes(header), vector['password'] as String),
      throwsFormatException,
    );
  });

  test('应用版本、盐、nonce 篡改不能通过认证', () async {
    for (final field in ['appVersion', 'salt', 'nonce']) {
      final header = envelope();
      if (field == 'appVersion') {
        header[field] = 'tampered';
      } else {
        final original = base64Decode(header['crypto'][field] as String);
        original[0] ^= 1;
        header['crypto'][field] = base64Encode(original);
      }
      await expectLater(
        BackupCodec.decryptHere(bytes(header), vector['password'] as String),
        throwsFormatException,
      );
    }
  });

  test('拒绝未知版本、算法和过大的 KDF 参数', () async {
    for (final field in [
      'version',
      'suite',
      'memory',
      'iterations',
      'parallelism',
    ]) {
      final header = envelope();
      switch (field) {
        case 'version':
          header['formatVersion'] = 999;
        case 'suite':
          header['crypto']['suite'] = 'unsupported';
        case 'memory':
          header['crypto']['kdfParams']['memoryKiB'] = 1024 * 1024 * 1024;
        case 'iterations':
          header['crypto']['kdfParams']['iterations'] = 999999;
        case 'parallelism':
          header['crypto']['kdfParams']['parallelism'] = 999;
      }
      await expectLater(
        BackupCodec.decryptHere(bytes(header), vector['password'] as String),
        throwsFormatException,
      );
    }
  });

  test('弱密码、文件截断与非法 base64 均安全失败', () async {
    await expectLater(
      BackupCodec.encryptHere(SnapshotCodec.empty(), 'short'),
      throwsFormatException,
    );
    final file = bytes(envelope());
    await expectLater(
      BackupCodec.decryptHere(file.sublist(0, file.length - 10), 'anything'),
      throwsFormatException,
    );
    final header = envelope();
    header['crypto']['salt'] = '!';
    await expectLater(
      BackupCodec.decryptHere(bytes(header), 'anything'),
      throwsFormatException,
    );
  });
}
