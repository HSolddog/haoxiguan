import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/record_editor.dart';

class _ControlledRepository extends MemoryHabitRepository {
  bool failNext = false;
  Completer<void>? pending;

  @override
  Future<void> save(String value) async {
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    await pending?.future;
    await super.save(value);
  }
}

void main() {
  late _ControlledRepository repository;
  late HabitController controller;
  late String id;

  setUp(() async {
    repository = _ControlledRepository();
    controller = HabitController(
      repository,
      clock: () => DateTime(2026, 10, 3, 12),
    );
    await controller.load();
    await controller.addHabit(
      title: '喝水',
      emoji: '💧',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: 'count',
      unit: '杯',
      scale: 1000,
      dailyTarget: 8000,
    );
    id = controller.habits.single.id;
  });

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showRecordEditor(
                context,
                controller,
                controller.habitById(id)!,
                controller.today,
              ),
              child: const Text('打开记录'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开记录'));
    await tester.pumpAndSettle();
  }

  for (final exit in ['系统返回', '遮罩', '取消按钮']) {
    testWidgets('记录草稿$exit可继续编辑或明确放弃', (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('record-value-field')),
        '2.5',
      );
      Future<void> attemptExit() async {
        if (exit == '系统返回') {
          await tester.binding.handlePopRoute();
        } else if (exit == '遮罩') {
          await tester.tapAt(const Offset(5, 5));
        } else {
          await tester.tap(find.text('取消'));
        }
        await tester.pumpAndSettle();
      }

      await attemptExit();
      expect(find.byKey(const Key('keep-editing-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('keep-editing-button')));
      await tester.pumpAndSettle();
      expect(find.text('2.5'), findsOneWidget);
      expect(controller.habitById(id)!.valueOn(controller.today), 0);
      await attemptExit();
      await tester.tap(find.byKey(const Key('discard-changes-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('record-value-field')), findsNothing);
      expect(controller.habitById(id)!.valueOn(controller.today), 0);
    });
  }

  testWidgets('200%字号完整输入保存失败再重试，保留其他记录和备注', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await controller.addValue(id, controller.today, 1000);
    await controller.setNote(id, controller.today, '保留备注');
    final originalEntry = controller.habitById(id)!.entries.single.id;
    await open(tester);
    await tester.enterText(find.byKey(const Key('record-value-field')), '2.5');
    repository.failNext = true;
    final save = find.byKey(const Key('save-record-button'));
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('2.5'), findsOneWidget);
    expect(find.text('保存未完成，请重试。'), findsOneWidget);
    expect(controller.habitById(id)!.valueOn(controller.today), 1000);
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-value-field')), findsNothing);
    expect(controller.habitById(id)!.valueOn(controller.today), 3500);
    expect(controller.habitById(id)!.noteOn(controller.today), '保留备注');
    expect(
      controller
          .habitById(id)!
          .entries
          .any((e) => e.id == originalEntry && !e.deleted),
      isTrue,
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('写入未结束时返回和重复点击都不关闭或重复提交', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('record-value-field')), '1');
    repository.pending = Completer<void>();
    await tester.tap(find.byKey(const Key('save-record-button')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-value-field')), findsOneWidget);
    expect(find.text('正在保存'), findsOneWidget);
    expect(find.byKey(const Key('discard-changes-button')), findsNothing);
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(controller.habitById(id)!.valueOn(controller.today), 1000);
    expect(
      controller.habitById(id)!.entries.where((e) => !e.deleted),
      hasLength(1),
    );
    expect(find.byKey(const Key('record-value-field')), findsNothing);
  });
}
