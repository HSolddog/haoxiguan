import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_settings.dart';
import 'package:haoxiguan/services/webdav_client.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/backup_restore_dialog.dart';
import 'package:haoxiguan/ui/legacy_restore_dialog.dart';
import 'package:haoxiguan/ui/trash_screen.dart';
import 'package:haoxiguan/ui/webdav_screen.dart';

class _Repository extends MemoryHabitRepository {
  int saves = 0;
  int replacements = 0;
  bool fail = false;
  Completer<void>? gate;

  @override
  Future<void> save(String value) async {
    saves++;
    await gate?.future;
    if (fail) throw StateError('synthetic storage failure');
    await super.save(value);
  }

  @override
  Future<void> replace(String value) async {
    replacements++;
    await super.replace(value);
  }
}

Future<HabitController> _seed(
  _Repository repository, {
  bool trash = false,
}) async {
  final c = HabitController(repository, clock: () => DateTime(2026, 10, 3));
  await c.load();
  await c.addHabit(
    title: '待处理习惯',
    emoji: '🌱',
    colorValue: 0xff5f8068,
    weekdays: {1, 2, 3, 4, 5, 6, 7},
  );
  await c.markCompleted(c.habits.single.id, c.today);
  await c.setNote(c.habits.single.id, c.today, '必须保留的备注');
  if (trash) await c.deleteHabit(c.habits.single.id);
  repository.saves = 0;
  addTearDown(c.dispose);
  return c;
}

Future<GlobalKey<NavigatorState>> _page(
  WidgetTester tester,
  Widget page,
) async {
  final key = GlobalKey<NavigatorState>();
  await tester.pumpWidget(
    MaterialApp(
      navigatorKey: key,
      home: const Scaffold(body: Text('底页')),
    ),
  );
  key.currentState!.push<void>(MaterialPageRoute(builder: (_) => page));
  await tester.pumpAndSettle();
  return key;
}

