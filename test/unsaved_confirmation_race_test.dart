import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:haoxiguan/ui/unsaved_changes_guard.dart';

class _DraftEditor extends StatefulWidget {
  const _DraftEditor({this.saveGate, this.saved});

  final Completer<void>? saveGate;
  final void Function(String)? saved;

  @override
  State<_DraftEditor> createState() => _DraftEditorState();
}

class _DraftEditorState extends State<_DraftEditor> {
  final _text = TextEditingController();
  bool _saving = false;

  Future<void> _save() async {
    if (_saving) return;
    final draft = _text.text;
    setState(() => _saving = true);
    await widget.saveGate!.future;
    widget.saved?.call(draft);
    if (mounted) Navigator.pop(context);
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => UnsavedChangesGuard(
    dirty: _text.text.isNotEmpty,
    isDirty: () => _text.text.isNotEmpty,
    saving: _saving,
    isSaving: () => _saving,
    child: SizedBox(
      height: 240,
      child: Column(
        children: [
          TextField(
            key: const Key('unsaved-race-draft'),
            controller: _text,
            onChanged: (_) => setState(() {}),
          ),
          if (widget.saveGate != null)
            FilledButton(
              key: const Key('unsaved-race-save'),
              onPressed: _saving ? null : _save,
              child: const Text('保存输入'),
            ),
        ],
      ),
    ),
  );
}

Future<void> _openDirtyEditor(
  WidgetTester tester,
  VoidCallback closed, {
  Completer<void>? saveGate,
  void Function(String)? saved,
  bool edit = true,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => FilledButton(
            onPressed: () async {
              await showModalBottomSheet<void>(
                context: context,
                builder: (_) => _DraftEditor(saveGate: saveGate, saved: saved),
              );
              closed();
            },
            child: const Text('打开编辑'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开编辑'));
  await tester.pumpAndSettle();
  if (!edit) return;
  await tester.enterText(
    find.byKey(const Key('unsaved-race-draft')),
    '保留这份未保存的输入',
  );
  await tester.binding.handlePopRoute();
  await tester.pumpAndSettle();
  expect(find.text('保留未保存的修改？'), findsOneWidget);
}

void _expectDraft(WidgetTester tester, int closed) {
  expect(closed, 0);
  final editor = tester.widget<TextField>(
    find.byKey(const Key('unsaved-race-draft')),
  );
  expect(editor.controller!.text, '保留这份未保存的输入');
  expect(tester.takeException(), isNull);
}

void main() {
  testWidgets('无草稿连续系统返回只退出编辑层一次', (tester) async {
    var closed = 0;
    await _openDirtyEditor(tester, () => closed++, edit: false);
    final first = tester.binding.handlePopRoute();
    final second = tester.binding.handlePopRoute();
    await Future.wait([first, second]);
    await tester.pumpAndSettle();
    expect(closed, 1);
    expect(find.text('打开编辑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('继续编辑旧回调同帧双调用只关闭确认且保留草稿', (tester) async {
    var closed = 0;
    await _openDirtyEditor(tester, () => closed++);
    final keep = tester.widget<TextButton>(
      find.byKey(const Key('keep-editing-button')),
    );
    keep.onPressed!();
    keep.onPressed!();
    await tester.pumpAndSettle();
    _expectDraft(tester, closed);
  });

  testWidgets('确认先被系统返回关闭后旧继续回调不得关闭草稿', (tester) async {
    var closed = 0;
    await _openDirtyEditor(tester, () => closed++);
    final keep = tester.widget<TextButton>(
      find.byKey(const Key('keep-editing-button')),
    );
    await tester.binding.handlePopRoute();
    keep.onPressed!();
    await tester.pumpAndSettle();
    _expectDraft(tester, closed);
  });

  testWidgets('确认先被系统返回关闭后旧放弃回调不得丢弃草稿', (tester) async {
    var closed = 0;
    await _openDirtyEditor(tester, () => closed++);
    final discard = tester.widget<TextButton>(
      find.byKey(const Key('discard-changes-button')),
    );
    await tester.binding.handlePopRoute();
    discard.onPressed!();
    await tester.pumpAndSettle();
    _expectDraft(tester, closed);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const Key('discard-changes-button')));
    await tester.pumpAndSettle();
    expect(closed, 1);
    expect(find.text('打开编辑'), findsOneWidget);
  });

  testWidgets('放弃旧回调同帧双调用只退出一次且保留首页', (tester) async {
    var closed = 0;
    await _openDirtyEditor(tester, () => closed++);
    final discard = tester.widget<TextButton>(
      find.byKey(const Key('discard-changes-button')),
    );
    discard.onPressed!();
    discard.onPressed!();
    await tester.pumpAndSettle();
    expect(closed, 1);
    expect(find.byKey(const Key('unsaved-race-draft')), findsNothing);
    expect(find.text('打开编辑'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('放弃结果恢复前出现新页面时不误关新页面', (tester) async {
    var closed = 0;
    await _openDirtyEditor(tester, () => closed++);
    final discard = tester.widget<TextButton>(
      find.byKey(const Key('discard-changes-button')),
    );
    final navigator = tester.state<NavigatorState>(find.byType(Navigator));
    discard.onPressed!();
    unawaited(
      navigator.push<void>(
        MaterialPageRoute(builder: (_) => const Scaffold(body: Text('后开的页面'))),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('后开的页面'), findsOneWidget);
    expect(closed, 0);
    navigator.pop();
    await tester.pumpAndSettle();
    _expectDraft(tester, closed);
  });

  testWidgets('放弃结果恢复前开始保存时实时拒绝退出', (tester) async {
    var closed = 0;
    final saved = <String>[];
    final gate = Completer<void>();
    await _openDirtyEditor(
      tester,
      () => closed++,
      saveGate: gate,
      saved: saved.add,
    );
    final discard = tester.widget<TextButton>(
      find.byKey(const Key('discard-changes-button')),
    );
    final save = tester.widget<FilledButton>(
      find.byKey(const Key('unsaved-race-save'), skipOffstage: false),
    );
    discard.onPressed!();
    save.onPressed!();
    await tester.pumpAndSettle();
    _expectDraft(tester, closed);
    expect(saved, isEmpty);
    gate.complete();
    await tester.pumpAndSettle();
    expect(saved, ['保留这份未保存的输入']);
    expect(closed, 1);
    expect(find.text('打开编辑'), findsOneWidget);
  });
}
