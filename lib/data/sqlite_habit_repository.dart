import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import 'habit_repository.dart';
import 'snapshot_codec.dart';

/// SQLite owns the commit boundary. Preferences are only a legacy import source.
class SqliteHabitRepository implements HabitRepository {
  SqliteHabitRepository(this.database, {this.legacy});

  static Future<SqliteHabitRepository> open() async {
    final directory = await getApplicationSupportDirectory();
    final file = File(p.join(directory.path, 'haoxiguan.sqlite'));
    final marker = File(p.join(directory.path, 'haoxiguan.initialized'));
    if (await marker.exists() && !await file.exists()) {
      throw const DataRecoveryRequired('本地数据库文件缺失。未创建空库，请保留应用数据并联系维护者。');
    }
    final repository = SqliteHabitRepository(
      HabitDatabase(
        NativeDatabase.createInBackground(
          file,
          setup: (db) {
            db.execute('PRAGMA journal_mode = WAL');
            db.execute('PRAGMA synchronous = FULL');
            db.execute('PRAGMA foreign_keys = ON');
            db.execute('PRAGMA busy_timeout = 3000');
          },
        ),
      ),
      legacy: SharedPreferencesHabitRepository(),
    );
    repository._marker = marker;
    return repository;
  }

  final HabitDatabase database;
  final HabitRepository? legacy;
  File? _marker;
  int? _revision;

  @override
  Future<String?> load() async {
    // quick_check does not alter or repair files. Never delete on open failure.
    final health = await database.customSelect('PRAGMA quick_check').get();
    if (health.length != 1 || health.single.data.values.single != 'ok') {
      throw const DataRecoveryRequired('数据库检查未通过。原文件已保留，已停止写入。');
    }
    return database
        .transaction(() async {
          final row = await _metadata();
          if (row != null) {
            _revision = row.read<int>('revision');
            final snapshot = await _readSnapshot(row);
            SnapshotCodec.decode(snapshot);
            _revision = row.read<int>('revision');
            await _markInitialized();
            return snapshot;
          }
          _revision = 0;
          if (await _marker?.exists() ?? false) {
            throw const DataRecoveryRequired('初始化标记存在，但数据库内容缺失。原文件已保留。');
          }
          final raw = await legacy?.load();
          final backup = await legacy?.loadBackup();
          if (raw == null && backup != null) {
            throw const DataRecoveryRequired('主数据缺失，检测到旧保护副本。请检查后确认恢复；不会自动覆盖。');
          }
          if (raw != null) SnapshotCodec.decode(raw);
          await _preserveLegacy(raw, backup);
          _revision = await _write(
            raw ?? SnapshotCodec.empty(),
            expectedRevision: 0,
          );
          return raw ?? SnapshotCodec.empty();
        })
        .then((value) async {
          await _markInitialized();
          return value;
        });
  }

  Future<void> _markInitialized() async {
    if (_marker != null && !await _marker!.exists()) {
      await _marker!.writeAsString('1\n', flush: true);
    }
  }

  Future<void> _preserveLegacy(String? raw, String? backup) async {
    for (final entry in {'primary': raw, 'backup': backup}.entries) {
      if (entry.value == null) continue;
      await database.customStatement(
        'INSERT OR IGNORE INTO legacy_sources(source_key, payload, digest) VALUES (?, ?, ?)',
        [entry.key, entry.value, _digest(entry.value!)],
      );
    }
  }

  Future<QueryRow?> _metadata() => database
      .customSelect('SELECT settings, revision FROM app_state WHERE id = 1')
      .getSingleOrNull();

  Future<String> _readSnapshot(QueryRow row) async {
    final settings =
        jsonDecode(row.read<String>('settings')) as Map<String, dynamic>;
    final habits = await database
        .customSelect('SELECT id, payload FROM habits ORDER BY position')
        .get();
    for (final habit in habits) {
      if ((jsonDecode(habit.read<String>('payload')) as Map)['id'] !=
          habit.read<String>('id')) {
        throw const DataRecoveryRequired('习惯主键与数据内容不一致，已停止写入。');
      }
    }
    return jsonEncode({
      ...settings,
      'habits': habits
          .map((r) => jsonDecode(r.read<String>('payload')))
          .toList(),
    });
  }

  @override
  Future<String?> loadBackup() async {
    final row = await database
        .customSelect(
          "SELECT payload, digest FROM protections ORDER BY sequence DESC LIMIT 1",
        )
        .getSingleOrNull();
    if (row != null &&
        _digest(row.read<String>('payload')) != row.read<String>('digest')) {
      throw const DataRecoveryRequired('保护副本校验未通过，不能用于恢复。');
    }
    return row?.read<String>('payload') ?? await legacy?.loadBackup();
  }

  @override
  Future<void> save(String value) async {
    SnapshotCodec.decode(value);
    final expected = _revision;
    if (expected == null) throw StateError('必须先打开并验证数据');
    final next = await database.transaction(
      () => _write(value, expectedRevision: expected),
    );
    _revision = next;
  }

