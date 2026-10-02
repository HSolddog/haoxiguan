import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:uuid/uuid.dart';

import '../data/snapshot_codec.dart';

import '../data/habit_repository.dart';
import '../models/habit.dart';
import '../models/plan.dart';
import '../models/record_entry.dart';
import '../services/reminder_service.dart';

class HabitController extends ChangeNotifier {
  HabitController(
    this._repository, {
    DateTime Function()? clock,
    ReminderScheduler? reminderScheduler,
    String Function()? timezoneId,
  }) : _clock = clock ?? DateTime.now,
       _timezoneId = timezoneId ?? (() => 'unknown'),
       _reminders = reminderScheduler ?? NoopReminderScheduler() {
    _reminderSubscription = _reminders.actions.listen(_handleReminderAction);
  }

  final HabitRepository _repository;
  final DateTime Function() _clock;
  final ReminderScheduler _reminders;
  final String Function() _timezoneId;
  late final StreamSubscription<ReminderAction> _reminderSubscription;
  final List<Habit> _habits = <Habit>[];
  bool _darkMode = false;
  int _themeColorValue = 0xFF5F8068;
  int _reviewDays = 30;
  final Set<String> _collapsedTodayCategories = <String>{};
  final Set<String> _collapsedHabitCategories = <String>{};
  bool _loaded = false;
  bool _loading = false;
  bool _disposed = false;
  String? _loadError;
  String? _saveError;
  String? _reminderError;
  ({String habitId, DateTime date})? _pendingRecord;
  ({String habitId, DateTime date})? takePendingRecord() {
    final value = _pendingRecord;
    _pendingRecord = null;
    return value;
  }

  String? _recoveryBackup;
  Map<String, Object?> _extensions = {};
  Future<void>? _writeQueue;

