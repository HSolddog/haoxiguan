import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/note_editor.dart';

class _NoteRepository extends MemoryHabitRepository {
  bool failNext = false;
  Completer<void>? pending;
  int writes = 0;
  @override
  Future<void> save(String value) async {
    writes++;
    if (failNext) {
      failNext = false;
      throw StateError('disk full');
    }
    await pending?.future;
    await super.save(value);
  }
}

void main() {
  late _NoteRepository repository;
  late HabitController controller;
  late String id;
  setUp(() async {
    repository = _NoteRepository();
    controller = HabitController(
      repository,
      clock: () => DateTime(2026, 10, 3, 12),
    );
    await controller.load();
    await controller.addHabit(
      title: '阅读',
      emoji: '📖',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    );
    id = controller.habits.single.id;
    await controller.markCompleted(id, controller.today);
    await controller.setNote(id, controller.today, '原备注');
  });
  tearDown(() => controller.dispose());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showNoteEditor(
                context,
                controller,
                controller.habitById(id)!,
                controller.today,
              ),
              child: const Text('打开备注'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开备注'));
    await tester.pumpAndSettle();
  }

  for (final exit in ['系统返回', '遮罩', '取消按钮']) {
    testWidgets('备注草稿$exit可保留或明确放弃，原数据不变', (tester) async {
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('note-text-field')),
        '未保存的感受',
      );
      Future<void> leave() async {
        if (exit == '系统返回') {
          await tester.binding.handlePopRoute();
        } else if (exit == '遮罩') {
          await tester.tapAt(const Offset(5, 5));
        } else {
          await tester.tap(find.byKey(const Key('cancel-note-button')));
        }
        await tester.pumpAndSettle();
      }

      await leave();
      expect(find.byKey(const Key('keep-editing-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('keep-editing-button')));
      await tester.pumpAndSettle();
      expect(find.text('未保存的感受'), findsOneWidget);
      expect(controller.habitById(id)!.noteOn(controller.today), '原备注');
      await leave();
      await tester.tap(find.byKey(const Key('discard-changes-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('note-text-field')), findsNothing);
      expect(controller.habitById(id)!.noteOn(controller.today), '原备注');
    });
  }

  testWidgets('200%字号备注失败保留输入后重试，仅更新备注', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final entry = controller.habitById(id)!.entries.single.toJson();
    await open(tester);
    await tester.enterText(find.byKey(const Key('note-text-field')), '完成后的感受');
    repository.failNext = true;
    final save = find.byKey(const Key('save-note-button'));
    await tester.ensureVisible(save);
    expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('完成后的感受'), findsOneWidget);
    expect(find.byKey(const Key('note-save-error')), findsOneWidget);
    expect(controller.habitById(id)!.noteOn(controller.today), '原备注');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('note-text-field')), findsNothing);
    expect(controller.habitById(id)!.noteOn(controller.today), '完成后的感受');
    expect(controller.habitById(id)!.entries.single.toJson(), entry);
    expect(tester.takeException(), isNull);
  });

  testWidgets('备注保存中屏蔽返回和重复提交，清空备注仍保留事实', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const Key('note-text-field')), '');
    repository.pending = Completer<void>();
    final beforeWrites = repository.writes;
    await tester.tap(find.byKey(const Key('save-note-button')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const Key('note-text-field')), findsOneWidget);
    expect(find.byKey(const Key('discard-changes-button')), findsNothing);
    expect(
      tester
          .widget<FilledButton>(find.byKey(const Key('save-note-button')))
          .onPressed,
      isNull,
    );
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(repository.writes, beforeWrites + 1);
    expect(controller.habitById(id)!.noteOn(controller.today), isNull);
    expect(controller.habitById(id)!.isCompletedOn(controller.today), isTrue);
  });
}
