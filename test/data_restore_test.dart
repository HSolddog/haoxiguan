import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/services/data_status.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/data_screen.dart';

class _Files implements BackupFiles {
  _Files(this.bytes);
  final Uint8List bytes;
  int opens = 0;
  @override
  Future<Uint8List?> open() async {
    opens++;
    return bytes;
  }

  @override
  Future<bool> save(Uint8List bytes, String name) async => true;
}

class _Status extends DataStatusReader {
  @override
  Future<DataServiceStatus> read(String snapshot) async =>
      const DataServiceStatus(backup: '尚无本机校验成功记录；WebDAV 未配置', sync: '未连接');
}

class _Repository extends MemoryHabitRepository {
  bool failNext = false;
  @override
  Future<void> replace(String value) async {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    await super.replace(value);
  }
}

Future<HabitController> _controller(
  String title, [
  HabitRepository? repo,
]) async {
  final c = HabitController(
    repo ?? MemoryHabitRepository(),
    clock: () => DateTime(2026, 10, 3),
  );
  await c.load();
  await c.addHabit(
    title: title,
    emoji: '🌱',
    colorValue: 0xff000000,
    weekdays: {1, 2, 3, 4, 5, 6, 7},
    startDate: DateTime(2026, 9, 1),
  );
  return c;
}

Future<void> _show(WidgetTester tester, HabitController c, _Files files) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: DataScreen(
          controller: c,
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
}

Future<void> _openRestore(WidgetTester tester) async {
  final entry = find.text('从文件恢复');
  await tester.scrollUntilVisible(
    entry,
    350,
    scrollable: find.descendant(
      of: find.byKey(const PageStorageKey<String>('data-scroll')),
      matching: find.byType(Scrollable),
    ),
  );
  await tester.tap(entry);
  await tester.pumpAndSettle();
}

void main() {
  testWidgets('200%字号完整恢复：预览、取消、失败保留、重试与保护原数据', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final source = await _controller('备份中的习惯');
    final id = source.habits.single.id;
    await source.markCompleted(id, DateTime(2026, 9, 2));
    await source.setNote(id, DateTime(2026, 10, 2), '备注不能丢');
    final files = _Files(
      Uint8List.fromList(
        utf8.encode(
          jsonEncode({
            'format': BackupCodec.format,
            'formatVersion': 1,
            'encrypted': false,
            'createdAtUtc': '2026-10-03T09:12:00Z',
            'data': jsonDecode(source.exportJson()),
          }),
        ),
      ),
    );
    final repo = _Repository();
    final local = await _controller('本机原有数据', repo);
    final before = repo.value;
    await _show(tester, local, files);
    await _openRestore(tester);
    expect(tester.takeException(), isNull);
    final summary = tester
        .widget<Text>(find.byKey(const Key('restore-preview-summary')))
        .data!;
    expect(summary, contains('2026-10-03'));
    expect(summary, contains('1 个习惯 · 1 条记录 · 1 条备注'));
    expect(summary, contains('2026-09-02 至 2026-10-02'));
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(repo.value, before);
    expect(repo.protectedSources, isEmpty);

    await _openRestore(tester);
    repo.failNext = true;
    final confirm = find.byKey(const Key('confirm-restore-button'));
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restore-error')), findsOneWidget);
    expect(find.byKey(const Key('restore-preview-summary')), findsOneWidget);
    expect(repo.value, before);
    expect(files.opens, 2);
    expect(tester.takeException(), isNull);
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.text('恢复预览'), findsNothing);
    await tester.scrollUntilVisible(
      find.byKey(const Key('data-result')),
      -200,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey<String>('data-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.text('数据恢复成功。'), findsOneWidget);
    expect(local.habits.single.title, '备份中的习惯');
    expect(local.habits.single.noteOn(DateTime(2026, 10, 2)), '备注不能丢');
    expect(
      local.habits.single.entries.single.id,
      source.habits.single.entries.single.id,
    );
    expect(repo.protectedSources.single, before);
    expect(files.opens, 2);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    local.dispose();
    source.dispose();
  });

  testWidgets('损坏文件显示错误且不进入替换流程', (tester) async {
    final local = await _controller('原记录');
    final before = local.exportJson();
    await _show(
      tester,
      local,
      _Files(Uint8List.fromList(utf8.encode('{broken'))),
    );
    await _openRestore(tester);
    expect(find.text('恢复预览'), findsNothing);
    expect(local.exportJson(), before);
    await tester.scrollUntilVisible(
      find.byKey(const Key('data-result')),
      -200,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey<String>('data-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    expect(find.byKey(const Key('data-result')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    local.dispose();
  });

  testWidgets('备份密码草稿在系统返回时可保留或明确放弃', (tester) async {
    final local = await _controller('原记录');
    await _show(tester, local, _Files(Uint8List(0)));
    final entry = find.text('创建加密备份');
    await tester.scrollUntilVisible(
      entry,
      300,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey<String>('data-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, '保留尚未保存的密码');
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('keep-editing-button')));
    await tester.pumpAndSettle();
    expect(
      tester.widget<TextField>(find.byType(TextField).first).controller!.text,
      '保留尚未保存的密码',
    );
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard-changes-button')));
    await tester.pumpAndSettle();
    expect(find.byType(TextField), findsNothing);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    local.dispose();
  });
}
