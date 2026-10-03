import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:uuid/uuid.dart';

import '../data/snapshot_codec.dart';
import '../models/category.dart';
import '../models/habit.dart';

typedef EntityMap = Map<String, dynamic>;

/// Portable entities exclude installation settings, credentials and frozen rewards.
/// Notes and individual records have independent CAS addresses.
class SyncEntities {
  static EntityMap encodeFacts(String snapshot) => {
    for (final entry in encode(snapshot).entries)
      entry.key: SyncOrigins.facts(entry.key, entry.value),
  };
  static EntityMap encode(String snapshot) {
    final doc = CategoryMetadata.normalize(SnapshotCodec.decode(snapshot));
    final result = <String, dynamic>{};
    for (final raw in doc['habits']! as List) {
      final h = Habit.fromJson((raw as Map).cast<String, Object?>());
      result['h/${h.id}'] = h.toJson()
        ..remove('entries')
        ..remove('plans')
        ..remove('notes')
        ..remove('completions');
      for (final r in h.entries) {
        result['r/${r.id}'] = {'habitId': h.id, 'data': r.toJson()};
      }
      for (final p in h.plans) {
        result['p/${p.id}'] = {'habitId': h.id, 'data': p.toJson()};
      }
      for (final n in h.notes.entries) {
        final id = base64UrlEncode(utf8.encode(jsonEncode([h.id, n.key])));
        result['n/$id'] = {'habitId': h.id, 'date': n.key, 'text': n.value};
      }
    }
    return result;
  }

  static String? habitId(String key, dynamic value) {
    if (value == null) return key.startsWith('h/') ? key.substring(2) : null;
    if (value is! Map) throw const FormatException('同步对象内容无效');
    if (key.startsWith('h/')) return value['id'] as String;
    if (!key.startsWith('r/') &&
        !key.startsWith('p/') &&
        !key.startsWith('n/')) {
      throw const FormatException('此版本不支持远端对象类型，请更新应用');
    }
    return value['habitId'] as String;
  }

  static String assemble(String localSnapshot, EntityMap entities) {
    final local = SnapshotCodec.decode(localSnapshot);
    final habits = <String, Map<String, dynamic>>{};
    for (final entry in entities.entries) {
      if (entry.value == null) continue;
      if (entry.key.startsWith('h/')) {
        final data = Map<String, dynamic>.from(entry.value as Map);
        if (entry.key != 'h/${data['id']}' ||
            data.containsKey('entries') ||
            data.containsKey('plans') ||
            data.containsKey('notes') ||
            data.containsKey('completions')) {
          throw const FormatException('同步习惯身份或结构无效');
        }
        habits[data['id'] as String] = {
          ...data,
          'entries': <dynamic>[],
          'plans': <dynamic>[],
          'notes': <String, dynamic>{},
        };
      }
    }
    for (final e in entities.entries) {
      if (e.value == null || e.key.startsWith('h/')) continue;
      final v = e.value as Map;
      final parent = habits[habitId(e.key, v)];
      if (parent == null) throw const FormatException('同步批次尚不完整，原记录保留，请稍后重试');
      if (e.key.startsWith('r/') || e.key.startsWith('p/')) {
        final data = Map<String, dynamic>.from(v['data'] as Map);
        if (v.length != 2 || e.key.substring(2) != data['id']) {
          throw const FormatException('同步记录身份无效');
        }
        (parent[e.key.startsWith('r/') ? 'entries' : 'plans'] as List).add(
          data,
        );
      } else {
        if (v.length != 3 || v['text'] is! String) {
          throw const FormatException('同步备注无效');
        }
        final id = base64UrlEncode(
          utf8.encode(jsonEncode([v['habitId'], v['date']])),
        );
        if (e.key != 'n/$id') throw const FormatException('同步备注身份无效');
        (parent['notes'] as Map)[v['date']] = v['text'];
      }
    }
    final order = [
      for (final h in local['habits']! as List) (h as Map)['id'] as String,
    ];
    final added = habits.keys.where((id) => !order.contains(id)).toList()
      ..sort();
    order.addAll(added);
    for (final h in habits.values) {
      (h['plans'] as List).sort(
        (dynamic a, dynamic b) =>
            (a['from'] as String).compareTo(b['from'] as String),
      );
      (h['entries'] as List).sort(
        (dynamic a, dynamic b) =>
            (a['id'] as String).compareTo(b['id'] as String),
      );
    }
    final raw = jsonEncode(
      CategoryMetadata.normalize({
        ...local,
        'version': SnapshotCodec.currentVersion,
        'categories': <dynamic>[],
        'habits': [
          for (final id in order)
            if (habits[id] != null) habits[id],
        ],
      }),
    );
    SnapshotCodec.decode(raw);
    return raw;
  }

