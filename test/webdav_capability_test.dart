import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_settings.dart';
import 'package:haoxiguan/services/webdav_client.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/webdav_screen.dart';

import 'support/sync_relay.dart' show MemorySecrets;

const _vault = '11111111-1111-4111-8111-111111111111';
const _device = '22222222-2222-4222-8222-222222222222';
const _oldId = '33333333-3333-4333-8333-333333333333';
const _endpoint = 'https://server.test/dav/';
const _backupPassword = 'public synthetic capability recovery phrase';
const _oldFile = '/dav/haoxiguan/$_vault/$_device/old-backup.hgb';
const _userFile = '/dav/user-document.txt';

class _Dav {
  final files = <String, List<int>>{
    _oldFile: utf8.encode('existing untouched backup'),
    _userFile: utf8.encode('existing untouched user document'),
  };
  final events = <String>[];
  final probeBodies = <List<int>>[];
  final requests = <http.Request>[];
  String failure = 'none';
  int closed = 0;
  Completer<void>? deleteGate;
  final enteredDelete = Completer<void>();

  WebDavClient client([BackupSettings? settings]) => WebDavClient(
    settings?.endpoint ?? _endpoint,
    settings?.username ?? 'synthetic-user',
    settings?.appPassword ?? 'public synthetic application password',
    client: _ClosingClient(handle, () => closed++),
  );

  Future<http.Response> handle(http.Request request) async {
    requests.add(request);
    final path = request.url.path;
    final probe = path.endsWith('.probe');
    events.add('${request.method}:$path');
    if (request.method == 'MKCOL') return http.Response('', 201);
    if (request.method == 'PUT') {
      expect(request.headers['if-none-match'], '*');
      if (probe) {
        probeBodies.add(List<int>.from(request.bodyBytes));
        if (failure == 'put-412') {
          files[path] = utf8.encode('unrelated collision contents');
          return http.Response('', 412);
        }
        if (failure == 'put-403') return http.Response('', 403);
      }
      if (files.containsKey(path)) return http.Response('', 412);
      files[path] = List<int>.from(request.bodyBytes);
      if (probe && failure == 'lost-put-response') {
        throw http.ClientException(
          'synthetic private URL/token must be redacted',
          request.url,
        );
      }
      return http.Response('', 201);
    }
    if (request.method == 'GET') {
      final bytes = files[path];
      if (bytes == null) return http.Response('', 404);
      if (probe && failure == 'read-404') return http.Response('', 404);
      if (probe && failure == 'read-timeout') {
        throw TimeoutException('synthetic private URL/token must be redacted');
      }
      final tag = '"${sha256.convert(bytes)}"';
      final headers = <String, String>{'etag': tag};
      if (probe && failure == 'missing-etag') headers.clear();
      if (probe && failure == 'weak-etag') headers['etag'] = 'W/$tag';
      if (probe && failure == 'malformed-etag') {
        headers['etag'] = 'unquoted-tag';
      }
      return http.Response.bytes(
        probe && failure == 'corrupt-read'
            ? List<int>.filled(bytes.length, 0)
            : bytes,
        200,
        headers: headers,
      );
    }
    if (request.method == 'DELETE') {
      expect(
        probe,
        isTrue,
        reason: 'Capability check must never delete a backup or user file.',
      );
      final bytes = files[path]!;
      expect(request.headers['if-match'], '"${sha256.convert(bytes)}"');
      if (!enteredDelete.isCompleted) enteredDelete.complete();
      if (deleteGate != null) await deleteGate!.future;
      if (failure == 'delete-403') return http.Response('', 403);
      if (failure == 'delete-412') {
        files[path] = utf8.encode('another writer replaced the probe');
        return http.Response('', 412);
      }
      if (failure == 'delete-remains') return http.Response('', 200);
      files.remove(path);
      return http.Response('', failure == 'delete-200' ? 200 : 204);
    }
    throw StateError(request.method);
  }
}

class _ClosingClient extends MockClient {
  _ClosingClient(super.handler, this.onClose);
  final VoidCallback onClose;
  @override
  void close() {
    onClose();
    super.close();
  }
}

