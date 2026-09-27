import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../data/habit_repository.dart';
import '../models/habit.dart';
import '../services/reminder_service.dart';

class HabitController extends ChangeNotifier {
  HabitController(
    this._repository, {
    DateTime Function()? clock,
    ReminderScheduler? reminderScheduler,
  }) : _clock = clock ?? DateTime.now,
       _reminders = reminderScheduler ?? NoopReminderScheduler() {
    _reminderSubscription = _reminders.actions.listen(_handleReminderAction);
  }

  final HabitRepository _repository;
  final DateTime Function() _clock;
  final ReminderScheduler _reminders;
  late final StreamSubscription<ReminderAction> _reminderSubscription;
  final List<Habit> _habits = <Habit>[];
  bool _darkMode = false;
  int _themeColorValue = 0xFF5F8068;
  int _reviewDays = 30;
  final Set<String> _collapsedTodayCategories = <String>{};
  final Set<String> _collapsedHabitCategories = <String>{};
  bool _loaded = false;

  bool get loaded => _loaded;
  bool get darkMode => _darkMode;
  int get themeColorValue => _themeColorValue;
  int get reviewDays => _reviewDays;
  DateTime get today => dateOnly(_clock());
  List<Habit> get habits => List<Habit>.unmodifiable(_habits);
  List<Habit> get activeHabits =>
      _habits.where((habit) => !habit.archived).toList(growable: false);
  List<Habit> get archivedHabits =>
      _habits.where((habit) => habit.archived).toList(growable: false);
  List<Habit> get todayHabits => activeHabits
      .where((habit) => habit.isScheduledOn(today))
      .toList(growable: false);
  List<String> get categories {
    final values = activeHabits.map((habit) => habit.category).toSet().toList()
      ..sort();
    return values;
  }

  bool isTodayCategoryCollapsed(String category) =>
      _collapsedTodayCategories.contains(category);

  bool isHabitCategoryCollapsed(String category) =>
      _collapsedHabitCategories.contains(category);

  Future<void> load() async {
    final raw = await _repository.load();
    if (raw == null || raw.isEmpty) {
      _habits.addAll(_seedHabits());
      await _persist();
    } else {
      try {
        _restore(raw);
      } on Object {
        final backup = await _repository.loadBackup();
        if (backup == null || backup.isEmpty) rethrow;
        _restore(backup);
        await _persist();
      }
    }
    _loaded = true;
    notifyListeners();
    unawaited(_syncAllReminders());
  }

  Habit? habitById(String id) {
    for (final habit in _habits) {
      if (habit.id == id) return habit;
    }
    return null;
  }

  Future<void> addHabit({
    required String title,
    required String emoji,
    required int colorValue,
    required Set<int> weekdays,
    String? reminderTime,
    String category = '未分类',
    bool effortEnabled = false,
    int rewardPoints = 10,
    int penaltyPoints = 5,
    int targetCount = 3,
    String rewardPeriod = 'week',
    bool wishEnabled = false,
    String wishTitle = '',
    int wishTarget = 100,
    String scheduleType = 'daily',
    int scheduleCount = 1,
  }) async {
    _habits.add(
      Habit(
        id: _clock().microsecondsSinceEpoch.toString(),
        title: title.trim(),
        emoji: emoji,
        colorValue: colorValue,
        weekdays: Set<int>.from(weekdays),
        createdAt: today,
        reminderTime: reminderTime,
        category: category.trim().isEmpty ? '未分类' : category.trim(),
        effortEnabled: effortEnabled,
        rewardPoints: rewardPoints,
        penaltyPoints: penaltyPoints,
        targetCount: targetCount,
        rewardPeriod: rewardPeriod,
        wishEnabled: wishEnabled,
        wishTitle: wishTitle.trim(),
        wishTarget: wishTarget,
        scheduleType: scheduleType,
        scheduleCount: scheduleCount,
      ),
    );
    await _changed();
    await _reminders.syncHabit(_habits.last);
  }

