import 'dart:convert';

import 'package:uuid/uuid.dart';

import '../data/snapshot_codec.dart';
import '../data/sqlite_habit_repository.dart';
import 'sync_client.dart';
import 'sync_crypto.dart';
import 'sync_entities.dart';

class SyncOutcome {
  const SyncOutcome({
    this.conflicts = const [],
    this.complete = false,
    this.uploaded = 0,
    this.preview,
  });
  final List<String> conflicts;
  final bool complete;
  final int uploaded;
  final InitialSyncPreview? preview;
}

class InitialSyncPreview {
  const InitialSyncPreview(
    this.local,
    this.remote,
    this.fingerprint,
    this.conflicts,
  );
  final EntityMap local, remote;
  final String fingerprint;
  final List<String> conflicts;
}

/// All network operations happen outside the business database transaction.
/// A frozen operation survives response loss and is retried byte-for-byte.
class SyncEngine {
  SyncEngine(this.repository, this.session);
  final SqliteHabitRepository repository;
  final SyncSession session;
  SyncSettings get settings => session.settings;

  Map<String, dynamic> _fresh(String epoch) => {
    'version': 1,
    'reviewAll': settings.initialReview,
    'previewRequired': true,
    'binding': settings.id,
    'epoch': epoch,
    'cursor': '',
    'highWater': '',
    'bootstrap': true,
    'remote': <String, dynamic>{},
    'base': <String, dynamic>{},
    'pending': <dynamic>[],
    'conflicts': <dynamic>[],
  };

  void _checkLocal(SyncFrame frame) {
    if (SnapshotCodec.decode(frame.snapshot)['vaultId'] !=
        settings.localVault) {
      throw const FormatException('本机已恢复为新的数据空间，同步已停止。请明确核对后重新连接。');
    }
  }

  Map<String, dynamic> _state(SyncFrame frame) {
    _checkLocal(frame);
    final value = frame.state;
    if (value == null || value['binding'] != settings.id) {
      throw const FormatException('同步尚未初始化');
    }
    if (value['version'] is! int || value['version'] != 1) {
      throw const FormatException('同步进度版本不支持，请更新应用');
    }
    return value;
  }

  static EntityMap _payloads(Map<String, dynamic> state) => {
    for (final e in (state['remote'] as Map).entries)
      e.key as String: (e.value as Map)['payload'],
  };

  Future<SyncOutcome> run({void Function(int uploaded)? onProgress}) async {
    try {
      return await _run(onProgress: onProgress);
    } on Object catch (error) {
      // Persist only allowlisted categories, never server text or credentials.
      try {
        final frame = await repository.readSyncFrame();
        _checkLocal(frame);
        final state =
            frame.state == null || frame.state!['binding'] != settings.id
            ? _fresh(settings.tokens['epoch'] as String)
            : _state(frame);
        state['lastFailureCode'] =
            error is SyncApiException &&
                const {
                  'unauthorized',
                  'epoch_changed',
                  'device_stale',
                  'maintenance_read_only',
                  'quota_exceeded',
                  'rate_limited',
                }.contains(error.code)
            ? error.code
            : error is FormatException
            ? 'invalid_data'
            : 'unavailable';
        state['lastFailureAt'] = DateTime.now().toUtc().toIso8601String();
        await repository.commitSyncFrame(frame, state);
      } on Object {
        // Failure reporting cannot replace the original storage/network error.
      }
      rethrow;
    }
  }

