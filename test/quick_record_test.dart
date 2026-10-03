import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';

void main() {
  late HabitController controller;
  setUp(() async {
    controller = HabitController(
      MemoryHabitRepository(),
      clock: () => DateTime(2026, 10, 3, 12),
    );
    await controller.load();
  });
  tearDown(() => controller.dispose());
  Future<String> create(String type) async {
    await controller.addHabit(
      title: '快捷',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
      recordType: type,
      scale: type == 'count' ? 1000 : 1,
      dailyTarget: 1000,
    );
    return controller.habits.last.id;
  }

  test('计数快捷加一单位，时长加五分钟', () async {
    final count = await create('count');
    final duration = await create('duration');
    await controller.quickRecord(count, controller.today);
    await controller.quickRecord(duration, controller.today);
    expect(controller.habitById(count)!.valueOn(controller.today), 1000);
    expect(controller.habitById(duration)!.valueOn(controller.today), 300);
  });

  test('撤销只删除这笔entryId，保留后来新增条目和备注', () async {
    final id = await create('count');
    await controller.addValue(id, controller.today, 500);
    final undo = (await controller.quickRecord(id, controller.today))!;
    await controller.addValue(id, controller.today, 2000);
    await controller.setNote(id, controller.today, '稍后备注');
    expect(await controller.undoQuickRecord(undo), isTrue);
    final habit = controller.habitById(id)!;
    expect(habit.valueOn(controller.today), 2500);
    expect(habit.noteOn(controller.today), '稍后备注');
    expect(
      habit.entries.singleWhere((e) => e.id == undo.after.id).deleted,
      isTrue,
    );
  });

  test('被更正的同一条记录不再允许旧撤销覆盖', () async {
    final id = await create('count');
    final undo = (await controller.quickRecord(id, controller.today))!;
    await controller.addValue(id, controller.today, 7000, replaceTotal: true);
    expect(await controller.undoQuickRecord(undo), isFalse);
    expect(controller.habitById(id)!.valueOn(controller.today), 7000);
  });

  test('完成型快捷撤销及再次操作的版本保护', () async {
    await controller.addHabit(
      title: '完成',
      emoji: '🌱',
      colorValue: 0xff5f8068,
      weekdays: {1, 2, 3, 4, 5, 6, 7},
    );
    final id = controller.habits.single.id;
    final undo = (await controller.quickRecord(id, controller.today))!;
    expect(await controller.undoQuickRecord(undo), isTrue);
    expect(controller.habits.single.isCompletedOn(controller.today), isFalse);
    final second = (await controller.quickRecord(id, controller.today))!;
    await controller.quickRecord(id, controller.today);
    expect(await controller.undoQuickRecord(second), isFalse);
    expect(controller.habits.single.isCompletedOn(controller.today), isFalse);
  });
}
