import 'dart:io';
import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:path_provider/path_provider.dart';

/// A separate SQLite lock serializes foreground/background platform side effects.
/// It never holds the business database's write lock while waiting on the OS/network.
class DeviceTaskLock {
  static Future<T> run<T>(String name, Future<T> Function() operation) async {
    if (!Platform.isAndroid) return operation();
    final directory = await getApplicationSupportDirectory();
    final db = _LockDatabase(
      NativeDatabase.createInBackground(
        File('${directory.path}/task-$name.sqlite'),
        setup: (db) => db.execute('PRAGMA busy_timeout=5000'),
      ),
    );
    try {
      return await db.transaction(() async {
        await db.customStatement('UPDATE mutex SET value=value+1 WHERE id=1');
        return operation();
      });
    } finally {
      await db.close();
    }
  }
}

class _LockDatabase extends GeneratedDatabase {
  _LockDatabase(super.executor);
  @override
  int get schemaVersion => 1;
  @override
  Iterable<TableInfo<Table, Object?>> get allTables => const [];
  @override
  MigrationStrategy get migration => MigrationStrategy(
    onCreate: (_) => transaction(() async {
      await customStatement(
        'CREATE TABLE mutex(id INTEGER PRIMARY KEY,value INTEGER NOT NULL)',
      );
      await customStatement('INSERT INTO mutex VALUES(1,0)');
      await customStatement('PRAGMA user_version=1');
    }),
    beforeOpen: (_) async {
      await customStatement('PRAGMA busy_timeout=5000');
    },
  );
}
