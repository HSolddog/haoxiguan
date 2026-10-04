import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import '../tools/android_acceptance.dart'
    show
        AcceptanceLaunch,
        acceptanceEngineChannel,
        engineHostIdentity,
        verifyNativeEngineRecreation;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final launch = AcceptanceLaunch.decode(
    jsonEncode({
      'version': 1,
      'package': 'com.haoxiguan.haoxiguan.acceptance',
      'build': '10001',
      'phase': 'create',
      'previousRunId': null,
      'nonce': 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    }),
    build: '10001',
  );
  late Directory directory;
  late File report;
  late Map<String, Object?> result;
  late Map<String, Object?> before;
  late Map<String, Object?> after;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('acceptance-engine-');
    report = File('${directory.path}/report.json');
    result = {
      'package': 'com.haoxiguan.haoxiguan.acceptance',
      'build': '10001',
      'runId': '123456',
      'entryId': 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
      'ownerPid': 313,
      'launchNonce': launch.nonce,
      'status': 'running',
    };
    await report.writeAsString(jsonEncode(result));
    before = {
      'package': 'com.haoxiguan.haoxiguan.acceptance',
      'build': '10001',
      'pid': 313,
      'engineId': 'cccccccccccccccccccccccccccccccc',
      'hostId': 'dddddddddddddddddddddddddddddddd',
      'attachCount': 1,
      'attached': true,
      'uiDisplayed': true,
      'executingDart': true,
    };
    after = {
      ...before,
      'hostId': 'eeeeeeeeeeeeeeeeeeeeeeeeeeeeeeee',
      'attachCount': 2,
    };
  });
  Map<String, Object?> queuedReply(MethodCall call) {
    final request = (call.arguments as Map)['requestId'];
    after.addAll({
      'requestId': request,
      'requestHostId': before['hostId'],
      'requestOutcome': 'executed',
    });
    return {'queued': true, 'requestId': request};
  }

  tearDown(() async {
    messenger.setMockMethodCallHandler(acceptanceEngineChannel, null);
    await directory.delete(recursive: true);
  });

  test(
    'recreation retains real authorization, one request and first raw report',
    () async {
      var requests = 0;
      var reads = 0;
      final raw = await report.readAsString();
      messenger.setMockMethodCallHandler(acceptanceEngineChannel, (call) async {
        if (call.method == 'identity') return reads++ == 0 ? before : after;
        requests++;
        final args = call.arguments as Map;
        expect(args['nonce'], launch.nonce);
        expect(args['runId'], '123456');
        expect(args['entryId'], result['entryId']);
        return queuedReply(call);
      });
      final proof = await verifyNativeEngineRecreation(report, result, launch);
      expect(requests, 1);
      expect(reads, 2);
      expect(proof['before'], before);
      expect(proof['after'], after);
      expect(proof['firstRunningReportUnchanged'], true);
      expect(await report.readAsString(), raw);
      expect(result.containsKey('nativeEngineRecreation'), false);
    },
  );

  test('foreign or malformed identity cannot become a native proof', () {
    for (final value in [
      null,
      {...before, 'package': 'other'},
      {...before, 'build': '10002'},
      {...before, 'pid': true},
      {...before, 'pid': 314},
      {...before, 'attachCount': true},
      {...before, 'attached': 'true'},
      {...before, 'executingDart': false},
      {...before, 'engineId': 'wrong'},
      {...before, 'hostId': null},
    ]) {
      expect(
        () => engineHostIdentity(value, build: '10001', expectedPid: 313),
        throwsFormatException,
      );
    }
  });

  test('a replacement engine is rejected without replaying recreate', () async {
    var requests = 0;
    messenger.setMockMethodCallHandler(acceptanceEngineChannel, (call) async {
      if (call.method == 'identity') {
        return requests == 0
            ? before
            : {...after, 'engineId': 'ffffffffffffffffffffffffffffffff'};
      }
      requests++;
      return queuedReply(call);
    });
    await expectLater(
      verifyNativeEngineRecreation(report, result, launch),
      throwsA(isA<StateError>()),
    );
    expect(requests, 1);
  });

  test('queued reply must bind the exact one request', () async {
    var requests = 0;
    messenger.setMockMethodCallHandler(acceptanceEngineChannel, (call) async {
      if (call.method == 'identity') return before;
      requests++;
      return {'queued': true, 'requestId': 'wrong'};
    });
    await expectLater(
      verifyNativeEngineRecreation(report, result, launch),
      throwsA(isA<StateError>()),
    );
    expect(requests, 1);
  });

  test(
    'an abandoned or unrelated request cannot borrow a new visible host',
    () async {
      for (final corruption in [
        {'requestOutcome': 'abandoned'},
        {'requestOutcome': 'queued'},
        {'requestId': 'ffffffffffffffffffffffffffffffff'},
        {'requestHostId': 'ffffffffffffffffffffffffffffffff'},
      ]) {
        var requests = 0;
        final raw = await report.readAsString();
        messenger.setMockMethodCallHandler(acceptanceEngineChannel, (
          call,
        ) async {
          if (call.method == 'identity') return requests == 0 ? before : after;
          requests++;
          final reply = queuedReply(call);
          after.addAll(corruption);
          return reply;
        });
        await expectLater(
          verifyNativeEngineRecreation(report, result, launch),
          throwsA(isA<StateError>()),
        );
        expect(requests, 1);
        expect(await report.readAsString(), raw);
      }
    },
  );

  test(
    'temporary channel detach can recover only on original visible engine',
    () async {
      var requests = 0, reads = 0;
      messenger.setMockMethodCallHandler(acceptanceEngineChannel, (call) async {
        if (call.method == 'identity') {
          if (requests == 0) return before;
          if (reads++ == 0) {
            throw MissingPluginException('fixture host changing');
          }
          return after;
        }
        requests++;
        return queuedReply(call);
      });
      await verifyNativeEngineRecreation(report, result, launch);
      expect(requests, 1);
      expect(reads, 2);
    },
  );

  test('same host or invisible reattachment times out, never passes', () async {
    for (final next in [
      before,
      {...after, 'uiDisplayed': false},
    ]) {
      var requests = 0;
      messenger.setMockMethodCallHandler(acceptanceEngineChannel, (call) async {
        if (call.method == 'identity') return requests == 0 ? before : next;
        requests++;
        return queuedReply(call);
      });
      await expectLater(
        verifyNativeEngineRecreation(
          report,
          result,
          launch,
          timeout: const Duration(milliseconds: 5),
        ),
        throwsA(isA<TimeoutException>()),
      );
      expect(requests, 1);
    }
  });

  test(
    'another entry overwriting the report cannot be accepted as recreation',
    () async {
      var requests = 0;
      messenger.setMockMethodCallHandler(acceptanceEngineChannel, (call) async {
        if (call.method == 'identity') return requests == 0 ? before : after;
        requests++;
        await report.writeAsString('{"status":"running","runId":"other"}');
        return queuedReply(call);
      });
      await expectLater(
        verifyNativeEngineRecreation(report, result, launch),
        throwsA(isA<StateError>()),
      );
      expect(requests, 1);
    },
  );
}
