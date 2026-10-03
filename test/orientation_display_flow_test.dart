import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_codec.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/data_screen.dart';
import 'package:haoxiguan/ui/habit_app.dart';

// Exercise the actual screens, controllers and repository reloads. Increasing
// DPR for a fixed physical display models the smaller logical viewport caused
// by display scaling; it does not prove Android's physical display-size setting,
// keyboard, rotation lifecycle or system back gesture on a device.
const _displays = [
  (
    name: '横屏 800×360 / DPR 1',
    physical: Size(800, 360),
    ratio: 1.0,
    logical: Size(800, 360),
  ),
  (
    name: '显示放大后横屏 640×288 / DPR 2.5',
    physical: Size(1600, 720),
    ratio: 2.5,
    logical: Size(640, 288),
  ),
];

void main() {
  for (final display in _displays) {
    for (final recordType in ['count', 'duration']) {
      testWidgets('200% ${display.name} 创建、$recordType记录和单笔撤销', (tester) async {
        _display(tester, display.physical, display.ratio);
        final repository = MemoryHabitRepository();
        final controller = await _controller(repository);
        addTearDown(controller.dispose);
        await tester.pumpWidget(HabitApp(controller: controller));
        await _settle(tester, '今日页');
        expect(
          MediaQuery.sizeOf(tester.element(find.byType(HomeShell))),
          display.logical,
        );

        final duration = recordType == 'duration';
        final title = duration ? '阅读' : '喝水';
        await _create(tester, title, recordType: recordType);
        final habit = controller.habits.single;
        final id = habit.id;
        expect(habit.title, title);
        expect(habit.recordType, recordType);
        expect(habit.unit, duration ? '秒' : '杯');
        expect(habit.dailyTarget, duration ? 1230 : 8000);
        await _expectReload(
          repository,
          (reloaded) =>
              expect(reloaded.habitById(id)!.toJson(), habit.toJson()),
        );

        // Establish the earlier fact through the real numerical entry dialog.
        await _todayTap(tester, find.byKey(Key('record-custom-$id')));
        await _enter(
          tester,
          find.byKey(const Key('record-value-field')),
          duration ? '1' : '2',
        );
        if (duration) {
          await _enter(tester, _field('秒（0–59）'), '30');
        }
        await _tap(tester, find.byKey(const Key('save-record-button')));
        final previousValue = duration ? 90 : 2000;
        expect(
          controller.habitById(id)!.valueOn(controller.today),
          previousValue,
        );
        final previousEntry = controller.habitById(id)!.entries.single.toJson();

        await _todayTap(tester, find.byTooltip('记录备注'));
        await _enter(
          tester,
          find.byKey(const Key('note-text-field')),
          '原有备注保留',
        );
        await _tap(tester, find.byKey(const Key('save-note-button')));
        expect(controller.habitById(id)!.noteOn(controller.today), '原有备注保留');

        final quick = find.byKey(Key('quick-$id'));
        await _todayReach(tester, quick);
        expect(find.text(duration ? '＋5 分钟' : '＋1 杯'), findsOneWidget);
        final size = tester.getSize(quick);
        expect(size.width, greaterThanOrEqualTo(48));
        expect(size.height, greaterThanOrEqualTo(48));
        await _tap(tester, quick);
        expect(
          controller.habitById(id)!.valueOn(controller.today),
          previousValue + (duration ? 300 : 1000),
        );
        expect(
          find.textContaining(duration ? '已增加 5分' : '已增加 1 杯'),
          findsOneWidget,
        );

        // A separate fact arriving during the five-second undo window must
        // survive Undo; comparing IDs and the saved fact prevents snapshot undo
        // from appearing correct merely because a total happens to match.
        final laterValue = duration ? 30 : 1000;
        await controller.addValue(id, controller.today, laterValue);
        await _settle(tester, '另一笔记录到达');
        final laterEntry = controller.habitById(id)!.entries.last.toJson();
        await _tap(tester, find.widgetWithText(SnackBarAction, '撤销'));
        final undone = controller.habitById(id)!;
        expect(undone.valueOn(controller.today), previousValue + laterValue);
        expect(undone.noteOn(controller.today), '原有备注保留');
        expect(
          undone.entries
              .singleWhere((e) => e.id == previousEntry['id'])
              .toJson(),
          previousEntry,
        );
        expect(
          undone.entries.singleWhere((e) => e.id == laterEntry['id']).toJson(),
          laterEntry,
        );
        expect(undone.entries.where((e) => !e.deleted), hasLength(2));
        await _expectReload(repository, (reloaded) {
          expect(reloaded.habitById(id)!.toJson(), undone.toJson());
        });
        await tester.pumpWidget(const SizedBox.shrink());
        await _settle(tester, '结束记录流程');
      });
    }

    testWidgets('200% ${display.name} 系统返回保留输入或明确放弃', (tester) async {
      _display(tester, display.physical, display.ratio);
      final repository = MemoryHabitRepository();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      await tester.pumpWidget(HabitApp(controller: controller));
      await _settle(tester, '今日页');
      final before = await repository.load();
      await _tap(tester, find.byKey(const Key('add-habit-button')));
      await _enter(
        tester,
        find.byKey(const Key('habit-title-field')),
        '尚未保存的横屏输入',
      );
      await tester.binding.handlePopRoute();
      await _settle(tester, '系统返回确认');
      await _tap(tester, find.byKey(const Key('keep-editing-button')));
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('habit-title-field')))
            .controller!
            .text,
        '尚未保存的横屏输入',
      );
      expect(await repository.load(), before);
      await tester.binding.handlePopRoute();
      await _settle(tester, '再次系统返回确认');
      await _tap(tester, find.byKey(const Key('discard-changes-button')));
      expect(find.byKey(const Key('habit-title-field')), findsNothing);
      expect(controller.habits, isEmpty);
      expect(await repository.load(), before);
      await _expectReload(repository, (reloaded) {
        expect(reloaded.habits, isEmpty);
      });
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester, '结束返回流程');
    });

    testWidgets('200% ${display.name} 文件恢复预览、取消、返回与保护原库', (tester) async {
      _display(tester, display.physical, display.ratio);
      final repository = MemoryHabitRepository();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      await tester.pumpWidget(HabitApp(controller: controller));
      await _settle(tester, '今日页');
      await _create(tester, '本机原有习惯');
      final originalId = controller.habits.single.id;
      await controller.markCompleted(originalId, controller.today);
      await controller.setNote(originalId, controller.today, '原库备注要保护');
      final before = await repository.load();

      final source = await _controller(MemoryHabitRepository());
      addTearDown(source.dispose);
      await source.addHabit(
        title: '备份中的习惯',
        emoji: '📖',
        colorValue: 0xff5f8068,
        weekdays: {1, 2, 3, 4, 5, 6, 7},
        startDate: DateTime(2026, 9, 1),
      );
      final restoredId = source.habits.single.id;
      await source.markCompleted(restoredId, DateTime(2026, 9, 2));
      await source.setNote(restoredId, DateTime(2026, 10, 2), '备份备注不能丢');
      final files = _SelectedBackup(
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
      await tester.pumpWidget(
        MaterialApp(
          locale: const Locale('zh', 'CN'),
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          supportedLocales: const [Locale('zh', 'CN')],
          home: Scaffold(
            body: DataScreen(
              controller: controller,
              files: files,
              onTheme: () {},
              onReview: () {},
              onLegacyRestore: () {},
            ),
          ),
        ),
      );
      await _settle(tester, '数据页');

      await _openRestore(tester);
      final summary = tester
          .widget<Text>(find.byKey(const Key('restore-preview-summary')))
          .data!;
      expect(summary, contains('2026-10-03'));
      expect(summary, contains('1 个习惯 · 1 条记录 · 1 条备注'));
      expect(summary, contains('2026-09-02 至 2026-10-02'));
      expect(await repository.load(), before);
      await _tap(tester, find.widgetWithText(TextButton, '取消'));
      expect(await repository.load(), before);
      expect(repository.protectedSources, isEmpty);

      await _openRestore(tester);
      await tester.binding.handlePopRoute();
      await _settle(tester, '恢复预览系统返回');
      expect(find.byKey(const Key('restore-preview-summary')), findsNothing);
      expect(await repository.load(), before);
      expect(repository.protectedSources, isEmpty);

      await _openRestore(tester);
      await _tap(tester, find.byKey(const Key('confirm-restore-button')));
      expect(find.byKey(const Key('restore-preview-summary')), findsNothing);
      await tester.scrollUntilVisible(
        find.byKey(const Key('data-result')),
        -120,
        scrollable: _dataScrollable,
      );
      await _reach(tester, find.byKey(const Key('data-result')));
      expect(find.text('数据恢复成功。'), findsOneWidget);
      expect(repository.protectedSources, [before]);
      expect(files.opens, 3);
      expect(controller.habits.single.title, '备份中的习惯');
      expect(controller.habitById(originalId), isNull);
      expect(
        controller.habits.single.entries.single.toJson(),
        source.habits.single.entries.single.toJson(),
      );
      expect(controller.habits.single.noteOn(DateTime(2026, 10, 2)), '备份备注不能丢');
      await _expectReload(repository, (reloaded) {
        expect(
          reloaded.habits.single.toJson(),
          controller.habits.single.toJson(),
        );
      });
      // The protected snapshot must itself reopen with the original facts.
      await _expectReload(
        MemoryHabitRepository(repository.protectedSources.single),
        (protected) {
          expect(protected.habits.single.id, originalId);
          expect(
            protected.habits.single.isCompletedOn(protected.today),
            isTrue,
          );
          expect(protected.habits.single.noteOn(protected.today), '原库备注要保护');
        },
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester, '结束恢复流程');
    });
  }
}

