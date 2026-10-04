import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/services/backup_preview.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/backup_restore_dialog.dart';
import 'package:haoxiguan/ui/habit_history.dart';

class _WritesRepository extends MemoryHabitRepository {
  int writes = 0;

  @override
  Future<void> save(String value) async {
    writes++;
    await super.save(value);
  }

  @override
  Future<void> replace(String value) async {
    writes++;
    await super.replace(value);
  }
}

Future<HabitController> _controller(
  HabitRepository repository,
  String title,
) async {
  final controller = HabitController(
    repository,
    clock: () => DateTime(2026, 10, 3),
  );
  await controller.load();
  await controller.addHabit(
    title: title,
    emoji: '🌱',
    colorValue: 0xff5f8068,
    weekdays: {1, 2, 3, 4, 5, 6, 7},
  );
  return controller;
}

void main() {
  for (final history in [false, true]) {
    for (final submitAfterCancel in [false, true]) {
      testWidgets(
        '${history ? '历史' : '恢复'}预览取消后旧${submitAfterCancel ? '确认不得写入' : '取消不得关闭底层页面'}',
        (tester) async {
          final repository = _WritesRepository();
          final target = await _controller(repository, '本机原事实');
          final source = await _controller(MemoryHabitRepository(), '备份新事实');
          addTearDown(target.dispose);
          addTearDown(source.dispose);
          final before = target.exportJson();
          final beforeRepository = repository.value;
          repository.writes = 0;
          final outcomes = <bool?>[];
          var pageClosed = 0;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: Builder(
                  builder: (context) => TextButton(
                    onPressed: () async {
                      await Navigator.push<void>(
                        context,
                        MaterialPageRoute(
                          builder: (pageContext) => Scaffold(
                            appBar: AppBar(title: const Text('数据操作页')),
                            body: TextButton(
                              onPressed: () async {
                                final raw = source.exportJson();
                                outcomes.add(
                                  history
                                      ? await showStartDateCorrection(
                                          pageContext,
                                          target,
                                          target.habits.single,
                                        )
                                      : await showDialog<bool>(
                                          context: pageContext,
                                          builder: (_) => BackupRestoreDialog(
                                            controller: target,
                                            raw: raw,
                                            preview: BackupPreview.forRestore(
                                              raw,
                                            ),
                                          ),
                                        ),
                                );
                              },
                              child: const Text('打开预览'),
                            ),
                          ),
                        ),
                      );
                      pageClosed++;
                    },
                    child: const Text('进入数据操作'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('进入数据操作'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('打开预览'));
          await tester.pumpAndSettle();
          if (history) {
            final label = MaterialLocalizations.of(
              tester.element(find.byType(DatePickerDialog)),
            ).okButtonLabel;
            await tester.tap(find.text(label));
            await tester.pumpAndSettle();
          }
          final cancel = tester.widget<TextButton>(
            find.widgetWithText(TextButton, '取消'),
          );
          final confirm = tester.widget<FilledButton>(
            find.byKey(
              Key(
                history ? 'confirm-start-correction' : 'confirm-restore-button',
              ),
            ),
          );
          cancel.onPressed!();
          if (submitAfterCancel) {
            confirm.onPressed!();
          } else {
            cancel.onPressed!();
          }
          await tester.pumpAndSettle();
          expect(pageClosed, 0);
          expect(find.text('数据操作页'), findsOneWidget);
          expect(outcomes, [false]);
          expect(repository.writes, 0);
          expect(repository.protectedSources, isEmpty);
          expect(repository.value, beforeRepository);
          expect(target.exportJson(), before);
          expect(tester.takeException(), isNull);
        },
      );
    }
  }
}
