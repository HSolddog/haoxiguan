import 'package:uuid/uuid.dart';

import 'plan.dart';
import 'record_entry.dart';

class Habit {
  Habit({
    required this.id,
    required this.title,
    required this.emoji,
    required this.colorValue,
    required Set<int> weekdays,
    required DateTime createdAt,
    this.reminderTime,
    Map<String, String> completions = const <String, String>{},
    Map<String, String> notes = const <String, String>{},
    Set<String> exemptions = const <String>{},
    this.pausedAt,
    this.archived = false,
    this.category = '未分类',
    this.effortEnabled = false,
    this.rewardPoints = 10,
    this.penaltyPoints = 5,
    this.targetCount = 3,
    this.rewardPeriod = 'week',
    this.wishEnabled = false,
    this.wishTitle = '',
    this.wishTarget = 100,
    this.scheduleType = 'daily',
    this.scheduleCount = 1,
    this.recordType = 'boolean',
    this.unit = '次',
    this.scale = 1,
    this.dailyTarget = 1,
    List<RecordEntry>? entries,
    List<PlanVersion> plans = const [],
    this.archivedAt,
    this.deletedAt,
    this.legacyRewardBalance,
    Map<String, Object?> extensions = const <String, Object?>{},
  }) : createdAt = dateOnly(createdAt),
       weekdays = Set.unmodifiable(weekdays),
       entries = List.unmodifiable(
         entries ??
             completions.entries.map((entry) {
               final parsed = DateTime.parse(entry.value);
               final hasOffset = RegExp(
                 r'(Z|[+-]\d\d:\d\d)$',
               ).hasMatch(entry.value);
               return RecordEntry(
                 id: const Uuid().v5(
                   Namespace.url.value,
                   'haoxiguan/record/$id/${entry.key}',
                 ),
                 date: entry.key,
                 value: 1,
                 recordedAtUtc: hasOffset
                     ? parsed.toUtc().toIso8601String()
                     : null,
                 recordedLocalDate: entry.value.substring(0, 10),
                 timezoneId: 'unknownLegacy',
                 utcOffsetMinutes: null,
                 source: 'legacy',
                 legacyTimestamp: entry.value,
               );
             }),
       ),
       plans = List.unmodifiable(plans),
       notes = Map.unmodifiable(notes),
       exemptions = Set.unmodifiable(exemptions),
       extensions = _freeze(extensions) as Map<String, Object?>;

  final String id;
  final String title;
  final String emoji;
  final int colorValue;
  final Set<int> weekdays;
  final DateTime createdAt;
  final String? reminderTime;
  final List<RecordEntry> entries;
  final List<PlanVersion> plans;
  final String recordType;
  final String unit;
  final int scale;
  final int dailyTarget;
  final DateTime? archivedAt;
  final DateTime? deletedAt;
  final int? legacyRewardBalance;
  bool get inTrash => deletedAt != null;

  Map<String, String> get completions => Map.unmodifiable({
    for (final entry in entries)
      if (!entry.deleted && isCompletedOn(DateTime.parse(entry.date)))
        entry.date:
            entry.legacyTimestamp ??
            entry.recordedAtUtc ??
            '${entry.recordedLocalDate}T00:00:00',
  });
  late final Map<String, int> _valuesByDate = _sumEntries();
  Map<String, int> _sumEntries() {
    final result = <String, int>{};
    for (final e in entries) {
      if (!e.deleted) {
        result.update(e.date, (v) => v + e.value, ifAbsent: () => e.value);
      }
    }
    return result;
  }

  int valueOn(DateTime day) => _valuesByDate[dateKey(day)] ?? 0;
  PlanVersion get initialPlan => PlanVersion(
    id: 'legacy-plan-$id',
    from: dateOnly(createdAt),
    kind: scheduleType,
    weekdays: weekdays,
    periodTarget: scheduleCount,
    dailyTarget: dailyTarget,
    legacyInferred: true,
  );
  List<PlanVersion> get effectivePlans => plans.isEmpty ? [initialPlan] : plans;
  PlanVersion planOn(DateTime day) {
    var current = effectivePlans.first;
    for (final plan in effectivePlans) {
      if (plan.from.isAfter(dateOnly(day))) break;
      current = plan;
    }
    return current;
  }

