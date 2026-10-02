import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/record_entry.dart';
import 'package:haoxiguan/state/habit_controller.dart';

void main() {
  late DateTime now;
  late HabitController controller;
  setUp(() async {
    now = DateTime(2026, 7, 13, 10);
    controller = HabitController(
      MemoryHabitRepository(),
      clock: () => now,
      timezoneId: () => 'Asia/Shanghai',
    );
    await controller.load();
  });
  Future<String> create({
    String type = 'boolean',
    String kind = 'daily',
    int count = 1,
    int target = 1,
    Set<int> days = const {1, 2, 3, 4, 5, 6, 7},
  }) async {
    expect(
      await controller.addHabit(
        title: '测试',
        emoji: '🌱',
        colorValue: 0xFF5F8068,
        weekdays: days,
        recordType: type,
        unit: type == 'duration' ? '秒' : '杯',
        scale: type == 'count' ? 1000 : 1,
        dailyTarget: target,
        scheduleType: kind,
        scheduleCount: count,
      ),
      isTrue,
    );
    return controller.habits.last.id;
  }

  test('十进制定点累计精确，重试同一条记录不重复，超额保留', () async {
    final id = await create(type: 'count', target: 300);
    await controller.addValue(id, now, parseFixed('0.1'), entryId: 'a');
    await controller.addValue(id, now, parseFixed('0.2'), entryId: 'b');
    await controller.addValue(id, now, parseFixed('0.2'), entryId: 'b');
    expect(controller.habitById(id)!.valueOn(now), 300);
    expect(controller.habitById(id)!.isCompletedOn(now), isTrue);
    await controller.addValue(id, now, 100);
    expect(controller.habitById(id)!.valueOn(now), 400);
    expect(controller.habitById(id)!.completions.length, 1);
  });
  test('手动时长整数秒累加，更正总量保留备注和旧事实标记', () async {
    final id = await create(type: 'duration', target: 90);
    await controller.addValue(id, now, 60);
    await controller.addValue(id, now, 45);
    await controller.setNote(id, now, '保留');
    expect(controller.habitById(id)!.valueOn(now), 105);
    await controller.addValue(id, now, 30, replaceTotal: true);
    final habit = controller.habitById(id)!;
    expect(habit.valueOn(now), 30);
    expect(habit.entries.where((e) => e.deleted), hasLength(2));
    expect(habit.noteOn(now), '保留');
  });
  test('修改每日目标从明天生效，不重解释已完成历史', () async {
    final id = await create(type: 'count', target: 1000);
    await controller.addValue(id, now, 1000);
    final original = controller.habitById(id)!;
    await controller.updateHabit(
      habitId: id,
      title: original.title,
      emoji: original.emoji,
      colorValue: original.colorValue,
      weekdays: original.weekdays,
      dailyTarget: 2000,
    );
    final updated = controller.habitById(id)!;
    expect(updated.isCompletedOn(now), isTrue);
    expect(updated.planOn(DateTime(2026, 7, 14)).dailyTarget, 2000);
    now = DateTime(2026, 7, 14);
    expect(controller.completionRate(updated), 1);
    expect(controller.expectedCountInRange(updated, days: 30), 1);
  });
  test('周目标修改下周生效，当前周期仍用旧目标', () async {
    final id = await create(kind: 'week', count: 3);
    final habit = controller.habitById(id)!;
    await controller.updateHabit(
      habitId: id,
      title: habit.title,
      emoji: habit.emoji,
      colorValue: habit.colorValue,
      weekdays: habit.weekdays,
      scheduleCount: 5,
    );
    final updated = controller.habitById(id)!;
    expect(updated.planOn(DateTime(2026, 7, 19)).periodTarget, 3);
    expect(updated.planOn(DateTime(2026, 7, 20)).periodTarget, 5);
  });
  test('周六创建三天目标，本周实际目标两天', () async {
    now = DateTime(2026, 7, 18);
    final id = await create(kind: 'week', count: 3);
    expect(controller.habitById(id)!.periodResult(now).expected, 2);
  });
  test('二月 31 天月目标缩为实际 28 天', () async {
    now = DateTime(2027, 2, 1);
    final id = await create(kind: 'month', count: 31);
    expect(controller.habitById(id)!.periodResult(now).expected, 28);
  });
  test('未结算的本周不计失败，上一周按一个周期结算', () async {
    final id = await create(kind: 'week', count: 3);
    await controller.markCompleted(id, now);
    now = DateTime(2026, 7, 14);
    await controller.markCompleted(id, now);
    expect(
      controller.expectedCountInRange(controller.habitById(id)!, days: 30),
      0,
    );
    now = DateTime(2026, 7, 20);
    final habit = controller.habitById(id)!;
    expect(controller.expectedCountInRange(habit, days: 30), 1);
    expect(controller.completedCountInRange(habit, days: 30), 0);
    expect(controller.settledResults(habit).single.completed, 2);
  });
  test('非计划日记录作为额外行为，不加入达标分子', () async {
    final id = await create(kind: 'weekdays', days: {1, 3, 5});
    now = DateTime(2026, 7, 14);
    await controller.markCompleted(id, now);
    now = DateTime(2026, 7, 15);
    final habit = controller.habitById(id)!;
    expect(habit.completions, hasLength(1));
    expect(controller.completedCountInRange(habit, days: 30), 0);
    expect(controller.expectedCountInRange(habit, days: 30), 1);
  });
  test('整周期休息不增加、不打断连续', () async {
    final id = await create(kind: 'week', count: 1);
    await controller.markCompleted(id, now);
    now = DateTime(2026, 7, 20);
    await controller.togglePaused(id);
    now = DateTime(2026, 7, 27);
    await controller.togglePaused(id);
    expect(controller.habitById(id)!.isActiveOn(now), isTrue);
    expect(controller.currentStreak(controller.habitById(id)!), 1);
    expect(
      controller.expectedCountInRange(controller.habitById(id)!, days: 30),
      1,
    );
  });
  test('暂停和取消休息不删除完成事实', () async {
    final id = await create();
    await controller.markCompleted(id, now);
    await controller.toggleRest(id, now);
    expect(controller.habitById(id)!.isCompletedOn(now), isTrue);
    expect(controller.habitById(id)!.isActiveOn(now), isFalse);
    await controller.toggleRest(id, now);
    expect(controller.habitById(id)!.isScheduledOn(now), isTrue);
  });
  test('归档从明天停用，已结束历史仍参与回顾', () async {
    final id = await create();
    await controller.markCompleted(id, now);
    now = DateTime(2026, 7, 14);
    await controller.toggleArchived(id);
    final habit = controller.habitById(id)!;
    expect(habit.isActiveOn(now), isTrue);
    expect(habit.isActiveOn(DateTime(2026, 7, 15)), isFalse);
    expect(controller.completedTotalInRange(days: 30), 1);
  });
  test('删除进回收站，排序不丢弃回收站，恢复保留事实', () async {
    final id = await create();
    await controller.markCompleted(id, now);
    await create();
    await create();
    await controller.deleteHabit(id);
    await controller.reorderActive(0, 2);
    expect(controller.trashedHabits, hasLength(1));
    await controller.restoreHabit(id);
    expect(controller.habitById(id)!.isCompletedOn(now), isTrue);
    expect(controller.trashedHabits, isEmpty);
  });
  test('新记录保存真实时刻、行为日、当时时区；以后不重写', () async {
    final id = await create();
    now = DateTime(2026, 7, 15, 10);
    await controller.markCompleted(id, DateTime(2026, 7, 13));
    final entry = controller.habitById(id)!.entries.single;
    expect(entry.date, '2026-07-13');
    expect(entry.recordedLocalDate, '2026-07-15');
    expect(entry.recordedAtUtc, now.toUtc().toIso8601String());
    expect(entry.timezoneId, 'Asia/Shanghai');
    expect(
      controller.habitById(id)!.isBackfilledOn(DateTime(2026, 7, 13)),
      isTrue,
    );
  });
  test('文件替换恢复创建独立空间，旧来源可追溯', () async {
    await create();
    final before = jsonDecode(controller.exportJson());
    expect(await controller.importJson(controller.exportJson()), isTrue);
    final after = jsonDecode(controller.exportJson());
    expect(after['vaultId'], isNot(before['vaultId']));
    expect(after['restoredFromVaultId'], before['vaultId']);
    expect(after['habits'], before['habits']);
  });
  test('数值精度与输入范围错误明确拒绝', () {
    expect(() => parseFixed('-1'), throwsFormatException);
    expect(() => parseFixed('0.0001'), throwsFormatException);
    expect(() => parseFixed('NaN'), throwsFormatException);
    expect(formatFixed(parseFixed('10.250')), '10.25');
  });
}