  static bool same(Object? a, Object? b) => canonical(a) == canonical(b);
  static bool sameFacts(String key, dynamic a, dynamic b) =>
      same(SyncOrigins.facts(key, a), SyncOrigins.facts(key, b));
  static String canonical(Object? value) => jsonEncode(_sort(value));
  static Object? _sort(Object? value) {
    if (value is Map) {
      final keys = value.keys.cast<String>().toList()..sort();
      return {for (final k in keys) k: _sort(value[k])};
    }
    if (value is List) return value.map(_sort).toList();
    return value;
  }

  static MergeDecision merge(
    String snapshot,
    EntityMap base,
    EntityMap remote,
  ) {
    final local = encode(snapshot);
    final merged = <String, dynamic>{};
    final conflicts = <String>{};
    final structural = <String>{};
    final items = <SyncConflict>[];
    try {
      assemble(snapshot, remote);
    } on Object {
      // An existing peer may race a parent deletion with a child edit. Preserve
      // this graph as a conflict instead of silently dropping orphaned records.
      // A never-seen partial initial upload must wait for its source to finish.
      final ids = <String>{};
      for (final e in remote.entries) {
        final id = habitId(e.key, e.value);
        if (id != null) ids.add(id);
      }
      for (final id in ids) {
        final one = <String, dynamic>{};
        chooseHabit(one, remote, id, [base, local]);
        try {
          assemble(snapshot, one);
        } on Object {
          if (base['h/$id'] == null && local['h/$id'] == null) rethrow;
          conflicts.add(id);
          structural.add(id);
        }
      }
      if (conflicts.isEmpty) rethrow;
    }
    for (final key in {...base.keys, ...local.keys, ...remote.keys}) {
      final b = base[key], l = local[key], r = remote[key];
      if (key.startsWith('h/') &&
          l is Map &&
          r is Map &&
          sameFacts(key, l, r)) {
        merged[key] = {
          ...l,
          if (l.containsKey(SyncOrigins.field) ||
              r.containsKey(SyncOrigins.field))
            SyncOrigins.field: SyncOrigins.combine(
              l[SyncOrigins.field],
              r[SyncOrigins.field],
            ),
        };
      } else if (sameFacts(key, l, b) || sameFacts(key, l, r)) {
        merged[key] = r;
      } else if (sameFacts(key, r, b)) {
        merged[key] = l;
      } else if (_sameBooleanCompletion(key, l, r, local, remote)) {
        // Two devices completing the same deterministic boolean record is one fact.
        final ld = (l as Map)['data'] as Map, rd = (r as Map)['data'] as Map;
        merged[key] =
            (ld['recordedAtUtc'] as String? ?? '').compareTo(
                  rd['recordedAtUtc'] as String? ?? '',
                ) <=
                0
            ? l
            : r;
      } else {
        final id = habitId(key, l ?? r ?? b);
        if (key.startsWith('h/') && b is Map && l is Map && r is Map) {
          // Unrelated habit fields can coexist; only overlapping edits need a
          // choice. Arrays remain atomic so plan/availability semantics survive.
          final value = <String, dynamic>{};
          for (final field in {
            ...b.keys,
            ...l.keys,
            ...r.keys,
          }.cast<String>()) {
            if (field == SyncOrigins.field) {
              value[field] = SyncOrigins.combine(l[field], r[field]);
            } else if (same(l[field], b[field]) || same(l[field], r[field])) {
              value[field] = r[field];
            } else if (same(r[field], b[field])) {
              value[field] = l[field];
            } else {
              value[field] = l[field];
              items.add(
                SyncConflict(key, id!, l[field], r[field], field: field),
              );
              conflicts.add(id);
            }
          }
          merged[key] = value;
        } else {
          merged[key] = l;
          if (id != null) {
            conflicts.add(id);
            items.add(
              SyncConflict(
                key,
                id,
                l,
                r,
                allowRecordBoth: canDuplicateRecord(key, l, r, local, remote),
              ),
            );
          }
        }
      }
    }
    try {
      assemble(snapshot, merged);
    } on Object {
      // Cross-entity invariants (delete versus child edit, two plans for one date)
      // need a whole-habit choice, never silent child removal.
      for (final key in {...base.keys, ...local.keys, ...remote.keys}) {
        if (!sameFacts(key, local[key], remote[key])) {
          final id = habitId(key, local[key] ?? remote[key] ?? base[key]);
          if (id != null) {
            conflicts.add(id);
            structural.add(id);
          }
        }
      }
    }
    final decision = MergeDecision(
      merged,
      conflicts,
      local,
      remote,
      base,
      items,
    );
    // Invalid cross-entity combinations require selecting the involved items;
    // validation after selection prevents orphaned records or overlapping plans.
    for (final id in conflicts) {
      if (structural.contains(id) || !items.any((item) => item.habitId == id)) {
        decision.reviewHabit(id);
      }
    }
    return decision;
  }

