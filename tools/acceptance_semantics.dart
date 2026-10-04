import 'dart:async';

import 'package:flutter/rendering.dart';
import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

class AcceptanceHostIdentityConflict extends StateError {
  AcceptanceHostIdentityConflict(
    this.comparison,
    Map<String, Object?> notified,
    Map<String, Object?> floor,
    Map<String, Object?> current,
  ) : diagnostic = {
        'comparison': comparison,
        'notified': _sample(notified),
        'floor': _sample(floor),
        'current': _sample(current),
      },
      super('semantics host identity conflict: $comparison');

  final String comparison;
  final Map<String, Object?> diagnostic;
  static Map<String, Object?> _sample(Map<String, Object?> value) => {
    for (final key in [
      'package',
      'build',
      'pid',
      'engineId',
      'hostId',
      'attachCount',
      'attached',
      'uiDisplayed',
      'executingDart',
    ])
      key: value[key],
  };
}

/// Rebinds semantics for every newly displayed acceptance Activity host,
/// including a system recreation outside the explicit lifecycle exercise.
class AcceptanceSemanticsRebinder {
  AcceptanceSemanticsRebinder({
    required this.channel,
    required this.decodeIdentity,
    required this.readIdentity,
    required this.onFailure,
    this.timeout = const Duration(seconds: 20),
    this.pollInterval = const Duration(milliseconds: 50),
    DateTime Function()? clock,
  }) : clock = clock ?? DateTime.now;
  final MethodChannel channel;
  final Map<String, Object?> Function(Object?) decodeIdentity;
  final Future<Object?> Function() readIdentity;
  final void Function(Object) onFailure;
  final Duration timeout;
  final Duration pollInterval;
  final DateTime Function() clock;
  final observations = <Map<String, Object?>>[];
  Future<void> _pending = Future<void>.value();
  Object? _failure;
  Map<String, Object?>? _last;
  bool _closed = false;

  void start() {
    channel.setMethodCallHandler((call) async {
      if (call.method != 'hostUiDisplayed') {
        throw MissingPluginException('unknown acceptance host notification');
      }
      await observeHost(call.arguments);
      return null;
    });
  }

  Future<Map<String, Object?>> refresh() async =>
      observeHost(await readIdentity());

  Future<Map<String, Object?>> observeHost(Object? raw) async {
    final deadline = clock().add(timeout);
    Duration remaining() {
      final value = deadline.difference(clock());
      if (value <= Duration.zero) {
        throw TimeoutException(
          'acceptance host did not become visibly attached',
          timeout,
        );
      }
      return value;
    }

    late Map<String, Object?> notified;
    try {
      notified = decodeIdentity(raw);
    } catch (error) {
      _recordFailure(error);
      rethrow;
    }
    Map<String, Object?>? observed;
    final next = _pending.then<void>((_) async {
      if (_closed) {
        throw StateError('acceptance semantics binding is closed');
      }
      if (_failure != null) {
        throw StateError('previous semantics rebind failed');
      }
      await WidgetsBinding.instance.endOfFrame.timeout(remaining());
      if (_closed) {
        throw StateError('acceptance semantics binding is closed');
      }
      final last = _last;
      if (last != null && notified['engineId'] != last['engineId']) {
        throw AcceptanceHostIdentityConflict(
          'foreign_engine',
          notified,
          last,
          notified,
        );
      }
      var floor =
          last != null &&
              (last['attachCount']! as int) > (notified['attachCount']! as int)
          ? last
          : notified;
      if (last != null &&
          last['attachCount'] == notified['attachCount'] &&
          last['hostId'] != notified['hostId']) {
        throw AcceptanceHostIdentityConflict(
          'same_count_host_changed',
          notified,
          last,
          notified,
        );
      }
      late Map<String, Object?> current;
      while (true) {
        current = decodeIdentity(await readIdentity().timeout(remaining()));
        if (current['engineId'] != notified['engineId']) {
          throw AcceptanceHostIdentityConflict(
            'foreign_engine',
            notified,
            floor,
            current,
          );
        }
        if ((current['attachCount']! as int) < (floor['attachCount']! as int)) {
          throw AcceptanceHostIdentityConflict(
            'attach_regression',
            notified,
            floor,
            current,
          );
        }
        if (current['attachCount'] == floor['attachCount'] &&
            current['hostId'] != floor['hostId']) {
          throw AcceptanceHostIdentityConflict(
            'same_count_host_changed',
            notified,
            floor,
            current,
          );
        }
        // Every strictly decoded observation advances the floor, even before
        // its first frame. A later older-but-visible host cannot be accepted.
        floor = current;
        remaining();
        if (current['attached'] == true && current['uiDisplayed'] == true) {
          break;
        }
        final left = remaining();
        await Future<void>.delayed(left < pollInterval ? left : pollInterval);
      }
      if (last?['hostId'] == current['hostId']) {
        observed = last;
        return;
      }
      observed = {...current, 'tree': resendAcceptanceSemantics()};
      _last = observed;
      observations.add(observed!);
    });
    _pending = next.catchError(_recordFailure);
    await next;
    return observed!;
  }

