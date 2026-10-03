import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/services/backup_settings.dart';
import 'package:haoxiguan/services/data_status.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/state/habit_controller.dart';

class _Secrets implements SecretStore {
  final data = <String, String>{};
  bool fail = false;
  @override
  Future<String?> read(String key) async {
    if (fail) throw StateError('storage unavailable');
    return data[key];
  }

  @override
  Future<void> write(String key, String value) async => data[key] = value;
  @override
  Future<void> delete(String key) async => data.remove(key);
}

void main() {
  test(
    'backup preview includes notes and date span but not future plans',
    () async {
      final c = HabitController(
        MemoryHabitRepository(),
        clock: () => DateTime(2026, 10, 3),
      );
      await c.load();
      await c.addHabit(
        title: '预览',
        emoji: '🌱',
        colorValue: 0xff000000,
        weekdays: {1},
        startDate: DateTime(2026, 9, 1),
      );
      final id = c.habits.single.id;
      await c.markCompleted(id, DateTime(2026, 9, 3));
      await c.markCompleted(id, DateTime(2026, 9, 5));
      await c.deleteEntry(id, c.habits.single.entries.last.id);
      await c.setNote(id, DateTime(2026, 10, 2), '备注');
      final created = DateTime.utc(2026, 10, 3, 9);
      final preview = BackupPreview.fromSnapshot(
        c.exportJson(),
        createdAtUtc: created,
      );
      expect(preview.createdAtUtc, created);
      expect(preview.habits, 1);
      expect(preview.records, 1);
      expect(preview.notes, 1);
      expect(preview.deletedRecords, 1);
      expect(preview.firstDate, '2026-09-03');
      expect(preview.lastDate, '2026-10-02');
      expect(
        BackupPreview.fromSnapshot(
          jsonEncode({'version': 7, 'habits': []}),
        ).summary,
        contains('旧文件未提供'),
      );
      c.dispose();
    },
  );

  test(
    'data status never treats absent, stale or unreadable evidence as protected',
    () async {
      final c = HabitController(MemoryHabitRepository());
      await c.load();
      final secrets = _Secrets();
      final reader = DataStatusReader(secrets: secrets);
      var status = await reader.read(c.exportJson());
      expect(status.backup, contains('尚无本机校验成功记录'));
      expect(status.backup, contains('WebDAV：未配置'));
      expect(status.sync, contains('未连接'));
      await reader.recordFileBackup(c.exportJson(), 'verified.hgb');
      status = await reader.read(c.exportJson());
      expect(status.backup, contains('verified.hgb'));
      expect(status.backup, isNot(contains('已有更改')));
      await c.addHabit(
        title: '新记录',
        emoji: '🌱',
        colorValue: 0xff000000,
        weekdays: {1},
      );
      status = await reader.read(c.exportJson());
      expect(status.backup, contains('备份后本机已有更改'));
      secrets.fail = true;
      status = await reader.read(c.exportJson());
      expect(status.backup, contains('状态读取失败'));
      expect(status.sync, contains('状态读取失败'));
      c.dispose();
    },
  );

  test(
    'sync summary keeps historic success distinct from pending local changes',
    () async {
      final c = HabitController(MemoryHabitRepository());
      await c.load();
      final baseline = SyncEntities.encode(c.exportJson());
      await c.addHabit(
        title: '待同步',
        emoji: '🌱',
        colorValue: 0xff000000,
        weekdays: {1},
      );
      final summary = DataStatusReader.describeSync(c.exportJson(), 'binding', {
        'binding': 'binding',
        'base': baseline,
        'lastSuccess': '2026-10-01T09:00:00Z',
        'pending': [1],
        'conflicts': ['habit'],
        'previewRequired': true,
        'lastFailureCode': 'unauthorized',
        'lastFailureAt': '2026-10-03T09:00:00Z',
      }, recoveryExported: true);
      expect(summary, contains('2026-10-01T09:00:00Z'));
      expect(summary, contains('待发送 1 个操作；本机待核对 2 项；待处理 1 个习惯'));
      expect(summary, contains('等待首次同步预览确认'));
      expect(summary, contains('当前授权需运行同步检查'));
      expect(summary, contains('最近同步失败：设备授权失效，请重新授权'));
      c.dispose();
    },
  );
}