  static bool _sameBooleanCompletion(
    String key,
    dynamic l,
    dynamic r,
    EntityMap local,
    EntityMap remote,
  ) {
    if (!key.startsWith('r/') ||
        l is! Map ||
        r is! Map ||
        l['habitId'] != r['habitId']) {
      return false;
    }
    final h = local['h/${l['habitId']}'] ?? remote['h/${l['habitId']}'];
    if (h is! Map || h['recordType'] != 'boolean') return false;
    final a = l['data'] as Map, b = r['data'] as Map;
    return a['deleted'] == false &&
        b['deleted'] == false &&
        a['date'] == b['date'] &&
        a['value'] == 1 &&
        b['value'] == 1;
  }

  static bool canDuplicateRecord(
    String key,
    dynamic l,
    dynamic r,
    EntityMap local,
    EntityMap remote,
  ) {
    if (!key.startsWith('r/') || l is! Map || r is! Map) return false;
    final h = local['h/${l['habitId']}'] ?? remote['h/${l['habitId']}'];
    return h is Map &&
        const {'count', 'duration'}.contains(h['recordType']) &&
        l['data']['deleted'] == false &&
        r['data']['deleted'] == false;
  }

  static void chooseHabit(
    EntityMap target,
    EntityMap source,
    String id,
    Iterable<EntityMap> references,
  ) {
    final keys = {...target.keys, ...source.keys};
    for (final ref in references) {
      keys.addAll(ref.keys);
    }
    for (final key in keys) {
      dynamic value = source[key] ?? target[key];
      for (final ref in references) {
        value ??= ref[key];
      }
      if (habitId(key, value) == id) {
        if (source[key] == null) {
          target.remove(key);
        } else {
          target[key] = source[key];
        }
      }
    }
  }
}

enum SyncChoice { local, remote, both, manual }

class SyncSelection {
  const SyncSelection(this.choice, {this.text});
  final SyncChoice choice;
  final String? text;
}

class SyncConflict {
  const SyncConflict(
    this.logicalId,
    this.habitId,
    this.local,
    this.remote, {
    this.field,
    this.allowRecordBoth = false,
  });
  final String logicalId, habitId;
  final String? field;
  final bool allowRecordBoth;
  final dynamic local, remote;
  String get id => jsonEncode([logicalId, field]);
  bool get isNote => logicalId.startsWith('n/') && field == null;
  bool get canKeepBoth =>
      field == null &&
      local != null &&
      remote != null &&
      (isNote || allowRecordBoth);
  String get label => field == null
      ? logicalId.startsWith('n/')
            ? '每日备注'
            : logicalId.startsWith('r/')
            ? '记录条目'
            : logicalId.startsWith('p/')
            ? '计划版本'
            : '习惯状态'
      : const {
              'title': '名称',
              'emoji': '图标',
              'colorValue': '颜色',
              'category': '分类',
              'reminderTime': '提醒时间',
              'exemptions': '休息日期',
              'pausedAt': '暂停日期',
              'archivedAt': '归档日期',
              'deletedAt': '删除日期',
              'unit': '单位',
              'createdAt': '开始日期',
            }[field] ??
            field!;
}

class MergeDecision {
  MergeDecision(
    this.entities,
    this.conflicts,
    this.local,
    this.remote,
    this.base,
    this.items,
  );
  final EntityMap entities, local, remote, base;
  final Set<String> conflicts;
  final List<SyncConflict> items;
  String? localDeviceId;
  final _reviewedHabits = <String>{};
  late final _itemLogicalIds = items.map((item) => item.logicalId).toSet();
  late final _differentKeysByHabit = _groupDifferences();

