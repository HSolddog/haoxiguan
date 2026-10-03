import 'habit.dart';
import 'plan.dart';

/// Daily and selected-weekday plans share a unit; weeks and months never do.
String reviewKind(PlanVersion plan) => plan.flexible ? plan.kind : 'day';

String reviewUnit(String kind) => switch (kind) {
  'week' => '周',
  'month' => '月',
  _ => '次计划',
};

class HistoryGroup {
  HistoryGroup({
    required this.kind,
    required this.settled,
    required this.inProgress,
  });
  final String kind;
  final List<PlanResult> settled;
  final List<PlanResult> inProgress;
  int get completed => settled.where((r) => r.met).length;
  int get expected => settled.length;
  double? get rate => expected == 0 ? null : completed / expected;
}

/// The immutable source is also the optimistic guard: a changed habit needs a
/// fresh preview, so confirmation can never apply a different unseen impact.
class StartDateCorrection {
  const StartDateCorrection({
    required this.original,
    required this.corrected,
    required this.before,
    required this.after,
  });
  final Habit original;
  final Habit corrected;
  final List<HistoryGroup> before;
  final List<HistoryGroup> after;
  DateTime get from => corrected.createdAt;
  DateTime get through => calendarDay(original.createdAt, -1);
}
