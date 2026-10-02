import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_recovery.dart';

void main() {
  const password = 'public recovery test password';
  test(
    'password recovery is randomized, authenticated and distinct from data backups',
    () async {
      final keys = await SyncKeyring.create('public-test-vault');
      final a = await SyncRecoveryCodec.encrypt(keys, password);
      final b = await SyncRecoveryCodec.encrypt(keys, password);
      expect(a, isNot(b));
      final decoded = await SyncRecoveryCodec.decrypt(a, password);
      expect(decoded.toJson(), keys.toJson());
      await expectLater(
        SyncRecoveryCodec.decrypt(a, 'wrong'),
        throwsFormatException,
      );
      await expectLater(
        BackupCodec.decrypt(a, password),
        throwsFormatException,
      );
      final h = jsonDecode(utf8.decode(a)) as Map<String, dynamic>;
      final cipher = base64Decode(h['payload'] as String)..[20] ^= 1;
      h['payload'] = base64Encode(cipher);
      await expectLater(
        SyncRecoveryCodec.decrypt(
          Uint8List.fromList(utf8.encode(jsonEncode(h))),
          password,
        ),
        throwsFormatException,
      );
      h['memoryKiB'] = 1024 * 1024 * 1024;
      await expectLater(
        SyncRecoveryCodec.decrypt(
          Uint8List.fromList(utf8.encode(jsonEncode(h))),
          password,
        ),
        throwsFormatException,
      );
      decoded.dispose();
      keys.dispose();
    },
  );
  test(
    'rejects weak creation passwords, oversized input and ambiguous generation keys',
    () async {
      final keys = await SyncKeyring.create('public-test-vault');
      await expectLater(
        SyncRecoveryCodec.encrypt(keys, 'short'),
        throwsFormatException,
      );
      await expectLater(
        SyncRecoveryCodec.decrypt(
          Uint8List(SyncRecoveryCodec.maxBytes + 1),
          password,
        ),
        throwsFormatException,
      );
      final raw = keys.toJson();
      raw['contentKeys'] = {'01': base64Encode(keys.contentKeys[1]!)};
      expect(() => SyncKeyring.fromJson(raw), throwsFormatException);
      keys.dispose();
    },
  );
}
