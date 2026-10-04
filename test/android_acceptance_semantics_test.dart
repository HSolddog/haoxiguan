import 'dart:async';
import 'dart:convert';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/backup_restore_dialog.dart';

import '../tools/acceptance_semantics.dart';
import '../tools/android_acceptance.dart' show engineHostIdentity;

// Observes the real framework's serialized updateNode calls. The receiver below
// models only the pinned Android bridge's root-reachability pruning; it is not
// an Android device or a substitute for the native XML/click acceptance gates.
class _Receiver {
  static final nodes =
      <int, ({String label, String value, List<int> children, int actions})>{};
  static final batches =
      <
        Map<
          int,
          ({String label, String value, List<int> children, int actions})
        >
      >[];
  static void update(
    Map<int, ({String label, String value, List<int> children, int actions})>
    changed,
  ) {
    batches.add(Map.of(changed));
    nodes.addAll(changed);
    final reached = <int>{};
    void visit(int id) {
      if (!reached.add(id)) return;
      final node = nodes[id];
      if (node != null) {
        for (final child in node.children) {
          visit(child);
        }
      }
    }

    if (nodes.containsKey(0)) visit(0);
    nodes.removeWhere((id, _) => !reached.contains(id));
  }

  static void newBridge() {
    nodes.clear();
    batches.clear();
  }
}

class _Binding extends AutomatedTestWidgetsFlutterBinding {
  @override
  ui.SemanticsUpdateBuilder createSemanticsUpdateBuilder() => _UpdateBuilder();
}

class _UpdateBuilder extends Fake implements ui.SemanticsUpdateBuilder {
  final _builder = ui.SemanticsUpdateBuilder();
  final changed =
      <int, ({String label, String value, List<int> children, int actions})>{};
  @override
  void updateNode({
    required int id,
    required SemanticsFlags flags,
    required int actions,
    required int maxValueLength,
    required int currentValueLength,
    required int textSelectionBase,
    required int textSelectionExtent,
    required int platformViewId,
    required int scrollChildren,
    required int scrollIndex,
    required int? traversalParent,
    required double scrollPosition,
    required double scrollExtentMax,
    required double scrollExtentMin,
    required Rect rect,
    required String identifier,
    required String label,
    List<StringAttribute>? labelAttributes,
    required String value,
    List<StringAttribute>? valueAttributes,
    required String increasedValue,
    List<StringAttribute>? increasedValueAttributes,
    required String decreasedValue,
    List<StringAttribute>? decreasedValueAttributes,
    required String hint,
    List<StringAttribute>? hintAttributes,
    String? tooltip,
    TextDirection? textDirection,
    required Float64List transform,
    required Float64List hitTestTransform,
    required Int32List childrenInTraversalOrder,
    required Int32List childrenInHitTestOrder,
    required Int32List additionalActions,
    int headingLevel = 0,
    String? linkUrl,
    SemanticsRole role = SemanticsRole.none,
    required List<String>? controlsNodes,
    SemanticsValidationResult validationResult = SemanticsValidationResult.none,
    ui.SemanticsHitTestBehavior hitTestBehavior =
        ui.SemanticsHitTestBehavior.defer,
    required ui.SemanticsInputType inputType,
    required ui.Locale? locale,
    required String minValue,
    required String maxValue,
  }) {
    expectSync(changed.containsKey(id), isFalse);
    changed[id] = (
      label: label,
      value: value,
      children: childrenInTraversalOrder.toList(),
      actions: actions,
    );
  }

  @override
  void updateCustomAction({
    required int id,
    String? label,
    String? hint,
    int overrideId = -1,
  }) => _builder.updateCustomAction(
    id: id,
    label: label,
    hint: hint,
    overrideId: overrideId,
  );
  @override
  ui.SemanticsUpdate build() {
    _Receiver.update(changed);
    return _builder.build();
  }
}

class _Owner extends StatefulWidget {
  const _Owner({super.key});
  @override
  State<_Owner> createState() => _OwnerState();
}

class _OwnerState extends State<_Owner> {
  static int creations = 0;
  int count = 0;
  @override
  void initState() {
    super.initState();
    creations++;
  }

  void change() => setState(() => count++);
  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Semantics(container: true, child: Text('owner $count')));
}

class _Repository extends MemoryHabitRepository {
  int replacements = 0;
  Completer<void>? pending;
  @override
  Future<void> replace(String raw) async {
    replacements++;
    await pending?.future;
    await super.replace(raw);
  }
}

