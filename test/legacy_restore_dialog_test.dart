import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/legacy_restore_dialog.dart';

class _RestoreRepository extends MemoryHabitRepository {
  bool failProtection = false;
  Completer<void>? pending;
  int replacements = 0;
  @override
  Future<void> replace(String value) async {
    replacements++;
    if (failProtection) throw StateError('protect failed');
    await pending?.future;
    await super.replace(value);
  }
}

void main() {
  late _RestoreRepository repository;
  late HabitController controller;
  late String source;
  late String before;

  setUp(() async {
    repository = _RestoreRepository();
    controller = HabitController(
      repository,
      clock: () => DateTime(2026, 10, 3),
    );
    await controller.load();
    await controller.addHabit(
      title: '保留当前数据',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    );
    before = controller.exportJson();
    final other = HabitController(
      MemoryHabitRepository(),
      clock: () => DateTime(2026, 10, 1),
    );
    await other.load();
    await other.addHabit(
      title: '从粘贴恢复',
      emoji: '📖',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    );
    await other.markCompleted(other.habits.single.id, other.today);
    await other.setNote(other.habits.single.id, other.today, '旧备注');
    source = other.exportJson();
    other.dispose();
  });
  tearDown(() => controller.dispose());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showLegacyRestoreDialog(context, controller),
              child: const Text('粘贴恢复'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('粘贴恢复'));
    await tester.pumpAndSettle();
  }

  for (final exit in ['系统返回', '遮罩', '取消按钮']) {
    testWidgets('JSON输入$exit可保留或明确放弃', (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('legacy-json-field')),
        source,
      );
      Future<void> leave() async {
        if (exit == '系统返回') {
          await tester.binding.handlePopRoute();
        } else if (exit == '遮罩') {
          await tester.tapAt(const Offset(5, 5));
        } else {
          await tester.tap(find.byKey(const Key('cancel-legacy-json-button')));
        }
        await tester.pumpAndSettle();
      }

      await leave();
      await tester.tap(find.byKey(const Key('keep-editing-button')));
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<TextField>(find.byKey(const Key('legacy-json-field')))
            .controller!
            .text,
        source,
      );
      await leave();
      await tester.tap(find.byKey(const Key('discard-changes-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('legacy-json-field')), findsNothing);
      expect(controller.exportJson(), before);
      expect(repository.replacements, 0);
    });
  }

  testWidgets('坏JSON校验失败保留输入，修正后预览取消不修改数据', (tester) async {
    await open(tester);
    final input = find.byKey(const Key('legacy-json-field'));
    await tester.enterText(input, '{invalid');
    await tester.tap(find.byKey(const Key('preview-legacy-json-button')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('legacy-json-error')), findsOneWidget);
    expect(tester.widget<TextField>(input).controller!.text, '{invalid');
    expect(controller.exportJson(), before);
    await tester.enterText(input, source);
    await tester.tap(find.byKey(const Key('preview-legacy-json-button')));
    await tester.pumpAndSettle();
    expect(find.text('恢复预览'), findsOneWidget);
    expect(find.textContaining('1 个习惯 · 1 条记录 · 1 条备注'), findsOneWidget);
    expect(find.textContaining('创建于：旧文件未提供'), findsOneWidget);
    expect(controller.exportJson(), before);
    expect(repository.replacements, 0);
    await tester.tap(find.text('取消').last);
    await tester.pumpAndSettle();
    expect(find.text('恢复预览'), findsNothing);
    expect(tester.widget<TextField>(input).controller!.text, source);
    expect(controller.exportJson(), before);
  });

  testWidgets('200%字号完整粘贴预览保护失败后重试恢复，不丢草稿', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await open(tester);
    await tester.enterText(find.byKey(const Key('legacy-json-field')), source);
    final preview = find.byKey(const Key('preview-legacy-json-button'));
    await tester.ensureVisible(preview);
    expect(tester.getSize(preview).height, greaterThanOrEqualTo(48));
    await tester.tap(preview);
    await tester.pumpAndSettle();
    expect(find.text('恢复预览'), findsOneWidget);
    final confirm = find.byKey(const Key('confirm-restore-button'));
    repository.failProtection = true;
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('restore-error')), findsOneWidget);
    expect(controller.exportJson(), before);
    expect(repository.protectedSources, isEmpty);
    repository.failProtection = false;
    await tester.ensureVisible(confirm);
    await tester.tap(confirm);
    await tester.pumpAndSettle();
    expect(find.text('恢复预览'), findsNothing);
    expect(find.byKey(const Key('legacy-json-field')), findsNothing);
    expect(controller.habits.single.title, '从粘贴恢复');
    expect(controller.habits.single.noteOn(DateTime(2026, 10, 1)), '旧备注');
    expect(controller.habits.single.entries, hasLength(1));
    expect(repository.protectedSources, [before]);
    expect(tester.takeException(), isNull);
  });

  testWidgets('确认恢复写入中不接受返回或重复提交', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('legacy-json-field')), source);
    await tester.tap(find.byKey(const Key('preview-legacy-json-button')));
    await tester.pumpAndSettle();
    repository.pending = Completer<void>();
    await tester.tap(find.byKey(const Key('confirm-restore-button')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.text('恢复预览'), findsOneWidget);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('confirm-restore-button')))
          .onPressed,
      isNull,
    );
    expect(controller.exportJson(), before);
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(repository.replacements, 1);
    expect(controller.habits.single.title, '从粘贴恢复');
  });
}
