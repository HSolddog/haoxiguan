import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:sodium/sodium_sumo.dart';

/// Client-only key material. Authentication tokens never derive content keys.
class SyncKeyring {
  SyncKeyring({
    required this.vault,
    required this.idKey,
    required this.currentGeneration,
    required this.contentKeys,
  });
  final String vault;
  final Uint8List idKey;
  final int currentGeneration;
  final Map<int, Uint8List> contentKeys;
  static Future<SyncKeyring> create(String vault) async {
    final sodium = await SodiumSumoInit.init();
    return SyncKeyring(
      vault: vault,
      idKey: sodium.randombytes.buf(32),
      currentGeneration: 1,
      contentKeys: {1: sodium.randombytes.buf(32)},
    );
  }

  String opaqueId(String logicalId) => base64UrlEncode(
    Hmac(
      sha256,
      idKey,
    ).convert(utf8.encode('haoxiguan/entity/v1/$logicalId')).bytes,
  ).replaceAll('=', '');
  Map<String, Object?> toJson() => {
    'format': 'haoxiguan-sync-keyring',
    'version': 1,
    'vault': vault,
    'idKey': base64Encode(idKey),
    'currentGeneration': currentGeneration,
    'contentKeys': {
      for (final entry in contentKeys.entries)
        '${entry.key}': base64Encode(entry.value),
    },
  };
  factory SyncKeyring.fromJson(Map<String, dynamic> value) {
    if (value['format'] != 'haoxiguan-sync-keyring' ||
        value['version'] is! int ||
        value['version'] != 1 ||
        value.length != 6) {
      throw const FormatException('同步恢复材料格式不支持');
    }
    final raw = value['contentKeys'];
    if (raw is! Map || raw.isEmpty || raw.length > 100) {
      throw const FormatException('同步密钥列表无效');
    }
    final keys = <int, Uint8List>{};
    for (final entry in raw.entries) {
      final n = entry.key is String ? int.tryParse(entry.key as String) : null;
      if (n == null || n < 1 || n > 1000000 || entry.key != '$n') {
        throw const FormatException('密钥版本无效');
      }
      keys[n] = _decodeBytes(entry.value, 32);
    }
    final vault = value['vault'] as String,
        generation = value['currentGeneration'] as int;
    if (vault.isEmpty || vault.length > 128 || !keys.containsKey(generation)) {
      throw const FormatException('同步空间或当前密钥无效');
    }
    return SyncKeyring(
      vault: vault,
      idKey: _decodeBytes(value['idKey'], 32),
      currentGeneration: generation,
      contentKeys: keys,
    );
  }
  void dispose() {
    idKey.fillRange(0, idKey.length, 0);
    for (final key in contentKeys.values) {
      key.fillRange(0, key.length, 0);
    }
  }
}

class SyncObjectContext {
  const SyncObjectContext({
    required this.vault,
    required this.epoch,
    required this.entityId,
    required this.baseRevision,
    required this.deleted,
  });
  final String vault, epoch, entityId;
  final int baseRevision;
  final bool deleted;
  Uint8List aad(int generation) => Uint8List.fromList(
    utf8.encode(
      jsonEncode([
        'haoxiguan-sync-object',
        1,
        vault,
        epoch,
        entityId,
        baseRevision,
        deleted,
        generation,
      ]),
    ),
  );
}

class SyncCrypto {
  static const maxPlaintextBytes = 128 * 1024;
  static Future<String> encrypt(
    SyncKeyring keys,
    SyncObjectContext context,
    String logicalId,
    Object? payload,
  ) async {
    if (context.vault != keys.vault ||
        context.entityId != keys.opaqueId(logicalId) ||
        context.baseRevision < 0) {
      throw const FormatException('同步对象与空间不匹配');
    }
    final sodium = await SodiumSumoInit.init();
    final generation = keys.currentGeneration;
    final key = sodium.secureCopy(keys.contentKeys[generation]!);
    final plaintext = Uint8List.fromList(
      utf8.encode(jsonEncode({'logicalId': logicalId, 'payload': payload})),
    );
    try {
      if (plaintext.length > maxPlaintextBytes) {
        throw const FormatException('单个同步对象过大，本地数据仍保留，可使用完整备份');
      }
      final nonce = sodium.randombytes.buf(24);
      final ciphertext = sodium.crypto.aeadXChaCha20Poly1305IETF.encrypt(
        message: plaintext,
        nonce: nonce,
        key: key,
        additionalData: context.aad(generation),
      );
      return base64Encode(
        utf8.encode(
          jsonEncode({
            'v': 1,
            'generation': generation,
            'nonce': base64Encode(nonce),
            'ciphertext': base64Encode(ciphertext),
          }),
        ),
      );
    } finally {
      key.dispose();
      plaintext.fillRange(0, plaintext.length, 0);
    }
  }

  static Future<({String logicalId, Object? payload})> decrypt(
    SyncKeyring keys,
    SyncObjectContext context,
    String encoded,
  ) async {
    if (encoded.length > 350000 ||
        context.vault != keys.vault ||
        context.baseRevision < 0) {
      throw const FormatException('同步对象格式无效');
    }
    final raw = _decodeBytes(encoded, null);
    final envelope = jsonDecode(utf8.decode(raw));
    if (envelope is! Map ||
        envelope.length != 4 ||
        envelope['v'] is! int ||
        envelope['v'] != 1 ||
        envelope['generation'] is! int) {
      throw const FormatException('同步加密版本不支持');
    }
    final generation = envelope['generation'] as int;
    final keyBytes = keys.contentKeys[generation];
    if (keyBytes == null) {
      throw const FormatException('缺少此版本内容密钥，请从可信设备导入新的恢复材料');
    }
    final nonce = _decodeBytes(envelope['nonce'], 24),
        ciphertext = _decodeBytes(envelope['ciphertext'], null);
    if (ciphertext.length < 16 || ciphertext.length > maxPlaintextBytes + 16) {
      throw const FormatException('同步对象大小无效');
    }
    final sodium = await SodiumSumoInit.init();
    final key = sodium.secureCopy(keyBytes);
    Uint8List? plain;
    try {
      plain = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
        cipherText: ciphertext,
        nonce: nonce,
        key: key,
        additionalData: context.aad(generation),
      );
      final data = jsonDecode(utf8.decode(plain));
      if (data is! Map ||
          data.length != 2 ||
          data['logicalId'] is! String ||
          keys.opaqueId(data['logicalId'] as String) != context.entityId) {
        throw const FormatException('同步对象身份校验失败');
      }
      return (logicalId: data['logicalId'] as String, payload: data['payload']);
    } on SodiumException {
      throw const FormatException('同步内容认证失败，本地记录未改变');
    } finally {
      key.dispose();
      plain?.fillRange(0, plain.length, 0);
    }
  }
}

Uint8List _decodeBytes(Object? value, int? length) {
  if (value is! String) throw const FormatException('缺少加密字段');
  final bytes = base64Decode(value);
  if (base64Encode(bytes) != value ||
      (length != null && bytes.length != length)) {
    throw const FormatException('加密字段无效');
  }
  return bytes;
}