  bool get loading => _loading || (!_loaded && _loadError == null);
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
  String get appearanceMode =>
      _extensions['appearanceMode'] as String? ?? 'system';
  int get themeColorValue => _themeColorValue;
  int get reviewDays => _reviewDays;
  DateTime get today => dateOnly(_clock());
  List<Habit> get habits => List<Habit>.unmodifiable(_habits);
  List<Habit> get activeHabits => _habits
      .where((habit) => !habit.archived && !habit.inTrash)
      .toList(growable: false);
  List<Habit> get archivedHabits => _habits
      .where((habit) => habit.archived && !habit.inTrash)
      .toList(growable: false);
  List<Habit> get todayHabits => _habits
      .where((h) => !h.inTrash)
      .where(
        (habit) => !habit.planOn(today).flexible && habit.isScheduledOn(today),
      )
      .toList(growable: false);
  List<Habit> get periodHabits => _habits
      .where((h) => !h.inTrash)
      .where((h) => h.planOn(today).flexible && h.isActiveOn(today))
      .toList();
  List<Habit> get trashedHabits => _habits.where((h) => h.inTrash).toList();
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
        final source = SnapshotCodec.decode(raw);
        if ((source['version'] as int? ?? 1) < SnapshotCodec.currentVersion ||
            source['vaultId'] == null) {
          await _repository.save(exportJson());
        }
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
    String recordType = 'boolean',
    String unit = '次',
    int scale = 1,
    int dailyTarget = 1,
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
        recordType: recordType,
        unit: unit,
        scale: scale,
        dailyTarget: dailyTarget,
        plans: [
          PlanVersion(
            id: const Uuid().v4(),
            from: today,
            kind: scheduleType,
            weekdays: weekdays,
            periodTarget: scheduleCount,
            dailyTarget: dailyTarget,
          ),
        ],
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
    int? dailyTarget,
  }) => _mutate(() {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    final kind = scheduleType ?? habit.scheduleType;
    final count = scheduleCount ?? habit.scheduleCount;
    final target = dailyTarget ?? habit.dailyTarget;
    var plans = habit.effectivePlans;
    if (kind != habit.scheduleType ||
        count != habit.scheduleCount ||
        target != habit.dailyTarget ||
        !setEquals(weekdays, habit.weekdays)) {
      final current = habit.planOn(today);
      final effective = current.flexible
          ? calendarDay(current.end(today), 1)
          : calendarDay(today, 1);
      plans = [
        ...plans.where((p) => p.from.isBefore(effective)),
        PlanVersion(
          id: const Uuid().v4(),
          from: effective,
          kind: kind,
          weekdays: weekdays,
          periodTarget: count,
          dailyTarget: target,
        ),
      ];
    }
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
      dailyTarget: target,
      plans: plans,
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
    final trash = trashedHabits;
    _habits
      ..clear()
      ..addAll(active)
      ..addAll(archived)
      ..addAll(trash);
  });

  Future<bool> requestReminderPermission() async {
    try {
      final granted = await _reminders.requestPermission();
      if (granted) await _syncAllReminders();
      return granted;
    } on Object {
      _reminderError = '无法申请通知权限，记录仍可正常保存。';
      notifyListeners();
      return false;
    }
  }

  RecordEntry _entry(String habitId, DateTime date, int value, {String? id}) {
    final now = _clock();
    return RecordEntry(
      id: id ?? const Uuid().v4(),
      date: dateKey(date),
      value: value,
      recordedAtUtc: now.toUtc().toIso8601String(),
      recordedLocalDate: dateKey(now),
      timezoneId: _timezoneId(),
      utcOffsetMinutes: now.timeZoneOffset.inMinutes,
    );
  }

  Future<bool> toggleCompletion(String habitId, DateTime date) => _mutate(() {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    if (habit.recordType != 'boolean' ||
        habit.inTrash ||
        dateOnly(date).isAfter(today) ||
        dateOnly(date).isBefore(dateOnly(habit.createdAt))) {
      return;
    }
    final key = dateKey(date);
    final id = const Uuid().v5(
      Namespace.url.value,
      'haoxiguan/record/$habitId/$key',
    );
    final entries = habit.entries.where((e) => e.id != id).toList();
    final previous = habit.entries.where((e) => e.id == id).firstOrNull;
    entries.add(
      previous == null
          ? _entry(habitId, date, 1, id: id)
          : previous.copyWith(deleted: habit.isCompletedOn(date)),
    );
    _habits[index] = habit.copyWith(entries: entries);
  });

  Future<bool> markCompleted(String habitId, DateTime date) => _mutate(() {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    if (habit.recordType != 'boolean' ||
        habit.inTrash ||
        habit.isCompletedOn(date) ||
        dateOnly(date).isAfter(today) ||
        dateOnly(date).isBefore(dateOnly(habit.createdAt))) {
      return;
    }
    final id = const Uuid().v5(
      Namespace.url.value,
      'haoxiguan/record/$habitId/${dateKey(date)}',
    );
    final previous = habit.entries.where((e) => e.id == id).firstOrNull;
    _habits[index] = habit.copyWith(
      entries: [
        ...habit.entries.where((e) => e.id != id),
        previous == null
            ? _entry(habitId, date, 1, id: id)
            : previous.copyWith(deleted: false),
      ],
    );
  });

  Future<bool> addValue(
    String habitId,
    DateTime date,
    int value, {
    String? entryId,
    bool replaceTotal = false,
  }) {
    final id = entryId ?? const Uuid().v4();
    return _mutate(() {
      final index = _habits.indexWhere((habit) => habit.id == habitId);
      if (index < 0) return;
      final habit = _habits[index];
      if (habit.inTrash ||
          habit.recordType == 'boolean' ||
          value < 0 ||
          value > 1000000000000 ||
          dateOnly(date).isAfter(today) ||
          dateOnly(date).isBefore(dateOnly(habit.createdAt))) {
        throw const FormatException('记录范围无效');
      }
      if (habit.entries.any((e) => e.id == id)) return;
      final entries = habit.entries
          .map(
            (e) => replaceTotal && e.date == dateKey(date)
                ? e.copyWith(deleted: true)
                : e,
          )
          .toList();
      if (value > 0) entries.add(_entry(habitId, date, value, id: id));
      _habits[index] = habit.copyWith(entries: entries);
    });
  }

  Future<bool> deleteEntry(String habitId, String entryId) => _mutate(() {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    _habits[index] = habit.copyWith(
      entries: habit.entries
          .map((e) => e.id == entryId ? e.copyWith(deleted: true) : e)
          .toList(),
    );
  });

  Future<bool> toggleRest(String habitId, DateTime date) => _mutate(() {
    final index = _habits.indexWhere((habit) => habit.id == habitId);
    if (index < 0 || dateOnly(date).isAfter(today)) return;
    final habit = _habits[index];
    final exemptions = {...habit.exemptions};
    if (!exemptions.add(dateKey(date))) exemptions.remove(dateKey(date));
    _habits[index] = habit.copyWith(exemptions: exemptions);
  });

  Future<bool> setNote(String habitId, DateTime date, String value) =>
      _mutate(() {
        final index = _habits.indexWhere((habit) => habit.id == habitId);
        if (index < 0) return;
        final habit = _habits[index];
        final notes = Map<String, String>.from(habit.notes);
        if (value.length > 2000) throw const FormatException('备注最多 2000 字');
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
        cursor = calendarDay(cursor, 1);
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
    final exemptions = {...habit.exemptions};
    if (habit.archived && habit.archivedAt != null) {
      for (
        var day = dateOnly(habit.archivedAt!);
        day.isBefore(today);
        day = calendarDay(day, 1)
      ) {
        exemptions.add(dateKey(day));
      }
    }
    _habits[index] = habit.copyWith(
      archived: !habit.archived,
      exemptions: exemptions,
      archivedAt: habit.archived ? null : calendarDay(today, 1),
      clearArchivedAt: habit.archived,
    );
  });

  Future<bool> deleteHabit(String habitId) => _mutate(() {
    final index = _habits.indexWhere((h) => h.id == habitId);
    if (index >= 0) _habits[index] = _habits[index].copyWith(deletedAt: today);
  });

  Future<bool> restoreHabit(String habitId) => _mutate(() {
    final index = _habits.indexWhere((h) => h.id == habitId);
    if (index < 0) return;
    final habit = _habits[index];
    final exemptions = {...habit.exemptions};
    if (habit.deletedAt != null) {
      for (
        var day = calendarDay(habit.deletedAt!, 1);
        day.isBefore(today);
        day = calendarDay(day, 1)
      ) {
        exemptions.add(dateKey(day));
      }
    }
    _habits[index] = habit.copyWith(
      clearDeletedAt: true,
      exemptions: exemptions,
    );
  });

  Future<bool> permanentlyDeleteHabit(String habitId) => _mutate(() {
    _habits.removeWhere((habit) => habit.id == habitId && habit.inTrash);
  });

  Future<bool> setDarkMode(bool value) => _mutate(() {
    _darkMode = value;
    _extensions['appearanceMode'] = value ? 'dark' : 'light';
  });

  Future<bool> setAppearanceMode(String value) => _mutate(() {
    if (!const {'system', 'light', 'dark'}.contains(value)) {
      throw const FormatException('外观设置无效');
    }
    _extensions['appearanceMode'] = value;
    if (value != 'system') _darkMode = value == 'dark';
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

  int completedCount(DateTime date) => _habits
      .where((h) => dateOnly(date) != today || !h.inTrash)
      .where(
        (habit) =>
            !habit.planOn(date).flexible &&
            habit.isActiveOn(date) &&
            habit.planOn(date).allows(date) &&
            habit.isCompletedOn(date),
      )
      .length;
  int scheduledCount(DateTime date) => _habits
      .where((h) => dateOnly(date) != today || !h.inTrash)
      .where(
        (habit) =>
            !habit.planOn(date).flexible &&
            habit.isActiveOn(date) &&
            habit.planOn(date).allows(date),
      )
      .length;
  double dayProgress(DateTime date) => scheduledCount(date) == 0
      ? 0
      : completedCount(date) / scheduledCount(date);

  List<PlanResult> settledResults(Habit habit, {int days = 30, String? kind}) {
    final start = calendarDay(today, -days);
    return habit
        .resultsThrough(today)
        .where(
          (r) =>
              !r.rested &&
              r.end.isBefore(today) &&
              !r.end.isBefore(start) &&
              (kind == null || r.plan.kind == kind),
        )
        .toList();
  }

  double completionRate(Habit habit, {int days = 30}) {
    final results = settledResults(habit, days: days);
    return results.isEmpty
        ? 0
        : results.where((r) => r.met).length / results.length;
  }

  int completedCountInRange(Habit habit, {required int days}) =>
      settledResults(habit, days: days).where((r) => r.met).length;
  int expectedCountInRange(Habit habit, {required int days}) =>
      settledResults(habit, days: days).length;
  int completedTotalInRange({required int days}) => _habits.fold(
    0,
    (sum, h) =>
        sum +
        settledResults(
          h,
          days: days,
        ).where((r) => !r.plan.flexible && r.met).length,
  );
  int expectedTotalInRange({required int days}) => _habits.fold(
    0,
    (sum, h) =>
        sum +
        settledResults(h, days: days).where((r) => !r.plan.flexible).length,
  );

  int effortPoints(Habit habit) =>
      habit.legacyRewardBalance ?? _legacyEffortPoints(habit);

  int _legacyEffortPoints(Habit habit) {
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
        cursor = calendarDay(cursor, 1);
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
    if (period == 'month') return DateTime.utc(day.year, day.month);
    return day.subtract(Duration(days: day.weekday - 1));
  }

  int currentStreak(Habit habit) {
    var streak = 0;
    final kind = habit.planOn(today).kind;
    for (final r in habit.resultsThrough(today).toList().reversed) {
      if (r.plan.kind != kind) break;
      if (r.rested) continue;
      if (!r.end.isBefore(today) && !r.met) continue;
      if (!r.met) break;
      streak++;
    }
    return streak;
  }

  int bestStreak(Habit habit) {
    var best = 0;
    var current = 0;
    final kind = habit.planOn(today).kind;
    for (final r in habit.resultsThrough(today)) {
      if (r.plan.kind != kind) {
        current = 0;
        continue;
      }
      if (r.rested || (!r.end.isBefore(today) && !r.met)) continue;
      current = r.met ? current + 1 : 0;
      if (current > best) best = current;
    }
    return best;
  }

  String exportJson() => jsonEncode(_stateJson());

  Future<bool> importJson(String raw) async {
    try {
      SnapshotCodec.decode(raw);
    } on Object {
      _saveError = '无法识别或不支持这份数据。原数据未修改。';
      notifyListeners();
      return false;
    }
    return _mutate(() {
      _restore(raw);
      _extensions['restoredFromVaultId'] = _extensions['vaultId'];
      _extensions['vaultId'] = const Uuid().v4();
    }, replace: true);
  }

  /// Serializes explicit external database work with UI and notification writes.
  /// Reloading the same repository also refreshes its optimistic revision guard.
  Future<T> runExternalUpdate<T>(Future<T> Function() operation) {
    Future<T> perform() async {
      try {
        return await operation();
      } finally {
        if (!_disposed) await load();
      }
    }

    final prior = _writeQueue;
    final result = prior == null
        ? Future<T>.sync(perform)
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
    final previous = _reminderError;
    try {
      await _reminders.syncAll(List<Habit>.of(_habits));
      _reminderError = null;
    } on Object {
      _reminderError = '提醒未能更新，记录已保存。可在系统通知设置中检查权限。';
    }
    if (!_disposed && previous != _reminderError) notifyListeners();
  }

  void refreshCalendar() {
    if (!_loaded || _disposed) return;
    notifyListeners();
    unawaited(_syncAllReminders());
  }

  Future<void> _handleReminderAction(ReminderAction action) async {
    final habit = habitById(action.habitId);
    if (habit == null || habit.inTrash || action.localDate == null) return;
    DateTime date;
    try {
      date = SnapshotCodec.requireDate(action.localDate!);
    } on Object {
      return;
    }
    if (dateOnly(date).isAfter(today) ||
        dateOnly(date).isBefore(dateOnly(habit.createdAt))) {
      return;
    }
    if (action.type == ReminderActionType.complete) {
      if (habit.recordType == 'boolean') {
        await markCompleted(habit.id, date);
      } else {
        _pendingRecord = (habitId: habit.id, date: date);
        notifyListeners();
      }
    } else {
      try {
        await _reminders.snooze(habit, forDate: date);
      } on Object {
        _reminderError = '稍后提醒未能设置，记录不受影响。';
        notifyListeners();
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
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
    _extensions['vaultId'] ??= const Uuid().v4();
    _extensions['appearanceMode'] ??= decoded.containsKey('darkMode')
        ? (restoredDarkMode ? 'dark' : 'light')
        : 'system';
    _habits
      ..clear()
      ..addAll(
        restoredHabits.map(
          (h) => h.copyWith(
            plans: h.effectivePlans,
            archivedAt: h.archived && h.archivedAt == null
                ? calendarDay(today, 1)
                : h.archivedAt,
            legacyRewardBalance:
                h.legacyRewardBalance ??
                (h.effortEnabled || h.wishEnabled
                    ? _legacyEffortPoints(h)
                    : null),
          ),
        ),
      );
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
