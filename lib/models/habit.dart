class Habit {
  Habit({
    required this.id,
    required this.title,
    required this.emoji,
    required this.colorValue,
    required Set<int> weekdays,
    required this.createdAt,
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
    Map<String, Object?> extensions = const <String, Object?>{},
  }) : weekdays = Set.unmodifiable(weekdays),
       completions = Map.unmodifiable(completions),
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
  final Map<String, String> completions;
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
    if (pausedAt != null && !day.isBefore(dateOnly(pausedAt!))) return false;
    return true;
  }

  bool isScheduledOn(DateTime date) {
    final day = dateOnly(date);
    if (!isActiveOn(day)) return false;
    if (scheduleType == 'daily') return true;
    if (scheduleType == 'weekdays') return weekdays.contains(day.weekday);
    if (isCompletedOn(day)) return true;
    return completionsInPeriod(day) < scheduleCount;
  }

  int completionsInPeriod(DateTime date) {
    final start = schedulePeriodStart(date);
    final end = schedulePeriodEnd(date);
    return completions.keys.where((key) {
      final completed = DateTime.tryParse(key);
      return completed != null &&
          !dateOnly(completed).isBefore(start) &&
          !dateOnly(completed).isAfter(end);
    }).length;
  }

  DateTime schedulePeriodStart(DateTime date) {
    final day = dateOnly(date);
    if (scheduleType == 'month') return DateTime(day.year, day.month);
    if (scheduleType == 'week') {
      return day.subtract(Duration(days: day.weekday - 1));
    }
    return day;
  }

  DateTime schedulePeriodEnd(DateTime date) {
    final start = schedulePeriodStart(date);
    if (scheduleType == 'month') {
      return DateTime(
        start.year,
        start.month + 1,
      ).subtract(const Duration(days: 1));
    }
    if (scheduleType == 'week') return start.add(const Duration(days: 6));
    return start;
  }

  bool isCompletedOn(DateTime date) => completions.containsKey(dateKey(date));

  bool isBackfilledOn(DateTime date) {
    final recorded = completions[dateKey(date)];
    if (recorded == null) return false;
    return dateKey(DateTime.parse(recorded).toLocal()) != dateKey(date);
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
  }) {
    return Habit(
      id: id,
      title: title ?? this.title,
      emoji: emoji ?? this.emoji,
      colorValue: colorValue ?? this.colorValue,
      weekdays: weekdays ?? this.weekdays,
      createdAt: createdAt,
      reminderTime: clearReminder ? null : reminderTime ?? this.reminderTime,
      completions: completions ?? this.completions,
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
      createdAt: DateTime.parse(json['createdAt']! as String),
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
      extensions: Map<String, Object?>.from(json),
    );
  }
}

DateTime dateOnly(DateTime value) =>
    DateTime(value.year, value.month, value.day);

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
