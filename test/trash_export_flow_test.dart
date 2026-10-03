import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_files.dart';
import 'package:haoxiguan/services/data_status.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/data_screen.dart';
import 'package:haoxiguan/ui/trash_screen.dart';

class _Files implements BackupFiles {
  int saves = 0;

  @override
  Future<Uint8List?> open() async => null;

  @override
  Future<bool> save(Uint8List bytes, String name) async {
    saves++;
    return true;
  }
}

class _Status extends DataStatusReader {
  @override
  Future<DataServiceStatus> read(String snapshot) async =>
      const DataServiceStatus(backup: '尚无本机校验成功记录', sync: '未连接');
}

Future<HabitController> _open(MemoryHabitRepository repository) async {
  final controller = HabitController(
    repository,
    clock: () => DateTime(2026, 10, 3, 10),
  );
  await controller.load();
  addTearDown(controller.dispose);
  return controller;
}

Future<String> _create(
  HabitController controller,
  String title, {
  bool trash = true,
}) async {
  expect(
    await controller.addHabit(
      title: title,
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: 'count',
      unit: '杯',
      scale: 1000,
      dailyTarget: 8000,
      startDate: DateTime(2026, 9, 1),
    ),
    isTrue,
  );
  final id = controller.habits.last.id;
  expect(await controller.addValue(id, DateTime(2026, 10, 2), 1000), isTrue);
  expect(await controller.addValue(id, controller.today, 2000), isTrue);
  expect(await controller.setNote(id, controller.today, '$title的原始备注'), isTrue);
  if (trash) expect(await controller.deleteHabit(id), isTrue);
  return id;
}

Future<void> _confirmDelete(WidgetTester tester, String title) async {
  final card = find.ancestor(
    of: find.text('🌱 $title'),
    matching: find.byType(Card),
  );
  final button = find.descendant(
    of: card,
    matching: find.widgetWithText(TextButton, '永久删除'),
  );
  await tester.ensureVisible(button);
  await tester.tap(button);
  await tester.pumpAndSettle();
  expect(find.text('永久删除“$title”？'), findsOneWidget);
  expect(find.textContaining('2 条记录、1 条备注及计划历史'), findsOneWidget);
}

void main() {
  testWidgets('永久删除前导出关闭确认，取消导出返回后事实与计划完整保留', (tester) async {
    final repository = MemoryHabitRepository();
    final controller = await _open(repository);
    final id = await _create(controller, '保留的喝水习惯');
    final before = repository.value;
    final beforeHabit = controller.habitById(id)!.toJson();
    final navigator = GlobalKey<NavigatorState>();
    final files = _Files();
    var exportRequests = 0;

    await tester.pumpWidget(
      MaterialApp(
        navigatorKey: navigator,
        home: TrashScreen(
          controller: controller,
          onExport: () {
            exportRequests++;
            navigator.currentState!.push<void>(
              MaterialPageRoute<void>(
                builder: (_) => Scaffold(
                  appBar: AppBar(title: const Text('数据备份')),
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
          },
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _confirmDelete(tester, '保留的喝水习惯');
    await tester.tap(find.byKey(const Key('export-before-delete')));
    await tester.pumpAndSettle();

    expect(exportRequests, 1);
    expect(find.byType(DataScreen), findsOneWidget);
    expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    expect(repository.value, before);
    expect(controller.habitById(id)!.toJson(), beforeHabit);

    final plainExport = find.text('导出可读 JSON');
    await tester.scrollUntilVisible(
      plainExport,
      300,
      scrollable: find.descendant(
        of: find.byKey(const PageStorageKey<String>('data-scroll')),
        matching: find.byType(Scrollable),
      ),
    );
    await tester.ensureVisible(plainExport);
    await tester.pumpAndSettle();
    await tester.tap(plainExport);
    await tester.pumpAndSettle();
    expect(find.text('导出可读 JSON？'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(files.saves, 0);
    await tester.pageBack();
    await tester.pumpAndSettle();

    expect(find.byType(TrashScreen), findsOneWidget);
    expect(find.byType(AlertDialog, skipOffstage: false), findsNothing);
    expect(find.text('🌱 保留的喝水习惯'), findsOneWidget);
    expect(controller.habitById(id)!.toJson(), beforeHabit);
    expect(repository.value, before);
    expect(tester.takeException(), isNull);

    final reopened = await _open(repository);
    expect(reopened.habitById(id)!.toJson(), beforeHabit);
    expect(reopened.trashedHabits, hasLength(1));
  });

  testWidgets('取消永久删除保留全部，再次确认仅删除选中的回收站习惯', (tester) async {
    final repository = MemoryHabitRepository();
    final controller = await _open(repository);
    final selectedId = await _create(controller, '选中的习惯');
    final otherId = await _create(controller, '另一个回收站习惯');
    final activeId = await _create(controller, '正在进行的习惯', trash: false);
    final before = repository.value;
    final otherBefore = controller.habitById(otherId)!.toJson();
    final activeBefore = controller.habitById(activeId)!.toJson();
    var exportRequests = 0;

    await tester.pumpWidget(
      MaterialApp(
        home: TrashScreen(
          controller: controller,
          onExport: () => exportRequests++,
        ),
      ),
    );
    await tester.pumpAndSettle();
    await _confirmDelete(tester, '选中的习惯');
    await tester.tap(find.widgetWithText(TextButton, '取消，保留数据'));
    await tester.pumpAndSettle();
    expect(repository.value, before);
    expect(controller.trashedHabits, hasLength(2));
    expect(exportRequests, 0);

    await _confirmDelete(tester, '选中的习惯');
    await tester.tap(find.widgetWithText(FilledButton, '永久删除'));
    await tester.pumpAndSettle();
    expect(controller.habitById(selectedId), isNull);
    expect(controller.trashedHabits.map((habit) => habit.id), [otherId]);
    expect(controller.habitById(otherId)!.toJson(), otherBefore);
    expect(controller.habitById(activeId)!.toJson(), activeBefore);
    expect(find.text('🌱 选中的习惯'), findsNothing);
    expect(find.text('🌱 另一个回收站习惯'), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(exportRequests, 0);
    expect(tester.takeException(), isNull);

    final reopened = await _open(repository);
    expect(reopened.habitById(selectedId), isNull);
    expect(reopened.habitById(otherId)!.toJson(), otherBefore);
    expect(reopened.habitById(activeId)!.toJson(), activeBefore);
  });
}
