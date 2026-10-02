import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

import '../models/habit.dart';

import 'habit_repository.dart';
import 'snapshot_codec.dart';

/// SQLite owns the commit boundary. Preferences are only a legacy import source.
class SqliteHabitRepository
    implements HabitRepository, IncrementalHabitRepository {
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
    final assembled = <Map<String, Object?>>[];
    for (final row in habits) {
      final id = row.read<String>('id');
      final habit = (jsonDecode(row.read<String>('payload')) as Map)
          .cast<String, Object?>();
      habit['entries'] =
          (await database
                  .customSelect(
                    'SELECT payload FROM records WHERE habit_id = ? ORDER BY local_date, id',
                    variables: [Variable(id)],
                  )
                  .get())
              .map((r) => jsonDecode(r.read<String>('payload')))
              .toList();
      habit['plans'] =
          (await database
                  .customSelect(
                    'SELECT payload FROM plans WHERE habit_id = ? ORDER BY effective_from',
                    variables: [Variable(id)],
                  )
                  .get())
              .map((r) => jsonDecode(r.read<String>('payload')))
              .toList();
      final notes = await database
          .customSelect(
            'SELECT local_date, content FROM daily_notes WHERE habit_id = ?',
            variables: [Variable(id)],
          )
          .get();
      habit['notes'] = {
        for (final r in notes)
          r.read<String>('local_date'): r.read<String>('content'),
      };
      assembled.add(habit);
    }
    return jsonEncode({...settings, 'habits': assembled});
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
    final expected = _revision;
    if (expected == null) throw StateError('必须先打开并验证数据');
    final next = await database.transaction(
      () => _write(value, expectedRevision: expected),
    );
    _revision = next;
  }

  @override
  Future<void> saveDelta(
    String changedSnapshot,
    List<String> habitOrder,
    String Function() completeSnapshot,
  ) async {
    final expected = _revision;
    if (expected == null) throw StateError('必须先打开并验证数据');
    final next = await database.transaction(
      () => _write(
        changedSnapshot,
        expectedRevision: expected,
        habitOrder: habitOrder,
      ),
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

  Future<int> _write(
    String raw, {
    required int expectedRevision,
    List<String>? habitOrder,
  }) async {
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
    final changed = {for (final h in incoming) h['id'] as String: h};
    final order = habitOrder ?? changed.keys.toList();
    if (order.length > 10000 ||
        order.toSet().length != order.length ||
        changed.keys.any((id) => !order.contains(id))) {
      throw const FormatException('习惯顺序无效');
    }
    for (var index = 0; index < order.length; index++) {
      final full = changed[order[index]];
      if (full == null) {
        final previous = old.remove(order[index]);
        if (previous == null) throw const FormatException('增量缺少新习惯');
        if (previous.read<int>('position') != index) {
          await database.customStatement(
            'UPDATE habits SET position=? WHERE id=?',
            [index, order[index]],
          );
          await _log(
            'habit:${order[index]}',
            previous.read<String>('payload'),
            current + 1,
          );
        }
        continue;
      }
      final habit = Habit.fromJson(full);
      final id = habit.id;
      final metadata = Map<String, Object?>.from(full)
        ..remove('entries')
        ..remove('plans')
        ..remove('notes')
        ..remove('completions');
      final payload = jsonEncode(metadata);
      final previous = old.remove(id);
      if (previous?.read<String>('payload') != payload ||
          previous?.read<int>('position') != index) {
        await database.customStatement(
          'INSERT INTO habits(id, payload, position) VALUES (?, ?, ?) '
          'ON CONFLICT(id) DO UPDATE SET payload=excluded.payload, position=excluded.position',
          [id, payload, index],
        );
        await _log('habit:$id', payload, current + 1);
      }
      await _syncChildren('records', id, {
        for (final e in habit.entries) e.id: jsonEncode(e.toJson()),
      }, current + 1);
      await _syncChildren('plans', id, {
        for (final p in habit.plans) p.id: jsonEncode(p.toJson()),
      }, current + 1);
      await _syncChildren('daily_notes', id, {
        for (final note in habit.notes.entries)
          '$id:${note.key}': jsonEncode({'date': note.key, 'text': note.value}),
      }, current + 1);
    }
    for (final id in old.keys) {
      for (final table in ['records', 'plans', 'daily_notes']) {
        await _syncChildren(table, id, {}, current + 1);
      }
      await database.customStatement('DELETE FROM habits WHERE id = ?', [id]);
      await _log('habit:$id', null, current + 1);
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

  Future<void> _syncChildren(
    String table,
    String habitId,
    Map<String, String> incoming,
    int revision,
  ) async {
    final existing = await database
        .customSelect(
          'SELECT id, payload FROM $table WHERE habit_id = ?',
          variables: [Variable(habitId)],
        )
        .get();
    final old = {
      for (final r in existing) r.read<String>('id'): r.read<String>('payload'),
    };
    final newIds = incoming.keys.where((id) => !old.containsKey(id)).toList();
    for (var offset = 0; offset < newIds.length; offset += 400) {
      final end = offset + 400 < newIds.length ? offset + 400 : newIds.length;
      final ids = newIds.sublist(offset, end);
      final owners = await database
          .customSelect(
            'SELECT habit_id FROM $table WHERE id IN (${List.filled(ids.length, '?').join(',')})',
            variables: ids.map(Variable.new).toList(),
          )
          .get();
      if (owners.any((r) => r.read<String>('habit_id') != habitId)) {
        throw const FormatException('记录或计划 ID 已属于其他习惯');
      }
    }
    await database.batch((batch) {
      void log(String id, String? payload) => batch.customStatement(
        'INSERT INTO local_changes(op_id, entity_id, payload, local_revision) VALUES (?, ?, ?, ?)',
        [const Uuid().v4(), '$table:$id', payload, revision],
      );
      for (final id in old.keys.where((id) => !incoming.containsKey(id))) {
        batch.customStatement('DELETE FROM $table WHERE id = ?', [id]);
        log(id, null);
      }
      for (final entry in incoming.entries) {
        if (old[entry.key] == entry.value) continue;
        final statement = database.childStatement(
          table,
          habitId,
          entry.key,
          entry.value,
        );
        batch.customStatement(statement.sql, statement.args);
        log(entry.key, entry.value);
      }
    });
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

  /// Reads business state and sync progress from one SQLite snapshot.
  Future<SyncFrame> readSyncFrame() => database.transaction(() async {
    final metadata = await _metadata();
    if (metadata == null) throw StateError('必须先打开本地数据');
    final row = await database
        .customSelect('SELECT revision,payload FROM sync_state WHERE id=1')
        .getSingleOrNull();
    return SyncFrame(
      businessRevision: metadata.read<int>('revision'),
      stateRevision: row?.read<int>('revision') ?? 0,
      snapshot: await _readSnapshot(metadata),
      state: row == null
          ? null
          : jsonDecode(row.read<String>('payload')) as Map<String, dynamic>,
    );
  });

  /// The cursor, shadow and business changes commit together. A foreground write
  /// after readSyncFrame invalidates this frame instead of being overwritten.
  Future<void> commitSyncFrame(
    SyncFrame frame,
    Map<String, dynamic> state, {
    String? snapshot,
    bool protect = false,
  }) async {
    final next = await database.transaction(() async {
      final metadata = await _metadata();
      final current = metadata?.read<int>('revision');
      final sync = await database
          .customSelect('SELECT revision,payload FROM sync_state WHERE id=1')
          .getSingleOrNull();
      if (current != frame.businessRevision ||
          (sync?.read<int>('revision') ?? 0) != frame.stateRevision) {
        throw const DataRecoveryRequired('同步期间本地数据已更新，请重试；原记录未覆盖。');
      }
      var revision = current!;
      if (snapshot != null) {
        SnapshotCodec.decode(snapshot);
        if (protect) {
          if (sync != null) {
            await database.customStatement(
              'INSERT INTO sync_protections(payload,created_at) VALUES(?,?)',
              [
                sync.read<String>('payload'),
                DateTime.now().toUtc().toIso8601String(),
              ],
            );
          }
          await database.customStatement(
            'INSERT INTO protections(payload,digest,created_at) VALUES(?,?,?)',
            [
              frame.snapshot,
              _digest(frame.snapshot),
              DateTime.now().toUtc().toIso8601String(),
            ],
          );
        }
        revision = await _write(snapshot, expectedRevision: revision);
      }
      await database.customStatement(
        'INSERT INTO sync_state(id,revision,payload) VALUES(1,?,?) '
        'ON CONFLICT(id) DO UPDATE SET revision=excluded.revision,payload=excluded.payload',
        [frame.stateRevision + 1, jsonEncode(state)],
      );
      await database.beforeSyncCommit?.call();
      return revision;
    });
    _revision = next;
  }

  Future<void> close() => database.close();
  static String _digest(String raw) =>
      sha256.convert(utf8.encode(raw)).toString();
}

/// Explicit SQL keeps migrations reviewable; no generated schema magic or reset.
class HabitDatabase extends GeneratedDatabase {
  HabitDatabase(super.executor);
  Future<void> Function()? beforeCommit;
  Future<void> Function()? beforeMigrationCommit;
  Future<void> Function()? beforeSyncCommit;

  @override
  int get schemaVersion => 3;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (migrator) => transaction(() async {
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
      await _createDomainTables();
      await _createSyncTables();
      await customStatement('PRAGMA user_version = 3');
    }),
    onUpgrade: (migrator, from, to) async {
      if ((from != 1 && from != 2) || to != 3) {
        throw DataRecoveryRequired('不支持数据库版本 $from → $to。请使用兼容版本，原库未被重置。');
      }
      await transaction(() async {
        if (from == 1) {
          final state = await customSelect(
            'SELECT settings FROM app_state WHERE id=1',
          ).getSingleOrNull();
          final rows = await customSelect(
            'SELECT id, payload FROM habits ORDER BY position',
          ).get();
          final settings = state == null
              ? <String, Object?>{}
              : (jsonDecode(state.read<String>('settings')) as Map)
                    .cast<String, Object?>();
          final raw = jsonEncode({
            ...settings,
            'habits': rows
                .map((r) => jsonDecode(r.read<String>('payload')))
                .toList(),
          });
          SnapshotCodec.decode(raw);
          await customStatement(
            'INSERT INTO protections(payload,digest,created_at) VALUES (?,?,?)',
            [
              raw,
              SqliteHabitRepository._digest(raw),
              DateTime.now().toUtc().toIso8601String(),
            ],
          );
          await _createDomainTables();
          for (final row in rows) {
            final full = (jsonDecode(row.read<String>('payload')) as Map)
                .cast<String, Object?>();
            final habit = Habit.fromJson(full);
            for (final e in habit.entries) {
              await putChild('records', habit.id, e.id, jsonEncode(e.toJson()));
            }
            for (final p in habit.plans) {
              await putChild('plans', habit.id, p.id, jsonEncode(p.toJson()));
            }
            for (final note in habit.notes.entries) {
              await putChild(
                'daily_notes',
                habit.id,
                '${habit.id}:${note.key}',
                jsonEncode({'date': note.key, 'text': note.value}),
              );
            }
            full
              ..remove('entries')
              ..remove('plans')
              ..remove('notes')
              ..remove('completions');
            await customStatement('UPDATE habits SET payload=? WHERE id=?', [
              jsonEncode(full),
              habit.id,
            ]);
          }
        }
        await _createSyncTables();
        await beforeMigrationCommit?.call();
        await customStatement('PRAGMA user_version = 3');
      });
    },
    beforeOpen: (_) async {
      await customStatement('PRAGMA foreign_keys = ON');
      await customStatement('PRAGMA busy_timeout = 3000');
      await customStatement('PRAGMA synchronous = FULL');
    },
  );
  Future<void> _createSyncTables() async {
    await customStatement(
      'CREATE TABLE sync_state(id INTEGER PRIMARY KEY CHECK(id=1),revision INTEGER NOT NULL,payload TEXT NOT NULL)',
    );
    await customStatement(
      'CREATE TABLE sync_protections(sequence INTEGER PRIMARY KEY AUTOINCREMENT,payload TEXT NOT NULL,created_at TEXT NOT NULL)',
    );
  }

  Future<void> _createDomainTables() async {
    await customStatement(
      "CREATE TABLE records(id TEXT PRIMARY KEY NOT NULL, habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE, local_date TEXT NOT NULL CHECK(length(local_date)=10), value INTEGER NOT NULL CHECK(value>0), deleted INTEGER NOT NULL CHECK(deleted IN (0,1)), payload TEXT NOT NULL)",
    );
    await customStatement(
      'CREATE INDEX records_habit_date ON records(habit_id, local_date)',
    );
    await customStatement(
      'CREATE TABLE plans(id TEXT PRIMARY KEY NOT NULL, habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE, effective_from TEXT NOT NULL, daily_target INTEGER NOT NULL CHECK(daily_target>0), payload TEXT NOT NULL, UNIQUE(habit_id,effective_from))',
    );
    await customStatement(
      'CREATE TABLE daily_notes(id TEXT PRIMARY KEY NOT NULL, habit_id TEXT NOT NULL REFERENCES habits(id) ON DELETE CASCADE, local_date TEXT NOT NULL CHECK(length(local_date)=10), content TEXT NOT NULL, payload TEXT NOT NULL, UNIQUE(habit_id,local_date))',
    );
  }

  Future<void> putChild(
    String table,
    String habitId,
    String id,
    String payload,
  ) {
    final statement = childStatement(table, habitId, id, payload);
    return customStatement(statement.sql, statement.args);
  }

  ({String sql, List<Object?> args}) childStatement(
    String table,
    String habitId,
    String id,
    String payload,
  ) {
    final value = jsonDecode(payload) as Map<String, dynamic>;
    return switch (table) {
      'records' => (
        sql:
            'INSERT INTO records(id,habit_id,local_date,value,deleted,payload) VALUES (?,?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET local_date=excluded.local_date,value=excluded.value,deleted=excluded.deleted,payload=excluded.payload',
        args: [
          id,
          habitId,
          value['date'],
          value['value'],
          value['deleted'] == true ? 1 : 0,
          payload,
        ],
      ),
      'plans' => (
        sql:
            'INSERT INTO plans(id,habit_id,effective_from,daily_target,payload) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET effective_from=excluded.effective_from,daily_target=excluded.daily_target,payload=excluded.payload',
        args: [id, habitId, value['from'], value['dailyTarget'], payload],
      ),
      'daily_notes' => (
        sql:
            'INSERT INTO daily_notes(id,habit_id,local_date,content,payload) VALUES (?,?,?,?,?) ON CONFLICT(id) DO UPDATE SET content=excluded.content,payload=excluded.payload',
        args: [id, habitId, value['date'], value['text'], payload],
      ),
      _ => throw ArgumentError.value(table),
    };
  }
}

/// No content key or authentication token may be persisted in this structure.
class SyncFrame {
  const SyncFrame({
    required this.businessRevision,
    required this.stateRevision,
    required this.snapshot,
    required this.state,
  });
  final int businessRevision, stateRevision;
  final String snapshot;
  final Map<String, dynamic>? state;
}