  Future<SyncOutcome> _run({void Function(int uploaded)? onProgress}) async {
    final caps = await session.transport.request('GET', '/v1/capabilities');
    if (caps['protocol'] != 1 ||
        caps['epoch'] is! String ||
        !RegExp(r'^[A-Za-z0-9_-]{32}$').hasMatch(caps['epoch'] as String)) {
      throw const FormatException('同步服务协议不兼容');
    }
    var frame = await repository.readSyncFrame();
    _checkLocal(frame);
    if (frame.state == null || frame.state!['binding'] != settings.id) {
      final fresh = _fresh(caps['epoch'] as String);
      await repository.commitSyncFrame(frame, fresh);
    } else if (_state(frame)['epoch'] != caps['epoch']) {
      // A restored server may have forgotten previously acknowledged writes or
      // deletions. Never treat its older state as a new ordinary remote edit.
      throw const SyncApiException('epoch_changed', 409);
    }
    var uploaded = 0;
    for (var round = 0; round < 1000; round++) {
      frame = await repository.readSyncFrame();
      var state = _state(frame);
      if (state['previewRequired'] == true) {
        await _pull();
        frame = await repository.readSyncFrame();
        state = _state(frame);
        final decision = _decision(frame, state);
        return SyncOutcome(
          preview: InitialSyncPreview(
            decision.local,
            decision.remote,
            _previewFingerprint(frame, state),
            decision.conflicts.toList()..sort(),
          ),
        );
      }
      if ((state['pending'] as List).isNotEmpty) {
        uploaded += await _push(frame, state);
        onProgress?.call(uploaded);
        continue;
      }
      await _pull();
      frame = await repository.readSyncFrame();
      state = _state(frame);
      final remote = _payloads(state);
      final decision = _decision(frame, state);
      if (decision.conflicts.isNotEmpty) {
        state['conflicts'] = decision.conflicts.toList()..sort();
        await repository.commitSyncFrame(frame, state);
        return SyncOutcome(
          conflicts: decision.conflicts.toList(),
          uploaded: uploaded,
        );
      }
      final snapshot = SyncEntities.assemble(frame.snapshot, decision.entities);
      state['base'] = remote;
      state['conflicts'] = <dynamic>[];
      state['reviewAll'] = false;
      // Save incoming facts and the baseline in the same transaction.
      await repository.commitSyncFrame(
        frame,
        state,
        snapshot:
            SyncEntities.same(jsonDecode(snapshot), jsonDecode(frame.snapshot))
            ? null
            : snapshot,
      );
      frame = await repository.readSyncFrame();
      state = _state(frame);
      final local = SyncEntities.encode(frame.snapshot);
      final baseline = _payloads(state);
      final changes =
          {...local.keys, ...baseline.keys}
              .where(
                (key) =>
                    !SyncEntities.sameFacts(key, local[key], baseline[key]),
              )
              .toList()
            ..sort();
      if (changes.isEmpty) {
        state['lastSuccess'] = DateTime.now().toUtc().toIso8601String();
        state.remove('lastFailureCode');
        state.remove('lastFailureAt');
        await repository.commitSyncFrame(frame, state);
        return SyncOutcome(complete: true, uploaded: uploaded);
      }
      final annotatedParents = SyncOrigins.stamp(
        local,
        baseline,
        changes,
        settings.tokens['deviceId'] as String,
      );
      for (final key in annotatedParents) {
        if (!changes.contains(key)) changes.add(key);
      }
      changes.sort();
      final pending = <Map<String, dynamic>>[];
      for (final logical in changes) {
        final old = (state['remote'] as Map)[logical] as Map?;
        final base = old?['revision'] as int? ?? 0;
        final deleted = local[logical] == null;
        final entity = settings.keys.opaqueId(logical);
        final cipher = await SyncCrypto.encrypt(
          settings.keys,
          SyncObjectContext(
            vault: settings.keys.vault,
            epoch: state['epoch'] as String,
            entityId: entity,
            baseRevision: base,
            deleted: deleted,
          ),
          logical,
          local[logical],
        );
        final op = <String, dynamic>{
          'opId': const Uuid().v4(),
          'entityId': entity,
          'baseRevision': base,
          'ciphertext': cipher,
          'deleted': deleted,
        };
        pending.add({
          'operation': op,
          'logicalId': logical,
          'payload': local[logical],
        });
      }
      state['pending'] = pending;
      // No request is sent until the exact nonce, ciphertext and opId are durable.
      await repository.commitSyncFrame(
        frame,
        state,
        snapshot: annotatedParents.isEmpty
            ? null
            : SyncEntities.assemble(frame.snapshot, local),
      );
    }
    return SyncOutcome(uploaded: uploaded);
  }

