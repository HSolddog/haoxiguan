import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/data/sqlite_habit_repository.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/services/data_status.dart';
import 'package:haoxiguan/services/sync_client.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/services/sync_recovery.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/data_screen.dart';
import 'package:haoxiguan/ui/sync_screen.dart';
// The test redirects the platform directory to an isolated temporary SQLite DB.
// ignore: depend_on_referenced_packages
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
// Existing SQLite facts must never fall through to a real legacy preferences store.
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_async_platform_interface.dart';

import 'support/sync_relay.dart';

const _password = 'public synthetic route consent phrase';

class _Repository extends MemoryHabitRepository {
  int replacements = 0;
  @override
  Future<void> replace(String value) async {
    replacements++;
    await super.replace(value);
  }
}

class _Files implements BackupFiles {
  int saves = 0;
  final entered = Completer<void>();
  final release = Completer<bool>();
  @override
  Future<bool> save(Uint8List bytes, String name) async {
    saves++;
    if (!entered.isCompleted) entered.complete();
    return release.future;
  }

  @override
  Future<Uint8List?> open() async => null;
}

class _Status extends DataStatusReader {
  @override
  Future<DataServiceStatus> read(String snapshot) async =>
      const DataServiceStatus(backup: '未启用', sync: '未启用');
  @override
  Future<void> recordFileBackup(String snapshot, String name) async {}
}

Future<HabitController> _seed(HabitRepository repository) async {
  final c = HabitController(repository, clock: () => DateTime(2026, 10, 3));
  await c.load();
  expect(
    await c.addHabit(
      title: '原始事实',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    ),
    isTrue,
  );
  addTearDown(c.dispose);
  return c;
}

class _Observer extends NavigatorObserver {
  int pushes = 0;
  @override
  void didPush(Route<dynamic> route, Route<dynamic>? previousRoute) {
    pushes++;
  }
}

class _OpenedFiles extends _Files {
  final read = Completer<Uint8List?>();
  int opens = 0;
  @override
  Future<Uint8List?> open() {
    opens++;
    return read.future;
  }
}

class _Host {
  final navigator = GlobalKey<NavigatorState>();
  final observer = _Observer();
  int closed = 0;
  Future<void> open(
    WidgetTester tester,
    Widget page, {
    bool waitForSync = false,
  }) async {
    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        navigatorObservers: [observer],
        home: const Scaffold(body: Text('底页')),
      ),
    );
    navigator.currentState!
        .push<void>(MaterialPageRoute(builder: (_) => page))
        .then((_) => closed++);
    await tester.pump();
    if (waitForSync) {
      final sync = find.widgetWithText(FilledButton, '立即同步');
      await _waitFor(
        tester,
        () =>
            sync.evaluate().isNotEmpty &&
            tester.widget<FilledButton>(sync).onPressed != null,
      );
    }
    await tester.pumpAndSettle();
  }

  void overlay() => navigator.currentState!.push<void>(
    MaterialPageRoute(builder: (_) => const Scaffold(body: Text('独立后来页'))),
  );
}

Future<void> _openDialog(
  WidgetTester tester,
  _Host host,
  WidgetBuilder builder,
) async {
  await host.open(
    tester,
    Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => showDialog<bool>(context: context, builder: builder),
          child: const Text('dialog'),
        ),
      ),
    ),
  );
  await tester.tap(find.text('dialog'));
  await tester.pumpAndSettle();
}

VoidCallback _filled(WidgetTester tester, String label) => tester
    .widget<FilledButton>(find.widgetWithText(FilledButton, label))
    .onPressed!;
VoidCallback _text(WidgetTester tester, String label) => tester
    .widget<TextButton>(find.widgetWithText(TextButton, label))
    .onPressed!;

Future<void> _discard(
  WidgetTester tester,
  String cancel,
  BuildContext context,
) async {
  final route = ModalRoute.of(context)!;
  _text(tester, cancel)();
  await tester.pumpAndSettle();
  tester
      .widget<TextButton>(find.byKey(const Key('discard-changes-button')))
      .onPressed!();
  await tester.idle(); // Flush leave() without disposing the original dialog.
  expect(context.mounted, isTrue);
  expect(route.isCurrent, isFalse);
}