  Map<String, List<String>> _groupDifferences() {
    final result = <String, List<String>>{};
    for (final key in {...local.keys, ...remote.keys, ...base.keys}) {
      if (SyncEntities.sameFacts(key, local[key], remote[key])) continue;
      final id = SyncEntities.habitId(
        key,
        local[key] ?? remote[key] ?? base[key],
      );
      if (id != null) result.putIfAbsent(id, () => []).add(key);
    }
    return result;
  }

  /// Initial/recovery review includes one-sided absence: it is never silently
  /// interpreted as permission to delete or resurrect a habit.
  void reviewHabit(String habitId) {
    conflicts.add(habitId);
    if (!_reviewedHabits.add(habitId)) return;
    for (final key in _differentKeysByHabit[habitId] ?? <String>[]) {
      if (!_itemLogicalIds.add(key)) continue;
      items.add(
        SyncConflict(
          key,
          habitId,
          local[key],
          remote[key],
          allowRecordBoth: SyncEntities.canDuplicateRecord(
            key,
            local[key],
            remote[key],
            local,
            remote,
          ),
        ),
      );
    }
  }

  /// Identity covers all candidates, including independently added records, so
  /// a dialog cannot overwrite edits made after it was opened.
  String get fingerprint => SyncEntities.canonical([local, remote, base]);

  List<String> sources(SyncConflict item, {required bool remoteSide}) {
    final map = remoteSide ? remote : local;
    final declared = SyncOrigins.sources(
      map,
      item.logicalId,
      map[item.logicalId],
      fallback: base['h/${item.habitId}'],
    );
    if (declared.isNotEmpty) return declared;
    if (!remoteSide &&
        localDeviceId != null &&
        !SyncEntities.sameFacts(
          item.logicalId,
          local[item.logicalId],
          base[item.logicalId],
        )) {
      return [localDeviceId!];
    }
    return [];
  }

  EntityMap select(Map<String, SyncSelection> selections) {
    if (!SyncEntities.same(
      selections.keys.toList()..sort(),
      items.map((e) => e.id).toList()..sort(),
    )) {
      throw const FormatException('请逐项选择全部冲突内容');
    }
    final result = Map<String, dynamic>.from(
      jsonDecode(jsonEncode(entities)) as Map,
    );
    for (final item in items) {
      final selection = selections[item.id]!;
      dynamic value;
      switch (selection.choice) {
        case SyncChoice.local:
          value = item.local;
        case SyncChoice.remote:
          value = item.remote;
        case SyncChoice.both:
          if (!item.canKeepBoth) throw const FormatException('此项不能同时保留两个值');
          value = item.local;
          if (item.isNote) {
            value = {
              ...item.local as Map,
              'text': '${item.local['text']}\n\n${item.remote['text']}',
            };
          } else {
            final duplicate = Map<String, dynamic>.from(item.remote as Map);
            final data = Map<String, dynamic>.from(duplicate['data'] as Map);
            final id = const Uuid().v4();
            data['id'] = id;
            data['revision'] = 1;
            duplicate['data'] = data;
            result['r/$id'] = duplicate;
          }
        case SyncChoice.manual:
          if (!item.isNote ||
              selection.text == null ||
              selection.text!.trim().isEmpty) {
            throw const FormatException('请输入合并后的备注');
          }
          value = {
            ...(item.local ?? item.remote) as Map,
            'text': selection.text,
          };
      }
      if (item.isNote &&
          (selection.choice == SyncChoice.both ||
              selection.choice == SyncChoice.manual) &&
          (value['text'] as String).length > 2000) {
        throw const FormatException('合并后的备注超过 2000 字，请选择手工合并并缩短；两份原文仍保留');
      }
      if (item.field != null) {
        (result[item.logicalId] as Map)[item.field] = value;
      } else if (value == null) {
        result.remove(item.logicalId);
      } else {
        result[item.logicalId] = value;
      }
    }
    return result;
  }
}