  Future<int> _push(SyncFrame frame, Map<String, dynamic> state) async {
    final allPending = (state['pending'] as List).cast<Map<String, dynamic>>();
    final pending = <Map<String, dynamic>>[];
    var size = 0;
    for (final p in allPending) {
      final length = utf8.encode(jsonEncode(p['operation'])).length;
      if (pending.isNotEmpty &&
          (pending.length >= 100 || size + length > 1500000)) {
        break;
      }
      size += length;
      pending.add(p);
    }
    final response = await session.request(
      'POST',
      '/v1/push',
      body: {
        'epoch': state['epoch'],
        'operations': [for (final p in pending) p['operation']],
      },
    );
    final results = response['results'];
    if (results is! List || results.length != pending.length) {
      throw const FormatException('同步写入回执缺失，待发送操作已保留');
    }
    final byId = <String, Map>{};
    for (final result in results) {
      if (result is! Map ||
          result['opId'] is! String ||
          byId.containsKey(result['opId'])) {
        throw const FormatException('同步回执格式无效');
      }
      byId[result['opId'] as String] = result;
    }
    var accepted = 0;
    for (final p in pending) {
      final op = p['operation'] as Map;
      final result = byId[op['opId']];
      if (result == null) throw const FormatException('同步回执身份不匹配');
      if (result['status'] == 'accepted' &&
          result['revision'] is int &&
          result['revision'] == (op['baseRevision'] as int) + 1) {
        accepted++;
        final logical = p['logicalId'] as String;
        (state['remote'] as Map)[logical] = {
          'revision': result['revision'],
          'payload': p['payload'],
        };
        (state['base'] as Map)[logical] = p['payload'];
      } else if (result['status'] == 'conflict') {
        final current = result['current'];
        if (current == null) throw const FormatException('远端版本发生回退，待发送操作已保留');
        if (current is! Map || current['entityId'] != op['entityId']) {
          throw const FormatException('冲突回执身份不匹配');
        }
        await _receive(state, Map<String, dynamic>.from(current));
      } else {
        throw const FormatException('同步回执版本无效');
      }
    }
    state['pending'] = allPending.skip(pending.length).toList();
    await repository.commitSyncFrame(frame, state);
    return accepted;
  }

  Future<void> _pull() async {
    for (var page = 0; page < 10000; page++) {
      final frame = await repository.readSyncFrame();
      final state = _state(frame);
      final path = state['bootstrap'] == true ? 'bootstrap' : 'pull';
      final query = Uri(
        queryParameters: {
          'epoch': state['epoch'] as String,
          'cursor': state['cursor'] as String,
          'highWater': state['highWater'] as String,
          'limit': '20',
        },
      ).query;
      final result = await session.request('GET', '/v1/$path?$query');
      if (result['epoch'] != state['epoch'] ||
          result['cursor'] is! String ||
          result['highWater'] is! String ||
          result['more'] is! bool ||
          result['objects'] is! List ||
          (result['objects'] as List).length > 20 ||
          (state['highWater'] != '' &&
              state['highWater'] != result['highWater'])) {
        throw const FormatException('同步分页格式无效，游标未推进');
      }
      for (final object in result['objects'] as List) {
        await _receive(state, Map<String, dynamic>.from(object as Map));
      }
      if (result['more'] == true && result['cursor'] == state['cursor']) {
        throw const FormatException('同步分页没有进展');
      }
      state['cursor'] = result['cursor'];
      state['highWater'] = result['more'] == true ? result['highWater'] : '';
      if (result['more'] == false) state['bootstrap'] = false;
      await repository.commitSyncFrame(frame, state);
      if (result['more'] == false) return;
    }
    throw const FormatException('同步分页超过上限，已保存进度');
  }