  bool hasPendingPlan(DateTime today) =>
      effectivePlans.last.from.isAfter(dateOnly(today));
  String valueLabel(int value) => recordType == 'duration'
      ? '${value ~/ 60}分${value % 60 == 0 ? '' : '${value % 60}秒'}'
      : '${formatFixed(value, scale: scale)} $unit';
  final Map<String, String> notes;
  final Set<String> exemptions;
  final DateTime? pausedAt;
  final bool archived;
  final String category;
  final bool effortEnabled;
  final int rewardPoints;
  final int penaltyPoints;
  final int targetCount;
  final String rewardPeriod;
  final bool wishEnabled;
  final String wishTitle;
  final int wishTarget;
  final String scheduleType;
  final int scheduleCount;
  // Preserve fields from supported legacy documents that this UI does not edit.
  final Map<String, Object?> extensions;

  bool get isPaused => pausedAt != null;

  bool isActiveOn(DateTime date) {
    final day = dateOnly(date);
    if (day.isBefore(dateOnly(createdAt))) return false;
    if (exemptions.contains(dateKey(day))) return false;
    if (archivedAt != null && !day.isBefore(dateOnly(archivedAt!))) {
      return false;
    }
    if (deletedAt != null && !day.isBefore(calendarDay(deletedAt!, 1))) {
      return false;
    }
    if (pausedAt != null && !day.isBefore(dateOnly(pausedAt!))) return false;
    return true;
  }

  bool isScheduledOn(DateTime date) {
    final day = dateOnly(date);
    if (!isActiveOn(day)) return false;
    final plan = planOn(day);
    if (!plan.allows(day)) return false;
    if (!plan.flexible) return true;
    return isCompletedOn(day) || !periodResult(day).met;
  }

  int completionsInPeriod(DateTime date) => periodResult(date).completed;
  DateTime schedulePeriodStart(DateTime date) => planOn(date).start(date);
  DateTime schedulePeriodEnd(DateTime date) => planOn(date).end(date);
  bool isCompletedOn(DateTime date) =>
      valueOn(date) >= planOn(date).dailyTarget;
  bool isBackfilledOn(DateTime date) => entries.any(
    (entry) =>
        !entry.deleted &&
        entry.date == dateKey(date) &&
        entry.recordedLocalDate != entry.date,
  );

  PlanResult periodResult(DateTime date) {
    final plan = planOn(date);
    var start = plan.start(date);
    if (start.isBefore(plan.from)) start = plan.from;
    if (start.isBefore(dateOnly(createdAt))) start = dateOnly(createdAt);
    var end = plan.end(date);
    for (final next in effectivePlans) {
      if (next.from.isAfter(plan.from) && !next.from.isAfter(end)) {
        end = calendarDay(next.from, -1);
      }
    }
    var available = 0;
    var completed = 0;
    for (var day = start; !day.isAfter(end); day = calendarDay(day, 1)) {
      if (isActiveOn(day) && plan.allows(day)) {
        available++;
        if (isCompletedOn(day)) completed++;
      }
    }
    final desired = plan.flexible ? plan.periodTarget : 1;
    return PlanResult(
      plan: plan,
      start: start,
      end: end,
      availableDays: available,
      expected: available < desired ? available : desired,
      completed: completed,
    );
  }

  Iterable<PlanResult> resultsThrough(DateTime today) sync* {
    var day = dateOnly(createdAt);
    while (!day.isAfter(dateOnly(today))) {
      final result = periodResult(day);
      yield result;
      day = calendarDay(result.end, 1);
    }
  }

  String? noteOn(DateTime date) => notes[dateKey(date)];