  Future<void> updateHabit({
    required String habitId,
    required String title,
    required String emoji,
    required int colorValue,
    required Set<int> weekdays,
    String? reminderTime,
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
  }) async {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    _habits[index] = habit.copyWith(
      title: title.trim(),
      emoji: emoji,
      colorValue: colorValue,
      weekdays: Set<int>.from(weekdays),
      reminderTime: reminderTime,
      clearReminder: reminderTime == null,
      category: category?.trim().isEmpty == true ? '未分类' : category,
      effortEnabled: effortEnabled,
      rewardPoints: rewardPoints,
      penaltyPoints: penaltyPoints,
      targetCount: targetCount,
      rewardPeriod: rewardPeriod,
      wishEnabled: wishEnabled,
      wishTitle: wishTitle?.trim(),
      wishTarget: wishTarget,
      scheduleType: scheduleType,
      scheduleCount: scheduleCount,
    );
    await _changed();
    await _reminders.syncHabit(_habits[index]);
  }

  Future<void> reorderActive(int oldIndex, int newIndex) async {
    final active = activeHabits.toList();
    if (oldIndex < 0 || oldIndex >= active.length) return;
    if (newIndex > oldIndex) newIndex--;
    if (newIndex < 0 || newIndex >= active.length) return;
    final moved = active.removeAt(oldIndex);
    active.insert(newIndex, moved);
    final archived = archivedHabits;
    _habits
      ..clear()
      ..addAll(active)
      ..addAll(archived);
    await _changed();
  }

  Future<bool> requestReminderPermission() => _reminders.requestPermission();

  Future<void> toggleCompletion(String habitId, DateTime date) async {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    final day = dateOnly(date);
    if (day.isAfter(today) || !habit.isScheduledOn(day)) return;
    final key = dateKey(day);
    final completions = Map<String, String>.from(habit.completions);
    if (completions.containsKey(key)) {
      completions.remove(key);
    } else {
      completions[key] = _clock().toIso8601String();
    }
    _habits[index] = habit.copyWith(completions: completions);
    await _changed();
  }

  Future<void> markCompleted(String habitId, DateTime date) async {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    final day = dateOnly(date);
    if (day.isAfter(today) || !habit.isScheduledOn(day)) return;
    final key = dateKey(day);
    if (habit.completions.containsKey(key)) return;
    final completions = Map<String, String>.from(habit.completions)
      ..[key] = _clock().toIso8601String();
    _habits[index] = habit.copyWith(completions: completions);
    await _changed();
  }

  Future<void> setNote(String habitId, DateTime date, String value) async {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    final notes = Map<String, String>.from(habit.notes);
    final trimmed = value.trim();
    if (trimmed.isEmpty) {
      notes.remove(dateKey(date));
    } else {
      notes[dateKey(date)] = trimmed;
    }
    _habits[index] = habit.copyWith(notes: notes);
    await _changed();
  }

  Future<void> togglePaused(String habitId) async {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    if (!habit.isPaused) {
      _habits[index] = habit.copyWith(pausedAt: today);
    } else {
      final exemptions = Set<String>.from(habit.exemptions);
      var cursor = dateOnly(habit.pausedAt!);
      while (!cursor.isAfter(today)) {
        exemptions.add(dateKey(cursor));
        cursor = cursor.add(const Duration(days: 1));
      }
      _habits[index] = habit.copyWith(
        exemptions: exemptions,
        clearPausedAt: true,
      );
    }
    await _changed();
    await _reminders.syncHabit(_habits[index]);
  }

  Future<void> toggleArchived(String habitId) async {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    _habits[index] = habit.copyWith(archived: !habit.archived);
    await _changed();
    await _reminders.syncHabit(_habits[index]);
  }

  Future<void> deleteHabit(String habitId) async {
    _habits.removeWhere((habit) => habit.id == habitId);
    await _changed();
    await _syncAllReminders();
  }

  Future<void> setDarkMode(bool value) async {
    _darkMode = value;
    await _changed();
  }

  Future<void> setThemeColor(int value) async {
    _themeColorValue = value;
    await _changed();
  }

  Future<void> setReviewDays(int value) async {
    if (!const <int>{7, 30, 90, 365}.contains(value)) return;
    _reviewDays = value;
    await _changed();
  }

  Future<void> toggleTodayCategory(String category) async {
    if (!_collapsedTodayCategories.add(category)) {
      _collapsedTodayCategories.remove(category);
    }
    await _changed();
  }

  Future<void> toggleHabitCategory(String category) async {
    if (!_collapsedHabitCategories.add(category)) {
      _collapsedHabitCategories.remove(category);
    }
    await _changed();
  }

  int completedCount(DateTime date) => activeHabits
      .where((habit) => habit.isActiveOn(date) && habit.isCompletedOn(date))
      .length;

