import 'dart:convert';
import 'dart:io';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqlite3/sqlite3.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'support/legacy_fixture.dart';

// Frozen schema 1 fixture, intentionally independent of the current schema builder.
void createV1(File file, String raw) {
  final db = sqlite3.open(file.path);
  try {
    db.execute('PRAGMA journal_mode=WAL');
    db.execute(
      'CREATE TABLE app_state(id INTEGER PRIMARY KEY CHECK(id=1), settings TEXT NOT NULL, revision INTEGER NOT NULL CHECK(revision>0))',
    );
    db.execute(
      'CREATE TABLE habits(id TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL, position INTEGER NOT NULL CHECK(position>=0))',
    );
    db.execute(
      'CREATE TABLE local_changes(sequence INTEGER PRIMARY KEY AUTOINCREMENT, op_id TEXT NOT NULL UNIQUE, entity_id TEXT NOT NULL, payload TEXT, local_revision INTEGER NOT NULL)',
    );
    db.execute(
      'CREATE TABLE legacy_sources(source_key TEXT PRIMARY KEY NOT NULL, payload TEXT NOT NULL, digest TEXT NOT NULL)',
    );
    db.execute(
      'CREATE TABLE protections(sequence INTEGER PRIMARY KEY AUTOINCREMENT, payload TEXT NOT NULL, digest TEXT NOT NULL, created_at TEXT NOT NULL)',
    );
    final document = jsonDecode(raw) as Map<String, dynamic>;
    final habits = document.remove('habits') as List;
    db.execute('INSERT INTO app_state VALUES(1,?,7)', [jsonEncode(document)]);
    for (var i = 0; i < habits.length; i++) {
      db.execute('INSERT INTO habits VALUES(?,?,?)', [
        habits[i]['id'],
        jsonEncode(habits[i]),
        i,
      ]);
    }
    db.execute('PRAGMA user_version=1');
  } finally {
    db.close();
  }
}

void main() {
  for (final interrupted in [false, true]) {
    test(
      'schema 1→3 ${interrupted ? '提交前失败保持版本和原数据，再打开可重试' : '保留记录、备注、设置与保护副本'}',
      () async {
        final dir = await Directory.systemTemp.createTemp('haoxiguan-upgrade-');
        final file = File('${dir.path}/db.sqlite');
        final now = DateTime(2026, 7, 15);
        final raw = legacyFixture(now);
        createV1(file, raw);
        try {
          if (interrupted) {
            final failed = SqliteHabitRepository(
              HabitDatabase(NativeDatabase(file))
                ..beforeMigrationCommit = () async =>
                    throw const FileSystemException('injected interruption'),
            );
            await expectLater(
              failed.load(),
              throwsA(isA<FileSystemException>()),
            );
            await failed.close();
            final check = sqlite3.open(file.path);
            try {
              expect(
                check.select('PRAGMA user_version').single.values.single,
                1,
              );
              expect(
                check.select(
                  "SELECT name FROM sqlite_master WHERE name='records'",
                ),
                isEmpty,
              );
              expect(
                check
                    .select('SELECT count(*) AS n FROM protections')
                    .single['n'],
                0,
              );
              final stored = check
                  .select('SELECT payload FROM habits ORDER BY position')
                  .map((r) => jsonDecode(r['payload'] as String))
                  .toList();
              expect(stored, jsonDecode(raw)['habits']);
            } finally {
              check.close();
            }
          }
          final repository = SqliteHabitRepository(
            HabitDatabase(NativeDatabase(file)),
          );
          final controller = HabitController(repository, clock: () => now);
          await controller.load();
          expect(controller.loaded, isTrue);
          expect(controller.habits.length, 3);
          expect(controller.habitById('seed-reading')!.entries.length, 2);
          expect(
            jsonDecode((await repository.loadBackup())!)['habits'],
            jsonDecode(raw)['habits'],
          );
          final version = await repository.database
              .customSelect('PRAGMA user_version')
              .getSingle();
          expect(version.data.values.single, 3);
          final export = controller.exportJson();
          controller.dispose();
          await repository.close();
          final reopened = SqliteHabitRepository(
            HabitDatabase(NativeDatabase(file)),
          );
          final next = HabitController(reopened, clock: () => now);
          await next.load();
          expect(jsonDecode(next.exportJson()), jsonDecode(export));
          next.dispose();
          await reopened.close();
        } finally {
          await dir.delete(recursive: true);
        }
      },
    );
  }
}