Future<T> _settleFuture<T>(WidgetTester tester, Future<T> future) async {
  var completed = false;
  future.then(
    (_) => completed = true,
    onError: (Object _, StackTrace _) => completed = true,
  );
  for (var frame = 0; frame < 8 && !completed; frame++) {
    await tester.pump(const Duration(milliseconds: 1));
  }
  expectSync(
    completed,
    isTrue,
    reason: 'the serialized host rebind must finish within eight pumped frames',
  );
  return future;
}

void main() {
  _Binding();
  testWidgets(
    'held semantics sends an orphan delta to a new bridge; full resend preserves IDs and State',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        _Receiver.newBridge();
        _OwnerState.creations = 0;
        final key = GlobalKey<_OwnerState>();
        await tester.pumpWidget(MaterialApp(home: _Owner(key: key)));
        final state = key.currentState!;
        final initialIds = _Receiver.nodes.keys.toSet();
        expectSync(initialIds, contains(0));
        _Receiver.newBridge();
        state.change();
        await tester.pump();
        expectSync(_Receiver.batches.expand((batch) => batch.keys), isNotEmpty);
        expectSync(
          _Receiver.batches.any((batch) => batch.containsKey(0)),
          isFalse,
        );
        expectSync(
          _Receiver.nodes,
          isEmpty,
        ); // The old fixture cannot populate an empty bridge.
        final proof = resendAcceptanceSemantics();
        expectSync(_Receiver.nodes.keys.toSet(), initialIds);
        expectSync(
          _Receiver.nodes.values.map((node) => node.label),
          contains('owner 1'),
        );
        expectSync((proof['views'] as List).single['nodeIdsPreserved'], true);
        expectSync(identical(key.currentState, state), isTrue);
        expectSync(_OwnerState.creations, 1);
        expectSync(state.count, 1);
        _Receiver.newBridge();
        resendAcceptanceSemantics();
        expectSync(_Receiver.nodes.keys.toSet(), initialIds);
        expectSync(_OwnerState.creations, 1);
        expectSync(tester.takeException(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'later native host notifications rebind the same tree, with no second owner or business call',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final key = GlobalKey<_OwnerState>();
        _OwnerState.creations = 0;
        await tester.pumpWidget(MaterialApp(home: _Owner(key: key)));
        final state = key.currentState;
        var host = <String, Object?>{
          'package': 'com.haoxiguan.haoxiguan.acceptance',
          'build': '10002',
          'pid': 313,
          'engineId': 'c' * 32,
          'hostId': 'd' * 32,
          'attachCount': 1,
          'attached': true,
          'uiDisplayed': true,
          'executingDart': true,
        };
        final errors = <Object>[];
        final rebinder = AcceptanceSemanticsRebinder(
          channel: const MethodChannel('acceptance-semantics-test'),
          decodeIdentity: (raw) =>
              engineHostIdentity(raw, build: '10002', expectedPid: 313),
          readIdentity: () async => host,
          onFailure: errors.add,
        );
        final first = rebinder.observeHost(host);
        await _settleFuture(tester, first);
        final ids = _Receiver.nodes.keys.toSet();
        final duplicate = rebinder.observeHost(host);
        await _settleFuture(tester, duplicate);
        expectSync(rebinder.observations.length, 1);
        final oldHost = host;
        host = {...host, 'hostId': 'e' * 32, 'attachCount': 2};
        _Receiver.newBridge();
        // Even a queued notification from the old host is matched to the current
        // new host, rather than publishing into a detached bridge.
        final later = rebinder.observeHost(oldHost);
        final observed = await _settleFuture(tester, later);
        expectSync(observed['hostId'], host['hostId']);
        expectSync(rebinder.observations.length, 2);
        expectSync(_Receiver.nodes.keys.toSet(), ids);
        expectSync(identical(key.currentState, state), isTrue);
        expectSync(_OwnerState.creations, 1);
        expectSync(errors, isEmpty);
        expectSync(await rebinder.close(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'queued old notification waits for the strictly identified new host first frame',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        _OwnerState.creations = 0;
        final key = GlobalKey<_OwnerState>();
        await tester.pumpWidget(MaterialApp(home: _Owner(key: key)));
        final state = key.currentState!;
        final ids = _Receiver.nodes.keys.toSet();
        final original = _hostIdentity();
        final nextHost = {...original, 'hostId': 'e' * 32, 'attachCount': 2};
        var reads = 0;
        final errors = <Object>[];
        final rebinder = AcceptanceSemanticsRebinder(
          channel: const MethodChannel('acceptance-semantics-delayed-visible'),
          decodeIdentity: (raw) =>
              engineHostIdentity(raw, build: '10002', expectedPid: 313),
          readIdentity: () async => {
            ...nextHost,
            'attached': ++reads > 1,
            'uiDisplayed': reads > 2,
          },
          onFailure: errors.add,
          timeout: const Duration(milliseconds: 20),
          pollInterval: const Duration(milliseconds: 2),
          clock: tester.binding.clock.now,
        );
        _Receiver.newBridge();
        final observed = await _settleFuture(
          tester,
          rebinder.observeHost(original),
        );
        expectSync(reads, 3);
        expectSync(observed['hostId'], nextHost['hostId']);
        expectSync(observed['attachCount'], 2);
        expectSync(observed['attached'], isTrue);
        expectSync(observed['uiDisplayed'], isTrue);
        expectSync(rebinder.observations.length, 1);
        expectSync(_Receiver.nodes.keys.toSet(), ids);
        expectSync(_Receiver.batches.length, 1);
        expectSync(errors, isEmpty);
        expectSync(identical(key.currentState, state), isTrue);
        expectSync(_OwnerState.creations, 1);
        expectSync(state.count, 0);
        expectSync(await rebinder.close(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'invisible observations advance the attachment floor and foreign samples fail immediately',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final key = GlobalKey<_OwnerState>();
        await tester.pumpWidget(MaterialApp(home: _Owner(key: key)));
        final state = key.currentState!;
        final original = _hostIdentity();
        final invisible = {
          ...original,
          'hostId': 'e' * 32,
          'attachCount': 2,
          'uiDisplayed': false,
        };
        final invalidSamples = <Map<String, Object?>>[
          original,
          {...invisible, 'hostId': 'f' * 32, 'uiDisplayed': true},
          {...invisible, 'engineId': 'f' * 32, 'uiDisplayed': true},
          {...invisible, 'pid': 314, 'uiDisplayed': true},
          {...invisible, 'build': '10001', 'uiDisplayed': true},
        ];
        for (final invalid in invalidSamples) {
          var reads = 0;
          final errors = <Object>[];
          final rebinder = AcceptanceSemanticsRebinder(
            channel: const MethodChannel('acceptance-semantics-invalid-floor'),
            decodeIdentity: (raw) =>
                engineHostIdentity(raw, build: '10002', expectedPid: 313),
            readIdentity: () async => ++reads == 1 ? invisible : invalid,
            onFailure: errors.add,
            timeout: const Duration(milliseconds: 20),
            pollInterval: const Duration(milliseconds: 1),
            clock: tester.binding.clock.now,
          );
          _Receiver.newBridge();
          await _settleFuture(
            tester,
            expectLater(
              rebinder.observeHost(original),
              throwsA(anyOf(isA<StateError>(), isA<FormatException>())),
            ),
          );
          expectSync(reads, 2);
          expectSync(errors.length, 1);
          expectSync(errors.single, isNot(isA<TimeoutException>()));
          expectSync(rebinder.observations, isEmpty);
          expectSync(_Receiver.batches, isEmpty);
          expectSync(_Receiver.nodes, isEmpty);
          expectSync(identical(key.currentState, state), isTrue);
          expectSync(state.count, 0);
          expectSync(await rebinder.close(), same(errors.single));
        }
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'one deadline bounds visibility and identity reads and a late reply cannot publish a tree',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final key = GlobalKey<_OwnerState>();
        await tester.pumpWidget(MaterialApp(home: _Owner(key: key)));
        final state = key.currentState!;
        final original = _hostIdentity();
        for (final stalledRead in [false, true]) {
          final reply = Completer<Object?>();
          var reads = 0;
          final errors = <Object>[];
          final rebinder = AcceptanceSemanticsRebinder(
            channel: const MethodChannel(
              'acceptance-semantics-visible-timeout',
            ),
            decodeIdentity: (raw) =>
                engineHostIdentity(raw, build: '10002', expectedPid: 313),
            readIdentity: () {
              reads++;
              return stalledRead
                  ? reply.future
                  : Future.value({...original, 'uiDisplayed': false});
            },
            onFailure: errors.add,
            timeout: const Duration(milliseconds: 4),
            pollInterval: const Duration(milliseconds: 1),
            clock: tester.binding.clock.now,
          );
          _Receiver.newBridge();
          await _settleFuture(
            tester,
            expectLater(
              rebinder.observeHost(original),
              throwsA(isA<TimeoutException>()),
            ),
          );
          expectSync(reads, greaterThan(0));
          expectSync(errors.length, 1);
          expectSync(rebinder.observations, isEmpty);
          if (stalledRead) reply.complete(original);
          await tester.pump(const Duration(milliseconds: 1));
          expectSync(_Receiver.batches, isEmpty);
          expectSync(_Receiver.nodes, isEmpty);
          expectSync(rebinder.observations, isEmpty);
          expectSync(identical(key.currentState, state), isTrue);
          expectSync(state.count, 0);
          expectSync(await rebinder.close(), same(errors.single));
        }
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'a captured old handler reads a coherent current binding through the detached gap',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final key = GlobalKey<_OwnerState>();
        await tester.pumpWidget(MaterialApp(home: _Owner(key: key)));
        final state = key.currentState!;
        final original = _hostIdentity();
        final next = {...original, 'hostId': 'e' * 32, 'attachCount': 2};
        var binding = original;
        Future<Object?> capturedOldHandler() async => binding;
        var reads = 0;
        final errors = <Object>[];
        final rebinder = AcceptanceSemanticsRebinder(
          channel: const MethodChannel('acceptance-coherent-binding'),
          decodeIdentity: (raw) =>
              engineHostIdentity(raw, build: '10002', expectedPid: 313),
          readIdentity: () {
            reads++;
            if (reads > 1) binding = next;
            return capturedOldHandler();
          },
          onFailure: errors.add,
          timeout: const Duration(milliseconds: 20),
          pollInterval: const Duration(milliseconds: 1),
          clock: tester.binding.clock.now,
        );
        binding = {...original, 'attached': false, 'uiDisplayed': false};
        _Receiver.newBridge();
        final observed = await _settleFuture(
          tester,
          rebinder.observeHost(original),
        );
        expectSync(reads, 2);
        expectSync(observed['hostId'], next['hostId']);
        expectSync(observed['attachCount'], 2);
        expectSync(rebinder.observations.length, 1);
        expectSync(_Receiver.batches.length, 1);
        expectSync(_Receiver.nodes, contains(0));
        expectSync(identical(key.currentState, state), isTrue);
        expectSync(state.count, 0);
        expectSync(errors, isEmpty);
        expectSync(await rebinder.close(), isNull);
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'hybrid old host with a new generation is rejected with exact comparison evidence',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        await tester.pumpWidget(const MaterialApp(home: _Owner()));
        final original = _hostIdentity();
        final newHost = {...original, 'hostId': 'e' * 32, 'attachCount': 2};
        final samples = [
          (
            'same_count_host_changed',
            {...original, 'attachCount': 2, 'attached': false},
            newHost,
          ),
          ('attach_regression', newHost, original),
          ('foreign_engine', original, {...original, 'engineId': 'f' * 32}),
        ];
        for (final (comparison, notified, current) in samples) {
          final errors = <Object>[];
          final rebinder = AcceptanceSemanticsRebinder(
            channel: const MethodChannel('acceptance-hybrid-binding-rejected'),
            decodeIdentity: (raw) =>
                engineHostIdentity(raw, build: '10002', expectedPid: 313),
            readIdentity: () async => current,
            onFailure: errors.add,
          );
          _Receiver.newBridge();
          await _settleFuture(
            tester,
            expectLater(
              rebinder.observeHost(notified),
              throwsA(isA<AcceptanceHostIdentityConflict>()),
            ),
          );
          final error = errors.single as AcceptanceHostIdentityConflict;
          expectSync(error.comparison, comparison);
          expectSync(error.diagnostic['comparison'], comparison);
          expectSync(error.diagnostic['notified'], notified);
          expectSync(error.diagnostic['floor'], notified);
          expectSync(error.diagnostic['current'], current);
          expectSync(_Receiver.batches, isEmpty);
          expectSync(rebinder.observations, isEmpty);
          expectSync(await rebinder.close(), same(error));
        }
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'a delayed captured identity reply interleaves with a queued new-host observation',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final key = GlobalKey<_OwnerState>();
        _OwnerState.creations = 0;
        await tester.pumpWidget(MaterialApp(home: _Owner(key: key)));
        final state = key.currentState!;
        final original = _hostIdentity();
        final nextHost = {...original, 'hostId': 'e' * 32, 'attachCount': 2};
        for (final hybrid in [true, false]) {
          final capturedReply = Completer<Object?>();
          var reads = 0;
          final errors = <Object>[];
          final rebinder = AcceptanceSemanticsRebinder(
            channel: const MethodChannel('acceptance-interleaved-binding'),
            decodeIdentity: (raw) =>
                engineHostIdentity(raw, build: '10002', expectedPid: 313),
            readIdentity: () =>
                ++reads == 1 ? capturedReply.future : Future.value(nextHost),
            onFailure: errors.add,
            timeout: const Duration(milliseconds: 20),
            pollInterval: const Duration(milliseconds: 1),
            clock: tester.binding.clock.now,
          );
          _Receiver.newBridge();
          final oldObservation = rebinder.observeHost(original);
          final oldChecked = expectLater(
            oldObservation,
            hybrid ? throwsA(isA<AcceptanceHostIdentityConflict>()) : completes,
          );
          await tester.pump(const Duration(milliseconds: 1));
          expectSync(reads, 1);
          // The new host is notified while the messenger-captured old handler's
          // reply remains in flight. It must queue behind that pending read.
          final newObservation = rebinder.observeHost(nextHost);
          final newChecked = expectLater(
            newObservation,
            hybrid ? throwsStateError : completes,
          );
          await tester.pump(const Duration(milliseconds: 1));
          expectSync(reads, 1);
          expectSync(rebinder.observations, isEmpty);
          expectSync(_Receiver.batches, isEmpty);
          capturedReply.complete(
            hybrid
                ? {...original, 'attachCount': 2, 'attached': false}
                : nextHost,
          );
          await _settleFuture(tester, Future.wait([oldChecked, newChecked]));
          if (hybrid) {
            final error = errors.single as AcceptanceHostIdentityConflict;
            expectSync(error.comparison, 'same_count_host_changed');
            expectSync(
              (error.diagnostic['floor'] as Map)['hostId'],
              original['hostId'],
            );
            expectSync(
              (error.diagnostic['current'] as Map)['hostId'],
              nextHost['hostId'],
            );
            expectSync(rebinder.observations, isEmpty);
            expectSync(_Receiver.nodes, isEmpty);
            expectSync(_Receiver.batches, isEmpty);
            expectSync(await rebinder.close(), same(error));
          } else {
            expectSync(errors, isEmpty);
            expectSync(rebinder.observations.length, 1);
            expectSync(
              rebinder.observations.single['hostId'],
              nextHost['hostId'],
            );
            expectSync(_Receiver.batches.length, 1);
            expectSync(_Receiver.nodes, contains(0));
            expectSync(await rebinder.close(), isNull);
          }
          expectSync(identical(key.currentState, state), isTrue);
          expectSync(_OwnerState.creations, 1);
          expectSync(state.count, 0);
        }
      } finally {
        handle.dispose();
      }
    },
  );

  testWidgets(
    'foreign engine or in-frame refresh fails closed without replay or State mutation',
    (tester) async {
      final handle = tester.ensureSemantics();
      try {
        final key = GlobalKey<_OwnerState>();
        await tester.pumpWidget(MaterialApp(home: _Owner(key: key)));
        final state = key.currentState;
        var host = <String, Object?>{
          'package': 'com.haoxiguan.haoxiguan.acceptance',
          'build': '10002',
          'pid': 313,
          'engineId': 'c' * 32,
          'hostId': 'd' * 32,
          'attachCount': 1,
          'attached': true,
          'uiDisplayed': true,
          'executingDart': true,
        };
        final errors = <Object>[];
        final rebinder = AcceptanceSemanticsRebinder(
          channel: const MethodChannel('acceptance-semantics-test'),
          decodeIdentity: (raw) =>
              engineHostIdentity(raw, build: '10002', expectedPid: 313),
          readIdentity: () async => host,
          onFailure: errors.add,
        );
        final first = rebinder.observeHost(host);
        await _settleFuture(tester, first);
        final oldHost = host;
        host = {
          ...host,
          'engineId': 'f' * 32,
          'hostId': 'e' * 32,
          'attachCount': 2,
        };
        final failed = expectLater(
          rebinder.observeHost(oldHost),
          throwsStateError,
        );
        await _settleFuture(tester, failed);
        expectSync(errors.length, 1);
        expectSync(rebinder.observations.length, 1);
        expectSync(identical(key.currentState, state), isTrue);
        expectSync(await rebinder.close(), same(errors.single));
        WidgetsBinding.instance.addPostFrameCallback((_) {
          expectSync(resendAcceptanceSemantics, throwsStateError);
        });
        await tester.pump();
      } finally {
        handle.dispose();
      }
    },
  );

  for (final confirm in [false, true]) {
    testWidgets(
      'real restore dialog full resend preserves ${confirm ? 'pending confirm' : 'compatibility draft and cancel'} without replay',
      (tester) async {
        final handle = tester.ensureSemantics();
        try {
          final repository = _Repository();
          final controller = HabitController(
            repository,
            clock: () => DateTime(2026, 7, 13),
          );
          await controller.load();
          await controller.addHabit(
            title: 'retained-before',
            emoji: 'A',
            colorValue: 0xff5f8068,
            weekdays: {1, 2, 3, 4, 5, 6, 7},
          );
          addTearDown(controller.dispose);
          final before = controller.exportJson();
          final source = jsonDecode(before) as Map<String, dynamic>;
          (source['habits'] as List).single['title'] = confirm
              ? 'confirmed-after'
              : 'L' * 81;
          final raw = jsonEncode(source);
          final navigator = GlobalKey<NavigatorState>();
          final dialogKey = GlobalKey<BackupRestoreDialogState>();
          await tester.pumpWidget(
            MaterialApp(navigatorKey: navigator, home: const Scaffold()),
          );
          final future = showDialog<bool>(
            context: navigator.currentContext!,
            builder: (_) => BackupRestoreDialog(
              key: dialogKey,
              controller: controller,
              raw: raw,
              preview: BackupPreview.forRestore(raw),
            ),
          );
          await tester.pumpAndSettle();
          final state = dialogKey.currentState;
          if (confirm) {
            repository.pending = Completer<void>();
            await tester.tap(find.byKey(const Key('confirm-restore-button')));
            await tester.pump();
            expectSync(find.byType(LinearProgressIndicator), findsOneWidget);
            expectSync(repository.replacements, 1);
          } else {
            await tester.tap(
              find.byKey(const Key('restore-preserve-legacy-text')),
            );
            await tester.pumpAndSettle();
            expectSync(
              tester
                  .widget<CheckboxListTile>(
                    find.byKey(const Key('restore-preserve-legacy-text')),
                  )
                  .value,
              isTrue,
            );
          }
          final stored = await repository.load();
          final oldModel = controller.exportJson();
          final originalSerializedIds = _Receiver.nodes.keys.toSet();
          _Receiver.newBridge();
          final proof = resendAcceptanceSemantics();
          expectSync(_Receiver.nodes, contains(0));
          final labels = _Receiver.nodes.values
              .map((node) => node.label)
              .join('\n');
          expectSync(labels, contains('取消'));
          expectSync(labels, contains('保护当前数据并恢复'));
          expectSync(
            _Receiver.nodes.keys.toSet(),
            originalSerializedIds,
            reason:
                'the new bridge receives every previously serialized node; merged children remain represented by their ancestor',
          );
          final view = (proof['views'] as List).single;
          expectSync(
            view['completeNodeCount'],
            (view['nodeIds'] as List).length,
          );
          expectSync(identical(dialogKey.currentState, state), isTrue);
          expectSync(navigator.currentState!.canPop(), isTrue);
          expectSync(await repository.load(), stored);
          expectSync(controller.exportJson(), oldModel);
          expectSync(repository.replacements, confirm ? 1 : 0);
          if (confirm) {
            expectSync(find.byType(LinearProgressIndicator), findsOneWidget);
            repository.pending!.complete();
            await tester.pumpAndSettle();
            expectSync(await future, isTrue);
            expectSync(repository.replacements, 1);
            expectSync(controller.habits.single.title, 'confirmed-after');
            expectSync(await repository.loadBackup(), before);
          } else {
            expectSync(
              tester
                  .widget<CheckboxListTile>(
                    find.byKey(const Key('restore-preserve-legacy-text')),
                  )
                  .value,
              isTrue,
            );
            await tester.tap(find.text('取消'));
            await tester.pumpAndSettle();
            expectSync(await future, isFalse);
            expectSync(controller.exportJson(), before);
            expectSync(repository.replacements, 0);
          }
          expectSync(tester.takeException(), isNull);
        } finally {
          handle.dispose();
        }
      },
    );
  }
}

Map<String, Object?> _hostIdentity() => {
  'package': 'com.haoxiguan.haoxiguan.acceptance',
  'build': '10002',
  'pid': 313,
  'engineId': 'c' * 32,
  'hostId': 'd' * 32,
  'attachCount': 1,
  'attached': true,
  'uiDisplayed': true,
  'executingDart': true,
};