  void _recordFailure(Object error) {
    if (_failure == null) {
      _failure = error;
      onFailure(error);
    }
  }

  Future<Object?> close() async {
    channel.setMethodCallHandler(null);
    await _pending;
    _closed = true;
    return _failure;
  }
}

/// A retained acceptance engine acquires a new Android AccessibilityBridge when
/// its Activity is recreated. The bridge needs the complete existing tree;
/// ordinary framework updates contain only nodes whose semantics changed.
/// This fixture-only operation preserves the render tree, State and node IDs.
Map<String, Object?> resendAcceptanceSemantics() {
  if (SchedulerBinding.instance.schedulerPhase != SchedulerPhase.idle) {
    throw StateError('semantics rebind must run outside a frame');
  }
  final trees = <({SemanticsOwner owner, SemanticsNode root, List<int> ids})>[];
  List<int> ids(SemanticsNode root, SemanticsOwner owner) {
    final result = <int>[];
    void visit(SemanticsNode node) {
      if (!node.attached || !identical(node.owner, owner)) {
        throw StateError('semantics tree has a foreign or detached node');
      }
      result.add(node.id);
      node.visitChildren((child) {
        visit(child);
        return true;
      });
    }

    visit(root);
    if (result.toSet().length != result.length) {
      throw StateError('semantics tree has duplicate IDs');
    }
    return result;
  }

  for (final view in RendererBinding.instance.renderViews) {
    final owner = view.owner?.semanticsOwner;
    final root = owner?.rootSemanticsNode;
    if (owner == null || root == null || root.id != 0) {
      throw StateError('acceptance view has no complete semantics root');
    }
    trees.add((owner: owner, root: root, ids: ids(root, owner)));
  }
  if (trees.isEmpty) throw StateError('acceptance has no rendered view');
  final observations = <Map<String, Object?>>[];
  for (final tree in trees) {
    // These public methods are annotated visibleForTesting. This file is only
    // used by the isolated acceptance target to republish a retained tree.
    // Detach recursively dirties every node; attach preserves its existing ID.
    // ignore: invalid_use_of_visible_for_testing_member
    tree.root.detach();
    // ignore: invalid_use_of_visible_for_testing_member
    tree.root.attach(tree.owner);
    final after = ids(tree.root, tree.owner);
    if (after.length != tree.ids.length ||
        List.generate(
          after.length,
          (i) => after[i] == tree.ids[i],
        ).any((same) => !same)) {
      throw StateError('semantics rebind changed the existing node IDs');
    }
    tree.owner.sendSemanticsUpdate();
    observations.add({
      'rootId': tree.root.id,
      'nodeIds': after,
      'completeNodeCount': after.length,
      'nodeIdsPreserved': true,
    });
  }
  return {'method': 'existingTreeDetachAttach', 'views': observations};
}
