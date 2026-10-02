import 'dart:async';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/reminder_plan.dart';
import 'package:haoxiguan/services/reminder_service.dart';
import 'package:haoxiguan/state/habit_controller.dart';

void main() {
  Habit habit(
    String id, {
    String kind = 'daily',
    Set<int> days = const {1, 2, 3, 4, 5, 6, 7},
  }) => Habit(
    id: id,
    title: id,
    emoji: '🌱',
    colorValue: 0xff00ff00,
    weekdays: days,
    createdAt: DateTime.utc(2026, 7, 13),
    reminderTime: '09:30',
    scheduleType: kind,
  );
  test('已过去时间、固定星期、暂停和归档不会产生错误提醒', () {
    final now = DateTime(2026, 7, 13, 10);
    final plan = buildReminderPlan(
      [
        habit('daily'),
        habit('weekdays', kind: 'weekdays', days: {1, 3}),
        habit('archived').copyWith(archived: true),
        habit('paused').copyWith(pausedAt: DateTime.utc(2026, 7, 13)),
      ],
      now,
      days: 7,
    );
    expect(plan.where((r) => r.habit.id == 'daily').length, 6);
    expect(
      plan.where((r) => r.habit.id == 'weekdays').map((r) => dateKey(r.date)),
      ['2026-07-15'],
    );
    expect(
      plan.any((r) => r.habit.id == 'paused' || r.habit.id == 'archived'),
      isFalse,
    );
  });
  test('提醒按实际日期排序且有总量上限', () {
    final plan = buildReminderPlan(
      [habit('z'), habit('a')],
      DateTime(2026, 7, 13, 8),
      limit: 3,
    );
    expect(plan.map((r) => '${r.habit.id}:${dateKey(r.date)}'), [
      'a:2026-07-13',
      'z:2026-07-13',
      'a:2026-07-14',
    ]);
  });
  test('跨午夜重复旧通知仅幂等记录原日期，无日期通知不写入', () async {
    final scheduler = _Scheduler();
    var now = DateTime(2026, 7, 13, 23, 59);
    final controller = HabitController(
      MemoryHabitRepository(),
      clock: () => now,
      reminderScheduler: scheduler,
    );
    await controller.load();
    await controller.addHabit(
      title: '阅读',
      emoji: '📖',
      colorValue: 0xff00ff00,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    );
    final id = controller.habits.single.id;
    now = DateTime(2026, 7, 14, 0, 1);
    for (var i = 0; i < 2; i++) {
      scheduler.events.add(
        ReminderAction(
          ReminderActionType.complete,
          id,
          localDate: '2026-07-13',
        ),
      );
    }
    await Future<void>.delayed(const Duration(milliseconds: 20));
    scheduler.events.add(ReminderAction(ReminderActionType.complete, id));
    await Future<void>.delayed(const Duration(milliseconds: 20));
    expect(controller.habits.single.entries, hasLength(1));
    expect(controller.habits.single.entries.single.revision, 1);
    expect(controller.habits.single.isCompletedOn(now), isFalse);
    controller.dispose();
    await scheduler.events.close();
  });
}

class _Scheduler extends NoopReminderScheduler {
  final events = StreamController<ReminderAction>.broadcast();
  @override
  Stream<ReminderAction> get actions => events.stream;
}