  Habit copyWith({
    String? title,
    String? emoji,
    int? colorValue,
    Set<int>? weekdays,
    String? reminderTime,
    bool clearReminder = false,
    Map<String, String>? completions,
    Map<String, String>? notes,
    Set<String>? exemptions,
    DateTime? pausedAt,
    bool clearPausedAt = false,
    bool? archived,
    String? category,
    bool? effortEnabled,
    int? rewardPoints,
    int? penaltyPoints,
    int? targetCount,
    String? rewardPeriod,
    bool? wishEnabled,
    String? wishTitle,
    int? wishTarget,
    String? scheduleType,
    int? scheduleCount,
    String? recordType,
    String? unit,
    int? scale,
    int? dailyTarget,
    List<RecordEntry>? entries,
    List<PlanVersion>? plans,
    DateTime? archivedAt,
    bool clearArchivedAt = false,
    DateTime? deletedAt,
    bool clearDeletedAt = false,
    int? legacyRewardBalance,
  }) {
    return Habit(
      id: id,
      title: title ?? this.title,
      emoji: emoji ?? this.emoji,
      colorValue: colorValue ?? this.colorValue,
      weekdays: weekdays ?? this.weekdays,
      createdAt: createdAt,
      reminderTime: clearReminder ? null : reminderTime ?? this.reminderTime,
      completions: completions ?? const {},
      entries: completions != null ? null : entries ?? this.entries,
      plans: plans ?? this.plans,
      recordType: recordType ?? this.recordType,
      unit: unit ?? this.unit,
      scale: scale ?? this.scale,
      dailyTarget: dailyTarget ?? this.dailyTarget,
      archivedAt: clearArchivedAt ? null : archivedAt ?? this.archivedAt,
      deletedAt: clearDeletedAt ? null : deletedAt ?? this.deletedAt,
      legacyRewardBalance: legacyRewardBalance ?? this.legacyRewardBalance,
      notes: notes ?? this.notes,
      exemptions: exemptions ?? this.exemptions,
      pausedAt: clearPausedAt ? null : pausedAt ?? this.pausedAt,
      archived: archived ?? this.archived,
      category: category ?? this.category,
      effortEnabled: effortEnabled ?? this.effortEnabled,
      rewardPoints: rewardPoints ?? this.rewardPoints,
      penaltyPoints: penaltyPoints ?? this.penaltyPoints,
      targetCount: targetCount ?? this.targetCount,
      rewardPeriod: rewardPeriod ?? this.rewardPeriod,
      wishEnabled: wishEnabled ?? this.wishEnabled,
      wishTitle: wishTitle ?? this.wishTitle,
      wishTarget: wishTarget ?? this.wishTarget,
      scheduleType: scheduleType ?? this.scheduleType,
      scheduleCount: scheduleCount ?? this.scheduleCount,
      extensions: extensions,
    );
  }

  Map<String, Object?> toJson() => <String, Object?>{
    ...extensions,
    'id': id,
    'title': title,
    'emoji': emoji,
    'colorValue': colorValue,
    'weekdays': weekdays.toList()..sort(),
    'createdAt': createdAt.toIso8601String(),
    'reminderTime': reminderTime,
    'completions': completions,
    'notes': notes,
    'exemptions': exemptions.toList(),
    'pausedAt': pausedAt?.toIso8601String(),
    'archived': archived,
    'category': category,
    'effortEnabled': effortEnabled,
    'rewardPoints': rewardPoints,
    'penaltyPoints': penaltyPoints,
    'targetCount': targetCount,
    'rewardPeriod': rewardPeriod,
    'wishEnabled': wishEnabled,
    'wishTitle': wishTitle,
    'wishTarget': wishTarget,
    'scheduleType': scheduleType,
    'scheduleCount': scheduleCount,
    'recordType': recordType,
    'unit': unit,
    'scale': scale,
    'dailyTarget': dailyTarget,
    'entries': entries.map((e) => e.toJson()).toList(),
    'plans': plans.map((p) => p.toJson()).toList(),
    'archivedAt': archivedAt?.toIso8601String(),
    'deletedAt': deletedAt?.toIso8601String(),
    'legacyRewardBalance': legacyRewardBalance,
  };

