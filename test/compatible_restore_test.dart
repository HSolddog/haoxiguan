import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/services/data_status.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/services/webdav_client.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/backup_restore_dialog.dart';
import 'package:haoxiguan/ui/data_screen.dart';
import 'package:haoxiguan/ui/legacy_restore_dialog.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'support/legacy_fixture.dart';

final _today = DateTime(2026, 10, 3);
const _vault = '8a77bd3f-9086-42b5-a9eb-fc5f294c6549';
const _password = 'public synthetic compatible restore test phrase';

String _legacy({int titleLength = 1000, int noteLength = 2001}) {
  final document = jsonDecode(legacyFixture(_today)) as Map<String, dynamic>;
  document['vaultId'] = _vault;
  final habit = (document['habits'] as List).first as Map;
  habit['title'] = '名' * titleLength;
  habit['notes'] = {'2026-10-02': '注' * noteLength};
  habit['futureMetadata'] = {
    'keep': ['完整', 7],
  };
  return jsonEncode(document);
}

Future<String> _snapshot(int version) async {
  if (version == 5) return _legacy();
  final controller = HabitController(
    MemoryHabitRepository(_legacy()),
    clock: () => _today,
  );
  try {
    await controller.load();
    expect(controller.loaded, isTrue);
    final exported = controller.exportJson();
    expect(jsonDecode(exported)['version'], 7);
    return exported;
  } finally {
    controller.dispose();
  }
}

class _GuardedRepository extends MemoryHabitRepository {
  bool failProtection = false;
  int replacements = 0;
  @override
  Future<void> replace(String value) async {
    replacements++;
    if (failProtection) throw const FileSystemException('protect failed');
    await super.replace(value);
  }
}

class _Files implements BackupFiles {
  _Files(this.bytes);
  final Uint8List bytes;
  int opens = 0;
  @override
  Future<Uint8List?> open() async {
    opens++;
    return bytes;
  }

  @override
  Future<bool> save(Uint8List bytes, String name) async => true;
}

class _Status extends DataStatusReader {
  @override
  Future<DataServiceStatus> read(String snapshot) async =>
      const DataServiceStatus(backup: '未配置', sync: '未连接');
}

Future<HabitController> _target(HabitRepository repository) async {
  final controller = HabitController(repository, clock: () => _today);
  await controller.load();
  expect(
    await controller.addHabit(
      title: '恢复前的本机事实',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    ),
    isTrue,
  );
  return controller;
}