class _Secrets extends MemorySecrets {
  _Secrets(this.events);
  final List<String> events;
  @override
  Future<void> write(String key, String value) async {
    events.add('STORE:$key');
    await super.write(key, value);
  }
}

Finder _input(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var i = 0; !ready() && i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 50)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

void main() {
  for (final success in ['none', 'delete-200']) {
    test(
      'access probe verifies and conditionally deletes without touching existing files: $success',
      () async {
        final server = _Dav()..failure = success;
        final before = jsonEncode(server.files);
        final client = server.client();
        addTearDown(client.close);
        await client.verifyAccess(_vault, _device);
        expect(jsonEncode(server.files), before);
        final probe = server.requests.firstWhere((r) => r.method == 'PUT');
        expect(
          probe.url.path,
          matches(
            RegExp(
              '/haoxiguan/$_vault/$_device/access-[0-9a-f-]{36}\\.probe\$',
            ),
          ),
        );
        expect(probe.bodyBytes, hasLength(32));
        final operations = server.requests
            .where((r) => r.url == probe.url)
            .map((r) => r.method)
            .toList();
        expect(operations, ['PUT', 'GET', 'DELETE', 'GET']);
        expect(
          server.files.keys.where((path) => path.endsWith('.probe')),
          isEmpty,
        );
      },
    );
  }

  test(
    'each verification uses a fresh random filename and non-business byte payload',
    () async {
      final server = _Dav();
      final client = server.client();
      addTearDown(client.close);
      await client.verifyAccess(_vault, _device);
      await client.verifyAccess(_vault, _device);
      final probes = server.requests.where((r) => r.method == 'PUT').toList();
      expect(probes[0].url, isNot(probes[1].url));
      expect(server.probeBodies[0], isNot(equals(server.probeBodies[1])));
      expect(server.probeBodies.every((bytes) => bytes.length == 32), isTrue);
      expect(
        server.files.keys.where((path) => path.endsWith('.probe')),
        isEmpty,
      );
    },
  );

  for (final failure in [
    'put-412',
    'put-403',
    'read-404',
    'corrupt-read',
    'missing-etag',
    'weak-etag',
    'malformed-etag',
    'delete-403',
    'delete-412',
    'delete-remains',
    'read-timeout',
    'lost-put-response',
  ]) {
    test(
      'access probe fails closed and leaves existing files untouched: $failure',
      () async {
        final server = _Dav()..failure = failure;
        final originalBackup = List<int>.from(server.files[_oldFile]!);
        final originalUser = List<int>.from(server.files[_userFile]!);
        final client = server.client();
        addTearDown(client.close);
        await expectLater(
          client.verifyAccess(_vault, _device),
          throwsA(
            isA<DavFailure>().having(
              (e) => e.message,
              'redaction',
              isNot(contains('synthetic private URL/token')),
            ),
          ),
        );
        expect(server.files[_oldFile], originalBackup);
        expect(server.files[_userFile], originalUser);
        expect(
          server.requests.where(
            (r) => r.method == 'PUT' && r.url.path.endsWith('.hgb'),
          ),
          isEmpty,
        );
        if ([
          'put-412',
          'put-403',
          'read-404',
          'corrupt-read',
          'missing-etag',
          'weak-etag',
          'malformed-etag',
          'read-timeout',
          'lost-put-response',
        ].contains(failure)) {
          expect(server.requests.where((r) => r.method == 'DELETE'), isEmpty);
        }
        if (failure == 'delete-412') {
          expect(
            server.files.entries
                .singleWhere((entry) => entry.key.endsWith('.probe'))
                .value,
            utf8.encode('another writer replaced the probe'),
          );
        }
      },
    );
  }

  test('invalid namespace is rejected before any request', () async {
    final server = _Dav();
    final client = server.client();
    addTearDown(client.close);
    await expectLater(
      client.verifyAccess('../old-user-file', _device),
      throwsFormatException,
    );
    expect(server.requests, isEmpty);
  });

  for (final streamed in [false, true]) {
    test(
      'typed TLS failure is classified and redacted from ${streamed ? 'response stream' : 'client send'}',
      () async {
        final error = HandshakeException(
          'secret credential and https://private-server/token',
        );
        final httpClient = streamed
            ? MockClient.streaming(
                (_, _) async =>
                    http.StreamedResponse(Stream<List<int>>.error(error), 200),
              )
            : MockClient((_) async => throw error);
        final client = WebDavClient(
          _endpoint,
          'synthetic-user',
          'synthetic secret',
          client: httpClient,
        );
        addTearDown(client.close);
        await expectLater(
          client.request('GET', 'haoxiguan/'),
          throwsA(
            isA<DavFailure>()
                .having(
                  (e) => e.message,
                  'certificate classification',
                  contains('HTTPS 证书'),
                )
                .having(
                  (e) => e.message,
                  'private details',
                  isNot(contains('private-server')),
                )
                .having(
                  (e) => e.message,
                  'secret details',
                  isNot(contains('secret credential')),
                ),
          ),
        );
      },
    );
  }

  test(
    'a generic ClientException that mentions certificates is not guessed to be a TLS failure',
    () async {
      final client = WebDavClient(
        _endpoint,
        'synthetic-user',
        'synthetic secret',
        client: MockClient((_) async {
          throw http.ClientException(
            'CERTIFICATE_VERIFY_FAILED secret raw message',
            Uri.parse('https://private-server/token'),
          );
        }),
      );
      addTearDown(client.close);
      await expectLater(
        client.request('GET', 'haoxiguan/'),
        throwsA(
          isA<DavFailure>()
              .having(
                (e) => e.message,
                'no string classification',
                isNot(contains('HTTPS 证书')),
              )
              .having(
                (e) => e.message,
                'redaction',
                isNot(contains('CERTIFICATE_VERIFY_FAILED')),
              ),
        ),
      );
    },
  );

  for (final existing in [false, true]) {
    testWidgets(
      'WebDAV delete-permission failure keeps ${existing ? 'old configuration' : 'new configuration disabled'} and input; retry verifies before first backup',
      (tester) async {
        final server = _Dav()
          ..failure = 'delete-403'
          ..deleteGate = Completer<void>();
        final secrets = _Secrets(server.events);
        secrets.values['device.id.v1'] = _device;
        final store = BackupSettingsStore(secrets);
        final repository = MemoryHabitRepository();
        final controller = HabitController(
          repository,
          clock: () => DateTime(2026, 10, 3),
        );
        addTearDown(controller.dispose);
        await controller.load();
        expect(
          await controller.addHabit(
            title: '探针不包含的本机习惯',
            emoji: '🌱',
            colorValue: 0xff5f8068,
            weekdays: {1, 2, 3, 4, 5, 6, 7},
          ),
          isTrue,
        );
        final before = controller.exportJson();
        final beforeRepository = repository.value;
        final vault = jsonDecode(before)['vaultId'] as String;
        if (existing) {
          await store.save(
            BackupSettings(
              id: _oldId,
              endpoint: _endpoint,
              username: 'old-user',
              appPassword: 'old synthetic application password',
              backupPassword: _backupPassword,
              vault: vault,
              device: _device,
            ),
          );
        }
        final beforeSecrets = Map<String, String>.from(secrets.values);
        var factories = 0;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => WebDavScreen(
                        controller: controller,
                        settingsStore: store,
                        clientFactory: (settings) {
                          factories++;
                          return server.client(settings);
                        },
                      ),
                    ),
                  ),
                  child: const Text('settings'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('settings'));
        await tester.pumpAndSettle();
        final scrollable = find
            .descendant(
              of: find.byType(WebDavScreen),
              matching: find.byType(Scrollable),
            )
            .first;
        final draft = {
          'HTTPS WebDAV 目录': _endpoint,
          '用户名': 'new-user',
          'WebDAV 应用密码': 'new public synthetic application password',
          '独立备份密码': _backupPassword,
          '再次输入备份密码（保存配置时）': _backupPassword,
        };
        for (final field in draft.entries) {
          await tester.scrollUntilVisible(
            _input(field.key),
            180,
            scrollable: scrollable,
          );
          await tester.enterText(_input(field.key), field.value);
          await tester.pumpAndSettle();
        }
        final save = find.widgetWithText(FilledButton, '验证并保存配置');
        await tester.scrollUntilVisible(save, 180, scrollable: scrollable);
        final oldSave = tester.widget<FilledButton>(save).onPressed!;
        await tester.tap(save);
        await tester.binding.handlePopRoute();
        oldSave();
        expect(factories, 1);
        await _waitFor(
          tester,
          () => server.enteredDelete.isCompleted || server.closed > 0,
        );
        expect((await store.load())?.id, existing ? _oldId : null);
        expect(server.enteredDelete.isCompleted, isTrue);
        expect(store.secrets, same(secrets));
        expect(secrets.values, beforeSecrets);
        server.deleteGate!.complete();
        await _waitFor(tester, () => server.closed == 1);
        expect((await store.load())?.id, existing ? _oldId : null);
        expect(secrets.values, beforeSecrets);
        await tester.scrollUntilVisible(
          find.textContaining('可能残留'),
          -200,
          scrollable: scrollable,
        );
        expect(find.textContaining('可能残留'), findsOneWidget);
        expect(
          server.requests.where(
            (r) => r.method == 'PUT' && r.url.path.endsWith('.hgb'),
          ),
          isEmpty,
        );
        expect(repository.value, beforeRepository);
        expect(repository.protectedSources, isEmpty);
        expect(controller.exportJson(), before);
        for (final field in draft.entries.toList().reversed) {
          await tester.scrollUntilVisible(
            _input(field.key),
            -180,
            scrollable: scrollable,
          );
          expect(
            tester.widget<TextField>(_input(field.key)).controller!.text,
            field.value,
          );
        }
        // Repair only the server permission. The retained input supports retry;
        // this new probe cannot delete the first inert failed probe or old files.
        final inertProbes = server.files.keys
            .where((path) => path.endsWith('.probe'))
            .toSet();
        expect(inertProbes, hasLength(1));
        server.failure = 'none';
        server.deleteGate = null;
        await tester.scrollUntilVisible(save, 180, scrollable: scrollable);
        await tester.tap(save);
        await _waitFor(tester, () => server.closed == 2);
        final current = (await store.load())!;
        expect(current.id, isNot(_oldId));
        expect(current.username, draft['用户名']);
        expect(current.appPassword, draft['WebDAV 应用密码']);
        expect(
          server.files.keys.where((path) => path.endsWith('.probe')).toSet(),
          inertProbes,
        );
        final marker = server.files.entries.singleWhere(
          (entry) => entry.key.endsWith('.complete.json'),
        );
        final item = RemoteBackup.fromJson(
          jsonDecode(utf8.decode(marker.value)) as Map<String, dynamic>,
        );
        final verification = server.client(current);
        final restored = await tester.runAsync(
          () => verification.restore(item, _backupPassword),
        );
        verification.close();
        expect(restored, before);
        final probeGets = server.events
            .where(
              (event) => event.startsWith('GET:') && event.endsWith('.probe'),
            )
            .toList();
        final confirmedDeleteRead = server.events.indexOf(probeGets.last);
        final firstBackupPut = server.events.indexWhere(
          (event) => event.startsWith('PUT:') && event.endsWith('.hgb'),
        );
        expect(confirmedDeleteRead, lessThan(firstBackupPut));
        final finalPointerWrite = server.events.lastIndexOf(
          'STORE:webdav.active.v1',
        );
        expect(firstBackupPut, lessThan(finalPointerWrite));
        expect(
          server.files[_oldFile],
          utf8.encode('existing untouched backup'),
        );
        expect(
          server.files[_userFile],
          utf8.encode('existing untouched user document'),
        );
        expect(repository.value, beforeRepository);
        expect(repository.protectedSources, isEmpty);
        expect(controller.exportJson(), before);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }
}