  int scheduledCount(DateTime date) => activeHabits.where((habit) {
    if (!habit.isActiveOn(date)) return false;
    if (habit.scheduleType == 'daily') return true;
    if (habit.isCompletedOn(date)) return true;
    return dateKey(date) == dateKey(today) && habit.isScheduledOn(date);
  }).length;

  double dayProgress(DateTime date) {
    final scheduled = scheduledCount(date);
    if (scheduled == 0) return 0;
    return completedCount(date) / scheduled;
  }

  double completionRate(Habit habit, {int days = 30}) {
    final scheduled = expectedCountInRange(habit, days: days);
    final completed = completedCountInRange(habit, days: days);
    return scheduled == 0 ? 0 : (completed / scheduled).clamp(0.0, 1.0);
  }

  int completedCountInRange(Habit habit, {required int days}) {
    final start = today.subtract(Duration(days: days - 1));
    return habit.completions.keys.where((key) {
      final completed = DateTime.tryParse(key);
      if (completed == null) return false;
      final day = dateOnly(completed);
      return !day.isBefore(start) && !day.isAfter(today);
    }).length;
  }

  int expectedCountInRange(Habit habit, {required int days}) {
    final start = today.subtract(Duration(days: days - 1));
    if (habit.scheduleType == 'daily') {
      var expected = 0;
      for (
        var day = start;
        !day.isAfter(today);
        day = day.add(const Duration(days: 1))
      ) {
        if (habit.isActiveOn(day)) expected++;
      }
      return expected;
    }
    var expected = 0;
    var periodStart = habit.schedulePeriodStart(start);
    while (!periodStart.isAfter(today)) {
      final periodEnd = habit.schedulePeriodEnd(periodStart);
      final windowStart = periodStart.isBefore(start) ? start : periodStart;
      final windowEnd = periodEnd.isAfter(today) ? today : periodEnd;
      var availableDays = 0;
      for (
        var day = windowStart;
        !day.isAfter(windowEnd);
        day = day.add(const Duration(days: 1))
      ) {
        if (habit.isActiveOn(day)) availableDays++;
      }
      expected += habit.scheduleCount < availableDays
          ? habit.scheduleCount
          : availableDays;
      periodStart = habit.scheduleType == 'month'
          ? DateTime(periodStart.year, periodStart.month + 1)
          : periodStart.add(const Duration(days: 7));
    }
    return expected;
  }

  int completedTotalInRange({required int days}) => activeHabits.fold<int>(
    0,
    (total, habit) => total + completedCountInRange(habit, days: days),
  );

  int expectedTotalInRange({required int days}) => activeHabits.fold<int>(
    0,
    (total, habit) => total + expectedCountInRange(habit, days: days),
  );

  int effortPoints(Habit habit) {
    if (!habit.effortEnabled) return 0;
    final completed = habit.completions.keys.where((key) {
      final day = DateTime.tryParse(key);
      return day != null &&
          !day.isAfter(today) &&
          !day.isBefore(dateOnly(habit.createdAt));
    }).length;
    var points = completed * habit.rewardPoints;
    final currentPeriodStart = _periodStart(today, habit.rewardPeriod);
    var periodStart = _periodStart(habit.createdAt, habit.rewardPeriod);
    while (periodStart.isBefore(currentPeriodStart)) {
      final periodEnd = habit.rewardPeriod == 'month'
          ? DateTime(
              periodStart.year,
              periodStart.month + 1,
            ).subtract(const Duration(days: 1))
          : periodStart.add(const Duration(days: 6));
      var scheduled = 0;
      var completedInPeriod = 0;
      var cursor = periodStart;
      while (!cursor.isAfter(periodEnd)) {
        if (!cursor.isBefore(dateOnly(habit.createdAt)) &&
            habit.isScheduledOn(cursor)) {
          scheduled++;
          if (habit.isCompletedOn(cursor)) completedInPeriod++;
        }
        cursor = cursor.add(const Duration(days: 1));
      }
      final required = habit.targetCount < scheduled
          ? habit.targetCount
          : scheduled;
      if (completedInPeriod < required) {
        points -= (required - completedInPeriod) * habit.penaltyPoints;
      }
      periodStart = habit.rewardPeriod == 'month'
          ? DateTime(periodStart.year, periodStart.month + 1)
          : periodStart.add(const Duration(days: 7));
    }
    return points;
  }

  int get totalEffort =>
      activeHabits.fold<int>(0, (total, habit) => total + effortPoints(habit));

