import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/state/habit_controller.dart';

void main() {
  final now = DateTime(2026, 10, 3);
  Future<HabitController> open(HabitRepository repo) async {
    final controller = HabitController(repo, clock: () => now);
    await controller.load();
    addTearDown(controller.dispose);
    return controller;
  }

  Future<String> create(
    HabitController c, {
    String type = 'boolean',
    String? related,
  }) async {
    final saved = await c.addHabit(
      title: '习惯',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: type,
      unit: type == 'duration' ? '秒' : '杯',
      relatedHabitId: related,
    );
    expect(saved, isTrue);
    return c.habits.last.id;
  }

  for (final method in [
    'toggle',
    'mark',
    'count',
    'duration',
    'quickBoolean',
    'quickCount',
  ]) {
    test('首次 $method 持久记录后一次备份建议，关闭后删除重开不重复', () async {
      final repo = MemoryHabitRepository();
      final c = await open(repo);
      final type = method == 'count' || method == 'quickCount'
          ? 'count'
          : method == 'duration'
          ? 'duration'
          : 'boolean';
      final id = await create(c, type: type);
      expect(c.showBackupSuggestion, isFalse);
      await c.setNote(id, c.today, '只有备注不触发');
      expect(c.showBackupSuggestion, isFalse);
      switch (method) {
        case 'toggle':
          await c.toggleCompletion(id, c.today);
        case 'mark':
          await c.markCompleted(id, c.today);
        case 'count' || 'duration':
          await c.addValue(id, c.today, 1);
        default:
          await c.quickRecord(id, c.today);
      }
      expect(c.showBackupSuggestion, isTrue);
      expect((await open(repo)).showBackupSuggestion, isTrue);
      expect(await c.dismissBackupSuggestion(), isTrue);
      for (final entry in c.habits.single.entries) {
        await c.deleteEntry(id, entry.id);
      }
      final reopened = await open(repo);
      expect(reopened.showBackupSuggestion, isFalse);
      await reopened.quickRecord(id, reopened.today);
      expect(reopened.showBackupSuggestion, isFalse);
    });
  }

  test('首次记录与提示同一持久事务，失败不显示，重试成功才显示', () async {
    final repo = _ControlledRepository();
    final c = await open(repo);
    final id = await create(c);
    repo.gate = Completer<void>();
    final first = c.markCompleted(id, c.today);
    await Future<void>.delayed(Duration.zero);
    expect(c.showBackupSuggestion, isFalse);
    expect(c.habits.single.entries, isEmpty);
    repo.gate!.completeError(StateError('disk full'));
    expect(await first, isFalse);
    expect(c.showBackupSuggestion, isFalse);
    expect(c.habits.single.entries, isEmpty);
    repo.gate = null;
    expect(await c.markCompleted(id, c.today), isTrue);
    final persisted = SnapshotCodec.decode(repo.value!);
    expect(persisted['firstRecordBackupSuggestion'], 'pending');
    expect((persisted['habits']! as List).single['entries'], hasLength(1));
    expect(c.showBackupSuggestion, isTrue);
    repo.gate = Completer<void>();
    final dismiss = c.dismissBackupSuggestion();
    await Future<void>.delayed(Duration.zero);
    repo.gate!.completeError(StateError('disk full'));
    expect(await dismiss, isFalse);
    expect(c.showBackupSuggestion, isTrue);
  });

  test('旧库包括旧空库不弹首次备份建议', () async {
    final c = await open(MemoryHabitRepository(SnapshotCodec.empty()));
    final id = await create(c);
    await c.markCompleted(id, c.today);
    expect(c.showBackupSuggestion, isFalse);
  });

  test('恢复备份不复活源空间pending提示，导入后继续记录也不触发', () async {
    final source = await open(MemoryHabitRepository());
    final id = await create(source);
    await source.markCompleted(id, source.today);
    expect(source.showBackupSuggestion, isTrue);
    final target = await open(MemoryHabitRepository());
    expect(await target.importJson(source.exportJson()), isTrue);
    expect(target.showBackupSuggestion, isFalse);
    await target.toggleCompletion(id, target.today);
    await target.toggleCompletion(id, target.today);
    expect(target.showBackupSuggestion, isFalse);
  });

  test('同步到空端的已有事实不触发新手提示', () async {
    final repo = MemoryHabitRepository();
    final c = await open(repo);
    final source = await open(MemoryHabitRepository());
    final id = await create(source);
    await source.markCompleted(id, source.today);
    final targetDocument = SnapshotCodec.decode(repo.value!);
    targetDocument['habits'] = SnapshotCodec.decode(
      source.exportJson(),
    )['habits'];
    await c.runExternalUpdate(() => repo.save(jsonEncode(targetDocument)));
    expect(c.showBackupSuggestion, isFalse);
    await c.toggleCompletion(id, c.today);
    await c.toggleCompletion(id, c.today);
    expect(c.showBackupSuggestion, isFalse);
  });

  test('关联新建保存源ID，但源记录类型、单位和事实均不改写', () async {
    final repo = MemoryHabitRepository();
    final c = await open(repo);
    final sourceId = await create(c, type: 'count');
    await c.addValue(sourceId, c.today, 3);
    await c.setNote(sourceId, c.today, '原始杯数');
    final source = c.habitById(sourceId)!.toJson();
    final relatedId = await create(c, type: 'duration', related: sourceId);
    expect(c.habitById(relatedId)!.extensions['relatedHabitId'], sourceId);
    expect(c.habitById(sourceId)!.toJson(), source);
    final reloaded = await open(repo);
    expect(
      reloaded.habitById(relatedId)!.extensions['relatedHabitId'],
      sourceId,
    );
    expect(reloaded.habitById(sourceId)!.toJson(), source);
    expect(
      await c.addHabit(
        title: '无效关联',
        emoji: '🌱',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        relatedHabitId: 'missing',
      ),
      isFalse,
    );
    expect(c.habits, hasLength(2));
  });
}

class _ControlledRepository extends MemoryHabitRepository {
  Completer<void>? gate;
  @override
  Future<void> save(String value) async {
    if (gate != null) await gate!.future;
    await super.save(value);
  }
}
