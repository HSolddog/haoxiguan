import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/services/backup_settings.dart';
import 'package:haoxiguan/services/data_status.dart';
import 'package:haoxiguan/services/sync_client.dart';
import 'package:haoxiguan/services/sync_crypto.dart';
import 'package:haoxiguan/services/sync_entities.dart';
import 'package:haoxiguan/services/sync_recovery.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/backup_restore_dialog.dart';
import 'package:haoxiguan/ui/data_screen.dart';
import 'package:haoxiguan/ui/sync_screen.dart';
import 'package:haoxiguan/ui/webdav_screen.dart';

import 'support/sync_relay.dart' show MemorySecrets;

final _today = DateTime(2026, 10, 3);
const _password = 'public synthetic first frame backup phrase';

class _RestoreRepository extends MemoryHabitRepository {
  final entered = Completer<void>();
  final release = Completer<void>();
  int replacements = 0;
  @override
  Future<void> replace(String value) async {
    replacements++;
    if (!entered.isCompleted) entered.complete();
    await release.future;
    await super.replace(value);
  }
}

class _Files implements BackupFiles {
  final release = Completer<bool>();
  int saves = 0;
  @override
  Future<bool> save(Uint8List bytes, String name) async {
    saves++;
    return release.future;
  }

  @override
  Future<Uint8List?> open() async => null;
}

class _Status extends DataStatusReader {
  @override
  Future<DataServiceStatus> read(String snapshot) async =>
      const DataServiceStatus(backup: '未配置', sync: '未连接');
  @override
  Future<void> recordFileBackup(String snapshot, String name) async {}
}

class _Settings extends BackupSettingsStore {
  _Settings() : super(MemorySecrets());
  final release = Completer<String>();
  int deviceRequests = 0;
  @override
  Future<String> deviceId() {
    deviceRequests++;
    return release.future;
  }
}

class _EnrollmentClient implements HttpClient {
  final release = Completer<HttpClientRequest>();
  int requests = 0;
  @override
  Future<HttpClientRequest> openUrl(String method, Uri url) {
    expect(method, 'POST');
    expect(url.path, '/v1/auth/enroll');
    requests++;
    return release.future;
  }

