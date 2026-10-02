import 'dart:convert';

import '../data/snapshot_codec.dart';
import '../models/habit.dart';

typedef EntityMap = Map<String, dynamic>;

/// Portable entities exclude installation settings, credentials and frozen rewards.
/// Notes and individual records have independent CAS addresses.
class SyncEntities {
  static EntityMap encode(String snapshot) {
    final doc = SnapshotCodec.decode(snapshot);
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
    final raw = jsonEncode({
      ...local,
      'version': SnapshotCodec.currentVersion,
      'habits': [
        for (final id in order)
          if (habits[id] != null) habits[id],
      ],
    });
    SnapshotCodec.decode(raw);
    return raw;
  }

  static bool same(Object? a, Object? b) => canonical(a) == canonical(b);
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
        }
      }
      if (conflicts.isEmpty) rethrow;
    }
    for (final key in {...base.keys, ...local.keys, ...remote.keys}) {
      final b = base[key], l = local[key], r = remote[key];
      if (same(l, b) || same(l, r)) {
        merged[key] = r;
      } else if (same(r, b)) {
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
        merged[key] = l;
        final id = habitId(key, l ?? r ?? b);
        if (id != null) conflicts.add(id);
      }
    }
    try {
      assemble(snapshot, merged);
    } on Object {
      // Cross-entity invariants (delete versus child edit, two plans for one date)
      // need a whole-habit choice, never silent child removal.
      for (final key in {...base.keys, ...local.keys, ...remote.keys}) {
        if (!same(local[key], remote[key])) {
          final id = habitId(key, local[key] ?? remote[key] ?? base[key]);
          if (id != null) conflicts.add(id);
        }
      }
    }
    return MergeDecision(merged, conflicts, local, remote);
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

class MergeDecision {
  MergeDecision(this.entities, this.conflicts, this.local, this.remote);
  final EntityMap entities, local, remote;
  final Set<String> conflicts;
}
