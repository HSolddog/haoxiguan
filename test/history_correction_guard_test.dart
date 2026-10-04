import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_history.dart';

class _CorrectionRepository extends MemoryHabitRepository {
  Completer<void>? pending;
  bool failNext = false;
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
  late _CorrectionRepository repository;
  late HabitController controller;
  bool? outcome;
  setUp(() async {
    repository = _CorrectionRepository();
    controller = HabitController(
      repository,
      clock: () => DateTime(2026, 10, 3),
    );
    await controller.load();
    await controller.addHabit(
      title: '阅读',
      emoji: '📖',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    );
    outcome = null;
  });
  tearDown(() => controller.dispose());
  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                outcome = await showStartDateCorrection(
                  context,
                  controller,
                  controller.habits.single,
                );
              },
              child: const Text('校正开始日'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('校正开始日'));
    await tester.pumpAndSettle();
    final label = MaterialLocalizations.of(
      tester.element(find.byType(DatePickerDialog)),
    ).okButtonLabel;
    await tester.tap(find.text(label));
    await tester.pumpAndSettle();
    expect(find.text('历史校正影响预览'), findsOneWidget);
  }

  testWidgets('历史校正确认写入中返回或遮罩不能伪装为取消', (tester) async {
    await open(tester);
    repository.pending = Completer<void>();
    await tester.tap(find.byKey(const Key('confirm-start-correction')));
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.tapAt(const Offset(5, 5));
    await tester.pump();
    expect(find.text('历史校正影响预览'), findsOneWidget);
    expect(outcome, isNull);
    expect(controller.habits.single.createdAt, DateTime.utc(2026, 10, 3));
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(outcome, isTrue);
    expect(controller.habits.single.createdAt, DateTime.utc(2026, 10, 2));
  });

  testWidgets('历史校正保存失败保留同一影响预览，可重试确认', (tester) async {
    final before = controller.exportJson();
    await open(tester);
    repository.failNext = true;
    await tester.tap(find.byKey(const Key('confirm-start-correction')));
    await tester.pumpAndSettle();
    expect(find.text('历史校正影响预览'), findsOneWidget);
    expect(find.textContaining('2026-10-03 → 2026-10-02'), findsOneWidget);
    expect(find.textContaining('保存未完成'), findsOneWidget);
    expect(controller.exportJson(), before);
    expect(outcome, isNull);
    await tester.tap(find.byKey(const Key('confirm-start-correction')));
    await tester.pumpAndSettle();
    expect(outcome, isTrue);
    expect(controller.habits.single.createdAt, DateTime.utc(2026, 10, 2));
  });
}
