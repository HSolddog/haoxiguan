// Run explicitly: flutter test --no-pub tools/generate_schema_examples_test.dart
// Only synthetic examples are written; normal `flutter test` does not regenerate
// the checked-in contract examples.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/services/data_status.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/data_screen.dart';
import 'package:sodium/sodium_sumo.dart';

import '../test/support/legacy_fixture.dart';

void main() {
  testWidgets('generate contracts from real exporters and decrypted bytes', (
    tester,
  ) async {
    final now = DateTime(2026, 10, 3);
    final legacy = jsonDecode(legacyFixture(now)) as Map<String, dynamic>;
    legacy['externalAppNote'] = {'label': 'synthetic preserved root extension'};
    (legacy['habits'] as List).first['externalAppNote'] =
        'synthetic habit field';
    final controller = HabitController(
      MemoryHabitRepository(jsonEncode(legacy)),
      clock: () => now,
      timezoneId: () => 'Asia/Shanghai',
    );
    addTearDown(controller.dispose);
    await controller.load();
    for (final kind in ['count', 'duration']) {
      expect(
        await controller.addHabit(
          title: '合成契约样例 $kind',
          emoji: '🌱',
          colorValue: 0xff5f8068,
          weekdays: {1, 2, 3, 4, 5, 6, 7},
          startDate: DateTime(2026, 9, 1),
          category: '合成分类',
          recordType: kind,
          unit: kind == 'count' ? '杯' : '秒',
          scale: kind == 'count' ? 1000 : 1,
          dailyTarget: kind == 'count' ? 8000 : 1200,
          scheduleType: kind == 'count' ? 'week' : 'month',
          scheduleCount: kind == 'count' ? 3 : 20,
        ),
        isTrue,
      );
      final habit = controller.habits.last;
      expect(await controller.addValue(habit.id, now, 1500), isTrue);
      expect(await controller.setNote(habit.id, now, '合成备注，真实导出'), isTrue);
    }
    final snapshot = jsonDecode(controller.exportJson());
    final files = _CaptureFiles();
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: DataScreen(
            controller: controller,
            files: files,
            statusReader: _Status(),
            onTheme: () {},
            onReview: () {},
            onLegacyRestore: () {},
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    await tester.scrollUntilVisible(
      find.text('导出可读 JSON'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(find.text('导出可读 JSON'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('导出明文'));
    await tester.pumpAndSettle();
    expect(files.saved, isNotNull);
    final plaintext = jsonDecode(utf8.decode(files.saved!)) as Map;
    expect(plaintext['data'], snapshot);
    const password = 'public synthetic contract sample password';
    late Map<String, dynamic> envelope;
    late Object? inner;
    await tester.runAsync(() async {
      final encrypted = await BackupCodec.encryptHere(
        controller.exportJson(),
        password,
      );
      final contents = await BackupCodec.decryptHereWithMetadata(
        encrypted,
        password,
      );
      expect(jsonDecode(contents.snapshot), snapshot);
      envelope = jsonDecode(utf8.decode(encrypted)) as Map<String, dynamic>;
      final crypto = envelope['crypto'] as Map;
      final sodium = await SodiumSumoInit.init();
      final key = sodium.crypto.pwhash(
        outLen: 32,
        password: Int8List.fromList(utf8.encode(password)),
        salt: base64Decode(crypto['salt'] as String),
        opsLimit: BackupCodec.iterations,
        memLimit: BackupCodec.memoryKiB * 1024,
        alg: CryptoPwhashAlgorithm.argon2id13,
      );
      try {
        final decoded = sodium.crypto.aeadXChaCha20Poly1305IETF.decrypt(
          cipherText: base64Decode(envelope['payload'] as String),
          nonce: base64Decode(crypto['nonce'] as String),
          key: key,
          additionalData: BackupCodec.associatedData(envelope),
        );
        inner = jsonDecode(utf8.decode(decoded));
        expect((inner as Map)['data'], snapshot);
        final out = Directory('docs/schemas/examples');
        await out.create(recursive: true);
        for (final example in {
          'logical-snapshot-v7.json': snapshot,
          'backup-plaintext-v1.json': plaintext,
          'backup-encrypted-v1.json': envelope,
          'backup-decrypted-v1.json': inner,
        }.entries) {
          await File('${out.path}/${example.key}').writeAsString(
            '${const JsonEncoder.withIndent('  ').convert(example.value)}\n',
          );
        }
      } finally {
        key.dispose();
      }
    });
    expect(tester.takeException(), isNull);
  });
}

class _CaptureFiles implements BackupFiles {
  Uint8List? saved;
  @override
  Future<bool> save(Uint8List bytes, String name) async {
    saved = Uint8List.fromList(bytes);
    return true;
  }

  @override
  Future<Uint8List?> open() async => null;
}

class _Status extends DataStatusReader {
  @override
  Future<DataServiceStatus> read(String snapshot) async =>
      const DataServiceStatus(backup: '未配置', sync: '未配置');
  @override
  Future<void> recordFileBackup(String snapshot, String name) async {}
}
