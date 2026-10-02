import 'package:flutter/material.dart';

import '../models/habit.dart';
import '../models/record_entry.dart';
import '../state/habit_controller.dart';

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
  final _value = TextEditingController();
  final _seconds = TextEditingController(text: '0');
  bool _replace = false;
  bool _saving = false;
  String? _error;
  @override
  void dispose() {
    _value.dispose();
    _seconds.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final habit = widget.habit;
    final duration = habit.recordType == 'duration';
    return AlertDialog(
      title: Text('${habit.title} · ${dateKey(widget.date)}'),
      content: SingleChildScrollView(
        child: Column(
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
                keyboardType: TextInputType.number,
                decoration: const InputDecoration(labelText: '秒（0–59）'),
              ),
            if (_replace)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('将更正当天的总量，备注和其他日期不变。'),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('save-record-button'),
          onPressed: _saving
              ? null
              : () async {
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
                    setState(() => _saving = false);
                  }
                },
          child: Text(_saving ? '正在保存' : '保存'),
        ),
      ],
    );
  }
}