  @override
  Future<void> replace(String value) async {
    SnapshotCodec.decode(value);
    final next = await database.transaction(() async {
      final row = await _metadata();
      if (row != null) {
        if (_revision != row.read<int>('revision')) {
          throw const DataRecoveryRequired('数据已被其他操作更新，请重新打开后再恢复。');
        }
        final previous = await _readSnapshot(row);
        await database.customStatement(
          'INSERT INTO protections(payload, digest, created_at) VALUES (?, ?, ?)',
          [
            previous,
            _digest(previous),
            DateTime.now().toUtc().toIso8601String(),
          ],
        );
      } else {
        await _preserveLegacy(await legacy?.load(), await legacy?.loadBackup());
      }
      return _write(value, expectedRevision: row?.read<int>('revision') ?? 0);
    });
    _revision = next;
    await _markInitialized();
  }

  Future<int> _write(String raw, {required int expectedRevision}) async {
    final document = SnapshotCodec.decode(raw);
    final row = await _metadata();
    final current = row?.read<int>('revision') ?? 0;
    if (current != expectedRevision) {
      throw const DataRecoveryRequired('数据已被其他操作更新。此次未覆盖，请重新打开后重试。');
    }
    final incoming = (document.remove('habits')! as List)
        .cast<Map<String, dynamic>>();
    final existing = await database
        .customSelect('SELECT id, payload, position FROM habits')
        .get();
    final old = {for (final r in existing) r.read<String>('id'): r};
    for (var index = 0; index < incoming.length; index++) {
      final habit = incoming[index];
      final id = habit['id']! as String;
      final payload = jsonEncode(habit);
      final previous = old.remove(id);
      if (previous?.read<String>('payload') == payload &&
          previous?.read<int>('position') == index) {
        continue;
      }
      await database.customStatement(
        'INSERT INTO habits(id, payload, position) VALUES (?, ?, ?) '
        'ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, position=excluded.position',
        [id, payload, index],
      );
      await _log(id, payload, current + 1);
    }
    for (final id in old.keys) {
      await database.customStatement('DELETE FROM habits WHERE id = ?', [id]);
      await _log(id, null, current + 1);
    }
    await database.customStatement(
      'INSERT INTO app_state(id, settings, revision) VALUES (1, ?, ?) '
      'ON CONFLICT(id) DO UPDATE SET settings=excluded.settings, revision=excluded.revision',
      [jsonEncode(document), current + 1],
    );
    if (row?.read<String>('settings') != jsonEncode(document)) {
      await _log('app-settings', jsonEncode(document), current + 1);
    }
    // Test hook is inside the transaction, including metadata and the journal.
    await database.beforeCommit?.call();
    return current + 1;
  }

  Future<void> _log(
    String id,
    String? payload,
    int revision,
  ) => database.customStatement(
    'INSERT INTO local_changes(op_id, entity_id, payload, local_revision) VALUES (?, ?, ?, ?)',
    [const Uuid().v4(), id, payload, revision],
  );

  @override
  Future<Map<String, String>> rawSources() async {
    final sources = await legacy?.rawSources() ?? <String, String>{};
    final rows = await database
        .customSelect('SELECT source_key, payload FROM legacy_sources')
        .get();
    for (final row in rows) {
      sources['legacy-${row.read<String>('source_key')}'] = row.read<String>(
        'payload',
      );
    }
    final current = await _metadata();
    if (current != null) sources['current'] = await _readSnapshot(current);
    return sources;
  }

  Future<void> close() => database.close();
  static String _digest(String raw) =>
      sha256.convert(utf8.encode(raw)).toString();
}

/// Explicit SQL keeps migrations reviewable; no generated schema magic or reset.
class HabitDatabase extends GeneratedDatabase {
  HabitDatabase(super.executor);
  Future<void> Function()? beforeCommit;

  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) async {
      await customStatement(
        'CREATE TABLE app_state(id INTEGER PRIMARY KEY CHECK(id=1), settings TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0))',
      );
      await customStatement(
        'CREATE TABLE habits(id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL, position INTEGER NOT NULL CHECK(position>=0))',
      );
      await customStatement(
        'CREATE TABLE local_changes(sequence INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT NOT NULL UNIQUE, entity_id TEXT NOT NULL, payload TEXT, local_revision INTEGER NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE legacy_sources(source_key TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL, digest TEXT NOT NULL)',
      );
      await customStatement(
        'CREATE TABLE protections(sequence INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL, digest TEXT NOT NULL, created_at TEXT NOT NULL)',
      );
    },
    onUpgrade: (migrator, from, to) async {
      throw DataRecoveryRequired('不支持数据库版本 $from → $to。请使用兼容版本，原库未被重置。');
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA busy_timeout = 3000');
      await customStatement('PRAGMA synchronous = FULL');
    },
  );
}
