import 'package:flutter/material.dart';

import '../models/habit.dart';
import '../models/record_entry.dart';
import '../state/habit_controller.dart';
import 'unsaved_changes_guard.dart';

Future<void> showRecordEditor(
  BuildContext context,
  HabitController controller,
  Habit habit,
  DateTime date,
) => showDialog<void>(
  context: context,
  builder: (_) =>
      _RecordEditor(controller: controller, habit: habit, date: date),
);

class _RecordEditor extends StatefulWidget {
  const _RecordEditor({
    required this.controller,
    required this.habit,
    required this.date,
  });
  final HabitController controller;
  final Habit habit;
  final DateTime date;
  @override
  State<_RecordEditor> createState() => _RecordEditorState();
}

class _RecordEditorState extends State<_RecordEditor> {
  final _guard = GlobalKey<UnsavedChangesGuardState>();
  final _value = TextEditingController();
  final _seconds = TextEditingController(text: '0');
  bool _replace = false;
  bool _saving = false;
  String? _error;
  bool get _dirty => _value.text.isNotEmpty || _seconds.text != '0' || _replace;

  @override
  void initState() {
    super.initState();
    _value.addListener(_draftChanged);
    _seconds.addListener(_draftChanged);
  }

  void _draftChanged() => setState(() {});
  @override
  void dispose() {
    _value.dispose();
    _seconds.dispose();
    super.dispose();
  }

  Future<void> _delete(Habit habit, RecordEntry entry) async {
    if (_saving) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('撤销这条 ${habit.valueLabel(entry.value)}？'),
        content: const Text('只撤销这次记录，当天的其他记录和备注保留。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('撤销这条记录'),
          ),
        ],
      ),
    );
    if (!mounted || confirmed != true || _saving) return;
    setState(() => _saving = true);
    final saved = await widget.controller.deleteEntry(habit.id, entry.id);
    if (!mounted) return;
    setState(() {
      _saving = false;
      _error = saved ? null : '撤销未保存，请重试。';
    });
  }

  @override
  Widget build(BuildContext context) {
    final habit = widget.controller.habitById(widget.habit.id) ?? widget.habit;
    final duration = habit.recordType == 'duration';
    final entries = habit.entries
        .where((e) => !e.deleted && e.date == dateKey(widget.date))
        .toList();
    return UnsavedChangesGuard(
      key: _guard,
      dirty: _dirty,
      isDirty: () => _dirty,
      isSaving: () => _saving,
      saving: _saving,
      child: AlertDialog(
        scrollable: true,
        title: Text('${habit.title} · ${dateKey(widget.date)}'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('目前 ${habit.valueLabel(habit.valueOn(widget.date))}'),
            const SizedBox(height: 12),
            SegmentedButton<bool>(
              segments: const [
                ButtonSegment(value: false, label: Text('增加')),
                ButtonSegment(value: true, label: Text('更正总量')),
              ],
              selected: {_replace},
              onSelectionChanged: _saving
                  ? null
                  : (v) => setState(() => _replace = v.first),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('record-value-field'),
              controller: _value,
              enabled: !_saving,
              autofocus: true,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(
                labelText: duration ? '分钟（整数）' : habit.unit,
                errorText: _error,
              ),
            ),
            if (duration)
              TextField(
                controller: _seconds,
                enabled: !_saving,
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '秒（0–59）'),
              ),
            if (_replace)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('将更正当天的总量，备注和其他日期不变。'),
              ),
            if (entries.isNotEmpty)
              ExpansionTile(
                key: const Key('record-facts'),
                title: Text('当天记录（${entries.length}）'),
                children: [
                  for (final entry in entries.reversed)
                    ListTile(
                      title: Text(habit.valueLabel(entry.value)),
                      subtitle: Text(
                        entry.recordedAtUtc == null
                            ? '旧版记录 · 原始时间 ${entry.legacyTimestamp}'
                            : '录入时间（UTC）\n${entry.recordedAtUtc}${entry.recordedLocalDate != entry.date ? '\n补记' : ''}',
                      ),
                      trailing: IconButton(
                        key: Key('delete-entry-${entry.id}'),
                        tooltip: '撤销这条记录',
                        icon: const Icon(Icons.undo),
                        onPressed: _saving ? null : () => _delete(habit, entry),
                      ),
                    ),
                ],
              ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => _guard.currentState?.leave(),
            child: const Text('取消'),
          ),
          FilledButton(
            key: const Key('save-record-button'),
            onPressed: _saving
                ? null
                : () async {
                    if (_saving) return;
                    int value;
                    try {
                      if (duration) {
                        final minutes = int.parse(_value.text.trim());
                        final seconds = int.parse(_seconds.text.trim());
                        if (minutes < 0 || seconds < 0 || seconds > 59) {
                          throw const FormatException('时长无效');
                        }
                        value = minutes * 60 + seconds;
                      } else {
                        value = parseFixed(_value.text, scale: habit.scale);
                      }
                      if (value == 0 && !_replace) {
                        throw const FormatException('增加的数值需大于 0');
                      }
                    } on FormatException catch (error) {
                      setState(() => _error = error.message);
                      return;
                    }
                    setState(() => _saving = true);
                    final saved = await widget.controller.addValue(
                      habit.id,
                      widget.date,
                      value,
                      replaceTotal: _replace,
                    );
                    if (!context.mounted) return;
                    if (saved) {
                      Navigator.pop(context);
                    } else {
                      setState(() {
                        _saving = false;
                        _error = '保存未完成，请重试。';
                      });
                    }
                  },
            child: Text(_saving ? '正在保存' : '保存'),
          ),
        ],
      ),
    );
  }
}