void _display(WidgetTester tester, Size physical, double ratio) {
  tester.view.physicalSize = physical;
  tester.view.devicePixelRatio = ratio;
  tester.platformDispatcher.textScaleFactorTestValue = 2;
  addTearDown(() {
    tester.view.resetPhysicalSize();
    tester.view.resetDevicePixelRatio();
    tester.platformDispatcher.clearTextScaleFactorTestValue();
  });
}

Future<HabitController> _controller(MemoryHabitRepository repository) async {
  final controller = HabitController(
    repository,
    clock: () => DateTime(2026, 10, 3, 10),
  );
  await controller.load();
  return controller;
}

Future<void> _expectReload(
  MemoryHabitRepository repository,
  void Function(HabitController) verify,
) async {
  final reopened = await _controller(repository);
  try {
    verify(reopened);
  } finally {
    reopened.dispose();
  }
}

Future<void> _settle(WidgetTester tester, String step) async {
  await tester.pumpAndSettle();
  expect(tester.takeException(), isNull, reason: '$step 不应 overflow 或抛出异常');
}

Future<void> _reach(WidgetTester tester, Finder target) async {
  expect(target, findsOneWidget);
  await Scrollable.ensureVisible(tester.element(target), alignment: 0.5);
  await _settle(tester, '滚动到 $target');
  final scrollViews = find.ancestor(
    of: target,
    matching: find.byType(SingleChildScrollView),
  );
  expect(
    target.hitTestable(),
    findsOneWidget,
    reason:
        '关键控件须滚达并实际可操作；控件区域 ${tester.getRect(target)}'
        '${scrollViews.evaluate().isEmpty ? '' : '，滚动区域 ${tester.getRect(scrollViews.first)}'}',
  );
}

