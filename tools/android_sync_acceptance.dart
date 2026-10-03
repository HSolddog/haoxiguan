// Isolated Android debug entrypoint. This is not installed over the normal app.
// The host runs a temporary local Go HTTPS service and drives Android SAF only.
// All enrollment, initial review, conflict and disconnect actions below travel
// through the unmodified production SyncScreen and its actual dialogs.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/services/backup_settings.dart';
import 'package:haoxiguan/services/sync_client.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/services/sync_recovery.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/sync_screen.dart';
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'native_sync/facts.dart';
import 'native_sync/protocol.dart';

const _build = String.fromEnvironment('SYNC_ACCEPTANCE_BUILD');
const _package = String.fromEnvironment('SYNC_ACCEPTANCE_PACKAGE');
const _syntheticPassword = 'public synthetic native recovery password';

/// Trust only the public certificate issued for this isolated loopback run.
/// Hostname/expiry/signature checks remain HttpClient's normal TLS checks.
class SyncAcceptanceHttpOverrides extends HttpOverrides {
  SyncAcceptanceHttpOverrides(String pem)
    : context = SecurityContext(withTrustedRoots: false)
        ..setTrustedCertificatesBytes(utf8.encode(pem));
  final SecurityContext context;
  @override
  HttpClient createHttpClient(SecurityContext? _) =>
      super.createHttpClient(context);
}

Future<void> main() async {
  final binding = WidgetsFlutterBinding.ensureInitialized();
  final semantics = binding.ensureSemantics();
  // Framework exceptions must not dump credential fields or arbitrary UI text.
  var uiFailure = false;
  FlutterError.onError = (_) => uiFailure = true;
  ErrorWidget.builder = (_) => const Text('isolated native fixture failed');
  final directory = await getApplicationSupportDirectory();
  final report = File('${directory.path}/sync_acceptance_result.json');
  final checkpoint = File('${directory.path}/sync_acceptance_checkpoint.json');
  NativeSyncAcceptance? fixture;
  try {
    final configFile = File('${directory.path}/sync_acceptance_config.json');
    Map<String, dynamic>? saved;
    if (await checkpoint.exists()) {
      saved =
          jsonDecode(await checkpoint.readAsString()) as Map<String, dynamic>;
    }
    final fresh = await configFile.exists();
    final raw = fresh
        ? await configFile.readAsString()
        : jsonEncode(saved?['publicConfig']);
    final config = SyncAcceptanceConfig.parse(
      raw,
      compiledPackage: _package,
      compiledBuild: _build,
      publicOnly: !fresh,
    );
    if (fresh) await configFile.delete();
    syncAcceptanceCheck(Platform.isAndroid, 'android_required');
    final sdk = await Process.run('/system/bin/getprop', [
      'ro.build.version.sdk',
    ]);
    syncAcceptanceCheck(
      sdk.exitCode == 0 &&
          int.tryParse('${sdk.stdout}'.trim()) == config.sdkInt,
      'sdk_mismatch',
    );
    final processName = utf8.decode(
      (await File(
        '/proc/self/cmdline',
      ).readAsBytes()).takeWhile((b) => b != 0).toList(),
    );
    syncAcceptanceCheck(processName == config.packageName, 'package_mismatch');
    syncAcceptanceCheck(fresh == (saved == null), 'invalid_restart_state');
    HttpOverrides.global = SyncAcceptanceHttpOverrides(
      config.publicCertificatePem,
    );
    fixture = NativeSyncAcceptance(
      directory: directory,
      report: report,
      checkpoint: checkpoint,
      config: config,
      ui: LiveWidgetController(binding),
      hasUiFailure: () => uiFailure,
    );
    await fixture.run(saved);
  } catch (error) {
    if (fixture != null) {
      fixture.result['errorCode'] = error is SyncAcceptanceFailure
          ? error.code
          : 'native_sync_failure';
      await fixture.publish('failed', status: 'failed');
    } else {
      await report.writeAsString(
        jsonEncode({
          'schemaVersion': syncAcceptanceSchema,
          'status': 'failed',
          'stage': 'failed',
          'errorCode': 'fixture_initialization_failed',
        }),
        flush: true,
      );
    }
  } finally {
    await fixture?.close();
    HttpOverrides.global = null;
    semantics.dispose();
  }
}