Future<void> _passwordFields(WidgetTester tester) async {
  final fields = find.descendant(
    of: find.byType(AlertDialog),
    matching: find.byType(TextField),
  );
  await tester.enterText(fields.at(0), _password);
  await tester.enterText(fields.at(1), _password);
  await tester.pumpAndSettle();
}

Future<void> _dataAction(WidgetTester tester, String label) async {
  final action = find.text(label);
  await tester.scrollUntilVisible(
    action,
    180,
    scrollable: find
        .descendant(
          of: find.byType(DataScreen),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await tester.pumpAndSettle();
  await tester.ensureVisible(action);
  await tester.pumpAndSettle();
  await tester.tap(action);
  await tester.pumpAndSettle();
}

Future<void> _waitFor(
  WidgetTester tester,
  bool Function() ready, {
  String Function()? reason,
}) async {
  for (var i = 0; !ready() && i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue, reason: reason?.call());
}

class _Paths extends PathProviderPlatform {
  _Paths(this.path);
  final String path;
  @override
  Future<String?> getApplicationSupportPath() async => path;
}

final class _UnusedLegacyPreferences extends SharedPreferencesAsyncPlatform {
  @override
  dynamic noSuchMethod(Invocation invocation) => throw StateError(
    'Unexpected legacy preferences access in initialized SQLite fixture',
  );
}

class _HttpHeaders implements HttpHeaders {
  final values = <String, String>{};
  @override
  void set(String name, Object value, {bool preserveHeaderCase = false}) =>
      values[name.toLowerCase()] = value.toString();
  @override
  set contentType(ContentType? value) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Reply extends Stream<List<int>> implements HttpClientResponse {
  _Reply(this.body);
  final Map<String, dynamic> body;
  @override
  int get statusCode => 200;
  @override
  StreamSubscription<List<int>> listen(
    void Function(List<int>)? onData, {
    Function? onError,
    void Function()? onDone,
    bool? cancelOnError,
  }) => Stream<List<int>>.value(utf8.encode(jsonEncode(body))).listen(
    onData,
    onError: onError,
    onDone: onDone,
    cancelOnError: cancelOnError,
  );
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Request implements HttpClientRequest {
  _Request(this.client, this.method, this.url);
  final _Http client;
  @override
  final String method;
  final Uri url;
  final bytes = <int>[];
  @override
  final _HttpHeaders headers = _HttpHeaders();
  @override
  bool followRedirects = false;
  @override
  int contentLength = 0;
  @override
  void add(List<int> data) => bytes.addAll(data);
  @override
  Future<HttpClientResponse> close() async {
    if (method == 'GET' && url.path == '/v1/devices') {
      return _Reply({
        'devices': [
          {'id': 'd' * 32, 'name': 'synthetic device', 'revoked': false},
        ],
      });
    }
    if (method == 'DELETE' && url.path == '/v1/account') {
      expect(headers.values['x-confirm-delete'], 'delete-remote-account');
      client.deletes++;
      return _Reply({});
    }
    final response = await client.relay.request(
      method,
      '${url.path}${url.hasQuery ? '?${url.query}' : ''}',
      body: bytes.isEmpty
          ? null
          : jsonDecode(utf8.decode(bytes)) as Map<String, Object?>,
      token: headers.values['authorization']?.replaceFirst('Bearer ', ''),
      headers: headers.values,
    );
    return _Reply(response);
  }

  @override
  void abort([Object? exception, StackTrace? stackTrace]) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Http implements HttpClient {
  final relay = TestSyncRelay();
  int deletes = 0;
  final requests = <String>[];
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) async {
    requests.add('$method ${url.path}');
    return _Request(this, method, url);
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _syncPage(
  WidgetTester tester,
  _Host host,
  Future<void> Function(
    HabitController,
    SqliteHabitRepository,
    MemorySecrets,
    _Http,
  )
  body,
) async {
  final directory = await tester.runAsync(
    () => Directory.systemTemp.createTemp('dialog-submit-route-'),
  );
  final previous = PathProviderPlatform.instance;
  final previousPreferences = SharedPreferencesAsyncPlatform.instance;
  PathProviderPlatform.instance = _Paths(directory!.path);
  SharedPreferencesAsyncPlatform.instance = _UnusedLegacyPreferences();
  final repository = SqliteHabitRepository(
    HabitDatabase(NativeDatabase(File('${directory.path}/haoxiguan.sqlite'))),
    legacy: MemoryHabitRepository(),
  );
  try {
    final c = await tester.runAsync(() => _seed(repository));
    await tester.runAsync(
      () => File('${directory.path}/haoxiguan.initialized').writeAsString('1'),
    );
    await tester.runAsync(() async {
      final beforeReopen = await repository.load();
      final reopened = await SqliteHabitRepository.open();
      try {
        expect(await reopened.load(), beforeReopen);
      } finally {
        await reopened.close();
      }
    });
    final keys = await tester.runAsync(() => SyncKeyring.create('v' * 32));
    final secrets = MemorySecrets();
    final store = SyncSettingsStore(secrets);
    await store.save(
      SyncSettings(
        id: '33333333-3333-4333-8333-333333333333',
        endpoint: 'https://sync.example.test',
        localVault: (jsonDecode(c!.exportJson()) as Map)['vaultId'] as String,
        keys: keys!,
        tokens: {
          'accessToken': 'a' * 43,
          'refreshToken': 'r' * 43,
          'deviceId': 'd' * 32,
          'vaultId': 'v' * 32,
          'epoch': 'e' * 32,
          'accessExpiresAt':
              DateTime.now().toUtc().millisecondsSinceEpoch ~/ 1000 + 3600,
        },
        recoveryExported: true,
        initialReview: false,
      ),
    );
    keys.dispose();
    final http = _Http();
    await HttpOverrides.runZoned(() async {
      await host.open(
        tester,
        Scaffold(
          body: SyncScreen(controller: c, settingsStore: store),
        ),
        waitForSync: true,
      );
      await body(c, repository, secrets, http);
      await tester.pumpWidget(const SizedBox.shrink());
    }, createHttpClient: (_) => http);
  } finally {
    await tester.runAsync(repository.close);
    PathProviderPlatform.instance = previous;
    SharedPreferencesAsyncPlatform.instance = previousPreferences;
    final resolved = directory.absolute.path;
    expect(resolved.startsWith(Directory.systemTemp.absolute.path), isTrue);
    await tester.runAsync(() => directory.delete(recursive: true));
  }
}

void main() {
  testWidgets(
    'dismissed merge submit cannot write through its mounted old callback',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository);
      await c.setNote(c.habits.single.id, c.today, '本机备注');
      final before = c.exportJson();
      String snapshot(String note) {
        final document = jsonDecode(before) as Map<String, dynamic>;
        document['habits'][0]['notes'] = {'2026-10-03': note};
        return jsonEncode(document);
      }

      final decision = SyncEntities.merge(
        before,
        SyncEntities.encode(snapshot('原备注')),
        SyncEntities.encode(snapshot('远端备注')),
      );
      var calls = 0;
      final host = _Host();
      await _openDialog(
        tester,
        host,
        (_) => SyncConflictDialog(
          decision: decision,
          onApply: (selections) async {
            calls++;
            await c.importJson(
              SyncEntities.assemble(before, decision.select(selections)),
            );
          },
        ),
      );
      await tester.tap(find.byType(DropdownButtonFormField<SyncChoice>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('采用远端此项').last);
      await tester.pumpAndSettle();
      final submit = _filled(tester, '保护副本并应用合并');
      final context = tester.element(find.byType(SyncConflictDialog));
      await _discard(tester, '稍后处理', context);
      submit();
      await tester.idle();
      expect(calls, 0);
      expect(repository.replacements, 0);
      expect(repository.protectedSources, isEmpty);
      expect(repository.value, before);
      await tester.pumpAndSettle();
      expect(host.closed, 0);
    },
  );

  testWidgets(
    'dismissed recovery submit cannot start KDF or save through its old callback',
    (tester) async {
      var kdfStarts = 0, files = 0;
      final keys = await tester.runAsync(() => SyncKeyring.create('v' * 32));
      addTearDown(keys!.dispose);
      Future<Uint8List>? pending;
      final host = _Host();
      await _openDialog(
        tester,
        host,
        (_) => SyncRecoveryPasswordDialog(
          onContinue: (password) async {
            kdfStarts++;
            // The real KDF delegate remains unreachable after cancellation.
            pending = SyncRecoveryCodec.encrypt(keys, password);
            await pending;
            files++;
            return true;
          },
        ),
      );
      await _passwordFields(tester);
      final submit = _filled(tester, '加密并保存');
      final context = tester.element(find.byType(SyncRecoveryPasswordDialog));
      await _discard(tester, '取消', context);
      submit();
      await tester.idle();
      if (pending != null) await _waitFor(tester, () => files == 1);
      expect(kdfStarts, 0);
      expect(files, 0);
      await tester.pumpAndSettle();
      expect(host.closed, 0);
    },
  );

  testWidgets(
    'dismissed backup password submit cannot save from its old callback',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository);
      final before = repository.value;
      final files = _Files();
      final host = _Host();
      await host.open(
        tester,
        Scaffold(
          body: DataScreen(
            controller: c,
            onTheme: () {},
            onReview: () {},
            onLegacyRestore: () {},
            files: files,
            statusReader: _Status(),
          ),
        ),
      );
      await _dataAction(tester, '创建加密备份');
      await _passwordFields(tester);
      final submit = _filled(tester, '继续');
      final context = tester.element(find.byType(AlertDialog));
      await _discard(tester, '取消', context);
      submit();
      for (var i = 0; files.saves == 0 && i < 60; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 50)),
        );
        await tester.pump();
      }
      if (!files.release.isCompleted) files.release.complete(false);
      await tester.idle();
      expect(files.saves, 0);
      expect(repository.value, before);
      expect(repository.protectedSources, isEmpty);
      await tester.pumpAndSettle();
      expect(host.closed, 0);
    },
  );

  testWidgets('completed recovery save cannot pop a later unrelated route', (
    tester,
  ) async {
    final gate = Completer<bool>();
    final host = _Host();
    await _openDialog(
      tester,
      host,
      (_) => SyncRecoveryPasswordDialog(onContinue: (_) => gate.future),
    );
    await _passwordFields(tester);
    _filled(tester, '加密并保存')();
    host.overlay();
    await tester.pumpAndSettle();
    gate.complete(true);
    await tester.pumpAndSettle();
    expect(find.text('独立后来页'), findsOneWidget);
    expect(host.closed, 0);
  });

  testWidgets(
    'completed backup password save cannot pop a later unrelated route',
    (tester) async {
      final c = await _seed(_Repository());
      final files = _Files();
      final host = _Host();
      await host.open(
        tester,
        Scaffold(
          body: DataScreen(
            controller: c,
            onTheme: () {},
            onReview: () {},
            onLegacyRestore: () {},
            files: files,
            statusReader: _Status(),
          ),
        ),
      );
      await _dataAction(tester, '创建加密备份');
      await _passwordFields(tester);
      _filled(tester, '继续')();
      await _waitFor(tester, () => files.saves == 1);
      host.overlay();
      await tester.pumpAndSettle();
      files.release.complete(true);
      await tester.pumpAndSettle();
      expect(find.text('独立后来页'), findsOneWidget);
      expect(files.saves, 1);
      expect(host.closed, 0);
    },
  );

  for (final csv in [false, true]) {
    for (final mode in ['cancel', 'double', 'parent leaves']) {
      testWidgets(
        '${csv ? 'CSV' : 'JSON'} consent $mode checks answer and original page live',
        (tester) async {
          final c = await _seed(_Repository());
          final files = _Files();
          files.release.complete(false);
          final host = _Host();
          await host.open(
            tester,
            Scaffold(
              body: DataScreen(
                controller: c,
                onTheme: () {},
                onReview: () {},
                onLegacyRestore: () {},
                files: files,
                statusReader: _Status(),
              ),
            ),
          );
          await _dataAction(tester, csv ? '导出可读 CSV' : '导出可读 JSON');
          final confirm = _filled(tester, csv ? '导出明文 CSV' : '导出明文');
          if (mode == 'cancel') {
            _text(tester, '取消')();
            confirm();
          }
          if (mode == 'double') {
            confirm();
            confirm();
          }
          if (mode == 'parent leaves') {
            confirm();
            host.navigator.currentState!.pop();
          }
          await tester.idle();
          await tester.pumpAndSettle();
          expect(files.saves, mode == 'double' ? 1 : 0);
          expect(host.closed, mode == 'parent leaves' ? 1 : 0);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }

  for (final mode in ['cancel', 'double', 'parent leaves']) {
    testWidgets(
      'permanent remote deletion consent $mode cannot use a stale answer',
      (tester) async {
        final host = _Host();
        await _syncPage(tester, host, (c, repository, secrets, http) async {
          final before = await tester.runAsync(repository.load);
          final secretBefore = Map<String, String>.from(secrets.values);
          final action = find.text('删除远端账户');
          await tester.scrollUntilVisible(
            action,
            200,
            scrollable: find
                .descendant(
                  of: find.byType(SyncScreen),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          late Future<void> operation;
          await tester.runAsync(() async {
            HttpOverrides.runZoned(() {
              operation =
                  Function.apply(_text(tester, '删除远端账户'), const [])
                      as Future<void>;
            }, createHttpClient: (_) => http);
          });
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 250));
          final confirm = _filled(tester, '永久删除远端账户');
          if (mode == 'cancel') {
            _text(tester, '取消')();
            confirm();
          }
          if (mode == 'double') {
            confirm();
            confirm();
          }
          if (mode == 'parent leaves') {
            confirm();
            host.navigator.currentState!.pop();
          }
          await tester.idle();
          await tester.runAsync(() => operation);
          await tester.pumpAndSettle();
          expect(http.deletes, mode == 'double' ? 1 : 0);
          expect(host.closed, mode == 'parent leaves' ? 1 : 0);
          final after = await tester.runAsync(repository.load);
          if (mode == 'double' && http.relay.operations.isNotEmpty) {
            final expected = SyncEntities.encode(before!);
            final actual = SyncEntities.encode(after!);
            expect(actual.keys.toSet(), expected.keys.toSet());
            for (final key in expected.keys) {
              expect(
                SyncEntities.sameFacts(key, actual[key], expected[key]),
                isTrue,
              );
            }
          } else {
            expect(after, before);
          }
          final protections = await tester.runAsync(
            () => repository.database
                .customSelect('SELECT count(*) AS n FROM sync_protections')
                .getSingle(),
          );
          expect(protections!.read<int>('n'), 0);
          if (mode != 'double') expect(secrets.values, secretBefore);
        });
      },
    );
  }

  testWidgets('completed merge save cannot pop a later unrelated route', (
    tester,
  ) async {
    final repository = _Repository();
    final c = await _seed(repository);
    await c.setNote(c.habits.single.id, c.today, '本机备注');
    final before = c.exportJson();
    String snapshot(String note) {
      final document = jsonDecode(before) as Map<String, dynamic>;
      document['habits'][0]['notes'] = {'2026-10-03': note};
      return jsonEncode(document);
    }

    final decision = SyncEntities.merge(
      before,
      SyncEntities.encode(snapshot('原备注')),
      SyncEntities.encode(snapshot('远端备注')),
    );
    final gate = Completer<void>();
    var calls = 0;
    final host = _Host();
    await _openDialog(
      tester,
      host,
      (_) => SyncConflictDialog(
        decision: decision,
        onApply: (selections) async {
          calls++;
          await gate.future;
          await c.importJson(
            SyncEntities.assemble(before, decision.select(selections)),
          );
        },
      ),
    );
    await tester.tap(find.byType(DropdownButtonFormField<SyncChoice>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('采用远端此项').last);
    await tester.pumpAndSettle();
    _filled(tester, '保护副本并应用合并')();
    host.overlay();
    await tester.pumpAndSettle();
    gate.complete();
    await tester.pumpAndSettle();
    expect(find.text('独立后来页'), findsOneWidget);
    expect(calls, 1);
    expect(repository.replacements, 1);
    expect(repository.protectedSources, hasLength(1));
    expect(host.closed, 0);
  });

  for (final mode in ['cancel', 'double', 'parent leaves']) {
    testWidgets(
      'initial sync consent $mode checks its route before transmitting',
      (tester) async {
        final host = _Host();
        await _syncPage(tester, host, (c, repository, secrets, http) async {
          final before = await tester.runAsync(repository.load);
          final action = find.text('立即同步');
          await tester.scrollUntilVisible(
            action,
            200,
            scrollable: find
                .descendant(
                  of: find.byType(SyncScreen),
                  matching: find.byType(Scrollable),
                )
                .first,
          );
          late Future<void> operation;
          await tester.runAsync(() async {
            HttpOverrides.runZoned(() {
              operation =
                  Function.apply(_filled(tester, '立即同步'), const [])
                      as Future<void>;
            }, createHttpClient: (_) => http);
          });
          await _waitFor(
            tester,
            () => find.byType(InitialSyncPreviewDialog).evaluate().isNotEmpty,
            reason: () =>
                'HTTP requests: ${http.requests}; UI: ${tester.widgetList<Text>(find.byType(Text)).map((t) => t.data).toList()}',
          );
          final confirm = _filled(tester, '确认并继续同步');
          if (mode == 'cancel') {
            _text(tester, '取消')();
            confirm();
          }
          if (mode == 'double') {
            confirm();
            confirm();
          }
          if (mode == 'parent leaves') {
            confirm();
            host.navigator.currentState!.pop();
          }
          await tester.idle();
          await tester.runAsync(() => operation);
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 100)),
          );
          await tester.pumpAndSettle();
          expect(http.relay.operations.isNotEmpty, mode == 'double');
          expect(host.closed, mode == 'parent leaves' ? 1 : 0);
          final after = await tester.runAsync(repository.load);
          if (mode == 'double' && http.relay.operations.isNotEmpty) {
            final expected = SyncEntities.encode(before!);
            final actual = SyncEntities.encode(after!);
            expect(actual.keys.toSet(), expected.keys.toSet());
            for (final key in expected.keys) {
              expect(
                SyncEntities.sameFacts(key, actual[key], expected[key]),
                isTrue,
              );
            }
          } else {
            expect(after, before);
          }
          final protections = await tester.runAsync(
            () => repository.database
                .customSelect('SELECT count(*) AS n FROM sync_protections')
                .getSingle(),
          );
          expect(protections!.read<int>('n'), mode == 'double' ? 1 : 0);
        });
      },
    );
  }
  testWidgets(
    'idle dismissed data export cannot open a password dialog from its old tile',
    (tester) async {
      final repository = _Repository();
      final c = await _seed(repository);
      final before = repository.value;
      final host = _Host();
      final files = _Files();
      await host.open(
        tester,
        Scaffold(
          body: DataScreen(
            controller: c,
            onTheme: () {},
            onReview: () {},
            onLegacyRestore: () {},
            files: files,
            statusReader: _Status(),
          ),
        ),
      );
      final tile = find.widgetWithText(ListTile, '创建加密备份');
      await tester.ensureVisible(tile);
      await tester.pumpAndSettle();
      final old = tester.widget<ListTile>(tile).onTap!;
      final context = tester.element(find.byType(DataScreen));
      final route = ModalRoute.of(context)!;
      host.navigator.currentState!.pop();
      await tester.idle();
      expect(context.mounted, isTrue);
      expect(route.isCurrent, isFalse);
      final pushes = host.observer.pushes;
      old();
      await tester.idle();
      expect(host.observer.pushes, pushes);
      expect(files.saves, 0);
      expect(repository.value, before);
      expect(repository.protectedSources, isEmpty);
      await tester.pumpAndSettle();
      expect(host.closed, 1);
    },
  );

  testWidgets(
    'idle dismissed sync enrollment cannot start a request from its old button',
    (tester) async {
      final c = await _seed(_Repository());
      final secrets = MemorySecrets();
      final http = _Http();
      final host = _Host();
      await host.open(
        tester,
        Scaffold(
          body: SyncScreen(
            controller: c,
            settingsStore: SyncSettingsStore(secrets),
          ),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('sync-endpoint')),
        'https://sync.example.test',
      );
      final invite = find.byWidgetPredicate(
        (w) => w is TextField && w.decoration?.labelText == '管理员提供的一次性邀请码',
      );
      await tester.enterText(invite, 'synthetic invite');
      final authorize = find.widgetWithText(FilledButton, '授权此设备');
      await tester.ensureVisible(authorize);
      await tester.pumpAndSettle();
      final old = tester.widget<FilledButton>(authorize).onPressed!;
      final context = tester.element(find.byType(SyncScreen));
      final route = ModalRoute.of(context)!;
      host.navigator.currentState!.pop();
      await tester.idle();
      expect(context.mounted, isTrue);
      expect(route.isCurrent, isFalse);
      await tester.runAsync(() async {
        await HttpOverrides.runZoned(() async {
          await (Function.apply(old, const []) as Future<void>);
        }, createHttpClient: (_) => http);
      });
      expect(http.requests, isEmpty);
      expect(secrets.values, isEmpty);
      await tester.pumpAndSettle();
      expect(host.closed, 1);
    },
  );

  testWidgets(
    'idle dismissed sync reauthorization cannot start a request from its old button',
    (tester) async {
      final host = _Host();
      await _syncPage(tester, host, (c, repository, secrets, http) async {
        final before = await tester.runAsync(repository.load);
        final beforeSecrets = Map<String, String>.from(secrets.values);
        await tester.scrollUntilVisible(
          find.text('重新授权与基线恢复'),
          150,
          scrollable: find
              .descendant(
                of: find.byType(SyncScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        await tester.tap(find.text('重新授权与基线恢复'));
        await tester.pumpAndSettle();
        final invite = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '新的邀请码',
        );
        await tester.ensureVisible(invite);
        await tester.enterText(invite, 'synthetic invite');
        await tester.pumpAndSettle();
        final old = _text(tester, '重新授权');
        final context = tester.element(find.byType(SyncScreen));
        final route = ModalRoute.of(context)!;
        host.navigator.currentState!.pop();
        await tester.idle();
        expect(context.mounted, isTrue);
        expect(route.isCurrent, isFalse);
        await tester.runAsync(() async {
          await HttpOverrides.runZoned(() async {
            await (Function.apply(old, const []) as Future<void>);
          }, createHttpClient: (_) => http);
        });
        expect(http.requests, isEmpty);
        expect(secrets.values, beforeSecrets);
        expect(await tester.runAsync(repository.load), before);
        await tester.pumpAndSettle();
        expect(host.closed, 1);
      });
    },
  );

  for (final encrypted in [false, true]) {
    testWidgets(
      'restore file return after leaving cannot open ${encrypted ? 'password' : 'preview'}',
      (tester) async {
        final repository = _Repository();
        final c = await _seed(repository);
        final before = repository.value;
        final files = _OpenedFiles();
        final host = _Host();
        await host.open(
          tester,
          Scaffold(
            body: DataScreen(
              controller: c,
              onTheme: () {},
              onReview: () {},
              onLegacyRestore: () {},
              files: files,
              statusReader: _Status(),
            ),
          ),
        );
        final tile = find.widgetWithText(ListTile, '从文件恢复');
        await tester.ensureVisible(tile);
        await tester.pumpAndSettle();
        tester.widget<ListTile>(tile).onTap!();
        expect(files.opens, 1);
        final context = tester.element(find.byType(DataScreen));
        final route = ModalRoute.of(context)!;
        host.navigator.currentState!.pop();
        await tester.idle();
        expect(context.mounted, isTrue);
        expect(route.isCurrent, isFalse);
        final pushes = host.observer.pushes;
        files.read.complete(
          Uint8List.fromList(
            utf8.encode(
              encrypted
                  ? jsonEncode({
                      'format': 'haoxiguan-backup',
                      'formatVersion': 1,
                      'encrypted': true,
                    })
                  : c.exportJson(),
            ),
          ),
        );
        await tester.idle();
        expect(host.observer.pushes, pushes);
        expect(repository.replacements, 0);
        expect(repository.protectedSources, isEmpty);
        expect(repository.value, before);
        expect(files.saves, 0);
        await tester.pumpAndSettle();
        expect(host.closed, 1);
      },
    );
  }

  testWidgets(
    'closed device picker cannot revive a revoke answer or pop its parent',
    (tester) async {
      final host = _Host();
      await _syncPage(tester, host, (c, repository, secrets, http) async {
        final before = await tester.runAsync(repository.load);
        await tester.scrollUntilVisible(
          find.widgetWithText(TextButton, '已授权设备'),
          150,
          scrollable: find
              .descendant(
                of: find.byType(SyncScreen),
                matching: find.byType(Scrollable),
              )
              .first,
        );
        await tester.pumpAndSettle();
        late Future<void> operation;
        await tester.runAsync(() async {
          HttpOverrides.runZoned(() {
            operation =
                Function.apply(_text(tester, '已授权设备'), const [])
                    as Future<void>;
          }, createHttpClient: (_) => http);
        });
        await _waitFor(
          tester,
          () => find.widgetWithText(AlertDialog, '已授权设备').evaluate().isNotEmpty,
        );
        final revoke = _text(tester, '撤销');
        final pushes = host.observer.pushes;
        _text(tester, '关闭')();
        revoke();
        await tester.idle();
        await tester.runAsync(() => operation);
        expect(host.observer.pushes, pushes);
        expect(http.requests, ['GET /v1/devices']);
        expect(await tester.runAsync(repository.load), before);
        await tester.pumpAndSettle();
        expect(host.closed, 0);
      });
    },
  );
}
