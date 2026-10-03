import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/services/webdav_client.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/legacy_restore_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'schema_upgrade_test.dart' show createV1;
import 'support/legacy_fixture.dart';

final _today = DateTime(2026, 10, 3);
const _vault = '8a77bd3f-9086-42b5-a9eb-fc5f294c6549';
const _password = 'public synthetic import test backup phrase';

String _input({int titleLength = 80, int noteLength = 2000}) {
  final document = jsonDecode(legacyFixture(_today)) as Map<String, dynamic>;
  document['vaultId'] = _vault;
  final habit = (document['habits'] as List).first as Map;
  habit['title'] = '名' * titleLength;
  habit['notes'] = {'2026-10-02': '注' * noteLength};
  // Future metadata is not the user's note and must retain compatibility.
  habit['futureMetadata'] = {'text': '扩' * 2001};
  return jsonEncode(document);
}

class _ProtectingRepository extends MemoryHabitRepository {
  bool failProtection = false;
  int replacements = 0;

  @override
  Future<void> replace(String value) async {
    replacements++;
    if (failProtection) throw const FileSystemException('protect failed');
    await super.replace(value);
  }
}

void main() {
  for (final lengths in [(1, 0), (80, 2000)]) {
    test(
      'external preview accepts title ${lengths.$1}, note ${lengths.$2}',
      () {
        final raw = _input(titleLength: lengths.$1, noteLength: lengths.$2);
        final decoded = SnapshotCodec.decodeImport(raw);
        expect(jsonEncode(decoded), raw);
        expect(BackupPreview.fromSnapshot(raw).habits, 3);
        expect(decoded['habits'], jsonDecode(raw)['habits']);
      },
    );
  }

  for (final lengths in [(81, 2000), (80, 2001)]) {
    test(
      'external import rejects ${lengths.$1}/${lengths.$2} before protection',
      () async {
        final repository = _ProtectingRepository();
        final controller = HabitController(repository, clock: () => _today);
        addTearDown(controller.dispose);
        await controller.load();
        final before = controller.exportJson();
        final disk = repository.value;
        final backup = repository.backupValue;
        final raw = _input(titleLength: lengths.$1, noteLength: lengths.$2);
        expect(() => SnapshotCodec.decodeImport(raw), throwsFormatException);
        expect(() => BackupPreview.fromSnapshot(raw), throwsFormatException);
        expect(await controller.importJson(raw), isFalse);
        expect(controller.exportJson(), before);
        expect(repository.value, disk);
        expect(repository.backupValue, backup);
        expect(repository.protectedSources, isEmpty);
        expect(repository.replacements, 0);
        expect(raw, _input(titleLength: lengths.$1, noteLength: lengths.$2));
      },
    );
  }

  test(
    'accepted import protects the original facts and never truncates input',
    () async {
      final repository = _ProtectingRepository();
      final controller = HabitController(repository, clock: () => _today);
      addTearDown(controller.dispose);
      await controller.load();
      final before = repository.value;
      final raw = _input();
      repository.failProtection = true;
      expect(await controller.importJson(raw), isFalse);
      expect(repository.value, before);
      expect(repository.protectedSources, isEmpty);
      repository.failProtection = false;
      expect(await controller.importJson(raw), isTrue);
      expect(repository.protectedSources.single, before);
      expect(controller.habits.first.title, '名' * 80);
      expect(controller.habits.first.notes['2026-10-02'], '注' * 2000);
      expect(controller.habits.first.extensions['futureMetadata'], {
        'text': '扩' * 2001,
      });
      expect(raw, _input());
    },
  );

  test(
    'old preferences migrate and reopen with 1000/2001 facts intact',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'hgw-import-local-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/data.sqlite');
      final raw = _input(titleLength: 1000, noteLength: 2001);
      final legacy = MemoryHabitRepository(raw);
      final repository = SqliteHabitRepository(
        HabitDatabase(NativeDatabase(file)),
        legacy: legacy,
      );
      final controller = HabitController(repository, clock: () => _today);
      await controller.load();
      expect(controller.loaded, isTrue);
      expect(controller.habits.first.title, '名' * 1000);
      expect(controller.habits.first.notes['2026-10-02'], '注' * 2001);
      expect(legacy.value, raw);
      expect((await repository.rawSources())['legacy-primary'], raw);
      expect(await controller.setDarkMode(true), isTrue);
      final exported = controller.exportJson();
      final encoded = SyncEntities.encode(exported);
      expect(encoded['h/seed-reading']['title'], '名' * 1000);
      expect(
        encoded.values.whereType<Map>().singleWhere(
          (v) => v['text'] != null,
        )['text'],
        '注' * 2001,
      );
      expect(
        SyncEntities.encode(SyncEntities.assemble(exported, encoded)),
        encoded,
      );
      controller.dispose();
      await repository.close();
      final reopened = SqliteHabitRepository(
        HabitDatabase(NativeDatabase(file)),
      );
      final next = HabitController(reopened, clock: () => _today);
      try {
        await next.load();
        expect(next.loaded, isTrue);
        expect(jsonDecode(next.exportJson()), jsonDecode(exported));
        final frame = await reopened.readSyncFrame();
        final protections = await reopened.database
            .customSelect('SELECT COUNT(*) AS n FROM protections')
            .getSingle();
        final changes = await reopened.database
            .customSelect('SELECT COUNT(*) AS n FROM local_changes')
            .getSingle();
        expect(await next.importJson(raw), isFalse);
        final after = await reopened.readSyncFrame();
        expect(after.snapshot, frame.snapshot);
        expect(after.businessRevision, frame.businessRevision);
        expect(
          (await reopened.database
                  .customSelect('SELECT COUNT(*) AS n FROM protections')
                  .getSingle())
              .data,
          protections.data,
        );
        expect(
          (await reopened.database
                  .customSelect('SELECT COUNT(*) AS n FROM local_changes')
                  .getSingle())
              .data,
          changes.data,
        );
      } finally {
        next.dispose();
        await reopened.close();
      }
    },
  );

  test(
    'schema 1 migration and local protection recovery keep oversized legacy facts',
    () async {
      final directory = await Directory.systemTemp.createTemp('hgw-import-v1-');
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/data.sqlite');
      final raw = _input(titleLength: 1000, noteLength: 2001);
      createV1(file, raw);
      final repository = SqliteHabitRepository(
        HabitDatabase(NativeDatabase(file)),
      );
      final controller = HabitController(repository, clock: () => _today);
      try {
        await controller.load();
        expect(controller.loaded, isTrue);
        expect(controller.habits.first.title, '名' * 1000);
        expect(controller.habits.first.notes['2026-10-02'], '注' * 2001);
        expect(jsonDecode((await repository.loadBackup())!), jsonDecode(raw));
      } finally {
        controller.dispose();
        await repository.close();
      }
      final recoveryRepository = MemoryHabitRepository(null, raw);
      final recovery = HabitController(recoveryRepository, clock: () => _today);
      addTearDown(recovery.dispose);
      await recovery.load();
      expect(recovery.canRecoverBackup, isTrue);
      expect(await recovery.recoverBackup(), isTrue);
      expect(recovery.habits.first.title, '名' * 1000);
      expect(recovery.habits.first.notes['2026-10-02'], '注' * 2001);
    },
  );

  test(
    'encrypted export stays lossless; file and WebDAV restore previews apply input limits',
    () async {
      final source = _input(titleLength: 1000, noteLength: 2001);
      final bytes = await BackupCodec.encryptHere(source, _password);
      final contents = await BackupCodec.decryptWithMetadata(bytes, _password);
      expect(jsonDecode(contents.snapshot), jsonDecode(source));
      expect(
        () => BackupPreview.fromSnapshot(contents.snapshot),
        throwsFormatException,
      );
      final client = WebDavClient(
        'https://example.test/backups/',
        'testuser',
        'public synthetic credential',
        client: MockClient((request) async => http.Response.bytes(bytes, 200)),
      );
      addTearDown(client.close);
      final item = RemoteBackup(
        vault: _vault,
        device: '23eb0dd1-845e-4430-b01b-c945b7897f42',
        id: 'f54e7800-9d65-47c1-8a8c-d356b5882201',
        created: _today.toUtc(),
        digest: sha256.convert(bytes).toString(),
        size: bytes.length,
      );
      final downloaded = await client.restore(item, _password);
      expect(jsonDecode(downloaded), jsonDecode(source));
      expect(
        () => BackupPreview.fromSnapshot(downloaded),
        throwsFormatException,
      );
      final targetRepository = MemoryHabitRepository();
      final target = HabitController(targetRepository, clock: () => _today);
      addTearDown(target.dispose);
      await target.load();
      final before = targetRepository.value;
      expect(await target.importJson(downloaded), isFalse);
      expect(targetRepository.value, before);
      expect(targetRepository.protectedSources, isEmpty);
    },
  );

  for (final lengths in [(81, 2000), (80, 2001)]) {
    testWidgets(
      'paste ${lengths.$1}/${lengths.$2} requires confirmation and retains the draft',
      (tester) async {
        final repository = _ProtectingRepository();
        final controller = HabitController(repository, clock: () => _today);
        addTearDown(controller.dispose);
        await controller.load();
        final before = repository.value;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => showLegacyRestoreDialog(context, controller),
                  child: const Text('open'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('open'));
        await tester.pumpAndSettle();
        final input = find.byKey(const Key('legacy-json-field'));
        final raw = _input(titleLength: lengths.$1, noteLength: lengths.$2);
        await tester.enterText(input, raw);
        await tester.tap(find.byKey(const Key('preview-legacy-json-button')));
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('restore-legacy-text-summary')),
          findsOneWidget,
        );
        expect(find.text('恢复预览'), findsOneWidget);
        expect(
          tester
              .widget<CheckboxListTile>(
                find.byKey(const Key('restore-preserve-legacy-text')),
              )
              .value,
          isFalse,
        );
        expect(
          tester
              .widget<FilledButton>(
                find.byKey(const Key('confirm-restore-button')),
              )
              .onPressed,
          isNull,
        );
        await tester.tap(find.widgetWithText(TextButton, '取消').last);
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(input).controller!.text, raw);
        expect(repository.value, before);
        expect(repository.replacements, 0);
        expect(repository.protectedSources, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
