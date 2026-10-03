import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:uuid/uuid.dart';

import '../data/snapshot_codec.dart';

class BackupContents {
  const BackupContents(this.snapshot, this.createdAtUtc);
  final String snapshot;
  final DateTime? createdAtUtc;
}

/// The entire header has an explicit, stable AEAD encoding (see protocol docs).
class BackupCodec {
  static const format = 'haoxiguan-backup';
  static const suite = 'argon2id-xchacha20poly1305-v1';
  static const maxFileBytes = 50 * 1024 * 1024;
  static const maxPlaintextBytes = 36 * 1024 * 1024;
  static const memoryKiB = 65536;
  static const iterations = 3;

  static Future<Uint8List> encrypt(String snapshot, String password) =>
      Isolate.run(() => encryptHere(snapshot, password));
  static Future<String> decrypt(Uint8List bytes, String password) =>
      Isolate.run(() => decryptHere(bytes, password));
  static Future<BackupContents> decryptWithMetadata(
    Uint8List bytes,
    String password,
  ) => Isolate.run(() => decryptHereWithMetadata(bytes, password));

  static Future<Uint8List> encryptHere(String snapshot, String password) async {
    final data = SnapshotCodec.decode(snapshot);
    if (password.runes.length < 12) {
      throw const FormatException('备份密码至少 12 个字符，建议使用多个随机词');
    }
    final sodium = await SodiumSumoInit.init();
    final salt = sodium.randombytes.buf(sodium.crypto.pwhash.saltBytes);
    final aead = sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = sodium.randombytes.buf(aead.nonceBytes);
    final header = <String, Object?>{
      'format': format,
      'formatVersion': 1,
      'appVersion': '1.2.0',
      'encrypted': true,
      'crypto': {
        'suite': suite,
        'salt': base64Encode(salt),
        'kdfParams': {
          'memoryKiB': memoryKiB,
          'iterations': iterations,
          'parallelism': 1,
        },
        'nonce': base64Encode(nonce),
      },
    };
    final plaintext = Uint8List.fromList(
      utf8.encode(
        jsonEncode({
          'manifest': {
            'snapshotId': const Uuid().v4(),
            'createdAtUtc': DateTime.now().toUtc().toIso8601String(),
            'sourceVaultId': data['vaultId'],
            'dataSchemaVersion': data['version'],
            'habitCount': (data['habits']! as List).length,
          },
          'data': data,
        }),
      ),
    );
    if (plaintext.length > maxPlaintextBytes) {
      throw const FormatException('数据过大，未生成备份');
    }
    final passwordBytes = _passwordBytes(password);
    SecureKey? key;
    try {
      key = sodium.crypto.pwhash(
        outLen: aead.keyBytes,
        password: passwordBytes,
        salt: salt,
        opsLimit: iterations,
        memLimit: memoryKiB * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      final ciphertext = aead.encrypt(
        message: plaintext,
        nonce: nonce,
        key: key,
        additionalData: associatedData(header),
      );
      return Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            ...header,
            'payload': base64Encode(ciphertext),
            'payloadSha256': sha256.convert(ciphertext).toString(),
          }),
        ),
      );
    } finally {
      key?.dispose();
      passwordBytes.fillRange(0, passwordBytes.length, 0);
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  static Future<String> decryptHere(Uint8List bytes, String password) async =>
      (await decryptHereWithMetadata(bytes, password)).snapshot;

  static Future<BackupContents> decryptHereWithMetadata(
    Uint8List bytes,
    String password,
  ) async {
    if (bytes.length > maxFileBytes) {
      throw const FormatException('备份文件超过 50 MiB');
    }
    final decoded = jsonDecode(utf8.decode(bytes));
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('备份文件格式无效');
    }
    final header = Map<String, Object?>.from(decoded);
    if (header['format'] != format ||
        header['formatVersion'] is! int ||
        header['formatVersion'] != 1 ||
        header.length != 7 ||
        header['encrypted'] != true) {
      throw const FormatException('备份格式或版本不支持');
    }
    if (header['appVersion'] is! String ||
        (header['appVersion'] as String).length > 64) {
      throw const FormatException('应用版本字段无效');
    }
    final crypto = header['crypto'];
    if (crypto is! Map || crypto.length != 4 || crypto['suite'] != suite) {
      throw const FormatException('加密算法不支持');
    }
    final kdf = crypto['kdfParams'];
    // Check BEFORE allocating a password hash or calling native crypto.
    if (kdf is! Map ||
        kdf.length != 3 ||
        kdf['memoryKiB'] is! int ||
        kdf['iterations'] is! int ||
        kdf['parallelism'] is! int ||
        kdf['memoryKiB'] != memoryKiB ||
        kdf['iterations'] != iterations ||
        kdf['parallelism'] != 1) {
      throw const FormatException('不支持的密码派生参数，未执行解密');
    }
    final salt = _base64(crypto['salt'], 16);
    final nonce = _base64(crypto['nonce'], 24);
    final ciphertext = _base64(header['payload'], null);
    if (ciphertext.length < 16 ||
        ciphertext.length > maxPlaintextBytes + 16 ||
        header['payloadSha256'] != sha256.convert(ciphertext).toString()) {
      throw const FormatException('备份校验未通过');
    }
    final sodium = await SodiumSumoInit.init();
    final passwordBytes = _passwordBytes(password);
    SecureKey? key;
    Uint8List? plaintext;
    try {
      key = sodium.crypto.pwhash(
        outLen: 32,
        password: passwordBytes,
        salt: salt,
        opsLimit: iterations,
        memLimit: memoryKiB * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      plaintext = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: key,
        additionalData: associatedData(header),
      );
      final inner = jsonDecode(utf8.decode(plaintext)) as Map<String, dynamic>;
      final raw = jsonEncode(inner['data']);
      final snapshot = SnapshotCodec.decode(raw);
      final manifest = inner['manifest'] as Map<String, dynamic>;
      if (manifest['dataSchemaVersion'] != snapshot['version'] ||
          manifest['habitCount'] != (snapshot['habits']! as List).length) {
        throw const FormatException('备份清单与内容不一致');
      }
      final createdAt = manifest['createdAtUtc'];
      final created = createdAt is String ? DateTime.tryParse(createdAt) : null;
      if (createdAt != null && (created == null || !created.isUtc)) {
        throw const FormatException('备份创建时间无效');
      }
      return BackupContents(raw, created);
    } on SodiumException {
      throw const FormatException('密码不正确或备份被修改，原数据未改变');
    } finally {
      key?.dispose();
      passwordBytes.fillRange(0, passwordBytes.length, 0);
      plaintext?.fillRange(0, plaintext.length, 0);
    }
  }

  static Uint8List associatedData(Map<String, Object?> header) {
    final crypto = header['crypto']! as Map;
    final kdf = crypto['kdfParams']! as Map;
    return Uint8List.fromList(
      utf8.encode(
        jsonEncode([
          header['format'],
          header['formatVersion'],
          header['appVersion'],
          header['encrypted'],
          crypto['suite'],
          crypto['salt'],
          kdf['memoryKiB'],
          kdf['iterations'],
          kdf['parallelism'],
          crypto['nonce'],
        ]),
      ),
    );
  }

  static Int8List _passwordBytes(String password) {
    final bytes = utf8.encode(password);
    if (bytes.length > 1024) throw const FormatException('密码超过 1024 字节');
    return Int8List.fromList(bytes);
  }

  static Uint8List _base64(Object? value, int? length) {
    if (value is! String) throw const FormatException('缺少加密字段');
    final bytes = base64Decode(value);
    if ((length != null && bytes.length != length) ||
        base64Encode(bytes) != value) {
      throw const FormatException('加密字段无效');
    }
    return bytes;
  }
}
