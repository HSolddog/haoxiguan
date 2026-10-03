import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:ui' show IsolateNameServer;

import 'package:flutter_test/flutter_test.dart';

import '../tools/android_acceptance.dart'
    show
        AcceptanceLaunch,
        AcceptanceOwner,
        CheckpointConflict,
        FailedCheckpointConflict,
        readSettingsCheckpoint,
        writeAtomic;

AcceptanceLaunch launch({
  String build = '10001',
  String phase = 'create',
  String nonce = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
  String? previous,
}) => AcceptanceLaunch.decode(
  jsonEncode({
    'version': 1,
    'package': 'com.haoxiguan.haoxiguan.acceptance',
    'build': build,
    'phase': phase,
    'nonce': nonce,
    'previousRunId': previous,
  }),
  build: build,
);

void duplicateIsolate(List<Object?> values) async {
  final reply = values[0]! as SendPort;
  final request = launch();
  final result = <String, Object?>{'runId': '999', 'status': 'running'};
  final owner = AcceptanceOwner.claim(
    request,
    result,
    'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
    name: values[1]! as String,
  );
  final observed = await AcceptanceOwner.observe(
    request,
    name: values[1]! as String,
  );
  reply.send({'claimed': owner != null, 'observed': observed});
  if (owner != null) {
    owner.port.close();
  }
}

