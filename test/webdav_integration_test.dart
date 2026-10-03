import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/io_client.dart';
import 'package:uuid/uuid.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/services/webdav_client.dart';
import 'package:haoxiguan/state/habit_controller.dart';

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
    '真实 TLS WebDAV：上传读回、跨设备恢复、完整元信息预览与保护原库',
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
      final source = HabitController(
        MemoryHabitRepository(),
        clock: () => DateTime(2026, 10, 3),
      );
      final targetRepository = MemoryHabitRepository();
      final target = HabitController(
        targetRepository,
        clock: () => DateTime(2026, 10, 3),
      );
      addTearDown(source.dispose);
      addTearDown(target.dispose);
      await source.load();
      await target.load();
      expect(
        await source.addHabit(
          title: '真实服务中的喝水记录',
          emoji: '💧',
          colorValue: 0xff5f8068,
          weekdays: {1, 2, 3, 4, 5, 6, 7},
          recordType: 'count',
          unit: '杯',
          scale: 1000,
          dailyTarget: 8000,
          startDate: DateTime(2026, 9, 1),
        ),
        isTrue,
      );
      final habitId = source.habits.single.id;
      await source.addValue(habitId, DateTime(2026, 9, 1), 1000);
      final withdrawn = source.habits.single.entries.single.id;
      await source.deleteEntry(habitId, withdrawn);
      await source.addValue(habitId, DateTime(2026, 10, 2), 2000);
      await source.addValue(habitId, DateTime(2026, 10, 3), 1000);
      await source.setNote(habitId, DateTime(2026, 10, 1), '跨设备仍保留的备注');
      await target.addHabit(
        title: '恢复前本机原有习惯',
        emoji: '🌱',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
      );
      final targetBefore = targetRepository.value;
      final raw = source.exportJson();
      final vault = SnapshotCodec.decode(raw)['vaultId']! as String;
      final device = const Uuid().v4();
      try {
        final item = await client.upload(raw, password, vault, device);
        final listed = await client.list(vault);
        expect(listed.map((b) => b.id), contains(item.id));
        final restoredItem = listed.singleWhere((b) => b.id == item.id);
        expect(restoredItem.created, item.created);
        final restoredRaw = await client.restore(restoredItem, password);
        expect(jsonDecode(restoredRaw), jsonDecode(raw));

        // Match the production WebDavScreen preview path, using metadata read
        // from the real completion marker and facts from decrypted remote bytes.
        final preview = BackupPreview.fromSnapshot(
          restoredRaw,
          createdAtUtc: restoredItem.created.toUtc(),
        );
        expect(preview.createdAtUtc, item.created);
        expect(preview.habits, 1);
        expect(preview.records, 2);
        expect(preview.notes, 1);
        expect(preview.deletedRecords, 1);
        expect(preview.firstDate, '2026-10-01');
        expect(preview.lastDate, '2026-10-03');
        expect(preview.summary, contains('1 个习惯 · 2 条记录 · 1 条备注'));
        expect(preview.summary, contains('另含 1 条已撤销记录'));

        // Also read the new authenticated manifest metadata through real TLS.
        final download = await client.request(
          'GET',
          '${restoredItem.relativePath}.hgb',
          maxBytes: BackupCodec.maxFileBytes,
          allowed: {200},
        );
        final contents = await BackupCodec.decryptWithMetadata(
          download.bytes,
          password,
        );
        expect(contents.createdAtUtc, isNotNull);
        expect(contents.createdAtUtc!.isUtc, isTrue);
        expect(jsonDecode(contents.snapshot), jsonDecode(restoredRaw));
        // Merely reviewing or abandoning a preview never imports into the target.
        expect(targetRepository.value, targetBefore);
        expect(targetRepository.protectedSources, isEmpty);
        await expectLater(
          client.restore(restoredItem, 'wrong synthetic recovery password'),
          throwsFormatException,
        );
        expect(targetRepository.value, targetBefore);
        expect(await target.importJson(restoredRaw), isTrue);
        expect(targetRepository.protectedSources, contains(targetBefore));
        expect(target.habits.single.toJson(), source.habits.single.toJson());
        expect(
          SnapshotCodec.decode(target.exportJson())['vaultId'],
          isNot(vault),
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