Future<void> _tap(WidgetTester tester, Finder target) async {
  await _reach(tester, target);
  await tester.tap(target);
  await _settle(tester, '点击 $target');
}

Future<void> _enter(WidgetTester tester, Finder target, String value) async {
  await _reach(tester, target);
  await tester.enterText(target, value);
  await _settle(tester, '输入 $value');
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

Future<void> _create(
  WidgetTester tester,
  String title, {
  String recordType = 'boolean',
}) async {
  await _tap(tester, find.byKey(const Key('add-habit-button')));
  await _enter(tester, find.byKey(const Key('habit-title-field')), title);
  if (recordType != 'boolean') {
    await _tap(tester, find.byKey(const Key('habit-advanced-options')));
    await _tap(tester, find.byKey(const Key('record-type-field')));
    await _tap(tester, find.text(recordType == 'count' ? '计数' : '手动时长').last);
    if (recordType == 'count') {
      await _enter(tester, _field('单位，例如 杯、页'), '杯');
    }
    await _enter(
      tester,
      find.byKey(const Key('daily-target-field')),
      recordType == 'duration' ? '20' : '8',
    );
    if (recordType == 'duration') {
      await _enter(tester, _field('目标秒数（0–59）'), '30');
    }
  }
  await _tap(tester, find.byKey(const Key('save-habit-button')));
  expect(find.byKey(const Key('habit-title-field')), findsNothing);
}

Future<void> _todayReach(WidgetTester tester, Finder target) async {
  await tester.scrollUntilVisible(
    target,
    100,
    scrollable: find
        .descendant(
          of: find.byType(TodayScreen),
          matching: find.byType(Scrollable),
        )
        .first,
  );
  await _reach(tester, target);
}

Future<void> _todayTap(WidgetTester tester, Finder target) async {
  await _todayReach(tester, target);
  await _tap(tester, target);
}

Finder get _dataScrollable => find.descendant(
  of: find.byKey(const PageStorageKey<String>('data-scroll')),
  matching: find.byType(Scrollable),
);

Future<void> _openRestore(WidgetTester tester) async {
  final entry = find.text('从文件恢复');
  await tester.scrollUntilVisible(entry, 120, scrollable: _dataScrollable);
  await _tap(tester, entry);
  expect(find.byKey(const Key('restore-preview-summary')), findsOneWidget);
}

class _SelectedBackup implements BackupFiles {
  _SelectedBackup(this.bytes);
  final Uint8List bytes;
  int opens = 0;

  @override
  Future<Uint8List?> open() async {
    opens++;
    return bytes;
  }

  @override
  Future<bool> save(Uint8List bytes, String name) async =>
      throw StateError('此流程只选择恢复文件，不应导出');
}
