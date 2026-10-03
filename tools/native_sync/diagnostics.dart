import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:haoxiguan/services/sync_client.dart';

import 'protocol.dart';

// Shared with the host's strict sanitizer. Unknown inputs map to a fixed generic
// value; these sets never grow from a device error, UI text or server response.
const syncAcceptanceFailureCodes = <String>{
  'none',
  'native_sync_failure',
  'fixture_initialization_failed',
  'invalid_config',
  'invalid_loopback_endpoint',
  'acknowledged_remote_facts_mismatch',
  'android_required',
  'conflict_dialog_missing',
  'conflict_original_not_protected',
  'connection_form_missing',
  'converged_full_facts_mismatch',
  'disconnect_changed_business_data',
  'disconnect_dialog_missing',
  'framework_ui_failure',
  'fresh_package_not_empty',
  'incomplete_native_evidence',
  'independent_entries_not_retained',
  'initial_full_facts_mismatch',
  'initial_preview_missing',
  'invalid_remote_watermark',
  'invalid_restart_state',
  'join_form_missing',
  'joined_initial_review_missing',
  'joined_review_candidates_mismatch',
  'joined_review_dialog_missing',
  'joined_review_full_facts_mismatch',
  'manual_merge_full_facts_mismatch',
  'manual_note_input_missing',
  'native_binding_missing',
  'native_entry_fields_mismatch',
  'native_local_edit_failed',
  'native_note_conflict_missing',
  'native_protections_missing',
  'native_sqlite_open_failed',
  'note_conflict_candidates_mismatch',
  'offline_backup_full_snapshot_mismatch',
  'offline_backup_open_cancelled',
  'offline_backup_save_failed',
  'offline_edit_changed_remote_or_reconnected',
  'offline_full_facts_mismatch',
  'offline_native_record_failed',
  'offline_record_reopen_mismatch',
  'package_mismatch',
  'preview_cancel_changed_local',
  'preview_cancel_changed_remote',
  'preview_local_facts_mismatch',
  'preview_remote_facts_mismatch',
  'process_reopen_data_or_keystore_mismatch',
  'production_enrollment_failed',
  'production_sync_incomplete',
  'production_sync_screen_required',
  'production_ui_action_timeout',
  'protection_digest_mismatch',
  'recovery_dialog_missing',
  'recovery_export_not_committed',
  'recovery_readback_cancelled',
  'recovery_readback_mismatch',
  'recovery_save_failed',
  'restart_checkpoint_mismatch',
  'restart_flags_invalid',
  'sdk_mismatch',
  'second_preview_missing',
  'source_baseline_mismatch',
  'source_remote_not_empty',
  'sqlite_close_reopen_mismatch',
  'stage_ack_timeout',
  'ui_input_missing',
  'ui_target_missing',
  'unexpected_repeat_preview',
  'exception_format',
  'exception_state',
  'exception_file_system',
  'exception_platform',
  'exception_tls',
  'exception_socket',
  'exception_timeout',
  'exception_flutter',
  'exception_type',
  'exception_assertion',
  'exception_sync_api',
};

const syncAcceptanceActionIds = <String>{
  'boot',
  'unknown_action',
  'open_sqlite',
  'seed_source',
  'show_sync_screen',
  'fill_endpoint',
  'read_connection_fields',
  'fill_device_name',
  'fill_invite',
  'join_switch',
  'fill_join_password',
  'enroll_device',
  'load_binding',
  'verify_binding',
  'read_remote_watermark',
  'export_recovery',
  'fill_recovery_password',
  'fill_recovery_confirm',
  'save_recovery',
  'readback_recovery',
  'verify_recovery',
  'initial_sync',
  'inspect_initial_preview',
  'cancel_initial_preview',
  'verify_cancelled_preview',
  'confirm_initial_preview',
  'open_initial_review',
  'choose_remote_item',
  'apply_initial_review',
  'verify_initial_review',
  'add_local_entry',
  'edit_local_note',
  'immediate_sync',
  'open_note_conflict',
  'choose_manual_note',
  'fill_manual_note',
  'apply_manual_note',
  'verify_conflict_protection',
  'verify_convergence',
  'close_sqlite',
  'reopen_sqlite',
  'prepare_process_restart',
  'verify_process_restart',
  'disconnect_device',
  'confirm_disconnect',
  'add_offline_entry',
  'save_offline_backup',
  'readback_offline_backup',
  'verify_offline_backup',
  'verify_offline_remote',
  'await_source_upload',
  'await_replica_import',
  'await_a_changes_uploaded',
  'await_conflict_resolution',
  'await_convergence',
  'await_reopen',
  'complete',
  'cleanup',
};

