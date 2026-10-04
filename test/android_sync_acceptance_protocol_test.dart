import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';

import '../tools/native_sync/protocol.dart';

void main() {
  const packageA = 'com.haoxiguan.haoxiguan.syncacceptance.a';
  const run = '0123456789abcdef0123456789abcdef';
  final values = <String, Object?>{
    'schemaVersion': 3,
    'runId': run,
    'sdkInt': 24,
    'packageName': packageA,
    'role': 'A',
    'endpoint': 'https://localhost:18443',
    'publicCertificatePem':
        '-----BEGIN CERTIFICATE-----\nYWJjZA==\n-----END CERTIFICATE-----\n',
    'invite': 's' * 43,
  };
  SyncAcceptanceConfig parse(Map<String, Object?> v, {bool public = false}) =>
      SyncAcceptanceConfig.parse(
        jsonEncode(v),
        compiledPackage: packageA,
        compiledBuild: '11001',
        publicOnly: public,
      );

  test(
    'isolated config pins run, role, package, build, SDK and loopback HTTPS',
    () {
      final config = parse(values);
      expect(config.runId, run);
      expect(config.sdkInt, 24);
      expect(config.invite, 's' * 43);
      for (final changed in [
        {'schemaVersion': 2},
        {'schemaVersion': 3.0},
        {'runId': 'prior-run'},
        {'runId': 'A' * 32},
        {'role': 'B'},
        {'role': null},
        {'packageName': 'com.haoxiguan.haoxiguan'},
        {'packageName': 'com.haoxiguan.haoxiguan.acceptance'},
        {'sdkInt': 23},
        {'sdkInt': '24'},
        {'sdkInt': 24.0},
        {'invite': 'secret'},
      ]) {
        expect(
          () => parse({...values, ...changed}),
          throwsA(isA<SyncAcceptanceFailure>()),
        );
      }
      expect(
        () => SyncAcceptanceConfig.parse(
          jsonEncode(values),
          compiledPackage: packageA,
          compiledBuild: '10002',
        ),
        throwsA(isA<SyncAcceptanceFailure>()),
      );
    },
  );

  test('only an explicit loopback TLS port is accepted', () {
    for (final endpoint in [
      'http://localhost:18443',
      'https://localhost',
      'https://localhost:443',
      'https://127.0.0.1:18443',
      'https://sync.example.test:18443',
      'https://localhost.example.test:18443',
      'https://secret@localhost:18443',
      'https://localhost:18443/path',
      'https://localhost:18443?secret=value',
      'https://localhost:18443#fragment',
    ]) {
      expect(
        () => parse({...values, 'endpoint': endpoint}),
        throwsA(isA<SyncAcceptanceFailure>()),
      );
    }
  });

  test('public certificate input excludes key material and multiple roots', () {
    for (final cert in [
      '-----BEGIN PRIVATE KEY-----\nYWJjZA==\n-----END PRIVATE KEY-----\n',
      '${values['publicCertificatePem']}${values['publicCertificatePem']}',
      '${values['publicCertificatePem']}password',
      'cert file path',
      '',
    ]) {
      expect(
        () => parse({...values, 'publicCertificatePem': cert}),
        throwsA(isA<SyncAcceptanceFailure>()),
      );
    }
  });

  test(
    'restart checkpoint keeps public config and excludes the invitation',
    () {
      final config = parse(values);
      expect(config.publicCheckpoint.containsKey('invite'), isFalse);
      final resumed = parse(config.publicCheckpoint, public: true);
      expect(resumed.runId, config.runId);
      expect(resumed.endpoint, config.endpoint);
      expect(resumed.invite, isEmpty);
      expect(
        () => parse(values, public: true),
        throwsA(isA<SyncAcceptanceFailure>()),
      );
      expect(
        () => parse(config.publicCheckpoint),
        throwsA(isA<SyncAcceptanceFailure>()),
      );
    },
  );

  test(
    'barriers reject stale runs, stages, packages, SDK types and protocol',
    () {
      final config = parse(values);
      final ack = <String, Object?>{
        'schemaVersion': 3,
        'runId': run,
        'sdkInt': 24,
        'packageName': packageA,
        'stage': 'awaitingAChangesUploaded',
        'launchId': 'b' * 32,
        'reportSequence': 9,
      };
      bool accept(Map<String, Object?> v) => syncAcceptanceControl(
        jsonEncode(v),
        config: config,
        stage: 'awaitingAChangesUploaded',
        launchId: 'b' * 32,
        reportSequence: 9,
      );
      expect(accept(ack), isTrue);
      for (final changed in [
        {'runId': 'f' * 32},
        {'stage': 'awaitingConvergence'},
        {'packageName': 'com.haoxiguan.haoxiguan.syncacceptance.b'},
        {'sdkInt': 35},
        {'sdkInt': 24.0},
        {'sdkInt': '24'},
        {'sdkInt': null},
        {'schemaVersion': 2},
        {'schemaVersion': 3.0},
        {'launchId': 'c' * 32},
        {'reportSequence': 8},
        {'reportSequence': 9.0},
        {'reportSequence': '9'},
      ]) {
        expect(accept({...ack, ...changed}), isFalse);
      }
      for (final raw in ['null', '[]', '{}', '{"status":"passed"}']) {
        expect(
          syncAcceptanceControl(
            raw,
            config: config,
            stage: 'awaitingAChangesUploaded',
            launchId: 'b' * 32,
            reportSequence: 9,
          ),
          isFalse,
        );
      }
      expect(
        () => syncAcceptanceControl(
          '{"runId":',
          config: config,
          stage: 'awaitingAChangesUploaded',
          launchId: 'b' * 32,
          reportSequence: 9,
        ),
        throwsFormatException,
      );
    },
  );

  test(
    'Go wire watermarks require canonical base64url of nonnegative int64 ASCII decimal',
    () {
      String cursor(String text) =>
          base64Url.encode(ascii.encode(text)).replaceAll('=', '');
      expect(syncAcceptanceHighWater('MA'), 0);
      expect(syncAcceptanceHighWater('MQ'), 1);
      expect(syncAcceptanceHighWater(cursor('20')), 20);
      expect(
        syncAcceptanceHighWater(cursor('9223372036854775807')),
        9223372036854775807,
      );
      for (final decimal in [
        '',
        '-1',
        '+1',
        '01',
        '1.0',
        '1e2',
        ' 1',
        '1\n',
        '9223372036854775808',
      ]) {
        expect(
          () => syncAcceptanceHighWater(cursor(decimal)),
          throwsA(isA<SyncAcceptanceFailure>()),
        );
      }
      for (final wire in <Object?>[
        null,
        1,
        1.0,
        true,
        '0',
        '1',
        'MA==',
        'M A',
        'MB',
        '____',
      ]) {
        expect(
          () => syncAcceptanceHighWater(wire),
          throwsA(isA<SyncAcceptanceFailure>()),
        );
      }
    },
  );
}