class NativeSyncAcceptance {
  NativeSyncAcceptance({
    required this.directory,
    required this.report,
    required this.checkpoint,
    required this.config,
    required this.ui,
    required this.hasUiFailure,
  }) : result = {
         'schemaVersion': syncAcceptanceSchema,
         'runId': config.runId,
         'sdkInt': config.sdkInt,
         'packageName': config.packageName,
         'role': config.role,
         'build': _build,
         'launchId': const Uuid().v4().replaceAll('-', ''),
         'source': syncAcceptanceSource,
         'evidence': <String, Object?>{},
         for (final flag in syncAcceptanceFlags) flag: false,
       };

  final Directory directory;
  final File report, checkpoint;
  final SyncAcceptanceConfig config;
  final LiveWidgetController ui;
  final bool Function() hasUiFailure;
  final Map<String, Object?> result;
  final navigator = GlobalKey<NavigatorState>();
  SqliteHabitRepository? repository;
  HabitController? controller;
  int sequence = 0;
  Map<String, Object?> get evidence =>
      result['evidence']! as Map<String, Object?>;
  String digest(Object? value) =>
      sha256.convert(utf8.encode(syncAcceptanceCanonical(value))).toString();

  Future<void> publish(
    String stage, {
    String status = 'running',
    String? documentName,
  }) async {
    result.addAll({
      'status': status,
      'stage': stage,
      'reportSequence': ++sequence,
    });
    result.remove('documentName');
    if (documentName != null) result['documentName'] = documentName;
    final temporary = File('${report.path}.tmp');
    await temporary.writeAsString(jsonEncode(result), flush: true);
    await temporary.rename(report.path);
  }

  Future<void> barrier(String stage) async {
    await publish(stage);
    final control = File('${directory.path}/sync_acceptance_control.json');
    await waitUntil(
      () async {
        try {
          return syncAcceptanceControl(
            await control.readAsString(),
            config: config,
            stage: stage,
            launchId: result['launchId']! as String,
            reportSequence: sequence,
          );
        } on FileSystemException {
          return false;
        } on FormatException {
          return false;
        }
      },
      'stage_ack_timeout',
      timeout: const Duration(seconds: 240),
    );
  }

