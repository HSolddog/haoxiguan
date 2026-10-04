import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/data/habit_repository.dart';
import 'package:haoxiguan/state/habit_controller.dart';
import 'package:haoxiguan/ui/accessible_controls.dart';
import 'package:haoxiguan/ui/theme_color_dialog.dart';

class _ThemeRepository extends MemoryHabitRepository {
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
  late _ThemeRepository repository;
  late HabitController controller;
  setUp(() async {
    repository = _ThemeRepository();
    controller = HabitController(repository);
    await controller.load();
  });
  tearDown(() => controller.dispose());

  Future<void> open(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showThemeColorDialog(context, controller),
              child: const Text('选择颜色'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('选择颜色'));
    await tester.pumpAndSettle();
  }

  for (final exit in ['系统返回', '遮罩', '取消按钮']) {
    testWidgets('自定义HEX$exit保留或明确放弃草稿', (tester) async {
      final before = controller.themeColorValue;
      await open(tester);
      await tester.enterText(
        find.byKey(const Key('theme-hex-field')),
        '#123456',
      );
      Future<void> leave() async {
        if (exit == '系统返回') {
          await tester.binding.handlePopRoute();
        } else if (exit == '遮罩') {
          await tester.tapAt(const Offset(5, 5));
        } else {
          await tester.tap(find.byKey(const Key('cancel-theme-button')));
        }
        await tester.pumpAndSettle();
      }

      await leave();
      await tester.tap(find.byKey(const Key('keep-editing-button')));
      await tester.pumpAndSettle();
      expect(find.text('#123456'), findsOneWidget);
      expect(controller.themeColorValue, before);
      await leave();
      await tester.tap(find.byKey(const Key('discard-changes-button')));
      await tester.pumpAndSettle();
      expect(find.byKey(const Key('theme-hex-field')), findsNothing);
      expect(controller.themeColorValue, before);
    });
  }

  testWidgets('200%字号HEX校验及保存失败保留色值后可重试', (tester) async {
    tester.view.physicalSize = const Size(360, 800);
    tester.view.devicePixelRatio = 1;
    tester.platformDispatcher.textScaleFactorTestValue = 2;
    addTearDown(() {
      tester.view.resetPhysicalSize();
      tester.view.resetDevicePixelRatio();
      tester.platformDispatcher.clearTextScaleFactorTestValue();
    });
    final before = controller.themeColorValue;
    await open(tester);
    final input = find.byKey(const Key('theme-hex-field'));
    final save = find.byKey(const Key('save-theme-button'));
    await tester.ensureVisible(input);
    await tester.enterText(input, 'xyz');
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.textContaining('请输入 6 位'), findsOneWidget);
    expect(controller.themeColorValue, before);
    await tester.ensureVisible(input);
    await tester.enterText(input, '#123456');
    repository.failNext = true;
    await tester.ensureVisible(save);
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(find.text('#123456'), findsOneWidget);
    expect(find.textContaining('主题颜色尚未保存'), findsOneWidget);
    expect(controller.themeColorValue, before);
    await tester.ensureVisible(save);
    expect(tester.getSize(save).height, greaterThanOrEqualTo(48));
    await tester.tap(save);
    await tester.pumpAndSettle();
    expect(controller.themeColorValue, 0xff123456);
    expect(find.byKey(const Key('theme-hex-field')), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('预设选择保存中阻止返回和重复点击，失败保留预设可重试', (tester) async {
    await open(tester);
    const selected = 0xff397d6d;
    repository.failNext = true;
    final preset = find.byKey(const ValueKey('theme-preset-$selected'));
    await tester.ensureVisible(preset);
    await tester.tap(preset);
    await tester.pumpAndSettle();
    expect(find.text('397D6D'), findsOneWidget);
    expect(find.byKey(const Key('theme-save-error')), findsOneWidget);
    repository.pending = Completer<void>();
    final beforeWrites = repository.writes;
    await tester.tap(preset);
    await tester.pump();
    // Exercise a second callback in the same pending save even if a pointer
    // gesture was already delivered before AbsorbPointer rebuilt.
    tester.widget<ColorChoice>(preset).onSelected();
    await tester.binding.handlePopRoute();
    await tester.pump();
    expect(find.byKey(const Key('theme-hex-field')), findsOneWidget);
    expect(find.byKey(const Key('discard-changes-button')), findsNothing);
    repository.pending!.complete();
    await tester.pumpAndSettle();
    expect(repository.writes, beforeWrites + 1);
    expect(controller.themeColorValue, selected);
  });
}