Future<void> _openFileRestore(WidgetTester tester) async {
  final entry = find.text('从文件恢复');
  await tester.scrollUntilVisible(
    entry,
    300,
    scrollable: find.descendant(
      of: find.byKey(const PageStorageKey<String>('data-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

Future<void> _decryptFile(WidgetTester tester) async {
  await tester.enterText(find.byType(TextField).first, _password);
  await tester.tap(find.widgetWithText(FilledButton, '继续'));
  // Real native crypto runs outside the fake widget clock.
  for (var attempt = 0; attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
    if (find.byType(BackupRestoreDialog).evaluate().isNotEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  fail('Encrypted restore did not reach the preview');
}

Future<void> _recordSqlEvidence(
  int sourceVersion,
  SqliteHabitRepository repository,
  EntityMap expectedFacts,
) async {
  final habit = await repository.database
      .customSelect("SELECT payload FROM habits WHERE id='seed-reading'")
      .getSingle();
  final title =
      (jsonDecode(habit.read<String>('payload')) as Map)['title'] as String;
  final note = await repository.database
      .customSelect(
        "SELECT content FROM daily_notes WHERE habit_id='seed-reading' AND local_date='2026-10-02'",
      )
      .getSingle();
  final notes = note.read<String>('content');
  expect(title, '名' * 1000);
  expect(notes, '注' * 2001);
  final counts = <String, int>{};
  for (final table in [
    'habits',
    'records',
    'plans',
    'daily_notes',
    'protections',
  ]) {
    counts[table] =
        (await repository.database
                .customSelect('SELECT COUNT(*) AS n FROM $table')
                .getSingle())
            .read<int>('n');
  }
  expect(counts['habits'], 3);
  expect(counts['protections'], 1);
  final version =
      (await repository.database
              .customSelect('PRAGMA user_version')
              .getSingle())
          .data
          .values
          .single;
  expect(version, 3);
  final destination = Platform.environment['HG_COMPAT_SQL_EVIDENCE_PATH'];
  if (destination == null) return;
  final file = File(destination);
  final evidence = await file.exists()
      ? jsonDecode(await file.readAsString()) as List
      : <dynamic>[];
  evidence.add({
    'sourceLogicalVersion': sourceVersion,
    'reopenedSqliteSchemaVersion': version,
    'rowCounts': counts,
    'storedTitleChars': title.length,
    'storedNoteChars': notes.length,
    'expectedCanonicalFactsSha256': sha256
        .convert(utf8.encode(SyncEntities.canonical(expectedFacts)))
        .toString(),
    'reopenedCanonicalFactsSha256': sha256
        .convert(
          utf8.encode(
            SyncEntities.canonical(
              SyncEntities.encodeFacts(
                (await repository.readSyncFrame()).snapshot,
              ),
            ),
          ),
        )
        .toString(),
    'originalSnapshotProtected': true,
    'ordinaryImportRejectedBeforeReplacement': true,
  });
  await file.writeAsString(
    '${const JsonEncoder.withIndent('  ').convert(evidence)}\n',
    flush: true,
  );
}

void main() {
  test(
    'restore preview reports only oversized facts; ordinary import remains strict',
    () {
      final raw = _legacy();
      expect(() => SnapshotCodec.decodeImport(raw), throwsFormatException);
      expect(() => BackupPreview.fromSnapshot(raw), throwsFormatException);
      final preview = BackupPreview.forRestore(raw);
      expect(preview.requiresCompatibilityConfirmation, isTrue);
      expect(preview.oversizedTitles, 1);
      expect(preview.longestTitle, 1000);
      expect(preview.oversizedNotes, 1);
      expect(preview.longestNote, 2001);
      expect(preview.habits, 3);
      expect(preview.compatibilitySummary, contains('最长 1000'));
      expect(preview.compatibilitySummary, contains('最长 2001'));
      expect(
        BackupPreview.forRestore(
          _legacy(titleLength: 80, noteLength: 2000),
        ).requiresCompatibilityConfirmation,
        isFalse,
      );
      expect(raw, _legacy());
    },
  );

  for (final version in [5, 7]) {
    test(
      'compatible version $version restores old text into a fresh SQLite installation and reopens intact',
      () async {
        final raw = await _snapshot(version);
        final expectedFacts = SyncEntities.encodeFacts(
          version == 7 ? raw : await _snapshot(7),
        );
        final directory = await Directory.systemTemp.createTemp(
          'hgw-compatible-restore-',
        );
        addTearDown(() => directory.delete(recursive: true));
        final file = File('${directory.path}/data.sqlite');
        final repository = SqliteHabitRepository(
          HabitDatabase(NativeDatabase(file)),
        );
        final controller = await _target(repository);
        late String exported;
        try {
          final before = (await repository.readSyncFrame()).snapshot;
          expect(await controller.importJson(raw), isFalse);
          expect(await repository.loadBackup(), isNull);
          expect(await controller.restoreCompatibleBackup(raw), isTrue);
          expect(controller.habits.first.title, '名' * 1000);
          expect(controller.habits.first.notes['2026-10-02'], '注' * 2001);
          expect(controller.habits.first.extensions['futureMetadata'], {
            'keep': ['完整', 7],
          });
          exported = controller.exportJson();
          expect(jsonDecode(exported)['vaultId'], isNot(_vault));
          expect(jsonDecode(exported)['restoredFromVaultId'], _vault);
          expect(
            jsonDecode((await repository.loadBackup())!),
            jsonDecode(before),
          );
          expect(SyncEntities.encodeFacts(exported), expectedFacts);
        } finally {
          controller.dispose();
          await repository.close();
        }
        final reopened = SqliteHabitRepository(
          HabitDatabase(NativeDatabase(file)),
        );
        final next = HabitController(reopened, clock: () => _today);
        try {
          await next.load();
          expect(next.loaded, isTrue);
          expect(
            SyncEntities.encodeFacts(next.exportJson()),
            SyncEntities.encodeFacts(exported),
          );
          await _recordSqlEvidence(version, reopened, expectedFacts);
          expect(
            await next.setNote('seed-reading', _today, '注' * 2001),
            isFalse,
          );
          expect(next.habits.first.notes['2026-10-02'], '注' * 2001);
          expect(await next.setNote('seed-reading', _today, '新备注'), isTrue);
          expect(next.habits.first.notes['2026-10-02'], '注' * 2001);
        } finally {
          next.dispose();
          await reopened.close();
        }
      },
    );
  }

  test(
    'compatible restore cannot bypass structure, date, duplicate ID or future version validation',
    () async {
      final repository = _GuardedRepository();
      final controller = await _target(repository);
      addTearDown(controller.dispose);
      final before = repository.value;
      for (final invalid in [
        'long-title',
        'date',
        'duplicate-id',
        'future-version',
        'note-type',
      ]) {
        final document = jsonDecode(_legacy()) as Map<String, dynamic>;
        final habits = document['habits'] as List;
        switch (invalid) {
          case 'long-title':
            habits.first['title'] = '名' * 1001;
          case 'date':
            habits.first['notes'] = {'2026-02-30': '原文'};
          case 'duplicate-id':
            habits[1]['id'] = habits.first['id'];
          case 'future-version':
            document['version'] = 999;
          case 'note-type':
            habits.first['notes'] = {'2026-10-02': 123};
        }
        final raw = jsonEncode(document);
        expect(() => BackupPreview.forRestore(raw), throwsA(isA<Object>()));
        expect(await controller.restoreCompatibleBackup(raw), isFalse);
        expect(repository.value, before);
        expect(repository.protectedSources, isEmpty);
        expect(repository.replacements, 0);
      }
    },
  );

  test(
    'authenticated encrypted and WebDAV snapshots preserve oversized text for explicit restore',
    () async {
      final raw = await _snapshot(7);
      final bytes = await BackupCodec.encryptHere(raw, _password);
      final contents = await BackupCodec.decryptWithMetadata(bytes, _password);
      expect(jsonDecode(contents.snapshot), jsonDecode(raw));
      expect(
        BackupPreview.forRestore(
          contents.snapshot,
        ).requiresCompatibilityConfirmation,
        isTrue,
      );
      await expectLater(
        BackupCodec.decryptWithMetadata(bytes, 'wrong password'),
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
      final repository = _GuardedRepository();
      final controller = await _target(repository);
      addTearDown(controller.dispose);
      final before = repository.value;
      final preview = BackupPreview.forRestore(downloaded);
      expect(preview.requiresCompatibilityConfirmation, isTrue);
      expect(repository.value, before);
      expect(await controller.importJson(downloaded), isFalse);
      expect(repository.protectedSources, isEmpty);
      expect(await controller.restoreCompatibleBackup(downloaded), isTrue);
      expect(
        SyncEntities.encodeFacts(controller.exportJson()),
        SyncEntities.encodeFacts(raw),
      );
      expect(repository.protectedSources.single, before);
    },
  );

  for (final format in ['json', 'plaintext-envelope', 'encrypted']) {
    testWidgets(
      '$format restore requires explicit selection; cancel and full restore preserve every fact',
      (tester) async {
        final raw = await _snapshot(7);
        final bytes = format == 'encrypted'
            ? (await tester.runAsync(
                () => BackupCodec.encryptHere(raw, _password),
              ))!
            : Uint8List.fromList(
                utf8.encode(
                  format == 'json'
                      ? raw
                      : jsonEncode({
                          'format': BackupCodec.format,
                          'formatVersion': 1,
                          'encrypted': false,
                          'data': jsonDecode(raw),
                        }),
                ),
              );
        final files = _Files(bytes);
        final repository = _GuardedRepository();
        final controller = await _target(repository);
        addTearDown(controller.dispose);
        final before = repository.value;
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
        Future<void> open() async {
          await _openFileRestore(tester);
          if (format == 'encrypted') await _decryptFile(tester);
        }

        await open();
        final checkbox = find.byKey(const Key('restore-preserve-legacy-text'));
        final confirm = find.byKey(const Key('confirm-restore-button'));
        expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        expect(repository.value, before);
        expect(repository.replacements, 0);
        await tester.tap(find.widgetWithText(TextButton, '取消').last);
        await tester.pumpAndSettle();
        expect(repository.value, before);
        expect(files.bytes, bytes);
        await open();
        expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
        await tester.ensureVisible(checkbox);
        await tester.tap(checkbox);
        await tester.pumpAndSettle();
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await tester.pumpAndSettle();
        expect(find.byType(BackupRestoreDialog), findsNothing);
        expect(
          SyncEntities.encodeFacts(controller.exportJson()),
          SyncEntities.encodeFacts(raw),
        );
        expect(repository.protectedSources.single, before);
        expect(files.opens, 2);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    '200% paste restore keeps confirmation, full draft and original data after protection failure',
    (tester) async {
      tester.view.physicalSize = const Size(360, 800);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.textScaleFactorTestValue = 2;
      addTearDown(() {
        tester.view.resetPhysicalSize();
        tester.view.resetDevicePixelRatio();
        tester.platformDispatcher.clearTextScaleFactorTestValue();
      });
      final raw = _legacy();
      final repository = _GuardedRepository();
      final controller = await _target(repository);
      addTearDown(controller.dispose);
      final before = repository.value;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => showLegacyRestoreDialog(context, controller),
                child: const Text('paste'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('paste'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const Key('legacy-json-field')), raw);
      final preview = find.byKey(const Key('preview-legacy-json-button'));
      await tester.ensureVisible(preview);
      await tester.tap(preview);
      await tester.pumpAndSettle();
      final checkbox = find.byKey(const Key('restore-preserve-legacy-text'));
      final confirm = find.byKey(const Key('confirm-restore-button'));
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      repository.failProtection = true;
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('restore-error')), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
      expect(
        tester
            .widget<TextField>(
              find.byKey(const Key('legacy-json-field'), skipOffstage: false),
            )
            .controller!
            .text,
        raw,
      );
      expect(repository.value, before);
      expect(repository.protectedSources, isEmpty);
      repository.failProtection = false;
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await tester.pumpAndSettle();
      expect(find.byType(BackupRestoreDialog), findsNothing);
      expect(find.byKey(const Key('legacy-json-field')), findsNothing);
      expect(controller.habits.first.title, '名' * 1000);
      expect(controller.habits.first.notes['2026-10-02'], '注' * 2001);
      expect(repository.protectedSources.single, before);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
