/// Calendar dates are advanced as calendar components, never fixed 24h spans.
DateTime calendarDay(DateTime date, [int offset = 0]) =>
    DateTime.utc(date.year, date.month, date.day + offset);

class PlanVersion {
  PlanVersion({
    required this.id,
    required this.from,
    required this.kind,
    required Set<int> weekdays,
    required this.periodTarget,
    required this.dailyTarget,
    this.legacyInferred = false,
  }) : weekdays = Set.unmodifiable(weekdays);
  final String id;
  final DateTime from;
  final String kind;
  final Set<int> weekdays;
  final int periodTarget;
  final int dailyTarget;
  final bool legacyInferred;
  bool get flexible => kind == 'week' || kind == 'month';
  bool allows(DateTime day) =>
      kind != 'weekdays' || weekdays.contains(day.weekday);
  DateTime start(DateTime day) => switch (kind) {
    'week' => calendarDay(day, 1 - day.weekday),
    'month' => DateTime.utc(day.year, day.month),
    _ => calendarDay(day),
  };
  DateTime end(DateTime day) => switch (kind) {
    'week' => calendarDay(start(day), 6),
    'month' => DateTime.utc(day.year, day.month + 1, 0),
    _ => calendarDay(day),
  };
  Map<String, Object?> toJson() => {
    'id': id,
    'from': from.toIso8601String().substring(0, 10),
    'kind': kind,
    'weekdays': weekdays.toList()..sort(),
    'periodTarget': periodTarget,
    'dailyTarget': dailyTarget,
    'legacyInferred': legacyInferred,
  };
  factory PlanVersion.fromJson(Map<String, Object?> value) => PlanVersion(
    id: value['id']! as String,
    from: calendarDay(DateTime.parse(value['from']! as String)),
    kind: value['kind']! as String,
    weekdays: (value['weekdays']! as List).cast<int>().toSet(),
    periodTarget: value['periodTarget']! as int,
    dailyTarget: value['dailyTarget']! as int,
    legacyInferred: value['legacyInferred'] as bool? ?? false,
  );
}

class PlanResult {
  const PlanResult({
    required this.plan,
    required this.start,
    required this.end,
    required this.availableDays,
    required this.expected,
    required this.completed,
  });
  final PlanVersion plan;
  final DateTime start;
  final DateTime end;
  final int availableDays;
  final int expected;
  final int completed;
  bool get rested => expected == 0;
  bool get met => expected > 0 && completed >= expected;
}