  DateTime _periodStart(DateTime value, String period) {
    final day = dateOnly(value);
    if (period == 'month') return DateTime(day.year, day.month);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  int currentStreak(Habit habit) {
    if (habit.scheduleType != 'daily') {
      var streak = 0;
      var periodStart = habit.schedulePeriodStart(today);
      if (!_schedulePeriodMet(habit, periodStart)) {
        periodStart = _previousSchedulePeriod(habit, periodStart);
      }
      final firstPeriod = habit.schedulePeriodStart(habit.createdAt);
      while (!periodStart.isBefore(firstPeriod) &&
          _schedulePeriodMet(habit, periodStart)) {
        streak++;
        periodStart = _previousSchedulePeriod(habit, periodStart);
      }
      return streak;
    }
    var streak = 0;
    var cursor = today;
    if (habit.isScheduledOn(cursor) && !habit.isCompletedOn(cursor)) {
      cursor = cursor.subtract(const Duration(days: 1));
    }
    while (!cursor.isBefore(dateOnly(habit.createdAt))) {
      if (habit.isScheduledOn(cursor)) {
        if (!habit.isCompletedOn(cursor)) break;
        streak++;
      }
      cursor = cursor.subtract(const Duration(days: 1));
    }
    return streak;
  }

  int bestStreak(Habit habit) {
    if (habit.scheduleType != 'daily') {
      var best = 0;
      var current = 0;
      var periodStart = habit.schedulePeriodStart(habit.createdAt);
      final lastPeriod = habit.schedulePeriodStart(today);
      while (!periodStart.isAfter(lastPeriod)) {
        if (_schedulePeriodMet(habit, periodStart)) {
          current++;
          if (current > best) best = current;
        } else {
          current = 0;
        }
        periodStart = _nextSchedulePeriod(habit, periodStart);
      }
      return best;
    }
    var best = 0;
    var current = 0;
    var cursor = dateOnly(habit.createdAt);
    while (!cursor.isAfter(today)) {
      if (habit.isScheduledOn(cursor)) {
        if (habit.isCompletedOn(cursor)) {
          current++;
          if (current > best) best = current;
        } else {
          current = 0;
        }
      }
      cursor = cursor.add(const Duration(days: 1));
    }
    return best;
  }

  bool _schedulePeriodMet(Habit habit, DateTime periodStart) {
    final periodEnd = habit.schedulePeriodEnd(periodStart);
    var availableDays = 0;
    for (
      var day = periodStart;
      !day.isAfter(periodEnd);
      day = day.add(const Duration(days: 1))
    ) {
      if (habit.isActiveOn(day)) availableDays++;
    }
    final required = habit.scheduleCount < availableDays
        ? habit.scheduleCount
        : availableDays;
    return required > 0 && habit.completionsInPeriod(periodStart) >= required;
  }

  DateTime _previousSchedulePeriod(Habit habit, DateTime periodStart) =>
      habit.scheduleType == 'month'
      ? DateTime(periodStart.year, periodStart.month - 1)
      : periodStart.subtract(const Duration(days: 7));

  DateTime _nextSchedulePeriod(Habit habit, DateTime periodStart) =>
      habit.scheduleType == 'month'
      ? DateTime(periodStart.year, periodStart.month + 1)
      : periodStart.add(const Duration(days: 7));

  String exportJson() => jsonEncode(_stateJson());

  Future<bool> importJson(String raw) async {
    try {
      final decoded = jsonDecode(raw) as Map<String, Object?>;
      final items = (decoded['habits']! as List<Object?>)
          .cast<Map<String, Object?>>();
      final restored = items.map(Habit.fromJson).toList();
      _habits
        ..clear()
        ..addAll(restored);
      _darkMode = decoded['darkMode'] as bool? ?? false;
      _themeColorValue = decoded['themeColorValue'] as int? ?? 0xFF5F8068;
      _reviewDays = decoded['reviewDays'] as int? ?? 30;
      _collapsedTodayCategories
        ..clear()
        ..addAll(
          (decoded['collapsedTodayCategories'] as List<Object?>? ?? const [])
              .cast<String>(),
        );
      _collapsedHabitCategories
        ..clear()
        ..addAll(
          (decoded['collapsedHabitCategories'] as List<Object?>? ?? const [])
              .cast<String>(),
        );
      await _changed();
      await _syncAllReminders();
      return true;
    } on Object {
      return false;
    }
  }

  Future<void> _changed() async {
    notifyListeners();
    await _persist();
  }

  Future<void> _persist() => _repository.save(exportJson());

  Future<void> _syncAllReminders() async {
    try {
      await _reminders.syncAll(_habits);
    } on Object {
      // 持久化数据仍可正常使用；通知初始化失败不应阻塞应用启动。
    }
  }

  Future<void> _handleReminderAction(ReminderAction action) async {
    final habit = habitById(action.habitId);
    if (habit == null) return;
    if (action.type == ReminderActionType.complete) {
      await markCompleted(habit.id, today);
    } else {
      await _reminders.snooze(habit);
    }
  }

  @override
  void dispose() {
    _reminderSubscription.cancel();
    super.dispose();
  }

  Map<String, Object?> _stateJson() => <String, Object?>{
    'version': 5,
    'darkMode': _darkMode,
    'themeColorValue': _themeColorValue,
    'reviewDays': _reviewDays,
    'collapsedTodayCategories': _collapsedTodayCategories.toList()..sort(),
    'collapsedHabitCategories': _collapsedHabitCategories.toList()..sort(),
    'habits': _habits.map((habit) => habit.toJson()).toList(),
  };

  void _restore(String raw) {
    final decoded = jsonDecode(raw) as Map<String, Object?>;
    final items = (decoded['habits']! as List<Object?>)
        .cast<Map<String, Object?>>();
    final restoredHabits = items.map(Habit.fromJson).toList(growable: false);
    final restoredDarkMode = decoded['darkMode'] as bool? ?? false;
    final restoredThemeColor = decoded['themeColorValue'] as int? ?? 0xFF5F8068;
    final restoredReviewDays = decoded['reviewDays'] as int? ?? 30;
    final restoredTodayCategories =
        (decoded['collapsedTodayCategories'] as List<Object?>? ?? const [])
            .cast<String>()
            .toSet();
    final restoredHabitCategories =
        (decoded['collapsedHabitCategories'] as List<Object?>? ?? const [])
            .cast<String>()
            .toSet();
    _habits
      ..clear()
      ..addAll(restoredHabits);
    _darkMode = restoredDarkMode;
    _themeColorValue = restoredThemeColor;
    _reviewDays = const <int>{7, 30, 90, 365}.contains(restoredReviewDays)
        ? restoredReviewDays
        : 30;
    _collapsedTodayCategories
      ..clear()
      ..addAll(restoredTodayCategories);
    _collapsedHabitCategories
      ..clear()
      ..addAll(restoredHabitCategories);
  }

  List<Habit> _seedHabits() {
    final now = _clock();
    final start = today.subtract(const Duration(days: 12));
    final yesterday = today.subtract(const Duration(days: 1));
    final twoDaysAgo = today.subtract(const Duration(days: 2));
    return <Habit>[
      Habit(
        id: 'seed-reading',
        title: '阅读 20 分钟',
        emoji: '📖',
        colorValue: 0xFF5F8068,
        weekdays: const <int>{1, 2, 3, 4, 5, 6, 7},
        createdAt: start,
        reminderTime: '21:30',
        category: '学习',
        effortEnabled: true,
        wishEnabled: true,
        wishTitle: '买一本期待已久的新书',
        wishTarget: 120,
        completions: <String, String>{
          dateKey(twoDaysAgo): now
              .subtract(const Duration(days: 2))
              .toIso8601String(),
          dateKey(yesterday): now
              .subtract(const Duration(days: 1))
              .toIso8601String(),
        },
      ),
      Habit(
        id: 'seed-water',
        title: '喝够 8 杯水',
        emoji: '💧',
        colorValue: 0xFF4D7C91,
        weekdays: const <int>{1, 2, 3, 4, 5, 6, 7},
        createdAt: start,
        reminderTime: '09:00',
        category: '健康',
        effortEnabled: true,
        completions: <String, String>{
          dateKey(yesterday): now
              .subtract(const Duration(days: 1))
              .toIso8601String(),
        },
      ),
      Habit(
        id: 'seed-stretch',
        title: '伸展一下',
        emoji: '🌿',
        colorValue: 0xFFD1815C,
        weekdays: const <int>{1, 2, 3, 4, 5},
        scheduleType: 'week',
        scheduleCount: 5,
        createdAt: start,
        reminderTime: '16:00',
        category: '健康',
        effortEnabled: true,
      ),
    ];
  }
}
