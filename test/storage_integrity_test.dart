import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/models/habit.dart';

import 'support/legacy_fixture.dart';

final _now = DateTime(2026, 7, 15, 10, 30);

HabitDatabase _open(File file) => HabitDatabase(
  NativeDatabase(
    file,
    setup: (db) {
      db.execute('PRAGMA journal_mode=WAL');
      db.execute('PRAGMA synchronous=FULL');
      db.execute('PRAGMA foreign_keys=ON');
    },
  ),
);

void main() {
  test('未配置同步和备份：首次为空，正常保存和重开保留事实', () async {
    final repository = MemoryHabitRepository();
    final controller = HabitController(repository, clock: () => _now);
    await controller.load();
    expect(controller.loaded, isTrue);
    expect(controller.habits, isEmpty);
    expect(
      await controller.addHabit(
        title: '阅读',
        emoji: '📖',
        colorValue: 0xFF5F8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
      ),
      isTrue,
    );
    final id = controller.habits.single.id;
    expect(await controller.markCompleted(id, _now), isTrue);
    final reopened = HabitController(repository, clock: () => _now);
    await reopened.load();
    expect(reopened.habitById(id)!.isCompletedOn(_now), isTrue);
  });

  test('事务确认前不可观察到完成，失败后重试不会毒化队列', () async {
    final repository = _ControlledRepository(legacyFixture(_now));
    final controller = HabitController(repository, clock: () => _now);
    await controller.load();
    repository.gate = Completer<void>();
    final first = controller.markCompleted('seed-reading', _now);
    await Future<void>.delayed(Duration.zero);
    expect(controller.habitById('seed-reading')!.isCompletedOn(_now), isFalse);
    repository.gate!.completeError(const FileSystemException('disk full'));
    expect(await first, isFalse);
    expect(controller.saveError, isNotNull);
    expect(controller.habitById('seed-reading')!.isCompletedOn(_now), isFalse);
    repository.gate = null;
    expect(await controller.markCompleted('seed-reading', _now), isTrue);
    expect(controller.habitById('seed-reading')!.isCompletedOn(_now), isTrue);
  });

  test('连续并发修改依据上次已提交状态执行，无丢失更新', () async {
    final repository = _ControlledRepository(legacyFixture(_now));
    final controller = HabitController(repository, clock: () => _now);
    await controller.load();
    repository.gate = Completer<void>();
    final first = controller.setNote('seed-reading', _now, '第一条');
    final second = controller.markCompleted('seed-water', _now);
    await Future<void>.delayed(Duration.zero);
    expect(controller.habitById('seed-reading')!.noteOn(_now), isNull);
    repository.gate!.complete();
    expect(await first, isTrue);
    expect(await second, isTrue);
    final reloaded = HabitController(repository, clock: () => _now);
    await reloaded.load();
    expect(reloaded.habitById('seed-reading')!.noteOn(_now), '第一条');
    expect(reloaded.habitById('seed-water')!.isCompletedOn(_now), isTrue);
  });

  test('非法导入的后部设置不会部分修改内存或持久化', () async {
    final repository = MemoryHabitRepository(legacyFixture(_now));
    final controller = HabitController(repository, clock: () => _now);
    await controller.load();
    final before = controller.exportJson();
    final disk = repository.value;
    expect(
      await controller.importJson(
        '{"version":6,"habits":[],"darkMode":"wrong"}',
      ),
      isFalse,
    );
    expect(controller.exportJson(), before);
    expect(repository.value, disk);
  });

  test('未来版本、空字符串、双坏数据绝不自动播种或覆盖', () async {
    for (final raw in ['', '{broken', '{"version":999,"habits":[]}']) {
      final repository = MemoryHabitRepository(raw, '{broken backup');
      final controller = HabitController(repository, clock: () => _now);
      await controller.load();
      expect(controller.loaded, isFalse);
      expect(controller.loadError, isNotNull);
      expect(repository.value, raw);
      expect(controller.habits, isEmpty);
    }
  });

  test('主键缺失但旧副本存在时要求显式恢复', () async {
    final repository = MemoryHabitRepository(null, legacyFixture(_now));
    final controller = HabitController(repository, clock: () => _now);
    await controller.load();
    expect(controller.loaded, isFalse);
    expect(repository.value, isNull);
    expect(controller.canRecoverBackup, isTrue);
    expect(await controller.recoverBackup(), isTrue);
    expect(controller.habits.length, 3);
  });

  test('未知扩展字段在编辑、导出、恢复中保留', () async {
    final document = jsonDecode(legacyFixture(_now)) as Map<String, dynamic>;
    document['legacyExtra'] = {
      'preserve': [1, 2, 3],
    };
    (document['habits'] as List).first['futureNote'] = 'keep me';
    final controller = HabitController(
      MemoryHabitRepository(jsonEncode(document)),
      clock: () => _now,
    );
    await controller.load();
    await controller.setDarkMode(true);
    final exported = jsonDecode(controller.exportJson());
    expect(exported['legacyExtra'], document['legacyExtra']);
    expect(exported['habits'].first['futureNote'], 'keep me');
  });

  group('真实 SQLite 文件', () {
    late Directory directory;
    late File file;
    late SqliteHabitRepository repository;
    setUp(() async {
      directory = await Directory.systemTemp.createTemp('haoxiguan-storage-');
      file = File('${directory.path}/haoxiguan.sqlite');
      repository = SqliteHabitRepository(
        _open(file),
        legacy: MemoryHabitRepository(legacyFixture(_now)),
      );
    });
    tearDown(() async {
      await repository.close();
      await directory.delete(recursive: true);
    });

    test('真实配置是 WAL、FULL、外键开启', () async {
      await repository.load();
      for (final pair in {
        'journal_mode': 'wal',
        'synchronous': 2,
        'foreign_keys': 1,
      }.entries) {
        final row = await repository.database
            .customSelect('PRAGMA ${pair.key}')
            .getSingle();
        expect(row.data.values.single, pair.value);
      }
    });

    test('迁移保存原文，关闭重开不会再次导入旧 preferences', () async {
      final first = await repository.load();
      final document = SnapshotCodec.decode(first!);
      document['darkMode'] = true;
      await repository.save(jsonEncode(document));
      final sources = await repository.rawSources();
      expect(sources['legacy-primary'], legacyFixture(_now));
      final other = SqliteHabitRepository(
        _open(file),
        legacy: MemoryHabitRepository('{now corrupt'),
      );
      try {
        final loaded = SnapshotCodec.decode((await other.load())!);
        expect(loaded['darkMode'], isTrue);
        expect(_canonical(loaded)['habits'], _canonical(document)['habits']);
      } finally {
        await other.close();
      }
    });

    test('写入中断回滚习惯、设置与日志，释放故障后可继续写', () async {
      final original = await repository.load();
      final beforeLog = await repository.database
          .customSelect('SELECT COUNT(*) AS n FROM local_changes')
          .getSingle();
      repository.database.beforeCommit = () async =>
          throw const FileSystemException('disk full');
      await expectLater(
        repository.save(SnapshotCodec.empty()),
        throwsA(isA<FileSystemException>()),
      );
      repository.database.beforeCommit = null;
      expect(
        _canonical(jsonDecode((await repository.load())!)),
        _canonical(jsonDecode(original!)),
      );
      final afterLog = await repository.database
          .customSelect('SELECT COUNT(*) AS n FROM local_changes')
          .getSingle();
      expect(afterLog.data, beforeLog.data);
      await repository.save(SnapshotCodec.empty());
      expect(
        SnapshotCodec.decode((await repository.load())!)['habits'],
        isEmpty,
      );
    });

    test('迁移中断可重试，旧源不改，未留下半份新库', () async {
      repository.database.beforeCommit = () async =>
          throw const FileSystemException('interrupted');
      await expectLater(repository.load(), throwsA(isA<FileSystemException>()));
      final count = await repository.database
          .customSelect('SELECT COUNT(*) AS n FROM habits')
          .getSingle();
      expect(count.read<int>('n'), 0);
      expect(await repository.legacy!.load(), legacyFixture(_now));
      repository.database.beforeCommit = null;
      expect(jsonDecode((await repository.load())!)['habits'].length, 3);
    });

    test('陈旧连接不能覆盖较新事务', () async {
      final first = (await repository.load())!;
      final second = SqliteHabitRepository(_open(file));
      try {
        await second.load();
        final document = SnapshotCodec.decode(first)..['darkMode'] = true;
        await repository.save(jsonEncode(document));
        await expectLater(
          second.save(SnapshotCodec.empty()),
          throwsA(isA<DataRecoveryRequired>()),
        );
        expect(
          SnapshotCodec.decode((await repository.load())!)['darkMode'],
          isTrue,
        );
      } finally {
        await second.close();
      }
    });

    test('替换保护原内容，恢复失败连保护记录一同回滚', () async {
      final first = (await repository.load())!;
      repository.database.beforeCommit = () async =>
          throw const FileSystemException('full');
      await expectLater(
        repository.replace(SnapshotCodec.empty()),
        throwsA(isA<FileSystemException>()),
      );
      expect(await repository.loadBackup(), isNull);
      repository.database.beforeCommit = null;
      await repository.replace(SnapshotCodec.empty());
      expect(
        _canonical(jsonDecode((await repository.loadBackup())!)),
        _canonical(jsonDecode(first)),
      );
      expect(
        SnapshotCodec.decode((await repository.load())!)['habits'],
        isEmpty,
      );
    });

    test('损坏旧源不被自动覆盖，显式恢复保留双源', () async {
      await repository.close();
      repository = SqliteHabitRepository(
        _open(file),
        legacy: MemoryHabitRepository('{broken', legacyFixture(_now)),
      );
      await expectLater(repository.load(), throwsA(isA<FormatException>()));
      expect(await repository.legacy!.load(), '{broken');
      await repository.replace((await repository.loadBackup())!);
      expect((await repository.rawSources())['legacy-primary'], '{broken');
      expect(
        SnapshotCodec.decode((await repository.load())!)['habits'],
        hasLength(3),
      );
    });
  });
}

class _ControlledRepository extends MemoryHabitRepository {
  _ControlledRepository(super.value);
  Completer<void>? gate;
  @override
  Future<void> save(String value) async {
    await gate?.future;
    await super.save(value);
  }
}

Map<String, dynamic> _canonical(Map<String, dynamic> document) => {
  ...document,
  'habits': (document['habits'] as List)
      .map((h) => Habit.fromJson((h as Map).cast<String, Object?>()).toJson())
      .toList(),
};