const syncAcceptanceDiagnosticStages = <String>{
  'boot',
  'awaitingSourceUpload',
  'awaitingRecoverySave',
  'awaitingRecoveryReadback',
  'awaitingRecoveryJoin',
  'awaitingReplicaImport',
  'awaitingAChangesUploaded',
  'awaitingConflictResolution',
  'awaitingConvergence',
  'awaitingReopen',
  'awaitingBackupSave',
  'awaitingBackupReadback',
  'complete',
};

const syncAcceptanceFrameworkFailures = <String>{
  'none',
  'layout_overflow',
  'layout_constraint',
  'widget_lifecycle',
  'gesture',
  'flutter_framework',
};

String syncAcceptanceFailureCode(Object error) {
  if (error is SyncAcceptanceFailure) {
    return syncAcceptanceFailureCodes.contains(error.code) &&
            error.code != 'none'
        ? error.code
        : 'native_sync_failure';
  }
  if (error is HandshakeException) return 'exception_tls';
  if (error is SocketException) return 'exception_socket';
  if (error is FileSystemException) return 'exception_file_system';
  if (error is PlatformException) return 'exception_platform';
  if (error is TimeoutException) return 'exception_timeout';
  if (error is FormatException) return 'exception_format';
  if (error is StateError) return 'exception_state';
  if (error is FlutterError) return 'exception_flutter';
  if (error is TypeError) return 'exception_type';
  if (error is AssertionError) return 'exception_assertion';
  if (error is SyncApiException) return 'exception_sync_api';
  return 'native_sync_failure';
}

String syncAcceptanceFrameworkFailure(FlutterErrorDetails details) {
  // Inspect only framework summaries in memory. Never retain a description,
  // library name, error object, diagnostic tree or stack in the report.
  final error = details.exception;
  if (error is FlutterError) {
    final summary = error.diagnostics
        .whereType<ErrorSummary>()
        .map((node) => node.toDescription().toLowerCase())
        .join('\n');
    if (summary.contains('overflowed by')) return 'layout_overflow';
    if (summary.contains('unbounded') ||
        summary.contains('infinite') ||
        summary.contains('was not laid out') ||
        summary.contains('boxconstraints')) {
      return 'layout_constraint';
    }
    if (summary.contains('after dispose') ||
        summary.contains('deactivated widget') ||
        summary.contains('during build') ||
        summary.contains('globalkey')) {
      return 'widget_lifecycle';
    }
  }
  if (details.library == 'gesture library' ||
      details.library == 'gestures library') {
    return 'gesture';
  }
  return 'flutter_framework';
}

class SyncAcceptanceDiagnostics {
  String _failureCode = 'none';
  String _lastStage = 'boot';
  String _lastAction = 'boot';
  String _frameworkFailure = 'none';

  bool get hasFrameworkFailure => _frameworkFailure != 'none';

  void enterStage(String stage) {
    if (hasFrameworkFailure || _failureCode != 'none') return;
    _lastStage = syncAcceptanceDiagnosticStages.contains(stage)
        ? stage
        : 'boot';
  }

  void action(String action) {
    if (hasFrameworkFailure || _failureCode != 'none') return;
    _lastAction = syncAcceptanceActionIds.contains(action)
        ? action
        : 'unknown_action';
  }

  void framework(FlutterErrorDetails details) {
    if (hasFrameworkFailure || _failureCode != 'none') return;
    _frameworkFailure = syncAcceptanceFrameworkFailure(details);
  }

  void failure(Object error) {
    if (_failureCode == 'none') _failureCode = syncAcceptanceFailureCode(error);
  }

  Map<String, String> toJson() => {
    'failureCode': _failureCode,
    'lastStage': _lastStage,
    'lastAction': _lastAction,
    'frameworkFailure': _frameworkFailure,
  };
}

/// Persisted SyncScreen endpoints have the production validator's root slash.
/// Compare that exact canonical result without relaxing scheme, origin or path.
bool syncAcceptanceStoredEndpointMatches(String stored, String configured) =>
    stored == HttpSyncTransport.validateEndpoint(configured).toString();
