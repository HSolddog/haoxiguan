import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/models/plan.dart';
import 'package:haoxiguan/state/habit_controller.dart';

void main() {
  late HabitController controller;
  final today = DateTime.utc(2026, 10, 3);
  setUp(() async {
    controller = HabitController(MemoryHabitRepository(), clock: () => today);
    await controller.load();
  });
  tearDown(() => controller.dispose());

  Future<bool> create(
    DateTime start, {
    String kind = 'daily',
    int target = 1,
  }) => controller.addHabit(
    title: '历史',
    emoji: '🌱',
    colorValue: 0xff5f8068,
    weekdays: {1, 2, 3, 4, 5, 6, 7},
    startDate: start,
    scheduleType: kind,
    scheduleCount: target,
  );

  test('创建可选过去开始日期，今天默认不生成历史，禁止未来', () async {
    expect(await create(DateTime.utc(2026, 9, 30)), isTrue);
    final habit = controller.habits.single;
    expect(habit.createdAt, DateTime.utc(2026, 9, 30));
    expect(habit.effectivePlans.single.from, habit.createdAt);
    expect(habit.entries, isEmpty);
    expect(await create(calendarDay(today, 1)), isFalse);
    expect(controller.habits, hasLength(1));
    await controller.toggleCompletion(habit.id, calendarDay(today, 1));
    expect(controller.habits.single.entries, isEmpty);
  });

  test('历史校正先预览分母，确认前不能补录；确认保留记录和备注', () async {
    await create(today);
    final id = controller.habits.single.id;
    await controller.markCompleted(id, today);
    await controller.setNote(id, today, '保留实际事实');
    final original = controller.habits.single;
    final earlier = DateTime.utc(2026, 9, 30);
    final preview = controller.previewStartDateCorrection(id, earlier);
    expect(preview.before.single.expected, 0);
    expect(preview.after.single.expected, 3);
    expect(controller.habits.single, same(original));
    await controller.toggleCompletion(id, earlier);
    expect(controller.habits.single.isCompletedOn(earlier), isFalse);
    expect(await controller.confirmStartDateCorrection(preview), isTrue);
    expect(
      controller.habits.single.entries.single,
      same(original.entries.single),
    );
    expect(controller.habits.single.noteOn(today), '保留实际事实');
    await controller.markCompleted(id, earlier);
    expect(controller.habits.single.isBackfilledOn(earlier), isTrue);
  });

  test('校正已有更改时拒绝旧预览，避免确认未见过的影响', () async {
    await create(today);
    final id = controller.habits.single.id;
    final preview = controller.previewStartDateCorrection(
      id,
      calendarDay(today, -2),
    );
    await controller.setNote(id, today, '预览之后新增');
    expect(await controller.confirmStartDateCorrection(preview), isFalse);
    expect(controller.habits.single.createdAt, today);
    expect(controller.habits.single.noteOn(today), '预览之后新增');
  });

  test('周六开始周目标校正至周五，首周期实际目标在预览反映', () async {
    await create(today, kind: 'week', target: 3);
    final preview = controller.previewStartDateCorrection(
      controller.habits.single.id,
      calendarDay(today, -1),
    );
    expect(preview.before.single.inProgress.single.expected, 2);
    expect(preview.after.single.inProgress.single.expected, 3);
    expect(controller.habits.single.periodResult(today).expected, 2);
  });

  test('日周月历史分组，零分母为空值，进行中不算失败，顶层只计日', () async {
    final start = DateTime.utc(2026, 8, 30);
    final habit = Habit(
      id: 'mixed',
      title: '变化',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      createdAt: start,
      plans: [
        PlanVersion(
          id: 'd',
          from: start,
          kind: 'daily',
          weekdays: {},
          periodTarget: 1,
          dailyTarget: 1,
        ),
        PlanVersion(
          id: 'w',
          from: DateTime.utc(2026, 8, 31),
          kind: 'week',
          weekdays: {},
          periodTarget: 3,
          dailyTarget: 1,
        ),
        PlanVersion(
          id: 'm',
          from: DateTime.utc(2026, 9, 7),
          kind: 'month',
          weekdays: {},
          periodTarget: 31,
          dailyTarget: 1,
        ),
      ],
    );
    final groups = controller.historyGroups(habit, days: 60);
    expect(groups.map((g) => g.kind), ['day', 'week', 'month']);
    expect(groups[0].expected, 1);
    expect(groups[1].expected, 1);
    expect(groups[1].settled.single.expected, 3);
    expect(groups[2].expected, 1);
    expect(groups[2].settled.single.expected, 24);
    expect(groups[2].inProgress.single.expected, 31);
    await create(today, kind: 'week', target: 3);
    expect(
      controller.historyGroups(controller.habits.single).single.rate,
      isNull,
    );
    expect(controller.expectedTotalInRange(days: 60), 0);
  });
}
