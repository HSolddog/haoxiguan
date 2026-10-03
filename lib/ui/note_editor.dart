import 'package:flutter/material.dart';

import '../models/habit.dart';
import '../state/habit_controller.dart';
import 'unsaved_changes_guard.dart';

Future<void> showNoteEditor(
  BuildContext context,
  HabitController controller,
  Habit habit,
  DateTime date,
) => showDialog<void>(
  context: context,
  builder: (_) => _NoteEditor(controller: controller, habit: habit, date: date),
);

class _NoteEditor extends StatefulWidget {
  const _NoteEditor({
    required this.controller,
    required this.habit,
    required this.date,
  });
  final HabitController controller;
  final Habit habit;
  final DateTime date;

  @override
  State<_NoteEditor> createState() => _NoteEditorState();
}

class _NoteEditorState extends State<_NoteEditor> {
  final _guard = GlobalKey<UnsavedChangesGuardState>();
  late final TextEditingController _text;
  late final String _initialText;
  bool _saving = false;
  String? _error;
  bool get _dirty => _text.text != _initialText;

  @override
  void initState() {
    super.initState();
    _initialText = widget.habit.noteOn(widget.date) ?? '';
    _text = TextEditingController(text: _initialText)..addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    if (!mounted || _saving) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return;
    final current = widget.controller.habitById(widget.habit.id);
    if (current == null) {
      setState(() => _error = '这个习惯已不存在，备注尚未保存。当前输入仍保留，可复制后关闭。');
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.controller.setNote(
        current.id,
        widget.date,
        _text.text,
      );
      if (!mounted) return;
      if (saved && route?.isCurrent == true) {
        Navigator.pop(context);
      } else if (!saved) {
        setState(() => _error = '备注尚未保存，输入已保留。请检查存储后重试。');
      }
    } on Object {
      if (mounted) setState(() => _error = '备注尚未保存，输入已保留。请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) => UnsavedChangesGuard(
    key: _guard,
    dirty: _dirty,
    isDirty: () => _dirty,
    saving: _saving,
    isSaving: () => _saving,
    child: AlertDialog(
      scrollable: true,
      title: Text('${widget.habit.emoji} ${dateKey(widget.date)} 备注'),
      content: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          TextField(
            key: const Key('note-text-field'),
            controller: _text,
            autofocus: true,
            enabled: !_saving,
            minLines: 2,
            maxLines: 5,
            maxLength: 2000,
            decoration: const InputDecoration(
              labelText: '备注',
              hintText: '简单记下感受或完成情况',
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(_error!, key: const Key('note-save-error')),
            ),
          ],
        ],
      ),
      actions: [
        TextButton(
          key: const Key('cancel-note-button'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _saving ? null : () => _guard.currentState?.leave(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('save-note-button'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _saving ? null : _save,
          child: Text(
            _saving
                ? '正在保存'
                : _error == null
                ? '保存备注'
                : '重试保存',
          ),
        ),
      ],
    ),
  );
}
