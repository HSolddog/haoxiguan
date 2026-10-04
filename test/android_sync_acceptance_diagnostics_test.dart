import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/services/sync_client.dart';

import '../tools/android_sync_acceptance.dart';
import '../tools/native_sync/diagnostics.dart';
import '../tools/native_sync/protocol.dart';

void main() {
  const secret = 'must-never-export-password-token-invite-or-key';

  test(
    'stored endpoints use the production canonical slash and exact origin',
    () {
      const configured = 'https://localhost:18443';
      final persisted = HttpSyncTransport.validateEndpoint(
        configured,
      ).toString();
      expect(persisted, 'https://localhost:18443/');
      expect(
        syncAcceptanceStoredEndpointMatches(persisted, configured),
        isTrue,
      );
      expect(
        syncAcceptanceStoredEndpointMatches(persisted, '$configured/'),
        isTrue,
      );
      for (final stored in [
        configured,
        'https://localhost:18444/',
        'https://other.test:18443/',
        'http://localhost:18443/',
        'https://localhost:18443/other',
        'https://secret@localhost:18443/',
        'https://localhost:18443/?secret=value',
      ]) {
        expect(
          syncAcceptanceStoredEndpointMatches(stored, configured),
          isFalse,
        );
      }
      expect(
        () =>
            syncAcceptanceStoredEndpointMatches(persisted, '$configured/path'),
        throwsFormatException,
      );
    },
  );

  test(
    'exception classification exports only finite codes even for secret messages',
    () {
      final errors = <Object, String>{
        const SyncAcceptanceFailure('production_enrollment_failed'):
            'production_enrollment_failed',
        const SyncAcceptanceFailure(secret): 'native_sync_failure',
        const FormatException(secret): 'exception_format',
        StateError(secret): 'exception_state',
        const FileSystemException(secret, secret): 'exception_file_system',
        PlatformException(code: secret, message: secret, details: secret):
            'exception_platform',
        const HandshakeException(secret): 'exception_tls',
        const SocketException(secret): 'exception_socket',
        TimeoutException(secret): 'exception_timeout',
        FlutterError(secret): 'exception_flutter',
        AssertionError(secret): 'exception_assertion',
        const SyncApiException(secret): 'exception_sync_api',
        Object(): 'native_sync_failure',
      };
      for (final entry in errors.entries) {
        final code = syncAcceptanceFailureCode(entry.key);
        expect(code, entry.value);
        expect(syncAcceptanceFailureCodes.contains(code), isTrue);
        expect(code.contains(secret), isFalse);
      }
      try {
        final dynamic value = 1;
        value as String;
        fail('expected a type error');
      } catch (error) {
        expect(syncAcceptanceFailureCode(error), 'exception_type');
      }
    },
  );

  test(
    'framework classification and first-failure context contain no original diagnostics',
    () {
      final cases = <String, String>{
        'A RenderFlex overflowed by 12 pixels. $secret': 'layout_overflow',
        'BoxConstraints forces an infinite width. $secret': 'layout_constraint',
        'setState() called after dispose(). $secret': 'widget_lifecycle',
        secret: 'flutter_framework',
      };
      for (final entry in cases.entries) {
        final diagnostics = SyncAcceptanceDiagnostics();
        diagnostics.action('enroll_device');
        diagnostics.framework(
          FlutterErrorDetails(
            exception: FlutterError.fromParts([ErrorSummary(entry.key)]),
            stack: StackTrace.fromString(secret),
            informationCollector: () => [ErrorDescription(secret)],
          ),
        );
        diagnostics.action('cleanup');
        diagnostics.enterStage('complete');
        diagnostics.framework(
          FlutterErrorDetails(exception: StateError(secret)),
        );
        diagnostics.failure(
          const SyncAcceptanceFailure('framework_ui_failure'),
        );
        final result = diagnostics.toJson();
        expect(result, {
          'failureCode': 'framework_ui_failure',
          'lastStage': 'boot',
          'lastAction': 'enroll_device',
          'frameworkFailure': entry.value,
        });
        expect(jsonEncode(result).contains(secret), isFalse);
      }
      expect(
        syncAcceptanceFrameworkFailure(
          FlutterErrorDetails(
            exception: StateError(secret),
            library: 'gesture library',
          ),
        ),
        'gesture',
      );
      final unknown = SyncAcceptanceDiagnostics()
        ..action(secret)
        ..enterStage(secret);
      expect(unknown.toJson()['lastAction'], 'unknown_action');
      expect(unknown.toJson()['lastStage'], 'boot');
      expect(jsonEncode(unknown.toJson()).contains(secret), isFalse);
    },
  );

  test(
    'sequential breadcrumbs pin SAF sequence and preserve first framework context',
    () async {
      final binding = TestWidgetsFlutterBinding.ensureInitialized();
      final directory = await Directory.systemTemp.createTemp(
        'native-sync-diagnostic-',
      );
      final report = File('${directory.path}/report.json');
      final diagnostics = SyncAcceptanceDiagnostics();
      final fixture = NativeSyncAcceptance(
        directory: directory,
        report: report,
        checkpoint: File('${directory.path}/checkpoint.json'),
        config: const SyncAcceptanceConfig(
          runId: '0123456789abcdef0123456789abcdef',
          sdkInt: 35,
          packageName: 'com.haoxiguan.haoxiguan.syncacceptance.a',
          role: 'A',
          endpoint: 'https://localhost:18443',
          publicCertificatePem: '',
          invite: '',
        ),
        ui: LiveWidgetController(binding),
        diagnostics: diagnostics,
      );
      try {
        await fixture.publish('boot');
        await fixture.breadcrumb('fill_endpoint');
        expect(jsonDecode(await report.readAsString())['reportSequence'], 2);
        await fixture.nativeStage(
          'awaitingRecoverySave',
          'save_recovery',
          documentName: 'sync-0123456789abcdef0123456789abcdef.hgr',
        );
        final pinned = await report.readAsString();
        diagnostics.framework(
          FlutterErrorDetails(
            exception: FlutterError.fromParts([
              ErrorSummary('A RenderFlex overflowed by 1 pixel. $secret'),
            ]),
          ),
        );
        await fixture.breadcrumb('cleanup');
        expect(await report.readAsString(), pinned);
        expect(fixture.sequence, 3);
        diagnostics.failure(
          const SyncAcceptanceFailure('framework_ui_failure'),
        );
        fixture.result['errorCode'] = diagnostics.toJson()['failureCode'];
        await fixture.publish('failed', status: 'failed');
        final failed = jsonDecode(await report.readAsString()) as Map;
        expect(failed['reportSequence'], 4);
        expect(failed['diagnostic'], {
          'failureCode': 'framework_ui_failure',
          'lastStage': 'awaitingRecoverySave',
          'lastAction': 'save_recovery',
          'frameworkFailure': 'layout_overflow',
        });
        expect(jsonEncode(failed).contains(secret), isFalse);
      } finally {
        if (await report.exists()) await report.delete();
        await directory.delete();
      }
    },
  );
}
