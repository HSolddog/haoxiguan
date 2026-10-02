import 'support/legacy_fixture.dart';
import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/services/reminder_service.dart';
import 'package:haoxiguan/state/habit_controller.dart';

void main() {
  final now = DateTime(2026, 7, 15, 10, 30);

  test('补记会保留实际记录时间并更新统计', () async {
    final controller = HabitController(
      MemoryHabitRepository(legacyFixture(now)),
      clock: () => now,
    );
    await controller.load();
    final habit = controller.habitById('seed-stretch')!;
    final yesterday = now.subtract(const Duration(days: 1));

    await controller.toggleCompletion(habit.id, yesterday);
    final updated = controller.habitById(habit.id)!;

    expect(updated.isCompletedOn(yesterday), isTrue);
    expect(updated.isBackfilledOn(yesterday), isTrue);
  });

  test('导出的数据可以恢复到新的控制器', () async {
    final source = HabitController(
      MemoryHabitRepository(legacyFixture(now)),
      clock: () => now,
    );
    await source.load();
    await source.addHabit(
      title: '冥想 5 分钟',
      emoji: '🧘',
      colorValue: 0xFF5F8068,
      weekdays: const <int>{1, 2, 3, 4, 5, 6, 7},
    );

    final target = HabitController(
      MemoryHabitRepository(legacyFixture(now)),
      clock: () => now,
    );
    await target.load();
    final success = await target.importJson(source.exportJson());

    expect(success, isTrue);
    expect(target.habits.any((habit) => habit.title == '冥想 5 分钟'), isTrue);
  });

  test('暂停后的日期不会计入计划，恢复后会记录为豁免', () async {
    final controller = HabitController(
      MemoryHabitRepository(legacyFixture(now)),
      clock: () => now,
    );
    await controller.load();
    const id = 'seed-reading';

    await controller.togglePaused(id);
    expect(controller.habitById(id)!.isScheduledOn(now), isFalse);
    await controller.togglePaused(id);

    final restored = controller.habitById(id)!;
    expect(restored.isPaused, isFalse);
    expect(restored.exemptions, isNot(contains(dateKey(now))));
    expect(restored.isScheduledOn(now), isTrue);
  });

  test('编辑习惯会更新内容并重新同步提醒', () async {
    final reminders = _FakeReminderScheduler();
    final controller = HabitController(
      MemoryHabitRepository(legacyFixture(now)),
      clock: () => now,
      reminderScheduler: reminders,
    );
    await controller.load();

    await controller.updateHabit(
      habitId: 'seed-reading',
      title: '阅读 30 分钟',
      emoji: '✍️',
      colorValue: 0xFF806A9A,
      weekdays: const <int>{1, 3, 5},
      reminderTime: '20:00',
    );

    final updated = controller.habitById('seed-reading')!;
    expect(updated.title, '阅读 30 分钟');
    expect(updated.weekdays, <int>{1, 3, 5});
    expect(updated.reminderTime, '20:00');
    expect(
      reminders.syncedHabits.lastWhere((h) => h.id == 'seed-reading').title,
      '阅读 30 分钟',
    );
  });

  test('习惯可以调整顺序且归档项保持在末尾', () async {
    final controller = HabitController(
      MemoryHabitRepository(legacyFixture(now)),
      clock: () => now,
    );
    await controller.load();
    await controller.toggleArchived('seed-stretch');

    await controller.reorderActive(0, 2);

    expect(controller.habits.map((habit) => habit.id), <String>[
      'seed-water',
      'seed-reading',
      'seed-stretch',
    ]);
    expect(controller.habits.last.archived, isTrue);
  });

  test('通知操作可以直接完成和稍后提醒', () async {
    final reminders = _FakeReminderScheduler();
    final controller = HabitController(
      MemoryHabitRepository(legacyFixture(now)),
      clock: () => now,
      reminderScheduler: reminders,
    );
    await controller.load();

    reminders.emit(
      const ReminderAction(
        ReminderActionType.complete,
        'seed-reading',
        localDate: '2026-07-15',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(controller.habitById('seed-reading')!.isCompletedOn(now), isTrue);

    reminders.emit(
      const ReminderAction(
        ReminderActionType.snooze,
        'seed-water',
        localDate: '2026-07-15',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(reminders.snoozed.map((habit) => habit.id), contains('seed-water'));
  });

  test('未来日期不能打卡，每周频次可在任意日期完成', () async {
    final controller = HabitController(
      MemoryHabitRepository(legacyFixture(now)),
      clock: () => now,
    );
    await controller.load();
    final habit = controller.habitById('seed-stretch')!;

    await controller.toggleCompletion(
      habit.id,
      now.add(const Duration(days: 1)),
    );
    await controller.toggleCompletion(habit.id, DateTime(2026, 7, 12));

    final updated = controller.habitById(habit.id)!;
    expect(updated.isCompletedOn(DateTime(2026, 7, 12)), isTrue);
    expect(updated.isCompletedOn(now.add(const Duration(days: 1))), isFalse);
  });

  test('每周任意天达到设定次数后，本周期不再重复安排', () async {
    final habit = Habit(
      id: 'flex-week',
      title: '灵活运动',
      emoji: '🏃',
      colorValue: 0xFF5F8068,
      weekdays: const <int>{1, 2, 3, 4, 5, 6, 7},
      createdAt: DateTime(2026, 7, 13),
      scheduleType: 'week',
      scheduleCount: 2,
    );
    final repository = MemoryHabitRepository(
      jsonEncode(<String, Object?>{
        'version': 3,
        'habits': <Object?>[habit.toJson()],
      }),
    );
    final controller = HabitController(repository, clock: () => now);
    await controller.load();

    await controller.toggleCompletion('flex-week', DateTime(2026, 7, 13));
    await controller.toggleCompletion('flex-week', DateTime(2026, 7, 14));
    await controller.toggleCompletion('flex-week', DateTime(2026, 7, 15));

    final updated = controller.habitById('flex-week')!;
    expect(updated.completions.length, 3);
    expect(updated.isScheduledOn(now), isTrue);
    expect(executionLabel(updated), '每周任意 2 天');
  });

  test('旧版固定周几数据保留原有固定星期语义', () {
    final habit = Habit.fromJson(<String, Object?>{
      'id': 'legacy',
      'title': '旧习惯',
      'emoji': '🌱',
      'colorValue': 0xFF5F8068,
      'weekdays': <Object?>[1, 3, 5],
      'createdAt': '2026-07-01T00:00:00',
    });

    expect(habit.scheduleType, 'weekdays');
    expect(habit.scheduleCount, 3);
    expect(executionLabel(habit), '周一、三、五');
    expect(habit.effortEnabled, isFalse);
    expect(habit.wishEnabled, isFalse);
  });

  test('主数据损坏时会从上一份备份恢复且不丢失习惯', () async {
    final backedUpHabit = Habit(
      id: 'backed-up',
      title: '备份里的习惯',
      emoji: '🛟',
      colorValue: 0xFF5F8068,
      weekdays: const <int>{1, 2, 3, 4, 5, 6, 7},
      createdAt: DateTime(2026, 7, 1),
      notes: const <String, String>{'2026-07-14': '今天状态不错'},
    );
    final backup = jsonEncode(<String, Object?>{
      'version': 1,
      'habits': <Object?>[backedUpHabit.toJson()],
    });
    final repository = MemoryHabitRepository('{broken json', backup);
    final controller = HabitController(repository, clock: () => now);

    await controller.load();

    expect(controller.loaded, isFalse);
    expect(repository.value, '{broken json');
    expect(await controller.recoverBackup(), isTrue);
    expect(repository.protectedSources, contains('{broken json'));
    expect(controller.habitById('backed-up')?.title, '备份里的习惯');
    expect(
      controller.habitById('backed-up')?.noteOn(DateTime(2026, 7, 14)),
      '今天状态不错',
    );
    expect(jsonDecode(repository.value!)['version'], 1);
  });

  test('习惯支持分类、自定义奖惩和心愿', () async {
    final controller = HabitController(
      MemoryHabitRepository(legacyFixture(now)),
      clock: () => now,
    );
    await controller.load();

    await controller.addHabit(
      title: '练习口语',
      emoji: '🗣️',
      colorValue: 0xFF6558A8,
      weekdays: const <int>{1, 2, 3, 4, 5},
      category: '学习',
      effortEnabled: true,
      rewardPoints: 12,
      penaltyPoints: 6,
      targetCount: 4,
      rewardPeriod: 'week',
      wishEnabled: true,
      wishTitle: '看一场电影',
      wishTarget: 200,
    );

    final habit = controller.habits.last;
    expect(habit.category, '学习');
    expect(habit.effortEnabled, isTrue);
    expect(habit.rewardPoints, 12);
    expect(habit.penaltyPoints, 6);
    expect(habit.targetCount, 4);
    expect(habit.wishTitle, '看一场电影');
    expect(habit.wishEnabled, isTrue);
    expect(controller.categories, containsAll(<String>['健康', '学习']));
  });

  test('努力值按完成次数奖励，并在已结束周期未达标时扣除', () async {
    final habit = Habit(
      id: 'effort',
      title: '测试习惯',
      emoji: '🎯',
      colorValue: 0xFF5F8068,
      weekdays: const <int>{1, 2, 3, 4, 5, 6, 7},
      createdAt: DateTime(2026, 7, 6),
      effortEnabled: true,
      rewardPoints: 10,
      penaltyPoints: 5,
      targetCount: 3,
      completions: <String, String>{
        '2026-07-06': '2026-07-06T10:00:00',
        '2026-07-07': '2026-07-07T10:00:00',
      },
    );
    final repository = MemoryHabitRepository(
      jsonEncode(<String, Object?>{
        'version': 2,
        'habits': <Object?>[habit.toJson()],
      }),
    );
    final controller = HabitController(repository, clock: () => now);
    await controller.load();

    expect(controller.effortPoints(controller.habits.single), 15);
  });

  test('默认习惯也可以永久删除，主题与回顾周期会持久化', () async {
    final repository = MemoryHabitRepository(legacyFixture(now));
    final controller = HabitController(repository, clock: () => now);
    await controller.load();

    await controller.deleteHabit('seed-water');
    await controller.setThemeColor(0xFF6558A8);
    await controller.setReviewDays(90);

    final restored = HabitController(repository, clock: () => now);
    await restored.load();
    expect(restored.habitById('seed-water')!.inTrash, isTrue);
    await restored.permanentlyDeleteHabit('seed-water');
    expect(restored.habitById('seed-water'), isNull);
    expect(restored.themeColorValue, 0xFF6558A8);
    expect(restored.reviewDays, 90);
  });

  test('今日和习惯页的分类折叠状态分别持久化', () async {
    final repository = MemoryHabitRepository(legacyFixture(now));
    final controller = HabitController(repository, clock: () => now);
    await controller.load();

    await controller.toggleTodayCategory('学习');
    await controller.toggleHabitCategory('健康');

    expect(controller.isTodayCategoryCollapsed('学习'), isTrue);
    expect(controller.isHabitCategoryCollapsed('学习'), isFalse);
    expect(controller.isHabitCategoryCollapsed('健康'), isTrue);

    final restored = HabitController(repository, clock: () => now);
    await restored.load();
    expect(restored.isTodayCategoryCollapsed('学习'), isTrue);
    expect(restored.isHabitCategoryCollapsed('学习'), isFalse);
    expect(restored.isHabitCategoryCollapsed('健康'), isTrue);

    await restored.toggleTodayCategory('学习');
    expect(restored.isTodayCategoryCollapsed('学习'), isFalse);
  });
}

class _FakeReminderScheduler implements ReminderScheduler {
  final _actions = StreamController<ReminderAction>.broadcast();
  final List<Habit> syncedHabits = <Habit>[];
  final List<Habit> snoozed = <Habit>[];

  @override
  Stream<ReminderAction> get actions => _actions.stream;

  void emit(ReminderAction action) => _actions.add(action);

  @override
  Future<bool> requestPermission() async => true;

  @override
  Future<void> snooze(Habit habit, {DateTime? forDate}) async =>
      snoozed.add(habit);

  @override
  Future<void> syncAll(Iterable<Habit> habits) async {
    syncedHabits.addAll(habits);
  }

  @override
  Future<void> syncHabit(Habit habit) async => syncedHabits.add(habit);
}
