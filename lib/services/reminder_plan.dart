import '../models/habit.dart';
import '../models/plan.dart';

class PlannedReminder {
  const PlannedReminder(this.habit, this.date, this.hour, this.minute);
  final Habit habit;
  final DateTime date;
  final int hour;
  final int minute;
  DateTime get wallTime =>
      DateTime.utc(date.year, date.month, date.day, hour, minute);
}

List<PlannedReminder> buildReminderPlan(
  Iterable<Habit> habits,
  DateTime now, {
  int days = 14,
  int limit = 256,
}) {
  final result = <PlannedReminder>[];
  for (final habit in habits) {
    if (habit.archived ||
        habit.inTrash ||
        habit.isPaused ||
        habit.reminderTime == null) {
      continue;
    }
    final parts = habit.reminderTime!.split(':');
    final hour = int.parse(parts[0]);
    final minute = int.parse(parts[1]);
    for (var offset = 0; offset < days; offset++) {
      final day = calendarDay(now, offset);
      if (offset == 0 && hour * 60 + minute <= now.hour * 60 + now.minute) {
        continue;
      }
      if (!habit.isScheduledOn(day) || habit.isCompletedOn(day)) continue;
      result.add(PlannedReminder(habit, day, hour, minute));
    }
  }
  result.sort((a, b) {
    final time = a.wallTime.compareTo(b.wallTime);
    return time != 0 ? time : a.habit.id.compareTo(b.habit.id);
  });
  return result.take(limit).toList(growable: false);
}
