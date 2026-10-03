// Explicit synthetic-only entry point; normal `flutter test` does not regenerate
// public schemas/examples. Run with the fixed toolchain and native libsodium.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/services/sync_recovery.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:sodium/sodium_sumo.dart';

void main() {
  test(
    'generate sync contracts with actual codecs and public synthetic keys',
    () async {
      final fixture =
          jsonDecode(
                await File('test/fixtures/sync-v1-vector.json').readAsString(),
              )
              as Map<String, dynamic>;
      final original = SyncKeyring.fromJson(
        fixture['keys'] as Map<String, dynamic>,
      );
      final keys = SyncKeyring(
        vault: original.vault,
        idKey: Uint8List.fromList(original.idKey),
        currentGeneration: 2,
        contentKeys: {
          1: Uint8List.fromList(original.contentKeys[1]!),
          // Public fixed bytes exercise the existing rotation representation.
          2: Uint8List.fromList(List.generate(32, (index) => 128 + index)),
        },
      );
      original.dispose();
      addTearDown(keys.dispose);
      final controller = HabitController(
        MemoryHabitRepository(
          await File(
            'docs/schemas/examples/logical-snapshot-v7.json',
          ).readAsString(),
        ),
        clock: () => DateTime(2026, 10, 3),
        timezoneId: () => 'Asia/Shanghai',
      );
      addTearDown(controller.dispose);
      await controller.load();
      final entities = SyncEntities.encode(controller.exportJson());
      expect(entities.keys.map((key) => key.substring(0, 1)).toSet(), {
        'h',
        'r',
        'p',
        'n',
      });
      final logicalId = entities.keys.firstWhere((key) => key.startsWith('h/'));
      final payload = entities[logicalId];
      final context = SyncObjectContext(
        vault: keys.vault,
        epoch: 'public-synthetic-schema-epoch',
        entityId: keys.opaqueId(logicalId),
        baseRevision: 3,
        deleted: false,
      );
      final wire = await SyncCrypto.encrypt(keys, context, logicalId, payload);
      final envelope = jsonDecode(utf8.decode(base64Decode(wire))) as Map;
      final decoded = await SyncCrypto.decrypt(keys, context, wire);
      expect(decoded.logicalId, logicalId);
      expect(decoded.payload, payload);
      final sodium = await SodiumSumoInit.init();
      final key = sodium.secureCopy(keys.contentKeys[keys.currentGeneration]!);
      late Object? plaintext;
      try {
        final bytes = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: base64Decode(envelope['ciphertext'] as String),
          nonce: base64Decode(envelope['nonce'] as String),
          key: key,
          additionalData: context.aad(keys.currentGeneration),
        );
        plaintext = jsonDecode(utf8.decode(bytes));
        expect(plaintext, {'logicalId': logicalId, 'payload': payload});
      } finally {
        key.dispose();
      }
      const password = 'public synthetic sync schema recovery password';
      final recoveryBytes = await SyncRecoveryCodec.encrypt(keys, password);
      final recovered = await SyncRecoveryCodec.decrypt(
        recoveryBytes,
        password,
      );
      expect(recovered.toJson(), keys.toJson());
      recovered.dispose();
      final output = Directory('docs/schemas/examples');
      final entityPlaintexts = [
        for (final entry in entities.entries)
          {'logicalId': entry.key, 'payload': entry.value},
        // Null payload is the existing authenticated deletion representation.
        for (final prefix in ['h', 'r', 'p', 'n'])
          {
            'logicalId': entities.keys.firstWhere(
              (key) => key.startsWith('$prefix/'),
            ),
            'payload': null,
          },
      ];
      for (final entry in {
        'sync-keyring-v1.json': keys.toJson(),
        'sync-recovery-v1.json': jsonDecode(utf8.decode(recoveryBytes)),
        'sync-encrypted-object-v1.json': envelope,
        'sync-decrypted-object-v1.json': plaintext,
        'sync-entity-plaintexts-v1.json': entityPlaintexts,
        'sync-object-context-v1.json': {
          'vault': context.vault,
          'epoch': context.epoch,
          'entityId': context.entityId,
          'baseRevision': context.baseRevision,
          'deleted': context.deleted,
        },
        // The schema's wireString is an annotation contract; tests decode this
        // actual codec return value explicitly before checking its JSON envelope.
        'sync-wire-string-v1.json': wire,
      }.entries) {
        await File('${output.path}/${entry.key}').writeAsString(
          '${const JsonEncoder.withIndent('  ').convert(entry.value)}\n',
        );
      }
    },
  );
}