  Future<void> _receive(
    Map<String, dynamic> state,
    Map<String, dynamic> object,
  ) async {
    if (object['revision'] is! int ||
        object['baseRevision'] is! int ||
        object['revision'] != (object['baseRevision'] as int) + 1 ||
        object['baseRevision'] < 0 ||
        object['deleted'] is! bool ||
        object['encryptionEpoch'] is! String) {
      throw const FormatException('同步对象版本无效');
    }
    final value = await SyncCrypto.decrypt(
      settings.keys,
      SyncObjectContext(
        vault: settings.keys.vault,
        epoch: object['encryptionEpoch'] as String,
        entityId: object['entityId'] as String,
        baseRevision: object['baseRevision'] as int,
        deleted: object['deleted'] as bool,
      ),
      object['ciphertext'] as String,
    );
    if ((value.payload == null) != object['deleted']) {
      throw const FormatException('同步对象删除标记不匹配');
    }
    if (value.payload != null) {
      SyncEntities.habitId(value.logicalId, value.payload);
      // Reject remote input before persisting its shadow or advancing a cursor.
      // Local encode/assemble must still preserve facts from compatible old DBs.
      final payload = value.payload as Map;
      if (value.logicalId.startsWith('h/')) {
        SnapshotCodec.validateImportedTitle(payload['title']);
      } else if (value.logicalId.startsWith('n/')) {
        SnapshotCodec.validateImportedNote(payload['text']);
      }
    }
    final remote = state['remote'] as Map;
    final previous = remote[value.logicalId] as Map?;
    if (previous != null &&
        (previous['revision'] as int) > (object['revision'] as int)) {
      return;
    }
    if (previous != null &&
        previous['revision'] == object['revision'] &&
        !SyncEntities.same(previous['payload'], value.payload)) {
      throw const FormatException('相同远端版本包含不同内容，已停止同步');
    }
    remote[value.logicalId] = {
      'revision': object['revision'],
      'payload': value.payload,
    };
  }

  MergeDecision _decision(SyncFrame frame, Map<String, dynamic> state) {
    final remote = _payloads(state);
    final decision = SyncEntities.merge(
      frame.snapshot,
      Map<String, dynamic>.from(state['base'] as Map),
      remote,
    );
    decision.localDeviceId = settings.tokens['deviceId'] as String;
    if (state['reviewAll'] == true) {
      for (final key in {...decision.local.keys, ...remote.keys}) {
        if (!SyncEntities.sameFacts(key, decision.local[key], remote[key])) {
          final id = SyncEntities.habitId(
            key,
            decision.local[key] ?? remote[key],
          );
          if (id != null) decision.reviewHabit(id);
        }
      }
    }
    return decision;
  }

  String _previewFingerprint(SyncFrame frame, Map<String, dynamic> state) =>
      SyncEntities.canonical([
        settings.id,
        state['epoch'],
        SyncEntities.encode(frame.snapshot),
        state['remote'],
      ]);

  /// Downloading a preview never mutates business facts or sends an outbox.
  /// An explicit confirmation also checks for changes since the dialog opened.
  Future<void> confirmInitialSync(InitialSyncPreview preview) async {
    await _pull();
    final frame = await repository.readSyncFrame();
    final state = _state(frame);
    if (state['previewRequired'] != true ||
        _previewFingerprint(frame, state) != preview.fingerprint) {
      throw const FormatException('预览后本机或远端数据已变化，请重新预览并确认');
    }
    state['previewRequired'] = false;
    await repository.commitSyncFrame(
      frame,
      state,
      snapshot: frame.snapshot,
      protect: true,
    );
  }

  /// Only after explicit server-restore confirmation and fresh authorization.
  /// All differences are reviewed; absence in an older server is not a deletion.
  Future<void> resetBaselineForReview() async {
    final frame = await repository.readSyncFrame();
    _checkLocal(frame);
    final next = _fresh(settings.tokens['epoch'] as String)
      ..['reviewAll'] = true;
    await repository.commitSyncFrame(
      frame,
      next,
      snapshot: frame.snapshot,
      protect: true,
    );
  }

