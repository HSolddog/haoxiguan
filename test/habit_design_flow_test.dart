import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/habit_app.dart';

void main() {
  late HabitController controller;
  late _FailingRepository repository;
  setUp(() async {
    repository = _FailingRepository();
    controller = HabitController(
      repository,
      clock: () => DateTime(2026, 10, 3),
    );
    await controller.load();
  });
  tearDown(() => controller.dispose());

  Future<void> editor(WidgetTester tester, {bool editing = false}) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showAddHabitSheet(
                context,
                controller,
                habit: editing ? controller.habits.single : null,
              ),
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开'));
    await tester.pumpAndSettle();
  }

  testWidgets('200% 字号小屏完成创建输入并保存，保留选择开始日期', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    await editor(tester);
    await tester.enterText(find.byKey(const Key('habit-title-field')), '阅读');
    await tester.ensureVisible(find.byKey(const Key('habit-advanced-options')));
    await tester.tap(find.byKey(const Key('habit-advanced-options')));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('habit-start-date')));
    await tester.tap(find.byKey(const Key('habit-start-date')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('2').last);
    await tester.tap(find.text('确定'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('save-habit-button')));
    await tester.tap(find.byKey(const Key('save-habit-button')));
    await tester.pumpAndSettle();
    expect(controller.habits.single.title, '阅读');
    expect(controller.habits.single.createdAt, DateTime.utc(2026, 10, 2));
    expect(tester.takeException(), isNull);
  });

  for (final exit in ['system', 'backdrop', 'drag']) {
    testWidgets('创建未保存 $exit 退出保留或明确放弃', (tester) async {
      await editor(tester);
      await tester.enterText(
        find.byKey(const Key('habit-title-field')),
        '尚未保存',
      );
      await tester.pump();
      if (exit == 'system') {
        await tester.binding.handlePopRoute();
      } else if (exit == 'backdrop') {
        await tester.tapAt(const Offset(10, 5));
      } else {
        await tester.fling(
          find.byKey(const Key('habit-editor-drag-handle')),
          const Offset(0, 150),
          1000,
        );
      }
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('keep-editing-button')), findsOneWidget);
      await tester.tap(find.byKey(const Key('keep-editing-button')));
      await tester.pumpAndSettle();
      expect(find.text('尚未保存'), findsOneWidget);
      expect(controller.habits, isEmpty);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const Key('discard-changes-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('habit-title-field')), findsNothing);
      expect(controller.habits, isEmpty);
    });
  }

  testWidgets('编辑失败保留输入，存储恢复后原位重试', (tester) async {
    await controller.addHabit(
      title: '原名',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    );
    await editor(tester, editing: true);
    await tester.enterText(find.byKey(const Key('habit-title-field')), '修改后');
    repository.fail = true;
    await tester.ensureVisible(find.byKey(const Key('save-habit-button')));
    await tester.tap(find.byKey(const Key('save-habit-button')));
    await tester.pumpAndSettle();
    expect(controller.habits.single.title, '原名');
    expect(find.byKey(const Key('save-habit-button')), findsOneWidget);
    repository.fail = false;
    await tester.ensureVisible(find.byKey(const Key('save-habit-button')));
    await tester.tap(find.byKey(const Key('save-habit-button')));
    await tester.pumpAndSettle();
    expect(controller.habits.single.title, '修改后');
  });

  testWidgets('今日快捷明确单位、反馈和五秒撤销只影响该笔', (tester) async {
    await controller.addHabit(
      title: '喝水',
      emoji: '💧',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: 'count',
      scale: 1000,
      unit: '杯',
      dailyTarget: 8000,
    );
    final id = controller.habits.single.id;
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    expect(find.text('＋1 杯'), findsOneWidget);
    await tester.ensureVisible(find.byKey(Key('quick-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('quick-$id')));
    await tester.pumpAndSettle();
    expect(find.text('喝水：已增加 1 杯'), findsOneWidget);
    await controller.addValue(id, controller.today, 2000);
    await controller.setNote(id, controller.today, '另外的备注');
    await tester.pumpAndSettle();
    await tester.tap(find.text('撤销'));
    await tester.pumpAndSettle();
    expect(controller.habits.single.valueOn(controller.today), 2000);
    expect(controller.habits.single.noteOn(controller.today), '另外的备注');
    await tester.ensureVisible(find.byKey(Key('quick-$id')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(Key('quick-$id')));
    await tester.pumpAndSettle();
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(find.text('撤销'), findsNothing);
  });
}

class _FailingRepository extends MemoryHabitRepository {
  bool fail = false;
  @override
  Future<void> save(String value) async {
    if (fail) throw StateError('disk full');
    await super.save(value);
  }
}