  @override
  void close({bool force = false}) {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; !ready() && attempt < 50; attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 100)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

Widget _dialogApp(WidgetBuilder builder, List<bool?> results) => MaterialApp(
  home: Scaffold(
    body: Builder(
      builder: (context) => TextButton(
        onPressed: () async => results.add(
          await showDialog<bool>(context: context, builder: builder),
        ),
        child: const Text('dialog'),
      ),
    ),
  ),
);

Future<HabitController> _controller(
  HabitRepository repository,
  String title,
) async {
  final controller = HabitController(repository, clock: () => _today);
  await controller.load();
  expect(
    await controller.addHabit(
      title: title,
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    ),
    isTrue,
  );
  return controller;
}

void main() {
  for (final compatible in [false, true]) {
    testWidgets(
      '${compatible ? 'compatible' : 'ordinary'} restore blocks back, barrier, cancel and repeated confirm before rebuilding',
      (tester) async {
        final repository = _RestoreRepository();
        final target = await _controller(repository, '原本机事实');
        final source = await _controller(MemoryHabitRepository(), '恢复内容');
        addTearDown(target.dispose);
        addTearDown(source.dispose);
        final document =
            jsonDecode(source.exportJson()) as Map<String, dynamic>;
        if (compatible) {
          document['habits'][0]['title'] = '名' * 1000;
          document['habits'][0]['notes'] = {'2026-10-03': '注' * 2001};
        }
        final raw = jsonEncode(document);
        final before = repository.value;
        final results = <bool?>[];
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () async {
                    results.add(
                      await showDialog<bool>(
                        context: context,
                        // Deliberately exercise barrier dismissal even though production
                        // restore entry points also make their barrier nondismissible.
                        builder: (_) => BackupRestoreDialog(
                          controller: target,
                          raw: raw,
                          preview: BackupPreview.forRestore(raw),
                        ),
                      ),
                    );
                  },
                  child: const Text('restore'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('restore'));
        await tester.pumpAndSettle();
        final checkbox = find.byKey(const Key('restore-preserve-legacy-text'));
        if (compatible) {
          await tester.ensureVisible(checkbox);
          await tester.tap(checkbox);
          await tester.pumpAndSettle();
        }
        final confirm = find.byKey(const Key('confirm-restore-button'));
        final oldConfirm = tester.widget<FilledButton>(confirm).onPressed!;
        final oldCancel = tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
            .onPressed!;
        final oldCheckbox = compatible
            ? tester.widget<CheckboxListTile>(checkbox).onChanged
            : null;
        await tester.ensureVisible(confirm);
        await tester.tap(confirm);
        await repository.entered.future;
        // No pump between the first tap and any of these previously enabled
        // callbacks or route events: the saving flag must be read live.
        await tester.binding.handlePopRoute();
        await tester.tapAt(const Offset(5, 5));
        oldCancel();
        await tester.tap(confirm);
        oldConfirm();
        oldCheckbox?.call(false);
        expect(results, isEmpty);
        expect(repository.replacements, 1);
        expect(repository.value, before);
        expect(repository.protectedSources, isEmpty);
        await tester.pump();
        expect(find.byType(BackupRestoreDialog), findsOneWidget);
        expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
        if (compatible) {
          expect(tester.widget<CheckboxListTile>(checkbox).value, isTrue);
        }
        repository.release.complete();
        await tester.pumpAndSettle();
        expect(results, [true]);
        expect(repository.replacements, 1);
        expect(repository.protectedSources, [before]);
        expect(find.byType(BackupRestoreDialog), findsNothing);
        expect(target.habits.single.title, compatible ? '名' * 1000 : '恢复内容');
        if (compatible) {
          expect(target.habits.single.notes['2026-10-03'], '注' * 2001);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'withdrawing compatible restore consent blocks a stale confirm before rebuilding, then renewed consent restores intact',
    (tester) async {
      final repository = _RestoreRepository();
      final target = await _controller(repository, '撤回同意前的本机事实');
      final source = await _controller(MemoryHabitRepository(), '历史恢复内容');
      addTearDown(target.dispose);
      addTearDown(source.dispose);
      final document = jsonDecode(source.exportJson()) as Map<String, dynamic>;
      document['habits'][0]['title'] = '名' * 1000;
      document['habits'][0]['notes'] = {'2026-10-03': '注' * 2001};
      final raw = jsonEncode(document);
      final beforeValue = repository.value;
      final beforeBackup = repository.backupValue;
      final beforeFacts = target.exportJson();
      final results = <bool?>[];
      await tester.pumpWidget(
        _dialogApp(
          (_) => BackupRestoreDialog(
            controller: target,
            raw: raw,
            preview: BackupPreview.forRestore(raw),
          ),
          results,
        ),
      );
      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      final checkbox = find.byKey(const Key('restore-preserve-legacy-text'));
      final confirm = find.byKey(const Key('confirm-restore-button'));
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      final oldConfirm = tester.widget<FilledButton>(confirm).onPressed!;
      final withdraw = tester.widget<CheckboxListTile>(checkbox).onChanged!;
      withdraw(false);
      // No frame updates the enabled button between consent withdrawal and
      // this real previously enabled callback. Flush queued work without
      // rebuilding so an incorrectly queued repository replacement is seen.
      oldConfirm();
      await tester.idle();
      expect(repository.replacements, 0);
      expect(repository.entered.isCompleted, isFalse);
      expect(repository.protectedSources, isEmpty);
      expect(repository.value, beforeValue);
      expect(repository.backupValue, beforeBackup);
      expect(target.exportJson(), beforeFacts);
      expect(results, isEmpty);
      await tester.pump();
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      expect(tester.widget<FilledButton>(confirm).onPressed, isNull);
      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pumpAndSettle();
      await tester.ensureVisible(confirm);
      await tester.tap(confirm);
      await repository.entered.future;
      expect(repository.replacements, 1);
      repository.release.complete();
      await tester.pumpAndSettle();
      expect(results, [true]);
      expect(repository.replacements, 1);
      expect(repository.protectedSources, [beforeValue]);
      expect(target.habits.single.title, '名' * 1000);
      expect(target.habits.single.notes['2026-10-03'], '注' * 2001);
      expect(find.byType(BackupRestoreDialog), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'password save blocks stale menu/continue/cancel and system back before the first frame',
    (tester) async {
      final controller = await _controller(MemoryHabitRepository(), '加密备份事实');
      addTearDown(controller.dispose);
      final files = _Files();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: DataScreen(
              controller: controller,
              files: files,
              statusReader: _Status(),
              onTheme: () {},
              onReview: () {},
              onLegacyRestore: () {},
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final create = find.text('创建加密备份');
      await tester.scrollUntilVisible(
        create,
        300,
        scrollable: find.descendant(
          of: find.byKey(const PageStorageKey<String>('data-scroll')),
          matching: find.byType(Scrollable),
        ),
      );
      final oldCreate = tester
          .widget<ListTile>(
            find.ancestor(of: create, matching: find.byType(ListTile)),
          )
          .onTap!;
      await tester.tap(create);
      oldCreate();
      await tester.pumpAndSettle();
      expect(find.text('设置备份密码'), findsOneWidget);
      await tester.enterText(find.byType(TextField).first, _password);
      await tester.enterText(find.byType(TextField).last, _password);
      await tester.pumpAndSettle();
      final proceed = find.widgetWithText(FilledButton, '继续');
      final oldContinue = tester.widget<FilledButton>(proceed).onPressed!;
      final oldCancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed!;
      await tester.tap(proceed);
      // Native KDF has been started, but no frame has rebuilt guard.saving yet.
      await tester.binding.handlePopRoute();
      oldCancel();
      await tester.tap(proceed);
      oldContinue();
      await tester.pump();
      expect(find.text('设置备份密码'), findsOneWidget);
      expect(find.byKey(const Key('discard-changes-button')), findsNothing);
      expect(
        tester.widget<TextField>(find.byType(TextField).first).controller!.text,
        _password,
      );
      for (var attempt = 0; files.saves == 0 && attempt < 50; attempt++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 100)),
        );
        await tester.pump();
      }
      expect(files.saves, 1);
      expect(find.text('设置备份密码'), findsOneWidget);
      files.release.complete(true);
      await tester.pumpAndSettle();
      expect(files.saves, 1);
      expect(find.text('设置备份密码'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'WebDAV settings first await blocks live back and repeated save, failure retains the draft',
    (tester) async {
      final controller = await _controller(MemoryHabitRepository(), '配置前事实');
      addTearDown(controller.dispose);
      final store = _Settings();
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => WebDavScreen(
                      controller: controller,
                      settingsStore: store,
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
      final draft = {
        'HTTPS WebDAV 目录': 'https://example.test/backups/',
        '用户名': 'synthetic-user',
        'WebDAV 应用密码': 'public synthetic credential',
        '独立备份密码': _password,
        '再次输入备份密码（保存配置时）': _password,
      };
      final scrollable = find
          .descendant(
            of: find.byType(WebDavScreen),
            matching: find.byType(Scrollable),
          )
          .first;
      for (final field in draft.entries) {
        final input = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == field.key,
        );
        await tester.scrollUntilVisible(input, 150, scrollable: scrollable);
        await tester.enterText(input, field.value);
        await tester.pumpAndSettle();
      }
      final save = find.widgetWithText(FilledButton, '验证并保存配置');
      await tester.scrollUntilVisible(save, 200, scrollable: scrollable);
      final oldSave = tester.widget<FilledButton>(save).onPressed!;
      await tester.tap(save);
      expect(store.deviceRequests, 1);
      // No pump: the guard still holds the previous frame's saving=false.
      await tester.binding.handlePopRoute();
      await tester.tap(save);
      oldSave();
      expect(store.deviceRequests, 1);
      await tester.pump();
      expect(find.byType(WebDavScreen), findsOneWidget);
      expect(find.byKey(const Key('discard-changes-button')), findsNothing);
      store.release.completeError(
        const FormatException('synthetic device store failure'),
      );
      await tester.pumpAndSettle();
      expect(find.byType(WebDavScreen), findsOneWidget);
      expect(store.deviceRequests, 1);
      expect((store.secrets as MemorySecrets).values, isEmpty);
      for (final field in draft.entries.toList().reversed) {
        final input = find.byWidgetPredicate(
          (widget) =>
              widget is TextField && widget.decoration?.labelText == field.key,
        );
        await tester.scrollUntilVisible(input, -150, scrollable: scrollable);
        expect(tester.widget<TextField>(input).controller!.text, field.value);
      }
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'sync enrollment blocks stale confirmation before rebuilding and retains failed connection input',
    (tester) async {
      final controller = await _controller(MemoryHabitRepository(), '同步前事实');
      addTearDown(controller.dispose);
      final client = _EnrollmentClient();
      final secrets = MemorySecrets();
      await HttpOverrides.runZoned(() async {
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.push<void>(
                    context,
                    MaterialPageRoute<void>(
                      builder: (_) => SyncScreen(
                        controller: controller,
                        settingsStore: SyncSettingsStore(secrets),
                      ),
                    ),
                  ),
                  child: const Text('sync'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('sync'));
        await tester.pumpAndSettle();
        final endpoint = find.byKey(const Key('sync-endpoint'));
        final invite = find.byWidgetPredicate(
          (w) => w is TextField && w.decoration?.labelText == '管理员提供的一次性邀请码',
        );
        await tester.enterText(endpoint, 'https://example.test');
        await tester.enterText(invite, 'public synthetic invite');
        final scrollable = find
            .descendant(
              of: find.byType(SyncScreen),
              matching: find.byType(Scrollable),
            )
            .first;
        final authorize = find.widgetWithText(FilledButton, '授权此设备');
        await tester.scrollUntilVisible(authorize, 180, scrollable: scrollable);
        final oldAuthorize = tester.widget<FilledButton>(authorize).onPressed!;
        await tester.tap(authorize);
        expect(client.requests, 1);
        await tester.binding.handlePopRoute();
        await tester.tap(authorize);
        oldAuthorize();
        expect(client.requests, 1);
        await tester.pump();
        expect(find.byType(SyncScreen), findsOneWidget);
        expect(find.byKey(const Key('discard-changes-button')), findsNothing);
        client.release.completeError(
          const FormatException('synthetic enrollment failure'),
        );
        await tester.pumpAndSettle();
        expect(client.requests, 1);
        expect(secrets.values, isEmpty);
        await tester.scrollUntilVisible(invite, -150, scrollable: scrollable);
        expect(
          tester.widget<TextField>(invite).controller!.text,
          'public synthetic invite',
        );
        await tester.scrollUntilVisible(endpoint, -150, scrollable: scrollable);
        expect(
          tester.widget<TextField>(endpoint).controller!.text,
          'https://example.test',
        );
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      }, createHttpClient: (_) => client);
    },
  );

  testWidgets(
    'sync merge first await blocks back and stale apply; failure preserves selection and retry protects once',
    (tester) async {
      final repository = MemoryHabitRepository();
      final controller = await _controller(repository, '合并事实');
      addTearDown(controller.dispose);
      final habitId = controller.habits.single.id;
      expect(await controller.setNote(habitId, _today, '本机备注'), isTrue);
      final before = controller.exportJson();
      String snapshot(String note) {
        final raw = jsonDecode(before) as Map<String, dynamic>;
        raw['habits'][0]['notes'] = {'2026-10-03': note};
        return jsonEncode(raw);
      }

      final decision = SyncEntities.merge(
        before,
        SyncEntities.encode(snapshot('原备注')),
        SyncEntities.encode(snapshot('远端备注')),
      );
      final releases = [Completer<void>(), Completer<void>()];
      var attempts = 0;
      final results = <bool?>[];
      await tester.pumpWidget(
        _dialogApp(
          (_) => SyncConflictDialog(
            decision: decision,
            onApply: (selections) async {
              final attempt = attempts++;
              expect(selections.values.single.choice, SyncChoice.manual);
              expect(selections.values.single.text, '保留的手工合并稿');
              await releases[attempt].future;
              expect(
                await controller.importJson(
                  SyncEntities.assemble(before, decision.select(selections)),
                ),
                isTrue,
              );
            },
          ),
          results,
        ),
      );
      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      final dropdown = find.byType(DropdownButtonFormField<SyncChoice>);
      await tester.ensureVisible(dropdown);
      await tester.tap(dropdown);
      await tester.pumpAndSettle();
      await tester.tap(find.text('手工合并备注').last);
      await tester.pumpAndSettle();
      final input = find.byType(TextFormField);
      await tester.ensureVisible(input);
      await tester.enterText(input, '保留的手工合并稿');
      await tester.pumpAndSettle();
      final apply = find.widgetWithText(FilledButton, '保护副本并应用合并');
      final oldApply = tester.widget<FilledButton>(apply).onPressed!;
      final oldCancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '稍后处理'))
          .onPressed!;
      await tester.tap(apply);
      expect(attempts, 1);
      await tester.binding.handlePopRoute();
      oldCancel();
      await tester.tap(apply);
      oldApply();
      expect(attempts, 1);
      expect(results, isEmpty);
      expect(repository.protectedSources, isEmpty);
      await tester.pump();
      expect(find.byType(SyncConflictDialog), findsOneWidget);
      expect(find.byKey(const Key('discard-changes-button')), findsNothing);
      releases[0].completeError(
        const FormatException('synthetic merge failure'),
      );
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(find.text('保留的手工合并稿'), findsOneWidget);
      expect(
        tester
            .widget<DropdownButtonFormField<SyncChoice>>(dropdown)
            .initialValue,
        SyncChoice.manual,
      );
      expect(repository.protectedSources, isEmpty);
      await tester.tap(apply);
      expect(attempts, 2);
      releases[1].complete();
      await tester.pumpAndSettle();
      expect(results, [true]);
      expect(repository.protectedSources, [before]);
      expect(controller.habits.single.notes['2026-10-03'], '保留的手工合并稿');
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'sync recovery first frame starts one KDF and file save; cancellation keeps password for retry',
    (tester) async {
      final keys = await tester.runAsync(() => SyncKeyring.create('v' * 32));
      addTearDown(keys!.dispose);
      final results = <bool?>[];
      final files = [_Files(), _Files()];
      var attempts = 0;
      await tester.pumpWidget(
        _dialogApp(
          (_) => SyncRecoveryPasswordDialog(
            onContinue: (password) async {
              final attempt = attempts++;
              expect(password, _password);
              final bytes = await SyncRecoveryCodec.encrypt(keys, password);
              final verified = await SyncRecoveryCodec.decrypt(bytes, password);
              verified.dispose();
              return files[attempt].save(bytes, 'synthetic-recovery.hgr');
            },
          ),
          results,
        ),
      );
      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      final first = find.byKey(const Key('sync-recovery-password'));
      final second = find.byKey(const Key('sync-recovery-confirm'));
      await tester.enterText(first, _password);
      await tester.enterText(second, _password);
      await tester.pumpAndSettle();
      final save = find.widgetWithText(FilledButton, '加密并保存');
      final oldSave = tester.widget<FilledButton>(save).onPressed!;
      final oldCancel = tester
          .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
          .onPressed!;
      await tester.tap(save);
      expect(attempts, 1);
      await tester.binding.handlePopRoute();
      oldCancel();
      await tester.tap(save);
      oldSave();
      expect(attempts, 1);
      await tester.pump();
      expect(find.byType(SyncRecoveryPasswordDialog), findsOneWidget);
      expect(find.byKey(const Key('discard-changes-button')), findsNothing);
      await _waitFor(tester, () => files[0].saves == 1);
      files[0].release.complete(false);
      await tester.pumpAndSettle();
      expect(results, isEmpty);
      expect(tester.widget<TextField>(first).controller!.text, _password);
      expect(tester.widget<TextField>(second).controller!.text, _password);
      await tester.tap(save);
      expect(attempts, 2);
      await _waitFor(tester, () => files[1].saves == 1);
      files[1].release.complete(true);
      await tester.pumpAndSettle();
      expect(results, [true]);
      expect(files.map((file) => file.saves).toList(), [1, 1]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
