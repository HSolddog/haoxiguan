import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/snapshot_codec.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/csv_export.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_entities.dart';

import 'support/sync_relay.dart';
import 'sync_engine_test.dart' as fixture;

void main() {
  late Directory directory;
  late TestSyncRelay relay;
  late SyncKeyring keys;
  late fixture.Device a, b;
  setUp(() async {
    directory = await Directory.systemTemp.createTemp('hgw-empty-category-');
    relay = TestSyncRelay();
    keys = await SyncKeyring.create(TestSyncRelay.vault);
    a = fixture.Device(
      await Directory('${directory.path}/a').create(),
      keys,
      relay,
    );
    b = fixture.Device(
      await Directory('${directory.path}/b').create(),
      keys,
      relay,
    );
    await a.open(first: true);
    await b.open(first: true);
  });
  tearDown(() async {
    await a.close();
    await b.close();
    keys.dispose();
    await directory.delete(recursive: true);
  });

  Map<String, dynamic> category(String snapshot, String id) =>
      ((jsonDecode(snapshot) as Map)['categories'] as List)
          .cast<Map<String, dynamic>>()
          .singleWhere((category) => category['id'] == id);

  Future<(String, Map<String, dynamic>)> seedCategory() async {
    expect(
      await a.controller.addHabit(
        title: '最后一个成员',
        emoji: '🌱',
        colorValue: 0xff123456,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        category: '原分类',
        recordType: 'count',
        dailyTarget: 100,
      ),
      true,
    );
    final id = a.controller.habits.single.id;
    await a.controller.addValue(id, fixture.today, 15);
    await a.controller.setNote(id, fixture.today, '原记录与备注');
    final document =
        jsonDecode(a.controller.exportJson()) as Map<String, dynamic>;
    final habit = (document['habits'] as List).single as Map;
    final descriptor = <String, dynamic>{
      ...habit['categoryInfo'] as Map,
      'sortKey': 4096,
      'revision': 7,
      'futureCategoryMetadata': {
        'label': '完整保留',
        'values': [1, true, null],
      },
    };
    habit['categoryInfo'] = descriptor;
    document['categories'] = [descriptor];
    await a.repository.save(jsonEncode(document));
    await a.controller.load();
    expect(
      category(a.controller.exportJson(), descriptor['id'] as String),
      descriptor,
    );
    return (id, descriptor);
  }

  Future<void> reassignLastHabit(String id) async {
    final habit = a.controller.habitById(id)!;
    expect(
      await a.controller.updateHabit(
        habitId: id,
        title: habit.title,
        emoji: habit.emoji,
        colorValue: habit.colorValue,
        weekdays: habit.weekdays,
        category: '新分类',
      ),
      true,
    );
  }

  test(
    'last member reassignment preserves empty category through normal sync, reopen and exports',
    () async {
      final (id, descriptor) = await seedCategory();
      final categoryId = descriptor['id'] as String;
      expect((await a.sync()).complete, true);
      expect((await b.sync()).complete, true);
      expect(
        (await a.repository.readSyncFrame()).state!['previewRequired'],
        false,
      );
      await reassignLastHabit(id);
      expect(
        a.controller.habits.where((h) => h.categoryId == categoryId),
        isEmpty,
      );
      final before = SyncEntities.encodeFacts(a.controller.exportJson());
      expect((await a.sync()).complete, true);
      expect((await b.sync()).complete, true);
      expect((await a.sync()).complete, true);
      for (final device in [a, b]) {
        expect(
          category(device.controller.exportJson(), categoryId),
          descriptor,
        );
        expect(
          device.controller.habits.where((h) => h.categoryId == categoryId),
          isEmpty,
        );
        expect(
          SyncEntities.encodeFacts(device.controller.exportJson()),
          before,
        );
      }
      await a.close();
      await a.open();
      final reopened = a.controller.exportJson();
      expect(category(reopened, categoryId), descriptor);
      expect(SyncEntities.encodeFacts(reopened), before);
      final jsonFile = File('${directory.path}/after-sync.json');
      await jsonFile.writeAsString(reopened, flush: true);
      final jsonReadback = await jsonFile.readAsString();
      SnapshotCodec.decode(jsonReadback);
      expect(category(jsonReadback, categoryId), descriptor);
      final backup = File('${directory.path}/after-sync.hgbak');
      await backup.writeAsBytes(
        await BackupCodec.encrypt(
          reopened,
          'synthetic empty category password',
        ),
        flush: true,
      );
      final restored = await BackupCodec.decrypt(
        await backup.readAsBytes(),
        'synthetic empty category password',
      );
      expect(category(restored, categoryId), descriptor);
      expect(SyncEntities.encodeFacts(restored), before);
      final csv = File('${directory.path}/categories.csv');
      await csv.writeAsBytes(
        CsvExport.tables(restored)['categories.csv']!,
        flush: true,
      );
      expect(
        await csv.readAsString(),
        contains('"$categoryId","原分类","4096","7"\r\n'),
      );
      final changes = relay.changes.length;
      expect((await a.sync()).complete, true);
      expect(relay.changes.length, changes);
      expect(category(a.controller.exportJson(), categoryId), descriptor);
    },
  );

  test(
    'selected category descriptor wins local projection while same-name empty identity survives',
    () async {
      final (id, descriptor) = await seedCategory();
      final local =
          jsonDecode(a.controller.exportJson()) as Map<String, dynamic>;
      final empty = <String, dynamic>{
        ...descriptor,
        'id': 'empty-same-name',
        'sortKey': -1024,
        'revision': 3,
        'futureCategoryMetadata': {'empty': true},
      };
      (local['categories'] as List).add(empty);
      final snapshot = jsonEncode(local);
      final selected = SyncEntities.encode(snapshot);
      final remoteDescriptor = <String, dynamic>{
        'id': descriptor['id'],
        'name': descriptor['name'],
        'sortKey': 8192,
        'revision': 2,
        'selectedRemoteMetadata': {'source': 'selected candidate'},
      };
      selected['h/$id']['categoryInfo'] = remoteDescriptor;
      final assembled = SyncEntities.assemble(snapshot, selected);
      expect(category(assembled, descriptor['id'] as String), remoteDescriptor);
      expect(category(assembled, 'empty-same-name'), empty);
      final document = jsonDecode(assembled) as Map;
      expect((document['categories'] as List).map((c) => c['id']), [
        'empty-same-name',
        descriptor['id'],
      ]);
      expect(
        (document['habits'] as List).single['categoryInfo'],
        remoteDescriptor,
      );
    },
  );

  test(
    'legacy label edit cannot replace newer local empty category or resurrect absent category',
    () async {
      final (id, descriptor) = await seedCategory();
      final snapshot = a.controller.exportJson();
      final selected = SyncEntities.encode(snapshot);
      // A legacy client changes the compatibility label while retaining an older
      // unknown categoryInfo extension. Normalization moves this habit to a new ID.
      selected['h/$id']['category'] = '旧端改成新分类';
      selected['h/$id']['categoryInfo'] = {
        'id': descriptor['id'],
        'name': descriptor['name'],
        'sortKey': 0,
        'revision': 1,
      };
      final assembled = SyncEntities.assemble(snapshot, selected);
      final document = jsonDecode(assembled) as Map<String, dynamic>;
      final habit = (document['habits'] as List).single as Map;
      expect(habit['categoryId'], isNot(descriptor['id']));
      expect(habit['category'], '旧端改成新分类');
      expect(category(assembled, descriptor['id'] as String), descriptor);
      // If the current local document no longer contains the old empty category,
      // the same stale remote categoryInfo must not bring it back.
      document['categories'] = (document['categories'] as List)
          .where((category) => (category as Map)['id'] != descriptor['id'])
          .toList();
      final withoutOldCategory = SyncEntities.assemble(
        jsonEncode(document),
        selected,
      );
      final decoded = jsonDecode(withoutOldCategory) as Map;
      expect(
        (decoded['categories'] as List).map((category) => category['id']),
        [habit['categoryId']],
      );
      expect(
        (decoded['habits'] as List).single['categoryId'],
        habit['categoryId'],
      );
    },
  );

  test(
    'cancelled initial preview preserves local empty categories and sends no objects',
    () async {
      final (id, descriptor) = await seedCategory();
      await reassignLastHabit(id);
      await b.add();
      expect((await b.sync()).complete, true);
      final before = (await a.repository.readSyncFrame()).snapshot;
      final changes = relay.changes.length;
      final first = await a.engine.run();
      expect(first.preview, isNotNull);
      expect((await a.repository.readSyncFrame()).snapshot, before);
      expect(relay.changes.length, changes);
      await a.close();
      await a.open();
      final second = await a.engine.run();
      expect(second.preview, isNotNull);
      expect((await a.repository.readSyncFrame()).snapshot, before);
      expect(
        category(a.controller.exportJson(), descriptor['id'] as String),
        descriptor,
      );
      expect(relay.changes.length, changes);
    },
  );

  test(
    'remote permanent deletion keeps category without reviving habit, records or notes',
    () async {
      final (id, descriptor) = await seedCategory();
      await a.sync();
      await b.sync();
      final entityIds = SyncEntities.encode(
        b.controller.exportJson(),
      ).keys.toList();
      expect(await a.controller.deleteHabit(id), true);
      expect(await a.controller.permanentlyDeleteHabit(id), true);
      expect((await a.sync()).complete, true);
      final changes = relay.changes.length;
      expect((await b.sync()).complete, true);
      expect(b.controller.habits, isEmpty);
      expect(SyncEntities.encodeFacts(b.controller.exportJson()), isEmpty);
      expect(
        category(b.controller.exportJson(), descriptor['id'] as String),
        descriptor,
      );
      expect(
        relay.objects.values.every((object) => object['deleted'] == true),
        true,
      );
      expect(relay.changes.length, changes);
      // A category absent from the current local document and all selected h/
      // entities is never reconstructed from base or remote deletion history.
      final noLocalCategory =
          jsonDecode(b.controller.exportJson()) as Map<String, dynamic>;
      noLocalCategory['categories'] = <dynamic>[];
      final deletedOnly = <String, dynamic>{
        for (final key in entityIds) key: null,
      };
      expect(
        (jsonDecode(
              SyncEntities.assemble(jsonEncode(noLocalCategory), deletedOnly),
            )
            as Map)['categories'],
        isEmpty,
      );
    },
  );
}
