import 'dart:convert';

import 'package:uuid/uuid.dart';

/// Stable category identity. The display name is never an identity after the
/// one-time conversion of legacy name-only categories.
class HabitCategory {
  const HabitCategory({
    required this.id,
    required this.name,
    required this.sortKey,
    this.revision = 1,
    this.extensions = const {},
  });
  final String id, name;
  final int sortKey, revision;
  final Map<String, Object?> extensions;

  HabitCategory copyWith({String? name, int? sortKey, int? revision}) =>
      HabitCategory(
        id: id,
        name: name ?? this.name,
        sortKey: sortKey ?? this.sortKey,
        revision: revision ?? this.revision,
        extensions: extensions,
      );
  Map<String, Object?> toJson() => {
    ...extensions,
    'id': id,
    'name': name,
    'sortKey': sortKey,
    'revision': revision,
  };
  factory HabitCategory.fromJson(Map<String, Object?> value) {
    final id = value['id'], name = value['name'], key = value['sortKey'];
    final revision = value['revision'] ?? 1;
    if (id is! String ||
        id.isEmpty ||
        id.length > 200 ||
        name is! String ||
        name.trim().isEmpty ||
        key is! int ||
        key.abs() > CategoryMetadata.maxSortKey ||
        revision is! int ||
        revision < 1 ||
        revision > CategoryMetadata.maxSortKey) {
      throw const FormatException('分类身份或顺序无效');
    }
    return HabitCategory(
      id: id,
      name: name,
      sortKey: key,
      revision: revision,
      extensions: Map<String, Object?>.unmodifiable(
        Map<String, Object?>.from(value)..removeWhere(
          (key, _) => const {'id', 'name', 'sortKey', 'revision'}.contains(key),
        ),
      ),
    );
  }
}

/// Additive format-7 metadata. Habit.category remains a readable compatibility
/// projection; categoryInfo travels inside the existing encrypted h/ entity.
class CategoryMetadata {
  static const step = 1024;
  static const maxSortKey = 9007199254740991;

  static String legacyId(String name) => const Uuid().v5(
    Namespace.url.value,
    'haoxiguan/category/legacy/v1/${jsonEncode(name)}',
  );

  static int compare(HabitCategory a, HabitCategory b) {
    final byOrder = a.sortKey.compareTo(b.sortKey);
    return byOrder == 0 ? a.id.compareTo(b.id) : byOrder;
  }

  static bool changed(Map<String, Object?> before, Map<String, Object?> after) {
    if (jsonEncode(before['categories']) != jsonEncode(after['categories'])) {
      return true;
    }
    final old = before['habits'] as List, next = after['habits'] as List;
    if (old.length != next.length) return true;
    for (var i = 0; i < old.length; i++) {
      for (final key in [
        'id',
        'category',
        'categoryId',
        'categoryInfo',
        'sortKey',
      ]) {
        if (jsonEncode((old[i] as Map)[key]) !=
            jsonEncode((next[i] as Map)[key])) {
          return true;
        }
      }
    }
    return false;
  }

  static List<HabitCategory> categories(Map<String, Object?> document) =>
      ((document['categories'] as List?) ?? const [])
          .map(
            (e) => HabitCategory.fromJson((e as Map).cast<String, Object?>()),
          )
          .toList()
        ..sort(compare);

  static void validate(Map<String, Object?> document) {
    final rawCategories = document['categories'];
    if (rawCategories != null && rawCategories is! List) {
      throw const FormatException('分类列表无效');
    }
    final ids = <String>{};
    for (final category in categories(document)) {
      if (!ids.add(category.id)) throw const FormatException('分类身份重复');
    }
    for (final raw in document['habits']! as List) {
      final habit = raw as Map;
      final id = habit['categoryId'], key = habit['sortKey'];
      if (id != null && (id is! String || id.isEmpty || id.length > 200)) {
        throw const FormatException('习惯分类身份无效');
      }
      if (key != null && (key is! int || key.abs() > maxSortKey)) {
        throw const FormatException('习惯顺序无效');
      }
      if (habit['categoryInfo'] case final Object info) {
        if (info is! Map) throw const FormatException('习惯分类描述无效');
        final category = HabitCategory.fromJson(info.cast<String, Object?>());
        if (id != null && id != category.id) {
          throw const FormatException('习惯分类身份与描述不一致');
        }
      }
    }
  }

  /// Preserve each existing fact/plan/entry ID. Migration seeds missing metadata
  /// from the old visible category names and array order, without rewriting facts.
  static Map<String, Object?> normalize(Map<String, Object?> document) {
    validate(document);
    final byId = <String, HabitCategory>{};
    void accept(HabitCategory candidate) {
      final current = byId[candidate.id];
      if (current == null || candidate.revision > current.revision) {
        byId[candidate.id] = candidate;
      } else if (candidate.revision == current.revision) {
        if (candidate.name != current.name) {
          throw const FormatException('同一分类身份含不同名称，请核对分类冲突');
        }
        if (candidate.sortKey < current.sortKey) byId[candidate.id] = candidate;
      }
    }

    for (final category in categories(document)) {
      accept(category);
    }
    final habits = <Map<String, Object?>>[
      for (final raw in document['habits']! as List)
        Map<String, Object?>.from(raw as Map),
    ];
    for (final habit in habits) {
      if (habit['categoryInfo'] case final Map info) {
        accept(HabitCategory.fromJson(info.cast<String, Object?>()));
      }
    }
    String nameOf(Map<String, Object?> habit) {
      final name = habit['category'] as String?;
      return name?.trim().isNotEmpty == true ? name! : '未分类';
    }

    final names = habits.map(nameOf).toSet().toList()..sort();
    for (var i = 0; i < habits.length; i++) {
      final habit = habits[i];
      final name = nameOf(habit);
      final rawId = habit['categoryId'] as String?;
      final info = habit['categoryInfo'] as Map?;
      // An older app may edit only the legacy category label. Treat that as a
      // reassignment, preserving the previous category rather than renaming it.
      final legacyEdited = info != null && name != info['name'];
      var id = legacyEdited ? null : rawId ?? info?['id'] as String?;
      HabitCategory? category = id == null ? null : byId[id];
      if (id == null) {
        final matching = byId.values.where((c) => c.name == name).toList()
          ..sort(compare);
        category = matching.firstOrNull;
        id = category?.id ?? legacyId(name);
      }
      category ??= HabitCategory(
        id: id,
        name: name,
        sortKey: names.indexOf(name) * step,
      );
      accept(category);
      habit['categoryId'] = id;
      habit['sortKey'] ??= i * step;
    }
    for (final habit in habits) {
      final category = byId[habit['categoryId']]!;
      habit['category'] = category.name;
      habit['categoryInfo'] = category.toJson();
    }
    habits.sort((a, b) {
      final byOrder = (a['sortKey'] as int).compareTo(b['sortKey'] as int);
      return byOrder == 0
          ? (a['id'] as String).compareTo(b['id'] as String)
          : byOrder;
    });
    final all = byId.values.toList()..sort(compare);
    return {
      ...document,
      'habits': habits,
      'categories': all.map((c) => c.toJson()).toList(),
    };
  }
}
