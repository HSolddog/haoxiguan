import 'dart:convert';
import 'package:haoxiguan/models/habit.dart';

String legacyFixture(DateTime now) => jsonEncode({
  'version': 5,
  'habits': legacyHabits(now).map((h) => h.toJson()).toList(),
});

List<Habit> legacyHabits(DateTime now) {
  final today = dateOnly(now);
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
