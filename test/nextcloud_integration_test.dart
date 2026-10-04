import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/services/webdav_client.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/backup_restore_dialog.dart';
import 'package:http/io_client.dart';
import 'package:uuid/uuid.dart';

import '../tools/android_acceptance.dart'
    show canonical, nativeDatabaseEvidence;
import 'support/legacy_fixture.dart';

const _endpoint = String.fromEnvironment('TEST_DAV_ENDPOINT');
const _cert = String.fromEnvironment('TEST_DAV_CERT');
const _user = String.fromEnvironment('TEST_DAV_USER', defaultValue: 'testuser');
const _credential = String.fromEnvironment(
  'TEST_DAV_PASSWORD',
  defaultValue: 'public-synthetic-test-password',
);
const _password = 'public synthetic Nextcloud recovery phrase';
final _today = DateTime(2026, 10, 3);
const _skip = _endpoint == '' || _cert == '';

class _NextcloudTestBinding extends AutomatedTestWidgetsFlutterBinding {
  // Only this explicitly configured integration file uses real HTTP. TLS trust
  // stays scoped to _client's SecurityContext; no bad-certificate callback.
  @override
  bool get overrideHttpClient => false;
}

WebDavClient _client() {
  final context = SecurityContext(withTrustedRoots: true);
  context.setTrustedCertificates(_cert);
  return WebDavClient(
    _endpoint,
    _user,
    _credential,
    client: IOClient(HttpClient(context: context)),
  );
}

Future<String> _source(bool compatibility) async {
  final legacy = jsonDecode(legacyFixture(_today)) as Map<String, dynamic>;
  legacy['vaultId'] = const Uuid().v4();
  legacy['nextcloudSyntheticMetadata'] = {
    'retained': ['complete source extension', 7],
  };
  final habit = (legacy['habits'] as List).first as Map;
  habit['title'] = compatibility ? 'L' * 1000 : 'synthetic remote reading';
  habit['notes'] = {
    '2026-10-02': compatibility ? 'N' * 2001 : 'synthetic remote note',
  };
  habit['futureMetadata'] = {
    'retained': ['complete habit extension', 7],
  };
  final controller = HabitController(
    MemoryHabitRepository(jsonEncode(legacy)),
    clock: () => _today,
  );
  try {
    await controller.load();
    expect(controller.loaded, isTrue);
    final raw = controller.exportJson();
    expect(jsonDecode(raw)['version'], 7);
    return raw;
  } finally {
    controller.dispose();
  }
}

Future<({SqliteHabitRepository repository, HabitController controller})> _open(
  File file,
) async {
  final repository = SqliteHabitRepository(HabitDatabase(NativeDatabase(file)));
  final controller = HabitController(repository, clock: () => _today);
  await controller.load();
  expect(controller.loaded, isTrue);
  return (repository: repository, controller: controller);
}

Future<Directory> _directory(String scenario) async {
  final configured = Platform.environment['HAOXIGUAN_NEXTCLOUD_EVIDENCE'];
  if (configured == null) {
    return Directory.systemTemp.createTemp('haoxiguan-nextcloud-$scenario-');
  }
  final root = Directory(configured);
  await root.create(recursive: true);
  return root.createTemp('$scenario-');
}

Future<void> _writeEvidence(
  Directory directory,
  Map<String, Object?> evidence,
) => File('${directory.path}/evidence.json').writeAsString(
  const JsonEncoder.withIndent('  ').convert(evidence),
  flush: true,
);

Future<bool?> _waitDialog(WidgetTester tester, Future<bool?> result) async {
  var completed = false;
  bool? outcome;
  result.then((value) {
    outcome = value;
    completed = true;
  });
  for (var attempt = 0; attempt < 100 && !completed; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    expect(find.byKey(const Key('restore-error')), findsNothing);
  }
  await tester.pumpAndSettle();
  expect(completed, isTrue, reason: 'SQLite restore must complete within 5s');
  return outcome;
}