  Future<void> waitUntil(
    FutureOr<bool> Function() ready,
    String failure, {
    Duration timeout = const Duration(seconds: 120),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      syncAcceptanceCheck(!hasUiFailure(), 'framework_ui_failure');
      if (await ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 150));
    }
    throw SyncAcceptanceFailure(failure);
  }

  Future<void> open() async {
    repository = await SqliteHabitRepository.open();
    controller = HabitController(
      repository!,
      clock: () => nativeSyncClock,
      timezoneId: () => 'UTC',
    );
    await controller!.load();
    syncAcceptanceCheck(controller!.loaded, 'native_sqlite_open_failed');
  }

  Future<void> showSyncScreen() async {
    runApp(
      MaterialApp(
        navigatorKey: navigator,
        home: SyncScreen(controller: controller!),
      ),
    );
    await ui.pump(const Duration(milliseconds: 250));
    await idle();
    syncAcceptanceCheck(
      find.byType(SyncScreen).evaluate().length == 1 &&
          ui.widget<SyncScreen>(find.byType(SyncScreen)).settingsStore == null,
      'production_sync_screen_required',
    );
    result['realSyncScreen'] = true;
    result['productionStorage'] = true;
  }

  Future<void> idle() async {
    await waitUntil(
      () => find.byType(LinearProgressIndicator).evaluate().isEmpty,
      'production_ui_action_timeout',
    );
    await ui.pump(const Duration(milliseconds: 350));
  }

  Future<void> tap(Finder target) async {
    if (target.evaluate().isEmpty) {
      await ui.scrollUntilVisible(
        target,
        230,
        scrollable: find.byType(Scrollable).first,
        maxScrolls: 35,
        duration: const Duration(milliseconds: 50),
      );
    }
    syncAcceptanceCheck(target.evaluate().length == 1, 'ui_target_missing');
    await ui.ensureVisible(target);
    await ui.pump(const Duration(milliseconds: 180));
    await ui.tap(target);
    await ui.pump(const Duration(milliseconds: 180));
  }

  Future<void> text(Key key, String value) async {
    final target = find.byKey(key);
    syncAcceptanceCheck(target.evaluate().length == 1, 'ui_input_missing');
    ui.widget<TextField>(target).controller!.text = value;
    await ui.pump(const Duration(milliseconds: 50));
  }

  Future<SyncSettings> settings() async {
    final saved = await SyncSettingsStore(DeviceSecretStore()).load();
    syncAcceptanceCheck(saved != null, 'native_binding_missing');
    return saved!;
  }

  Future<Map<String, Object?>> remoteWatermark({SyncSettings? retained}) async {
    final saved = retained ?? await settings();
    final transport = HttpSyncTransport(saved.endpoint);
    try {
      final value = retained != null
          // A diagnostic GET after disconnect must never refresh/save tokens or
          // restore the deleted active pointer. It does not run a sync engine.
          ? await transport.request(
              'GET',
              '/v1/vault',
              token: saved.tokens['accessToken'] as String,
            )
          : await SyncSession(
              saved,
              SyncSettingsStore(DeviceSecretStore()),
              transport,
            ).request('GET', '/v1/vault');
      syncAcceptanceCheck(
        value['objects'] is int &&
            (value['objects'] as int) >= 0 &&
            value['vaultId'] == saved.keys.vault,
        'invalid_remote_watermark',
      );
      result['realTlsTransport'] = true;
      return {
        'objects': value['objects'],
        'highWater': syncAcceptanceHighWater(value['highWater']),
      };
    } finally {
      transport.close();
      if (retained == null) saved.keys.dispose();
    }
  }

  /// Always read through a fresh default native connection. The image contains
  /// synthetic business facts and sync progress, never a token or private key.
  Future<Map<String, Object?>> image() async {
    final fresh = await SqliteHabitRepository.open();
    try {
      await fresh.load();
      final frame = await fresh.readSyncFrame();
      final protections = await fresh.database
          .customSelect(
            'SELECT sequence,payload,digest,created_at FROM protections ORDER BY sequence',
          )
          .get();
      for (final row in protections) {
        final payload = row.read<String>('payload');
        syncAcceptanceCheck(
          sha256.convert(utf8.encode(payload)).toString() ==
              row.read<String>('digest'),
          'protection_digest_mismatch',
        );
        SnapshotCodec.decode(payload);
      }
      final syncProtections = await fresh.database
          .customSelect(
            'SELECT sequence,payload,created_at FROM sync_protections ORDER BY sequence',
          )
          .get();
      return {
        'businessRevision': frame.businessRevision,
        'stateRevision': frame.stateRevision,
        'snapshot': jsonDecode(frame.snapshot),
        'state': frame.state,
        'protections': protections.map((r) => r.data).toList(),
        'syncProtections': syncProtections.map((r) => r.data).toList(),
      };
    } finally {
      await fresh.close();
    }
  }

  Future<void> enroll() async {
    await text(const Key('sync-endpoint'), config.endpoint);
    final fields = find.byType(TextField);
    syncAcceptanceCheck(
      fields.evaluate().length == 3,
      'connection_form_missing',
    );
    ui.widget<TextField>(fields.at(1)).controller!.text =
        'synthetic Android ${config.role}';
    ui.widget<TextField>(fields.at(2)).controller!.text = config.invite;
    if (config.role == 'B') {
      await tap(find.byType(SwitchListTile));
      final joined = find.byType(TextField);
      syncAcceptanceCheck(joined.evaluate().length == 4, 'join_form_missing');
      ui.widget<TextField>(joined.last).controller!.text = _syntheticPassword;
      await publish(
        'awaitingRecoveryJoin',
        documentName: 'sync-${config.runId}.hgr',
      );
      await tap(find.widgetWithText(FilledButton, '选择恢复文件并授权'));
    } else {
      await tap(find.widgetWithText(FilledButton, '授权此设备'));
    }
    await idle();
    final saved = await settings();
    try {
      syncAcceptanceCheck(
        saved.endpoint == config.endpoint &&
            saved.recoveryExported == (config.role == 'B') &&
            saved.initialReview == (config.role == 'B'),
        'production_enrollment_failed',
      );
    } finally {
      saved.keys.dispose();
    }
    await remoteWatermark();
    if (config.role == 'B') result['recoverySafVerified'] = true;
  }

  Future<void> recovery() async {
    await tap(find.widgetWithText(OutlinedButton, '导出加密恢复文件'));
    await waitUntil(
      () => find.byType(SyncRecoveryPasswordDialog).evaluate().isNotEmpty,
      'recovery_dialog_missing',
    );
    await text(const Key('sync-recovery-password'), _syntheticPassword);
    await text(const Key('sync-recovery-confirm'), _syntheticPassword);
    await publish(
      'awaitingRecoverySave',
      documentName: 'sync-${config.runId}.hgr',
    );
    await tap(
      find.descendant(
        of: find.byType(SyncRecoveryPasswordDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await idle();
    syncAcceptanceCheck(
      find.byType(SyncRecoveryPasswordDialog).evaluate().isEmpty,
      'recovery_save_failed',
    );
    final saved = await settings();
    try {
      syncAcceptanceCheck(
        saved.recoveryExported,
        'recovery_export_not_committed',
      );
      await publish(
        'awaitingRecoveryReadback',
        documentName: 'sync-${config.runId}.hgr',
      );
      final bytes = await PlatformBackupFiles().open();
      syncAcceptanceCheck(bytes != null, 'recovery_readback_cancelled');
      final restored = await SyncRecoveryCodec.decrypt(
        bytes!,
        _syntheticPassword,
      );
      try {
        syncAcceptanceCheck(
          syncAcceptanceCanonical(restored.toJson()) ==
              syncAcceptanceCanonical(saved.keys.toJson()),
          'recovery_readback_mismatch',
        );
      } finally {
        restored.dispose();
      }
    } finally {
      saved.keys.dispose();
    }
    result['recoverySafVerified'] = true;
  }

  Future<void> initialReview() async {
    final before = await image();
    final remoteBefore = await remoteWatermark();
    await tap(find.widgetWithText(FilledButton, '立即同步'));
    await waitUntil(
      () => find.byType(InitialSyncPreviewDialog).evaluate().isNotEmpty,
      'initial_preview_missing',
    );
    final preview = ui
        .widget<InitialSyncPreviewDialog>(find.byType(InitialSyncPreviewDialog))
        .preview;
    syncAcceptanceCheck(
      syncAcceptanceCanonical(
            preview.local.map((k, v) => MapEntry(k, SyncOrigins.facts(k, v))),
          ) ==
          syncAcceptanceCanonical(
            SyncEntities.encodeFacts(jsonEncode(before['snapshot'])),
          ),
      'preview_local_facts_mismatch',
    );
    if (config.role == 'B') {
      syncAcceptanceCheck(
        syncAcceptanceCanonical(
              preview.remote.map(
                (k, v) => MapEntry(k, SyncOrigins.facts(k, v)),
              ),
            ) ==
            nativeSyncExpected(),
        'preview_remote_facts_mismatch',
      );
    } else {
      syncAcceptanceCheck(preview.remote.isEmpty, 'source_remote_not_empty');
    }
    await tap(
      find.descendant(
        of: find.byType(InitialSyncPreviewDialog),
        matching: find.byType(TextButton),
      ),
    );
    await idle();
    final after = await image();
    for (final key in [
      'snapshot',
      'businessRevision',
      'protections',
      'syncProtections',
    ]) {
      syncAcceptanceCheck(
        syncAcceptanceCanonical(before[key]) ==
            syncAcceptanceCanonical(after[key]),
        'preview_cancel_changed_local',
      );
    }
    final remoteAfter = await remoteWatermark();
    syncAcceptanceCheck(
      syncAcceptanceCanonical(remoteBefore) ==
              syncAcceptanceCanonical(remoteAfter) &&
          (after['state'] as Map)['previewRequired'] == true &&
          ((after['state'] as Map)['pending'] as List).isEmpty,
      'preview_cancel_changed_remote',
    );
    evidence['cancel'] = {
      'beforeSnapshotSha256': digest(before['snapshot']),
      'afterSnapshotSha256': digest(after['snapshot']),
      'beforeBusinessRevision': before['businessRevision'],
      'afterBusinessRevision': after['businessRevision'],
      'beforeProtectionCount': (before['protections'] as List).length,
      'afterProtectionCount': (after['protections'] as List).length,
      'beforeSyncProtectionCount': (before['syncProtections'] as List).length,
      'afterSyncProtectionCount': (after['syncProtections'] as List).length,
      'beforeRemoteObjects': remoteBefore['objects'],
      'afterRemoteObjects': remoteAfter['objects'],
      'beforeRemoteHighWater': remoteBefore['highWater'],
      'afterRemoteHighWater': remoteAfter['highWater'],
    };
    result['initialPreviewCancelled'] = true;
    await tap(find.widgetWithText(FilledButton, '立即同步'));
    await waitUntil(
      () => find.byType(InitialSyncPreviewDialog).evaluate().isNotEmpty,
      'second_preview_missing',
    );
    await tap(
      find.descendant(
        of: find.byType(InitialSyncPreviewDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await idle();
    if (config.role == 'B') await adoptInitialRemote();
    await assertComplete();
    result['initialPreviewConfirmed'] = true;
    syncAcceptanceCheck(
      nativeSyncFactsMatch(controller!.exportJson()),
      'initial_full_facts_mismatch',
    );
    result['fullFactsTransferred'] = true;
    evidence['initialExpectedFactsSha256'] = digest(
      jsonDecode(nativeSyncExpected()),
    );
    evidence['initialActualFactsSha256'] = digest(
      SyncEntities.encodeFacts(controller!.exportJson()),
    );
  }

  Future<void> adoptInitialRemote() async {
    final before = await image();
    syncAcceptanceCheck(
      ((before['state'] as Map)['conflicts'] as List).length == 3,
      'joined_initial_review_missing',
    );
    await tap(find.widgetWithText(OutlinedButton, '检查与处理冲突'));
    await waitUntil(
      () => find.byType(SyncConflictDialog).evaluate().isNotEmpty,
      'joined_review_dialog_missing',
    );
    final decision = ui
        .widget<SyncConflictDialog>(find.byType(SyncConflictDialog))
        .decision;
    syncAcceptanceCheck(
      decision.local.isEmpty &&
          decision.items.length == 20 &&
          decision.items.every(
            (item) => item.local == null && item.remote != null,
          ),
      'joined_review_candidates_mismatch',
    );
    for (final item in decision.items) {
      await tap(find.byKey(ValueKey(item.id)));
      await tap(find.text('保留远端此项').last);
    }
    await tap(
      find.descendant(
        of: find.byType(SyncConflictDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await idle();
    syncAcceptanceCheck(
      nativeSyncFactsMatch(controller!.exportJson()),
      'joined_review_full_facts_mismatch',
    );
    await immediateSync();
  }

  Future<void> assertComplete() async {
    final current = await image();
    final state = current['state'] as Map;
    syncAcceptanceCheck(
      state['previewRequired'] == false &&
          state['lastSuccess'] is String &&
          state['lastFailureCode'] == null &&
          (state['pending'] as List).isEmpty &&
          (state['conflicts'] as List).isEmpty,
      'production_sync_incomplete',
    );
    final remote = <String, dynamic>{
      for (final entry in (state['remote'] as Map).entries)
        entry.key as String: SyncOrigins.facts(
          entry.key as String,
          (entry.value as Map)['payload'],
        ),
    };
    syncAcceptanceCheck(
      syncAcceptanceCanonical(remote) ==
          syncAcceptanceCanonical(
            SyncEntities.encodeFacts(jsonEncode(current['snapshot'])),
          ),
      'acknowledged_remote_facts_mismatch',
    );
  }

  Future<void> diverge() async {
    final entry = nativeSyncNewEntry(config.role);
    syncAcceptanceCheck(
      await controller!.addValue(
            nativeSyncCountHabit,
            nativeSyncClock,
            entry.value,
            entryId: entry.id,
          ) &&
          await controller!.setNote(
            nativeSyncCountHabit,
            nativeSyncClock,
            'synthetic device ${config.role} note',
          ),
      'native_local_edit_failed',
    );
    final added = controller!.habits
        .singleWhere((h) => h.id == nativeSyncCountHabit)
        .entries
        .singleWhere((e) => e.id == entry.id);
    syncAcceptanceCheck(
      syncAcceptanceCanonical(added.toJson()) ==
          syncAcceptanceCanonical(entry.toJson()),
      'native_entry_fields_mismatch',
    );
  }

  Future<void> immediateSync() async {
    await tap(find.widgetWithText(FilledButton, '立即同步'));
    await idle();
    syncAcceptanceCheck(
      find.byType(InitialSyncPreviewDialog).evaluate().isEmpty,
      'unexpected_repeat_preview',
    );
  }

  Future<void> manualConflict() async {
    await immediateSync();
    final before = await image();
    final beforeState = before['state'] as Map;
    syncAcceptanceCheck(
      (beforeState['conflicts'] as List).length == 1 &&
          (beforeState['conflicts'] as List).single == nativeSyncCountHabit,
      'native_note_conflict_missing',
    );
    await tap(find.widgetWithText(OutlinedButton, '检查与处理冲突'));
    await waitUntil(
      () => find.byType(SyncConflictDialog).evaluate().isNotEmpty,
      'conflict_dialog_missing',
    );
    final dialog = ui.widget<SyncConflictDialog>(
      find.byType(SyncConflictDialog),
    );
    syncAcceptanceCheck(
      dialog.decision.items.length == 1 &&
          dialog.decision.items.single.isNote &&
          (dialog.decision.items.single.local as Map)['text'] ==
              'synthetic device B note' &&
          (dialog.decision.items.single.remote as Map)['text'] ==
              'synthetic device A note',
      'note_conflict_candidates_mismatch',
    );
    await tap(find.byType(DropdownButtonFormField<SyncChoice>));
    await tap(find.text('手工合并备注').last);
    final field = find.byType(TextFormField);
    await waitUntil(
      () => field.evaluate().length == 1,
      'manual_note_input_missing',
    );
    final editable = find.descendant(
      of: field,
      matching: find.byType(EditableText),
    );
    ui.widget<EditableText>(editable).controller.text = nativeSyncMergedNote;
    // The production TextFormField's onChanged records the real editing draft.
    ui.widget<TextFormField>(field).onChanged!(nativeSyncMergedNote);
    await ui.pump(const Duration(milliseconds: 100));
    await tap(
      find.descendant(
        of: find.byType(SyncConflictDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await idle();
    final after = await image();
    final protected = after['protections'] as List;
    final syncProtected = after['syncProtections'] as List;
    syncAcceptanceCheck(
      protected.length == (before['protections'] as List).length + 1 &&
          syncProtected.length ==
              (before['syncProtections'] as List).length + 1 &&
          syncAcceptanceCanonical(
                jsonDecode((protected.last as Map)['payload'] as String),
              ) ==
              syncAcceptanceCanonical(before['snapshot']) &&
          syncAcceptanceCanonical(
                jsonDecode((syncProtected.last as Map)['payload'] as String),
              ) ==
              syncAcceptanceCanonical(before['state']),
      'conflict_original_not_protected',
    );
    syncAcceptanceCheck(
      nativeSyncFactsMatch(controller!.exportJson(), merged: true),
      'manual_merge_full_facts_mismatch',
    );
    result['manualConflictMerged'] = true;
    result['protectionIntegrity'] = true;
    await immediateSync();
    await assertComplete();
  }

  Future<void> validateConvergence() async {
    syncAcceptanceCheck(
      nativeSyncFactsMatch(controller!.exportJson(), merged: true),
      'converged_full_facts_mismatch',
    );
    final habit = controller!.habits.singleWhere(
      (h) => h.id == nativeSyncCountHabit,
    );
    final a = habit.entries.singleWhere(
      (e) => e.id == nativeSyncNewEntry('A').id,
    );
    final b = habit.entries.singleWhere(
      (e) => e.id == nativeSyncNewEntry('B').id,
    );
    syncAcceptanceCheck(
      a.id != b.id &&
          a.date == b.date &&
          habit.valueOn(nativeSyncClock) == 400 &&
          habit.notes[nativeSyncDay] == nativeSyncMergedNote,
      'independent_entries_not_retained',
    );
    result['independentSameDayEntries'] = true;
    result['manualConflictMerged'] = true;
    final saved = await image();
    syncAcceptanceCheck(
      (saved['protections'] as List).isNotEmpty &&
          (saved['syncProtections'] as List).isNotEmpty,
      'native_protections_missing',
    );
    result['protectionIntegrity'] = true;
    final facts = SyncEntities.encodeFacts(controller!.exportJson());
    evidence['convergedExpectedFactsSha256'] = digest(
      jsonDecode(nativeSyncExpected(merged: true)),
    );
    evidence['convergedActualFactsSha256'] = digest(facts);
  }

  Future<String> bindingDigest() async {
    final saved = await settings();
    try {
      return sha256
          .convert(utf8.encode(syncAcceptanceCanonical(saved.toJson())))
          .toString();
    } finally {
      saved.keys.dispose();
    }
  }

  Future<void> close() async {
    runApp(
      const MaterialApp(
        home: Scaffold(body: Text('isolated native sync fixture')),
      ),
    );
    await ui.pump(const Duration(milliseconds: 100));
    controller?.dispose();
    controller = null;
    await repository?.close();
    repository = null;
  }

  Future<void> prepareRestart() async {
    final before = await image();
    final bindingBefore = await bindingDigest();
    await close();
    await open();
    syncAcceptanceCheck(
      syncAcceptanceCanonical(before) ==
              syncAcceptanceCanonical(await image()) &&
          bindingBefore == await bindingDigest(),
      'sqlite_close_reopen_mismatch',
    );
    result['sqliteReopened'] = true;
    await checkpoint.writeAsString(
      jsonEncode({
        'schemaVersion': syncAcceptanceSchema,
        'runId': config.runId,
        'launchId': result['launchId'],
        'reportSequence': sequence,
        'publicConfig': config.publicCheckpoint,
        'image': before,
        'bindingDigest': bindingBefore,
        'evidence': evidence,
        'flags': {for (final flag in syncAcceptanceFlags) flag: result[flag]},
      }),
      flush: true,
    );
    await publish('awaitingReopen');
    // Only a real Android process restart may release this stage. No file
    // acknowledgement, timer or in-process reopen counts as Keystore survival.
    await Completer<void>().future;
  }

  Future<void> disconnectedBackup() async {
    final retained = await settings();
    try {
      await disconnectedBackupWithDiagnostic(retained);
    } finally {
      retained.keys.dispose();
    }
  }

  Future<void> disconnectedBackupWithDiagnostic(SyncSettings retained) async {
    final before = await image();
    final remoteBefore = await remoteWatermark(retained: retained);
    await tap(find.widgetWithText(TextButton, '断开本机同步'));
    await waitUntil(
      () => find.byType(AlertDialog).evaluate().isNotEmpty,
      'disconnect_dialog_missing',
    );
    await tap(
      find.descendant(
        of: find.byType(AlertDialog),
        matching: find.byType(FilledButton),
      ),
    );
    await idle();
    syncAcceptanceCheck(
      await SyncSettingsStore(DeviceSecretStore()).load() == null &&
          syncAcceptanceCanonical(before) ==
              syncAcceptanceCanonical(await image()),
      'disconnect_changed_business_data',
    );
    final offline = nativeSyncNewEntry(config.role, offline: true);
    syncAcceptanceCheck(
      await controller!.addValue(
        nativeSyncCountHabit,
        nativeSyncClock,
        offline.value,
        entryId: offline.id,
      ),
      'offline_native_record_failed',
    );
    final snapshot = controller!.exportJson();
    syncAcceptanceCheck(
      nativeSyncFactsMatch(snapshot, merged: true, offlineRole: config.role),
      'offline_full_facts_mismatch',
    );
    final facts = SyncEntities.encodeFacts(snapshot);
    evidence['offlineExpectedFactsSha256'] = digest(
      jsonDecode(nativeSyncExpected(merged: true, offlineRole: config.role)),
    );
    evidence['offlineActualFactsSha256'] = digest(facts);
    int count(String prefix) =>
        facts.keys.where((key) => key.startsWith(prefix)).length;
    evidence['counts'] = {
      'habits': count('h/'),
      'plans': count('p/'),
      'entries': count('r/'),
      'notes': count('n/'),
    };
    final files = PlatformBackupFiles();
    final bytes = await BackupCodec.encrypt(snapshot, _syntheticPassword);
    final name = 'sync-${config.runId}-${config.role}.hgb';
    await publish('awaitingBackupSave', documentName: name);
    syncAcceptanceCheck(
      await files.save(bytes, name),
      'offline_backup_save_failed',
    );
    await publish('awaitingBackupReadback', documentName: name);
    final selected = await files.open();
    syncAcceptanceCheck(selected != null, 'offline_backup_open_cancelled');
    final restored = await BackupCodec.decrypt(selected!, _syntheticPassword);
    syncAcceptanceCheck(
      syncAcceptanceCanonical(jsonDecode(restored)) ==
          syncAcceptanceCanonical(jsonDecode(snapshot)),
      'offline_backup_full_snapshot_mismatch',
    );
    // The disconnected store retains its encrypted immutable document, while
    // its active pointer is gone. No transport or engine performs offline edits.
    final fresh = await SqliteHabitRepository.open();
    try {
      final reopened = (await fresh.load())!;
      syncAcceptanceCheck(
        nativeSyncFactsMatch(reopened, merged: true, offlineRole: config.role),
        'offline_record_reopen_mismatch',
      );
    } finally {
      await fresh.close();
    }
    syncAcceptanceCheck(
      syncAcceptanceCanonical(remoteBefore) ==
              syncAcceptanceCanonical(
                await remoteWatermark(retained: retained),
              ) &&
          await SyncSettingsStore(DeviceSecretStore()).load() == null,
      'offline_edit_changed_remote_or_reconnected',
    );
    result['disconnectedOfflineBackup'] = true;
  }

  Future<void> run(Map<String, dynamic>? saved) async {
    await publish('boot');
    await open();
    if (saved != null) {
      syncAcceptanceCheck(
        saved['schemaVersion'] == syncAcceptanceSchema &&
            saved['runId'] == config.runId &&
            saved['launchId'] != result['launchId'] &&
            saved['launchId'] is String &&
            saved['reportSequence'] is int,
        'restart_checkpoint_mismatch',
      );
      sequence = saved['reportSequence'] as int;
      for (final flag in syncAcceptanceFlags) {
        final v = (saved['flags'] as Map)[flag];
        syncAcceptanceCheck(v is bool, 'restart_flags_invalid');
        result[flag] = v;
      }
      result['evidence'] = Map<String, Object?>.from(saved['evidence'] as Map);
      final reopened = await image();
      syncAcceptanceCheck(
        syncAcceptanceCanonical(saved['image']) ==
                syncAcceptanceCanonical(reopened) &&
            saved['bindingDigest'] == await bindingDigest(),
        'process_reopen_data_or_keystore_mismatch',
      );
      final previous = saved['image'] as Map;
      evidence['restart'] = {
        'beforeBusinessRevision': previous['businessRevision'],
        'afterBusinessRevision': reopened['businessRevision'],
        'beforeStateRevision': previous['stateRevision'],
        'afterStateRevision': reopened['stateRevision'],
        'beforeProtectionCount': (previous['protections'] as List).length,
        'afterProtectionCount': (reopened['protections'] as List).length,
        'beforeSyncProtectionCount':
            (previous['syncProtections'] as List).length,
        'afterSyncProtectionCount':
            (reopened['syncProtections'] as List).length,
        'beforeSnapshotSha256': digest(previous['snapshot']),
        'afterSnapshotSha256': digest(reopened['snapshot']),
      };
      result['keystoreProcessReopened'] = true;
      await showSyncScreen();
      await disconnectedBackup();
      syncAcceptanceCheck(
        syncAcceptanceFlags.every((f) => result[f] == true),
        'incomplete_native_evidence',
      );
      await publish('complete', status: 'passed');
      await checkpoint.delete();
      return;
    }

    syncAcceptanceCheck(controller!.habits.isEmpty, 'fresh_package_not_empty');
    if (config.role == 'A') {
      final initial = SnapshotCodec.decode(controller!.exportJson());
      final seed = SnapshotCodec.decode(nativeSyncBaseline());
      await repository!.save(
        jsonEncode({
          ...initial,
          'habits': seed['habits'],
          'categories': seed['categories'],
        }),
      );
      await controller!.load();
      syncAcceptanceCheck(
        nativeSyncFactsMatch(controller!.exportJson()),
        'source_baseline_mismatch',
      );
    } else {
      await barrier('awaitingSourceUpload');
    }
    await showSyncScreen();
    await enroll();
    if (config.role == 'A') await recovery();
    await initialReview();
    if (config.role == 'A') {
      await barrier('awaitingReplicaImport');
      await diverge();
      await immediateSync();
      await assertComplete();
      await barrier('awaitingConflictResolution');
      await immediateSync();
      await assertComplete();
    } else {
      await diverge();
      await barrier('awaitingAChangesUploaded');
      await manualConflict();
      await barrier('awaitingConvergence');
    }
    await validateConvergence();
    await prepareRestart();
  }
}