Future<void> _legacy(WidgetTester tester, HabitController c) async {
  await _page(
    tester,
    Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => showLegacyRestoreDialog(context, c),
          child: const Text('工作页：恢复'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('工作页：恢复'));
  await tester.pumpAndSettle();
  await tester.enterText(
    find.byKey(const Key('legacy-json-field')),
    c.exportJson(),
  );
}

VoidCallback _textAction(WidgetTester tester, String text) =>
    tester.widget<TextButton>(find.widgetWithText(TextButton, text)).onPressed!;
VoidCallback _filledAction(WidgetTester tester, String text) => tester
    .widget<FilledButton>(find.widgetWithText(FilledButton, text))
    .onPressed!;

Finder get _webdavScroll => find
    .descendant(
      of: find.byType(WebDavScreen),
      matching: find.byType(Scrollable),
    )
    .first;

Future<void> _deleteDialog(WidgetTester tester) async {
  await tester.tap(find.widgetWithText(TextButton, '永久删除'));
  await tester.pumpAndSettle();
  expect(find.text('永久删除“待处理习惯”？'), findsOneWidget);
}

class _Secrets implements SecretStore {
  final values = <String, String>{};
  int reads = 0, writes = 0, deletes = 0;
  bool blockRead = false;
  @override
  Future<String?> read(String key) async {
    reads++;
    if (blockRead) throw StateError('synthetic stale credential-read trap');
    return values[key];
  }

  @override
  Future<void> write(String key, String value) async {
    writes++;
    values[key] = value;
  }

  @override
  Future<void> delete(String key) async {
    deletes++;
    values.remove(key);
  }

  void resetCounts() {
    reads = 0;
    writes = 0;
    deletes = 0;
  }
}

class _Dav extends WebDavClient {
  _Dav(this.raw)
    : super('https://synthetic.invalid/dav/', 'synthetic', 'synthetic');
  final String raw;
  int probes = 0, uploads = 0, restores = 0, closes = 0;
  Completer<void>? probeGate;
  @override
  Future<void> verifyAccess(String vault, String device) async {
    probes++;
    await probeGate?.future;
  }

  @override
  Future<RemoteBackup> upload(
    String raw,
    String password,
    String vault,
    String device,
  ) async {
    uploads++;
    return RemoteBackup(
      vault: vault,
      device: device,
      id: '44444444-4444-4444-8444-444444444444',
      created: DateTime.utc(2026, 10, 3),
      digest: 'a' * 64,
      size: 128,
    );
  }

  @override
  Future<String> restore(RemoteBackup item, String password) async {
    restores++;
    return raw;
  }

  @override
  void close() {
    closes++;
    super.close();
  }
}

Future<({BackupSettingsStore store, _Secrets secrets, String activeId})>
_settings(HabitController c) async {
  final secrets = _Secrets();
  final store = BackupSettingsStore(secrets);
  const id = '33333333-3333-4333-8333-333333333333';
  const device = '22222222-2222-4222-8222-222222222222';
  await secrets.write('device.id.v1', device);
  await store.save(
    BackupSettings(
      id: id,
      endpoint: 'https://synthetic.invalid/dav/',
      username: 'synthetic',
      appPassword: 'synthetic app password',
      backupPassword: 'synthetic backup password',
      vault: (jsonDecode(c.exportJson()) as Map)['vaultId'] as String,
      device: device,
    ),
  );
  secrets.resetCounts();
  return (store: store, secrets: secrets, activeId: id);
}

void main() {
  testWidgets(
    'legacy dismissed idle preview callback neither opens recovery nor pops work page',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository);
      final before = repository.value;
      await _legacy(tester, c);
      final finder = find.byKey(const Key('preview-legacy-json-button'));
      final element = tester.element(finder);
      final route = ModalRoute.of(element)!;
      final old = tester.widget<FilledButton>(finder).onPressed!;
      await tester.tap(find.byKey(const Key('cancel-legacy-json-button')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discard-changes-button')));
      await tester.pump();
      expect(element.mounted, isTrue);
      expect(route.isCurrent, isFalse);
      old();
      await tester.pumpAndSettle();
      expect(find.byType(BackupRestoreDialog), findsNothing);
      expect(find.text('工作页：恢复'), findsOneWidget);
      expect(repository.replacements, 0);
      expect(repository.saves, 0);
      expect(repository.value, before);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('legacy preview completion does not pop a newer route', (
    tester,
  ) async {
    final repository = _Repository();
    final c = await _seed(repository);
    await _legacy(tester, c);
    await tester.tap(find.byKey(const Key('preview-legacy-json-button')));
    await tester.pumpAndSettle();
    expect(find.byType(BackupRestoreDialog), findsOneWidget);
    final nav = Navigator.of(tester.element(find.byType(BackupRestoreDialog)));
    // Exercise the caller continuation: the child returns before another route
    // is pushed, while the legacy caller is still mounted beneath both.
    nav.pop(true);
    nav.push<void>(
      MaterialPageRoute(builder: (_) => const Scaffold(body: Text('后来的页面'))),
    );
    await tester.pumpAndSettle();
    expect(find.text('后来的页面'), findsOneWidget);
    expect(repository.replacements, 0);
    expect(tester.takeException(), isNull);
  });

  for (final action in ['恢复习惯', '永久删除']) {
    testWidgets(
      'trash dismissed idle $action callback performs zero writes and opens no confirmation',
      (tester) async {
        final repository = _Repository();
        final c = await _seed(repository, trash: true);
        final before = repository.value;
        final nav = await _page(tester, TrashScreen(controller: c));
        final element = tester.element(find.byType(TrashScreen));
        final route = ModalRoute.of(element)!;
        final old = _textAction(tester, action);
        nav.currentState!.pop();
        await tester.pump();
        expect(element.mounted, isTrue);
        expect(route.isCurrent, isFalse);
        old();
        await tester.pumpAndSettle();
        expect(repository.saves, 0);
        expect(repository.value, before);
        expect(find.byType(AlertDialog), findsNothing);
        expect(find.text('底页'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets(
    'trash canceled old confirm neither deletes nor pops underlying page',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository, trash: true);
      final before = repository.value;
      await _page(tester, TrashScreen(controller: c));
      await _deleteDialog(tester);
      final element = tester.element(find.byType(AlertDialog));
      final old = _filledAction(tester, '永久删除');
      await tester.tap(find.text('取消，保留数据'));
      expect(element.mounted, isTrue);
      expect(ModalRoute.of(element)!.isCurrent, isFalse);
      old();
      await tester.pumpAndSettle();
      expect(repository.saves, 0);
      expect(repository.value, before);
      expect(find.text('回收站'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'trash canceled old export callback performs no export or navigation',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository, trash: true);
      var exports = 0;
      await _page(
        tester,
        TrashScreen(controller: c, onExport: () => exports++),
      );
      await _deleteDialog(tester);
      final old = tester
          .widget<TextButton>(find.byKey(const Key('export-before-delete')))
          .onPressed!;
      await tester.tap(find.text('取消，保留数据'));
      old();
      await tester.pumpAndSettle();
      expect(exports, 0);
      expect(repository.saves, 0);
      expect(find.text('回收站'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'trash double confirm authorizes one durable deletion and keeps page',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository, trash: true);
      await _page(tester, TrashScreen(controller: c));
      await _deleteDialog(tester);
      final confirm = _filledAction(tester, '永久删除');
      confirm();
      confirm();
      await tester.pumpAndSettle();
      expect(repository.saves, 1);
      expect(c.habits, isEmpty);
      expect((jsonDecode(repository.value!) as Map)['habits'], isEmpty);
      expect(find.text('回收站'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'trash confirmation returning beneath new page cannot authorize deletion',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository, trash: true);
      final before = repository.value;
      final nav = await _page(tester, TrashScreen(controller: c));
      await _deleteDialog(tester);
      _filledAction(tester, '永久删除')();
      nav.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('后来的页面'))),
      );
      await tester.pumpAndSettle();
      expect(repository.saves, 0);
      expect(repository.value, before);
      expect(find.text('后来的页面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'trash double restore starts one write while pending and preserves record and note',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository, trash: true);
      final facts = c.habits.single.entries.map((e) => e.toJson()).toList();
      final notes = c.habits.single.notes;
      await _page(tester, TrashScreen(controller: c));
      repository.gate = Completer<void>();
      final restore = _textAction(tester, '恢复习惯');
      restore();
      restore();
      await tester.pump();
      expect(repository.saves, 1);
      repository.gate!.complete();
      await tester.pumpAndSettle();
      expect(repository.saves, 1);
      expect(c.trashedHabits, isEmpty);
      expect(c.habits.single.entries.map((e) => e.toJson()).toList(), facts);
      expect(c.habits.single.notes, notes);
      expect(tester.takeException(), isNull);
    },
  );

  for (final action in ['恢复习惯', '永久删除']) {
    testWidgets(
      'trash $action write failure preserves facts and allows a real retry',
      (tester) async {
        final repository = _Repository();
        final c = await _seed(repository, trash: true);
        final before = repository.value;
        await _page(tester, TrashScreen(controller: c));
        repository.fail = true;
        Future<void> invoke() async {
          if (action == '永久删除') {
            await _deleteDialog(tester);
            await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
          } else {
            await tester.tap(find.text('恢复习惯'));
          }
          await tester.pumpAndSettle();
        }

        await invoke();
        expect(repository.saves, 1);
        expect(repository.value, before);
        expect(c.exportJson(), before);
        expect(c.trashedHabits, hasLength(1));
        expect(c.saveError, isNotNull);
        expect(find.text(c.saveError!), findsOneWidget);
        repository.fail = false;
        await invoke();
        expect(repository.saves, 2);
        expect(c.trashedHabits, isEmpty);
        if (action == '恢复习惯') {
          expect(c.habits.single.entries, hasLength(1));
          expect(c.habits.single.notes, hasLength(1));
        } else {
          expect(c.habits, isEmpty);
        }
        expect(find.text('回收站'), findsOneWidget);
        expect(tester.takeException(), isNull);
      },
    );
  }

  for (final action in ['验证并保存配置', '立即备份', '断开']) {
    testWidgets(
      'WebDAV dismissed idle $action callback does no credential or network work',
      (tester) async {
        final repository = _Repository();
        final c = await _seed(repository);
        final settings = await _settings(c);
        var factories = 0;
        final dav = _Dav(c.exportJson());
        final nav = await _page(
          tester,
          WebDavScreen(
            controller: c,
            settingsStore: settings.store,
            clientFactory: (_) {
              factories++;
              return dav;
            },
          ),
        );
        // Local initialization must still complete and expose configured actions.
        expect(find.text('立即备份'), findsOneWidget);
        if (action == '验证并保存配置') {
          await tester.scrollUntilVisible(
            find.widgetWithText(FilledButton, action),
            300,
            scrollable: _webdavScroll,
          );
        }
        final old = action == '断开'
            ? _textAction(tester, action)
            : _filledAction(tester, action);
        final element = tester.element(find.byType(WebDavScreen));
        final route = ModalRoute.of(element)!;
        final before = Map<String, String>.from(settings.secrets.values);
        settings.secrets.resetCounts();
        // Any stale backup credential read fails locally, preventing a real
        // network client from reaching even the synthetic reserved hostname.
        if (action == '立即备份') settings.secrets.blockRead = true;
        nav.currentState!.pop();
        await tester.pump();
        expect(element.mounted, isTrue);
        expect(route.isCurrent, isFalse);
        old();
        await tester.pumpAndSettle();
        expect(settings.secrets.reads, 0);
        expect(settings.secrets.writes, 0);
        expect(settings.secrets.deletes, 0);
        expect(settings.secrets.values, before);
        expect(factories, 0);
        expect(dav.probes + dav.uploads + dav.restores, 0);
        expect(find.text('底页'), findsOneWidget);
        expect(tester.takeException(), isNull);
        dav.close();
      },
    );
  }

  testWidgets(
    'WebDAV successful initial load and active save still probe and preserve first backup',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository);
      final settings = await _settings(c);
      final dav = _Dav(c.exportJson());
      await _page(
        tester,
        WebDavScreen(
          controller: c,
          settingsStore: settings.store,
          clientFactory: (_) => dav,
        ),
      );
      final save = find.widgetWithText(FilledButton, '验证并保存配置');
      await tester.scrollUntilVisible(save, 300, scrollable: _webdavScroll);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(dav.probes, 1);
      expect(dav.uploads, 1);
      expect(dav.restores, 1);
      expect(dav.closes, 1);
      expect((await settings.store.load())!.id, isNot(settings.activeId));
      await tester.scrollUntilVisible(
        find.textContaining('第一份加密备份已上传并验证可恢复'),
        -300,
        scrollable: _webdavScroll,
      );
      expect(find.textContaining('第一份加密备份已上传并验证可恢复'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'WebDAV pending probe returning under new page cannot start backup or commit credentials',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository);
      final settings = await _settings(c);
      final dav = _Dav(c.exportJson())..probeGate = Completer<void>();
      final nav = await _page(
        tester,
        WebDavScreen(
          controller: c,
          settingsStore: settings.store,
          clientFactory: (_) => dav,
        ),
      );
      final before = Map<String, String>.from(settings.secrets.values);
      final save = find.widgetWithText(FilledButton, '验证并保存配置');
      await tester.scrollUntilVisible(save, 300, scrollable: _webdavScroll);
      await tester.tap(save);
      await tester.pump();
      expect(dav.probes, 1);
      nav.currentState!.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('后来的页面'))),
      );
      await tester.pump(const Duration(milliseconds: 400));
      dav.probeGate!.complete();
      await tester.pumpAndSettle();
      expect(dav.uploads, 0);
      expect(dav.restores, 0);
      expect(dav.closes, 1);
      expect(settings.secrets.values, before);
      expect(find.text('后来的页面'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