void main() {
  if (!_skip) _NextcloudTestBinding();
  for (final compatibility in [false, true]) {
    final scenario = compatibility ? 'compatible-text' : 'ordinary';
    testWidgets(
      'Nextcloud $scenario download, preview cancellation, SQLite protection and reopen',
      (tester) async {
        late Directory directory;
        late File targetFile;
        late SqliteHabitRepository repository;
        late HabitController controller;
        late WebDavClient client;
        late RemoteBackup remote;
        late String sourceRaw;
        late String downloaded;
        late String beforeController;
        late BackupPreview preview;
        late Map<String, Object?> before;
        final evidence = <String, Object?>{'scenario': scenario};
        await tester.runAsync(() async {
          directory = await _directory(scenario);
          targetFile = File('${directory.path}/target.sqlite');
          final target = await _open(targetFile);
          repository = target.repository;
          controller = target.controller;
          expect(
            await controller.addHabit(
              title: 'synthetic target before restore',
              emoji: 'S',
              colorValue: 0xff5f8068,
              weekdays: {1, 2, 3, 4, 5, 6, 7},
            ),
            isTrue,
          );
          expect(
            await controller.setNote(
              controller.habits.single.id,
              _today,
              'the protected SQLite snapshot must preserve this note',
            ),
            isTrue,
          );
          beforeController = controller.exportJson();
          before = await nativeDatabaseEvidence(repository);
          sourceRaw = await _source(compatibility);
          final vault = jsonDecode(sourceRaw)['vaultId'] as String;
          client = _client();
          final device = const Uuid().v4();
          await client.verifyAccess(vault, device);
          remote = await client.upload(sourceRaw, _password, vault, device);
          final listed = (await client.list(vault)).single;
          expect(listed.toJson(), remote.toJson());
          downloaded = await client.restore(listed, _password);
          expect(
            canonical(jsonDecode(downloaded)),
            canonical(jsonDecode(sourceRaw)),
          );
          final file = await client.request(
            'GET',
            '${listed.relativePath}.hgb',
            maxBytes: BackupCodec.maxFileBytes,
            allowed: {200},
          );
          final contents = await BackupCodec.decryptWithMetadata(
            file.bytes,
            _password,
          );
          expect(contents.createdAtUtc, isNotNull);
          expect(contents.createdAtUtc!.isUtc, isTrue);
          expect(
            canonical(jsonDecode(contents.snapshot)),
            canonical(jsonDecode(sourceRaw)),
          );
          preview = BackupPreview.forRestore(
            downloaded,
            createdAtUtc: listed.created,
          );
          expect(preview.createdAtUtc, remote.created);
          expect(preview.habits, 3);
          expect(preview.records, 3);
          expect(preview.notes, 1);
          expect(preview.firstDate, '2026-10-01');
          expect(preview.lastDate, '2026-10-02');
          expect(preview.requiresCompatibilityConfirmation, compatibility);
          expect(preview.oversizedTitles, compatibility ? 1 : 0);
          expect(preview.oversizedNotes, compatibility ? 1 : 0);
          expect(await nativeDatabaseEvidence(repository), before);
          await expectLater(
            client.restore(listed, 'wrong synthetic recovery phrase'),
            throwsFormatException,
          );
          expect(await nativeDatabaseEvidence(repository), before);
          if (compatibility) {
            expect(await controller.importJson(downloaded), isFalse);
            expect(await nativeDatabaseEvidence(repository), before);
          }
          evidence.addAll({
            'remoteMarker': remote.toJson(),
            'sourceRaw': sourceRaw,
            'downloadedRaw': downloaded,
            'authenticatedManifestCreatedAtUtc': contents.createdAtUtc!
                .toIso8601String(),
            'controllerBeforeRaw': beforeController,
            'before': before,
            'afterDownloadAndWrongPassword': await nativeDatabaseEvidence(
              repository,
            ),
          });
        });
        addTearDown(() async {
          client.close();
          controller.dispose();
          await repository.close();
          if (Platform.environment['HAOXIGUAN_NEXTCLOUD_EVIDENCE'] == null) {
            await directory.delete(recursive: true);
          }
        });
        final navigator = GlobalKey<NavigatorState>();
        await tester.pumpWidget(
          MaterialApp(navigatorKey: navigator, home: const Scaffold()),
        );
        Future<bool?> openPreview() => showDialog<bool>(
          context: navigator.currentContext!,
          builder: (_) => BackupRestoreDialog(
            controller: controller,
            raw: downloaded,
            preview: preview,
          ),
        );
        final confirm = find.byKey(const Key('confirm-restore-button'));
        final checkbox = find.byKey(const Key('restore-preserve-legacy-text'));
        final cancelled = openPreview();
        await tester.pumpAndSettle();
        expect(
          find.byKey(const Key('restore-preview-summary')),
          findsOneWidget,
        );
        if (compatibility) {
          expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
          expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
          await tester.tap(confirm);
          await tester.pumpAndSettle();
          expect(find.byType(BackupRestoreDialog), findsOneWidget);
        }
        await tester.tap(
          find.descendant(
            of: find.byType(BackupRestoreDialog),
            matching: find.byType(TextButton),
          ),
        );
        await tester.pumpAndSettle();
        expect(await cancelled, isFalse);
        await tester.runAsync(() async {
          final afterCancel = await nativeDatabaseEvidence(repository);
          expect(afterCancel, before);
          expect(controller.exportJson(), beforeController);
          evidence['afterCancel'] = afterCancel;
        });
        final restored = openPreview();
        await tester.pumpAndSettle();
        if (compatibility) {
          expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
          expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
          await tester.ensureVisible(checkbox);
          await tester.tap(checkbox);
          await tester.pumpAndSettle();
          expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
          evidence['compatibilityExplicitlySelected'] = true;
        }
        expect(tester.widget<FilledButton>(confirm).onPressed, isNotNull);
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        expect(await _waitDialog(tester, restored), isTrue);
        await tester.runAsync(() async {
          final importedRaw = controller.exportJson();
          final imported = jsonDecode(importedRaw) as Map<String, dynamic>;
          final source = jsonDecode(sourceRaw) as Map<String, dynamic>;
          expect(imported['vaultId'], isNot(source['vaultId']));
          expect(imported['restoredFromVaultId'], source['vaultId']);
          final expected = Map<String, dynamic>.from(source)
            ..['vaultId'] = imported['vaultId']
            ..['restoredFromVaultId'] = source['vaultId']
            ..['firstRecordBackupSuggestion'] = 'dismissed';
          expect(canonical(imported), canonical(expected));
          final protectedRaw = (await repository.loadBackup())!;
          expect(
            canonical(jsonDecode(protectedRaw)),
            canonical(jsonDecode(before['snapshotRaw']! as String)),
          );
          final afterConfirm = await nativeDatabaseEvidence(repository);
          controller.dispose();
          await repository.close();
          final reopened = await _open(targetFile);
          repository = reopened.repository;
          controller = reopened.controller;
          expect(
            canonical(jsonDecode(controller.exportJson())),
            canonical(imported),
          );
          expect(
            canonical(jsonDecode((await repository.loadBackup())!)),
            canonical(jsonDecode(protectedRaw)),
          );
          final afterReopen = await nativeDatabaseEvidence(repository);
          expect(afterReopen, afterConfirm);
          evidence.addAll({
            'importedControllerRaw': importedRaw,
            'protectedSnapshotRaw': protectedRaw,
            'afterConfirm': afterConfirm,
            'reopenedControllerRaw': controller.exportJson(),
            'afterReopen': afterReopen,
          });
          await _writeEvidence(directory, evidence);
          // Only this test's random vault is eligible for cleanup.
          await client.request(
            'DELETE',
            'haoxiguan/${remote.vault}/',
            allowed: {204},
          );
        });
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
      skip: _skip,
    );
  }

  test(
    'Nextcloud retention prunes only an owned older same-day backup',
    () async {
      final client = _client();
      addTearDown(client.close);
      final raw = await _source(false);
      final vault = jsonDecode(raw)['vaultId'] as String;
      final device = const Uuid().v4();
      final oldUpload = await client.upload(raw, _password, vault, device);
      final newUpload = await client.upload(raw, _password, vault, device);
      final other = await client.upload(
        raw,
        _password,
        vault,
        const Uuid().v4(),
      );
      // Fixture timestamps avoid UTC-midnight flakiness. Only our synthetic
      // completion markers are adjusted, guarded by their current strong ETags.
      Future<RemoteBackup> atTime(RemoteBackup item, DateTime created) async {
        final fixture = RemoteBackup(
          vault: item.vault,
          device: item.device,
          id: item.id,
          created: created,
          digest: item.digest,
          size: item.size,
        );
        final marker = await client.request(
          'GET',
          '${item.relativePath}.complete.json',
          maxBytes: 4096,
          allowed: {200},
        );
        final tag = marker.headers['etag'];
        expect(tag, isNotNull);
        expect(tag, isNot(startsWith('W/')));
        await client.request(
          'PUT',
          '${item.relativePath}.complete.json',
          body: utf8.encode(jsonEncode(fixture.toJson())),
          headers: {'If-Match': tag!},
          allowed: {204},
        );
        return fixture;
      }

      final old = await atTime(oldUpload, DateTime.utc(2026, 10, 3, 10));
      final newest = await atTime(newUpload, DateTime.utc(2026, 10, 3, 11));
      expect(
        (await client.list(vault)).map((item) => item.id),
        containsAll([old.id, newest.id, other.id]),
      );
      await client.prune([old, newest, other], newest, _password);
      expect((await client.list(vault)).map((item) => item.id).toSet(), {
        newest.id,
        other.id,
      });
      for (final suffix in ['.hgb', '.complete.json']) {
        final removed = await client.request(
          'GET',
          '${old.relativePath}$suffix',
          maxBytes: 4096,
          allowed: {404},
        );
        expect(removed.status, 404);
      }
      expect(
        canonical(jsonDecode(await client.restore(newest, _password))),
        canonical(jsonDecode(raw)),
      );
      expect(
        canonical(jsonDecode(await client.restore(other, _password))),
        canonical(jsonDecode(raw)),
      );
      final directory = await _directory('retention');
      await _writeEvidence(directory, {
        'ownedPrunedId': old.id,
        'ownedRetainedId': newest.id,
        'otherDeviceRetainedId': other.id,
        'removedDataAndMarkerReturned404': true,
        'retainedBackupsRestoredExactly': true,
      });
      if (Platform.environment['HAOXIGUAN_NEXTCLOUD_EVIDENCE'] == null) {
        await directory.delete(recursive: true);
      }
      await client.request('DELETE', 'haoxiguan/$vault/', allowed: {204});
    },
    skip: _skip,
  );
}