  factory Habit.fromJson(Map<String, Object?> json) {
    final legacyWeekdays = (json['weekdays']! as List<Object?>)
        .cast<int>()
        .toSet();
    return Habit(
      id: json['id']! as String,
      title: json['title']! as String,
      emoji: json['emoji']! as String,
      colorValue: json['colorValue']! as int,
      weekdays: legacyWeekdays,
      createdAt: DateTime.parse(
        (json['createdAt']! as String).substring(0, 10),
      ),
      reminderTime: json['reminderTime'] as String?,
      completions: (json['completions'] as Map<String, Object?>? ?? const {})
          .map((key, value) => MapEntry(key, value! as String)),
      notes: (json['notes'] as Map<String, Object?>? ?? const {}).map(
        (key, value) => MapEntry(key, value! as String),
      ),
      exemptions: (json['exemptions'] as List<Object?>? ?? const [])
          .cast<String>()
          .toSet(),
      pausedAt: json['pausedAt'] == null
          ? null
          : DateTime.parse(json['pausedAt']! as String),
      archived: json['archived'] as bool? ?? false,
      category: (json['category'] as String?)?.trim().isNotEmpty == true
          ? json['category']! as String
          : '未分类',
      effortEnabled:
          json['effortEnabled'] as bool? ?? json.containsKey('rewardPoints'),
      rewardPoints: json['rewardPoints'] as int? ?? 10,
      penaltyPoints: json['penaltyPoints'] as int? ?? 5,
      targetCount: json['targetCount'] as int? ?? 3,
      rewardPeriod: json['rewardPeriod'] as String? ?? 'week',
      wishEnabled:
          json['wishEnabled'] as bool? ??
          (json['wishTitle'] as String?)?.trim().isNotEmpty == true,
      wishTitle: json['wishTitle'] as String? ?? '',
      wishTarget: json['wishTarget'] as int? ?? 100,
      scheduleType:
          json['scheduleType'] as String? ??
          (legacyWeekdays.length == 7 ? 'daily' : 'weekdays'),
      scheduleCount:
          json['scheduleCount'] as int? ??
          (legacyWeekdays.length == 7 ? 1 : legacyWeekdays.length),
      recordType: json['recordType'] as String? ?? 'boolean',
      unit: json['unit'] as String? ?? '次',
      scale: json['scale'] as int? ?? 1,
      dailyTarget: json['dailyTarget'] as int? ?? 1,
      entries: (json['entries'] as List?)
          ?.map((e) => RecordEntry.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      plans: (json['plans'] as List? ?? [])
          .map((e) => PlanVersion.fromJson((e as Map).cast<String, Object?>()))
          .toList(),
      archivedAt: json['archivedAt'] == null
          ? null
          : DateTime.parse(json['archivedAt']! as String),
      deletedAt: json['deletedAt'] == null
          ? null
          : DateTime.parse(json['deletedAt']! as String),
      legacyRewardBalance: json['legacyRewardBalance'] as int?,
      extensions: Map<String, Object?>.from(json),
    );
  }
}

DateTime dateOnly(DateTime value) =>
    DateTime.utc(value.year, value.month, value.day);

String dateKey(DateTime value) {
  final date = dateOnly(value);
  return '${date.year.toString().padLeft(4, '0')}-'
      '${date.month.toString().padLeft(2, '0')}-'
      '${date.day.toString().padLeft(2, '0')}';
}

const chineseWeekdays = <String>['一', '二', '三', '四', '五', '六', '日'];

String scheduleLabel(Set<int> weekdays) {
  if (weekdays.length == 7) return '每天';
  if (weekdays.length == 5 &&
      weekdays.containsAll(const <int>{1, 2, 3, 4, 5})) {
    return '工作日';
  }
  final days = weekdays.toList()..sort();
  return '周${days.map((day) => chineseWeekdays[day - 1]).join('、')}';
}

String executionLabel(Habit habit) => switch (habit.scheduleType) {
  'weekdays' => scheduleLabel(habit.weekdays),
  'week' => '每周任意 ${habit.scheduleCount} 天',
  'month' => '每月任意 ${habit.scheduleCount} 天',
  _ => '每天',
};

Object? _freeze(Object? value) {
  if (value is Map<String, Object?>) {
    return Map<String, Object?>.unmodifiable(
      value.map((k, v) => MapEntry(k, _freeze(v))),
    );
  }
  if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
  return value;
}
