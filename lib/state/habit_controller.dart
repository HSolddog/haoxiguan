import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/snapshot_codec.dart';

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
  bool _loading = false;
  String? _loadError;
  String? _saveError;
  String? _reminderError;
  String? _recoveryBackup;
  Map<String, Object?> _extensions = {};
  Future<void>? _writeQueue;

  bool get loading => _loading;
  String? get loadError => _loadError;
  String? get saveError => _saveError;
  String? get reminderError => _reminderError;
  bool get canRecoverBackup => _recoveryBackup != null;
  void dismissSaveError() {
    _saveError = null;
    notifyListeners();
  }

  Future<Map<String, String>> rawSources() => _repository.rawSources();

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
    if (_loading) return;
    _loading = true;
    _loaded = false;
    _loadError = null;
    _recoveryBackup = null;
    notifyListeners();
    try {
      final raw = await _repository.load();
      if (raw == null) {
        final backup = await _repository.loadBackup();
        if (backup != null) {
          throw const DataRecoveryRequired('主数据缺失，检测到保护副本。请检查后确认恢复。');
        }
        final empty = SnapshotCodec.empty();
        await _repository.save(empty);
        _restore(empty);
      } else {
        _restore(raw);
      }
      _loaded = true;
      unawaited(_syncAllReminders());
    } on Object catch (error) {
      _loadError = error is UnsupportedSnapshotVersion
          ? error.toString()
          : '无法安全打开数据。原数据已保留，请释放存储空间或检查数据后重试。';
      if (error is! UnsupportedSnapshotVersion) {
        try {
          final backup = await _repository.loadBackup();
          if (backup != null) {
            SnapshotCodec.decode(backup);
            _recoveryBackup = backup;
          }
        } on Object {
          /* Recovery must not replace the original failure. */
        }
      }
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Future<bool> recoverBackup() async {
    final raw = _recoveryBackup;
    if (raw == null || _loading) return false;
    _loading = true;
    notifyListeners();
    try {
      SnapshotCodec.decode(raw);
      await _repository.replace(raw);
      _restore(raw);
      _loaded = true;
      _loadError = null;
      _recoveryBackup = null;
      unawaited(_syncAllReminders());
      return true;
    } on Object {
      _loadError = '恢复未完成，原数据已保留。请检查可用存储后重试。';
      return false;
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  Habit? habitById(String id) {
    for (final habit in _habits) {
      if (habit.id == id) return habit;
    }
    return null;
  }

  Future<bool> addHabit({
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
  }) => _mutate(() {
    _habits.add(
      Habit(
        id: const Uuid().v4(),
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
  });

  Future<bool> updateHabit({
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
  }) => _mutate(() {
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
  });

  Future<bool> reorderActive(int oldIndex, int newIndex) => _mutate(() {
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
  });

  Future<bool> requestReminderPermission() async {
    try {
      return await _reminders.requestPermission();
    } on Object {
      _reminderError = '无法申请通知权限，记录仍可正常保存。';
      notifyListeners();
      return false;
    }
  }

  Future<bool> toggleCompletion(String habitId, DateTime date) => _mutate(() {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    final day = dateOnly(date);
    if (day.isAfter(today) || day.isBefore(dateOnly(habit.createdAt))) return;
    final key = dateKey(day);
    final completions = Map<String, String>.from(habit.completions);
    if (completions.containsKey(key)) {
      completions.remove(key);
    } else {
      completions[key] = _clock().toIso8601String();
    }
    _habits[index] = habit.copyWith(completions: completions);
  });

  Future<bool> markCompleted(String habitId, DateTime date) => _mutate(() {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    final day = dateOnly(date);
    if (day.isAfter(today) || day.isBefore(dateOnly(habit.createdAt))) return;
    final key = dateKey(day);
    if (habit.completions.containsKey(key)) return;
    final completions = Map<String, String>.from(habit.completions)
      ..[key] = _clock().toIso8601String();
    _habits[index] = habit.copyWith(completions: completions);
  });

  Future<bool> setNote(String habitId, DateTime date, String value) =>
      _mutate(() {
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
      });

  Future<bool> togglePaused(String habitId) => _mutate(() {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    if (!habit.isPaused) {
      _habits[index] = habit.copyWith(pausedAt: today);
    } else {
      final exemptions = Set<String>.from(habit.exemptions);
      var cursor = dateOnly(habit.pausedAt!);
      while (cursor.isBefore(today)) {
        exemptions.add(dateKey(cursor));
        cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
      }
      _habits[index] = habit.copyWith(
        exemptions: exemptions,
        clearPausedAt: true,
      );
    }
  });

  Future<bool> toggleArchived(String habitId) => _mutate(() {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    _habits[index] = habit.copyWith(archived: !habit.archived);
  });

  Future<bool> deleteHabit(String habitId) => _mutate(() {
    _habits.removeWhere((habit) => habit.id == habitId);
  });

  Future<bool> setDarkMode(bool value) => _mutate(() {
    _darkMode = value;
  });

  Future<bool> setThemeColor(int value) => _mutate(() {
    _themeColorValue = value;
  });

  Future<bool> setReviewDays(int value) => _mutate(() {
    if (!const <int>{7, 30, 90, 365}.contains(value)) return;
    _reviewDays = value;
  });

  Future<bool> toggleTodayCategory(String category) => _mutate(() {
    if (!_collapsedTodayCategories.add(category)) {
      _collapsedTodayCategories.remove(category);
    }
  });

  Future<bool> toggleHabitCategory(String category) => _mutate(() {
    if (!_collapsedHabitCategories.add(category)) {
      _collapsedHabitCategories.remove(category);
    }
  });

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
        cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
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
      cursor = DateTime(cursor.year, cursor.month, cursor.day + 1);
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
      SnapshotCodec.decode(raw);
    } on Object {
      _saveError = '无法识别或不支持这份数据。原数据未修改。';
      notifyListeners();
      return false;
    }
    return _mutate(() => _restore(raw), replace: true);
  }

  Future<bool> _mutate(void Function() change, {bool replace = false}) {
    Future<bool> perform() async {
      if (!_loaded) return false;
      final before = exportJson();
      late String candidate;
      try {
        change();
        candidate = exportJson();
        SnapshotCodec.decode(candidate);
      } on Object {
        _restore(before);
        _saveError = '输入无效，未保存。原数据未修改。';
        notifyListeners();
        return false;
      }
      // No uncommitted state is observable while the asynchronous I/O runs.
      _restore(before);
      try {
        if (replace) {
          await _repository.replace(candidate);
        } else {
          await _repository.save(candidate);
        }
      } on Object {
        _saveError = '保存未完成。原数据未修改，请检查存储空间后重试。';
        notifyListeners();
        return false;
      }
      _restore(candidate);
      _saveError = null;
      notifyListeners();
      unawaited(_syncAllReminders());
      return true;
    }

    final prior = _writeQueue;
    final result = prior == null
        ? Future<bool>.sync(perform)
        : prior.then((_) => perform());
    late Future<void> tail;
    void release() {
      if (identical(_writeQueue, tail)) _writeQueue = null;
    }

    tail = result.then<void>(
      (_) => release(),
      onError: (Object _, StackTrace _) => release(),
    );
    _writeQueue = tail;
    return result;
  }

  Future<void> _syncAllReminders() async {
    try {
      await _reminders.syncAll(_habits);
      _reminderError = null;
    } on Object {
      _reminderError = '提醒未能更新，记录已保存。可在系统通知设置中检查权限。';
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
    ..._extensions,
    'version': SnapshotCodec.currentVersion,
    'darkMode': _darkMode,
    'themeColorValue': _themeColorValue,
    'reviewDays': _reviewDays,
    'collapsedTodayCategories': _collapsedTodayCategories.toList()..sort(),
    'collapsedHabitCategories': _collapsedHabitCategories.toList()..sort(),
    'habits': _habits.map((habit) => habit.toJson()).toList(),
  };

  void _restore(String raw) {
    final decoded = SnapshotCodec.decode(raw);
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
    _extensions = Map<String, Object?>.from(decoded);
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
}
