import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/models/habit.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/data_screen.dart';
import 'package:haoxiguan/ui/habit_app.dart';

void main() {
  late HabitController controller;
  setUp(() async {
    controller = HabitController(
      MemoryHabitRepository(),
      clock: () => DateTime(2026, 10, 3),
    );
    await controller.load();
  });
  tearDown(() => controller.dispose());

  void smallScreen(WidgetTester tester) {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
    });
  }

  Future<void> openEditor(WidgetTester tester, {Habit? habit}) async {
    await tester.pumpWidget(
      MaterialApp(
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        supportedLocales: const [Locale('zh', 'CN')],
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () =>
                  showAddHabitSheet(context, controller, habit: habit),
              child: const Text('打开习惯编辑'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开习惯编辑'));
    await tester.pumpAndSettle();
  }

  Future<Habit> createSource() async {
    await controller.addHabit(
      title: '原始喝水',
      emoji: '💧',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: 'count',
      unit: '杯',
      scale: 1000,
      dailyTarget: 8000,
    );
    final id = controller.habits.single.id;
    await controller.addValue(id, controller.today, 2500);
    await controller.setNote(id, controller.today, '保留杯数和原备注');
    return controller.habitById(id)!;
  }

  testWidgets('简单创建默认只展示名称输入和保存，填名称即可创建每日完成型', (tester) async {
    smallScreen(tester);
    await openEditor(tester);
    expect(
      find.byKey(const Key('habit-title-field')).hitTestable(),
      findsOneWidget,
    );
    expect(
      find.byKey(const Key('save-habit-button')).hitTestable(),
      findsOneWidget,
    );
    expect(find.byType(TextField), findsOneWidget);
    expect(find.byKey(const Key('record-type-field')), findsNothing);
    expect(find.byKey(const Key('habit-category-field')), findsNothing);
    expect(find.byKey(const Key('habit-start-date')), findsNothing);
    await tester.enterText(find.byKey(const Key('habit-title-field')), '每天伸展');
    await tester.tap(find.byKey(const Key('save-habit-button')));
    await tester.pumpAndSettle();
    final habit = controller.habits.single;
    expect(habit.title, '每天伸展');
    expect(habit.recordType, 'boolean');
    expect(habit.scheduleType, 'daily');
    expect(habit.createdAt, controller.today);
    expect(habit.entries, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('更多选项可展开类型和开始日期，折叠不会丢失名称', (tester) async {
    await openEditor(tester);
    await tester.enterText(find.byKey(const Key('habit-title-field')), '选填详情');
    await tester.tap(find.byKey(const Key('habit-advanced-options')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-type-field')), findsOneWidget);
    expect(find.byKey(const Key('habit-start-date')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('record-type-field')));
    expect(
      find.byKey(const Key('record-type-field')).hitTestable(),
      findsOneWidget,
    );
    await tester.ensureVisible(find.text('更多选项'));
    await tester.tap(find.text('更多选项'));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('record-type-field')), findsNothing);
    expect(find.text('选填详情'), findsOneWidget);
  });

  testWidgets('编辑中关联新建可改记录类型，保存新ID和来源且完整保留源事实', (tester) async {
    final source = await createSource();
    final original = source.toJson();
    await openEditor(tester, habit: source);
    expect(
      tester
          .widget<DropdownButtonFormField<String>>(
            find.byKey(const Key('record-type-field')),
          )
          .onChanged,
      isNull,
    );
    await tester.ensureVisible(find.byKey(const Key('create-related-habit')));
    await tester.tap(find.byKey(const Key('create-related-habit')));
    await tester.pumpAndSettle();
    expect(find.textContaining('关联原习惯：原始喝水'), findsOneWidget);
    await tester.ensureVisible(find.byKey(const Key('habit-title-field')));
    await tester.enterText(
      find.byKey(const Key('habit-title-field')),
      '饮水休息时长',
    );
    await tester.ensureVisible(find.byKey(const Key('record-type-field')));
    await tester.tap(find.byKey(const Key('record-type-field')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('手动时长').last);
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.byKey(const Key('daily-target-field')));
    await tester.enterText(find.byKey(const Key('daily-target-field')), '3');
    await tester.ensureVisible(find.byKey(const Key('save-habit-button')));
    await tester.tap(find.byKey(const Key('save-habit-button')));
    await tester.pumpAndSettle();
    expect(controller.habits, hasLength(2));
    final related = controller.habits.singleWhere((h) => h.id != source.id);
    expect(related.extensions['relatedHabitId'], source.id);
    expect(related.title, '饮水休息时长');
    expect(related.recordType, 'duration');
    expect(related.unit, '秒');
    expect(related.dailyTarget, 180);
    expect(related.entries, isEmpty);
    expect(related.notes, isEmpty);
    expect(controller.habitById(source.id)!.toJson(), original);
    expect(tester.takeException(), isNull);
  });

  testWidgets('从未保存的编辑跳转关联创建也先保护原草稿', (tester) async {
    final source = await createSource();
    await openEditor(tester, habit: source);
    await tester.enterText(find.byKey(const Key('habit-title-field')), '未保存原名');
    await tester.ensureVisible(find.byKey(const Key('create-related-habit')));
    await tester.tap(find.byKey(const Key('create-related-habit')));
    await tester.pumpAndSettle();
    expect(find.byKey(const Key('keep-editing-button')), findsOneWidget);
    await tester.tap(find.byKey(const Key('keep-editing-button')));
    await tester.pumpAndSettle();
    expect(controller.habits, hasLength(1));
    expect(controller.habits.single.title, source.title);
    expect(
      tester
          .widget<TextField>(find.byKey(const Key('habit-title-field')))
          .controller!
          .text,
      '未保存原名',
    );
    await tester.ensureVisible(find.byKey(const Key('create-related-habit')));
    await tester.tap(find.byKey(const Key('create-related-habit')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard-changes-button')));
    await tester.pumpAndSettle();
    expect(find.textContaining('关联原习惯：原始喝水'), findsOneWidget);
    expect(controller.habits.single.title, source.title);
  });

  testWidgets('空态从备份恢复入口到达数据页，原空库不变', (tester) async {
    smallScreen(tester);
    await tester.pumpWidget(HabitApp(controller: controller));
    await tester.pumpAndSettle();
    final restore = find.text('从备份恢复');
    await tester.ensureVisible(restore);
    expect(restore.hitTestable(), findsOneWidget);
    await tester.tap(restore);
    await tester.pumpAndSettle();
    expect(find.byType(DataScreen), findsOneWidget);
    expect(find.text('数据与备份'), findsWidgets);
    await tester.ensureVisible(find.text('从文件恢复'));
    expect(find.text('从文件恢复').hitTestable(), findsOneWidget);
    expect(controller.habits, isEmpty);
    expect(tester.takeException(), isNull);
  });
}
