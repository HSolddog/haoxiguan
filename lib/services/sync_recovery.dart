import 'dart:convert';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

import 'sync_crypto.dart';

/// A different magic and extension prevent key material from being mistaken for
/// a business-data backup. Authentication tokens are deliberately absent.
class SyncRecoveryCodec {
  static const format = 'haoxiguan-sync-recovery';
  static const maxBytes = 128 * 1024;
  static const suite = 'argon2id-xchacha20poly1305-v1';

  static Future<Uint8List> encrypt(SyncKeyring keys, String password) {
    final raw = jsonEncode(keys.toJson());
    return Isolate.run(() => _encrypt(raw, password));
  }

  static Future<SyncKeyring> decrypt(Uint8List bytes, String password) async {
    final raw = await Isolate.run(() => _decrypt(bytes, password));
    return SyncKeyring.fromJson(jsonDecode(raw) as Map<String, dynamic>);
  }

  static Uint8List _aad(Map<String, dynamic> h) => Uint8List.fromList(
    utf8.encode(
      jsonEncode([
        h['format'],
        h['version'],
        h['suite'],
        h['memoryKiB'],
        h['iterations'],
        h['parallelism'],
        h['salt'],
        h['nonce'],
      ]),
    ),
  );

  static Int8List _password(String value) {
    final encoded = utf8.encode(value);
    if (encoded.length > 1024) throw const FormatException('密码超过 1024 字节');
    return Int8List.fromList(encoded);
  }

  static Uint8List _decode(Object? value, int? size) {
    if (value is! String) throw const FormatException('恢复材料缺少字段');
    final bytes = base64Decode(value);
    if (base64Encode(bytes) != value ||
        (size != null && bytes.length != size)) {
      throw const FormatException('恢复材料字段无效');
    }
    return bytes;
  }

  static Future<Uint8List> _encrypt(String raw, String password) async {
    if (password.runes.length < 12) {
      throw const FormatException('恢复密码至少 12 个字符');
    }
    final s = await SodiumSumoInit.init();
    final salt = s.randombytes.buf(16), nonce = s.randombytes.buf(24);
    final h = <String, dynamic>{
      'format': format,
      'version': 1,
      'suite': suite,
      'memoryKiB': 65536,
      'iterations': 3,
      'parallelism': 1,
      'salt': base64Encode(salt),
      'nonce': base64Encode(nonce),
    };
    final pass = _password(password),
        plain = Uint8List.fromList(utf8.encode(raw));
    SecureKey? key;
    try {
      if (plain.length > maxBytes ~/ 2) throw const FormatException('恢复材料过大');
      key = s.crypto.pwhash(
        outLen: 32,
        password: pass,
        salt: salt,
        opsLimit: 3,
        memLimit: 65536 * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      final cipher = s.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: plain,
        nonce: nonce,
        key: key,
        additionalData: _aad(h),
      );
      return Uint8List.fromList(
        utf8.encode(jsonEncode({...h, 'payload': base64Encode(cipher)})),
      );
    } finally {
      key?.dispose();
      pass.fillRange(0, pass.length, 0);
      plain.fillRange(0, plain.length, 0);
    }
  }

  static Future<String> _decrypt(Uint8List bytes, String password) async {
    if (bytes.length > maxBytes) throw const FormatException('恢复材料超过 128 KiB');
    final h = jsonDecode(utf8.decode(bytes));
    if (h is! Map<String, dynamic> ||
        h.length != 9 ||
        h['format'] != format ||
        h['version'] is! int ||
        h['version'] != 1 ||
        h['suite'] != suite ||
        h['memoryKiB'] is! int ||
        h['memoryKiB'] != 65536 ||
        h['iterations'] is! int ||
        h['iterations'] != 3 ||
        h['parallelism'] is! int ||
        h['parallelism'] != 1) {
      throw const FormatException('恢复材料格式或密码派生参数不支持');
    }
    final salt = _decode(h['salt'], 16), nonce = _decode(h['nonce'], 24);
    final cipher = _decode(h['payload'], null);
    if (cipher.length < 16 || cipher.length > maxBytes ~/ 2 + 16) {
      throw const FormatException('恢复材料长度无效');
    }
    final s = await SodiumSumoInit.init(), pass = _password(password);
    SecureKey? key;
    Uint8List? plain;
    try {
      key = s.crypto.pwhash(
        outLen: 32,
        password: pass,
        salt: salt,
        opsLimit: 3,
        memLimit: 65536 * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      plain = s.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: cipher,
        nonce: nonce,
        key: key,
        additionalData: _aad(h),
      );
      return utf8.decode(plain);
    } on SodiumException {
      throw const FormatException('恢复密码不正确或文件被修改');
    } finally {
      key?.dispose();
      pass.fillRange(0, pass.length, 0);
      plain?.fillRange(0, plain.length, 0);
    }
  }
}