/// Compatibility envelope inside Habit.extensions. Old clients preserve this
/// unknown habit field; record/plan/note payloads and the v1 AEAD wrapper stay
/// byte-structure compatible. A declaration is displayed only when its digest
/// matches the exact candidate facts, so an old client cannot carry stale
/// attribution onto an edit. Shared-key declarations are not device signatures.
class SyncOrigins {
  static const field = 'syncOriginsV1';
  static const maxDeclarations = 128;
  static final _device = RegExp(r'^[A-Za-z0-9_-]{32}$');
  static final _digest = RegExp(r'^[a-f0-9]{64}$');

  static dynamic facts(String logicalId, dynamic payload) {
    if (!logicalId.startsWith('h/') || payload is! Map) return payload;
    return Map<String, dynamic>.from(payload)..remove(field);
  }

  static String digest(String logicalId, dynamic payload) => sha256
      .convert(
        utf8.encode(
          SyncEntities.canonical([logicalId, facts(logicalId, payload)]),
        ),
      )
      .toString();

  static List<Map<String, dynamic>> _read(dynamic raw) {
    if (raw is! List) return [];
    return [
      for (final row in raw.take(maxDeclarations))
        if (row is Map &&
            row.length == 3 &&
            row['entityId'] is String &&
            (row['entityId'] as String).length <= 512 &&
            RegExp(r'^[hrpn]/').hasMatch(row['entityId'] as String) &&
            row['digest'] is String &&
            _digest.hasMatch(row['digest'] as String) &&
            row['deviceId'] is String &&
            _device.hasMatch(row['deviceId'] as String))
          Map<String, dynamic>.from(row),
    ];
  }

  static List<Map<String, dynamic>> combine(dynamic first, dynamic second) {
    final byValue = <String, Map<String, dynamic>>{};
    for (final row in [..._read(first), ..._read(second)]) {
      byValue[SyncEntities.canonical(row)] = row;
    }
    final keys = byValue.keys.toList()..sort();
    return [for (final key in keys.take(maxDeclarations)) byValue[key]!];
  }

  static List<String> sources(
    EntityMap entities,
    String logicalId,
    dynamic payload, {
    dynamic fallback,
  }) {
    if (payload == null) return [];
    final id = SyncEntities.habitId(logicalId, payload);
    final habit = entities['h/$id'] ?? fallback;
    if (habit is! Map) return [];
    final expected = digest(logicalId, payload);
    return _read(habit[field])
        .where(
          (row) => row['entityId'] == logicalId && row['digest'] == expected,
        )
        .map((row) => row['deviceId'] as String)
        .toSet()
        .toList()
      ..sort();
  }

  /// Only stamp real business changes. The annotated snapshot and the frozen
  /// operations commit together before any request, preventing a metadata echo.
  /// Bounded history respects v1's 128 KiB per-object limit; missing/evicted
  /// declarations remain explicitly unknown, never inferred from another row.
  static Set<String> stamp(
    EntityMap entities,
    EntityMap previous,
    Iterable<String> changes,
    String deviceId,
  ) {
    if (!_device.hasMatch(deviceId)) throw const FormatException('来源设备标识无效');
    final rowsByHabit = <String, List<Map<String, dynamic>>>{};
    for (final key in changes) {
      final payload = entities[key];
      final id = SyncEntities.habitId(key, payload ?? previous[key]);
      final parent = entities['h/$id'];
      if (id == null || parent is! Map || payload == null) continue;
      final rows = rowsByHabit.putIfAbsent(id, () => _read(parent[field]));
      final row = {
        'entityId': key,
        'digest': digest(key, payload),
        'deviceId': deviceId,
      };
      rows.removeWhere((old) => old['entityId'] == key);
      rows.add(row);
      if (rows.length > maxDeclarations) rows.removeAt(0);
    }
    final changedParents = <String>{};
    for (final entry in rowsByHabit.entries) {
      final logicalId = 'h/${entry.key}';
      final parent = Map<String, dynamic>.from(entities[logicalId] as Map);
      final rows = entry.value;
      if (rows.length > maxDeclarations) {
        rows.removeRange(0, rows.length - maxDeclarations);
      }
      parent[field] = rows;
      while (rows.isNotEmpty &&
          utf8
                  .encode(
                    jsonEncode({'logicalId': logicalId, 'payload': parent}),
                  )
                  .length >
              128 * 1024) {
        rows.removeAt(0);
      }
      if (rows.isEmpty) parent.remove(field);
      if (!SyncEntities.same(entities[logicalId], parent)) {
        entities[logicalId] = parent;
        changedParents.add(logicalId);
      }
    }
    return changedParents;
  }
}