  /// Read-only preparation allows frozen outboxes to be reconciled without
  /// submitting their old ciphertext. Local unsent intentions stay in facts.
  Future<SyncOutcome> prepareRotation() async {
    final initialFrame = await repository.readSyncFrame();
    if (_state(initialFrame)['previewRequired'] == true) {
      throw const FormatException('请先完成首次同步预览确认');
    }
    final before = await session.request('GET', '/v1/vault');
    if (before['readOnly'] != true ||
        before['vaultId'] != settings.keys.vault) {
      throw const FormatException('请先让管理员冻结此空间的写入，再准备密钥轮换');
    }
    await _pull();
    final after = await session.request('GET', '/v1/vault');
    if (after['readOnly'] != true ||
        after['vaultId'] != before['vaultId'] ||
        after['highWater'] != before['highWater']) {
      throw const FormatException('准备期间远端基线发生变化，未确认完成，请重新核对');
    }
    final frame = await repository.readSyncFrame();
    final state = _state(frame);
    final decision = _decision(frame, state);
    if (decision.conflicts.isNotEmpty) {
      state['conflicts'] = decision.conflicts.toList()..sort();
      await repository.commitSyncFrame(frame, state);
      return SyncOutcome(conflicts: decision.conflicts.toList());
    }
    final snapshot = SyncEntities.assemble(frame.snapshot, decision.entities);
    state['base'] = _payloads(state);
    state['pending'] = <dynamic>[];
    state['conflicts'] = <dynamic>[];
    state['rotationPrepared'] = DateTime.now().toUtc().toIso8601String();
    await repository.commitSyncFrame(
      frame,
      state,
      snapshot: snapshot,
      protect: true,
    );
    return const SyncOutcome(complete: true);
  }

  Future<MergeDecision> conflicts() async {
    final frame = await repository.readSyncFrame();
    final state = _state(frame);
    return _decision(frame, state);
  }

  Future<void> resolveItems(
    MergeDecision reviewed,
    Map<String, SyncSelection> selections,
  ) async {
    final frame = await repository.readSyncFrame();
    final state = _state(frame);
    if (state['previewRequired'] == true) {
      throw const FormatException('请先完成首次同步预览确认');
    }
    final current = _decision(frame, state);
    if (current.fingerprint != reviewed.fingerprint) {
      throw const FormatException('冲突内容已更新，请重新核对');
    }
    final entities = current.select(selections);
    final snapshot = SyncEntities.assemble(frame.snapshot, entities);
    state['base'] = _payloads(state);
    state['conflicts'] = <dynamic>[];
    state['reviewAll'] = false;
    await repository.commitSyncFrame(
      frame,
      state,
      snapshot: snapshot,
      protect: true,
    );
  }

  /// A choice applies to one whole habit, protecting cross-entity invariants.
  /// The previous local snapshot remains in protections before any replacement.
  Future<void> resolve(Map<String, bool> useRemote) async {
    final frame = await repository.readSyncFrame();
    final state = _state(frame), remote = _payloads(_state(frame));
    if (state['previewRequired'] == true) {
      throw const FormatException('请先完成首次同步预览确认');
    }
    final decision = _decision(frame, state);
    if (!SyncEntities.same(
      useRemote.keys.toList()..sort(),
      decision.conflicts.toList()..sort(),
    )) {
      throw const FormatException('冲突内容已更新，请重新核对');
    }
    for (final id in decision.conflicts) {
      SyncEntities.chooseHabit(
        decision.entities,
        useRemote[id]! ? decision.remote : decision.local,
        id,
        [
          decision.local,
          decision.remote,
          Map<String, dynamic>.from(state['base'] as Map),
        ],
      );
    }
    final snapshot = SyncEntities.assemble(frame.snapshot, decision.entities);
    state['base'] = remote;
    state['conflicts'] = <dynamic>[];
    state['reviewAll'] = false;
    await repository.commitSyncFrame(
      frame,
      state,
      snapshot: snapshot,
      protect: true,
    );
  }
}