void main() {
  test(
    'host launch requires isolated identity and each real phase predecessor',
    () {
      final first = launch();
      expect(first.previous, isNull);
      for (final request in [
        launch(phase: 'reopen', previous: '1'),
        launch(build: '10002', phase: 'reopen', previous: '2'),
        launch(
          build: '10002',
          phase: 'reopen',
          previous: '3',
          nonce: 'cccccccccccccccccccccccccccccccc',
        ),
      ]) {
        expect(request.phase, 'reopen');
      }
      for (final field in {
        'version': true,
        'package': 'com.other',
        'nonce': 'x',
        'phase': 'unknown',
        'previousRunId': 'unknown',
      }.entries) {
        expect(
          () => AcceptanceLaunch.decode(
            jsonEncode({...first.data, field.key: field.value}),
            build: '10001',
          ),
          throwsFormatException,
        );
      }
      expect(() => launch(phase: 'reopen'), throwsFormatException);
      expect(() => launch(build: '10002'), throwsFormatException);
      expect(
        () => AcceptanceLaunch.decode('{', build: '10001'),
        throwsFormatException,
      );
    },
  );

  test(
    'atomic owner rejects a concurrent isolate and remains owner after terminal completion',
    () async {
      final name = 'acceptance-owner-${DateTime.now().microsecondsSinceEpoch}';
      final result = <String, Object?>{
        'runId': '123',
        'status': 'running',
        'stage': 'bootstrap',
      };
      final owner = AcceptanceOwner.claim(
        launch(),
        result,
        'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
        name: name,
      )!;
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(name);
        owner.port.close();
        AcceptanceOwner.retained.remove(owner);
      });
      final response = ReceivePort();
      addTearDown(response.close);
      final isolate = await Isolate.spawn(duplicateIsolate, [
        response.sendPort,
        name,
      ]);
      addTearDown(() => isolate.kill(priority: Isolate.immediate));
      final observed =
          await response.first.timeout(const Duration(seconds: 5)) as Map;
      expect(observed['claimed'], isFalse);
      expect((observed['observed'] as Map)['runId'], '123');
      expect((observed['observed'] as Map)['pid'], pid);
      expect(result, {
        'runId': '123',
        'status': 'running',
        'stage': 'bootstrap',
      });
      result['status'] = 'passed';
      expect(
        AcceptanceOwner.claim(
          launch(),
          <String, Object?>{},
          'cccccccccccccccccccccccccccccccc',
          name: name,
        ),
        isNull,
      );
      expect(
        (await AcceptanceOwner.observe(launch(), name: name))!['status'],
        'passed',
      );
      expect(
        AcceptanceOwner.claim(
          launch(nonce: 'dddddddddddddddddddddddddddddddd'),
          <String, Object?>{},
          'cccccccccccccccccccccccccccccccc',
          name: name,
        ),
        isNull,
      );
      expect(
        await AcceptanceOwner.observe(
          launch(nonce: 'dddddddddddddddddddddddddddddddd'),
          name: name,
        ),
        isNull,
      );
      expect(result['runId'], '123');
    },
  );

  test(
    'silent or wrong-challenge owner cannot be treated as live or replaced',
    () async {
      final name = 'acceptance-silent-${DateTime.now().microsecondsSinceEpoch}';
      final port = ReceivePort();
      expect(
        IsolateNameServer.registerPortWithName(port.sendPort, name),
        isTrue,
      );
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(name);
        port.close();
      });
      final subscription = port.listen((message) {
        ((message as Map)['reply'] as SendPort).send({'challenge': 'wrong'});
      });
      expect(
        await AcceptanceOwner.observe(
          launch(),
          name: name,
          timeout: const Duration(milliseconds: 30),
        ),
        isNull,
      );
      await subscription.cancel();
      final silent = ReceivePort();
      final silentName = '$name-dead';
      expect(
        IsolateNameServer.registerPortWithName(silent.sendPort, silentName),
        isTrue,
      );
      addTearDown(() {
        IsolateNameServer.removePortNameMapping(silentName);
        silent.close();
      });
      expect(
        await AcceptanceOwner.observe(
          launch(),
          name: silentName,
          timeout: const Duration(milliseconds: 30),
        ),
        isNull,
      );
      expect(
        AcceptanceOwner.claim(
          launch(),
          <String, Object?>{},
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          name: silentName,
        ),
        isNull,
      );
      expect(
        AcceptanceOwner.claim(
          launch(),
          <String, Object?>{},
          'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb',
          name: name,
        ),
        isNull,
      );
    },
  );

  test(
    'nonce and full passed predecessor chain permit only the existing four host launches',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'acceptance-owner-protocol-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final report = File('${directory.path}/acceptance-report.json');
      expect(
        await readSettingsCheckpoint(
          directory,
          '10001',
          report,
          launch: launch(),
        ),
        isNull,
      );
      final phases = [
        (priorBuild: '10001', priorPhase: 'create', build: '10001'),
        (priorBuild: '10001', priorPhase: 'reopen', build: '10002'),
        (priorBuild: '10002', priorPhase: 'reopen', build: '10002'),
      ];
      for (final phase in phases) {
        final prior = {
          'build': phase.priorBuild,
          'phase': phase.priorPhase,
          'runId': '123',
          'status': 'passed',
          'launchNonce': 'cccccccccccccccccccccccccccccccc',
        };
        await writeAtomic(report, jsonEncode(prior));
        final request = launch(
          build: phase.build,
          phase: 'reopen',
          previous: '123',
        );
        expect(
          await readSettingsCheckpoint(
            directory,
            phase.build,
            report,
            launch: request,
          ),
          isNull,
        );
        for (final wrong in [
          {...prior, 'phase': 'unknown'},
          {...prior, 'runId': '124'},
          {...prior, 'launchNonce': request.nonce},
        ]) {
          await writeAtomic(report, jsonEncode(wrong));
          await expectLater(
            readSettingsCheckpoint(
              directory,
              phase.build,
              report,
              launch: request,
            ),
            throwsA(isA<CheckpointConflict>()),
          );
          expect(jsonDecode(await report.readAsString()), wrong);
        }
      }
    },
  );

  test(
    'new build or nonce never replaces a retained first failure or unfinished run',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'acceptance-owner-rejection-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final report = File('${directory.path}/acceptance-report.json');
      for (final status in ['failed', 'running']) {
        final original = {
          'build': '10001',
          'status': status,
          'runId': '123',
          'error': 'first failure',
          'stack': 'first stack',
          'launchNonce': 'cccccccccccccccccccccccccccccccc',
        };
        final raw = jsonEncode(original);
        await writeAtomic(report, raw);
        final request = launch(
          build: '10002',
          phase: 'reopen',
          previous: '123',
        );
        try {
          await readSettingsCheckpoint(
            directory,
            '10002',
            report,
            launch: request,
          );
          fail('must reject fresh replay');
        } on CheckpointConflict catch (error) {
          expect(error.previous, original);
          if (status == 'failed') {
            expect(error, isA<FailedCheckpointConflict>());
          }
        }
        expect(await report.readAsString(), raw);
      }
    },
  );
}
