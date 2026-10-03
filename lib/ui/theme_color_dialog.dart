import 'package:flutter/material.dart';

import '../state/habit_controller.dart';
import 'accessible_controls.dart';
import 'unsaved_changes_guard.dart';

Future<void> showThemeColorDialog(
  BuildContext context,
  HabitController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _ThemeColorDialog(controller: controller),
);

class _ThemeColorDialog extends StatefulWidget {
  const _ThemeColorDialog({required this.controller});
  final HabitController controller;
  @override
  State<_ThemeColorDialog> createState() => _ThemeColorDialogState();
}

class _ThemeColorDialogState extends State<_ThemeColorDialog> {
  static const colors = [
    0xFF5F8068,
    0xFF397D6D,
    0xFF2F6DB0,
    0xFF6558A8,
    0xFF8A4E9B,
    0xFFBA4A68,
    0xFFD0573F,
    0xFFB97824,
    0xFF65713B,
    0xFF4D7C91,
    0xFF795548,
    0xFF546E7A,
  ];
  final _guard = GlobalKey<UnsavedChangesGuardState>();
  late final TextEditingController _hex;
  late final String _initialHex;
  bool _saving = false;
  String? _error;
  bool get _dirty => _hex.text != _initialHex;
  static String _format(int value) =>
      value.toRadixString(16).padLeft(8, '0').substring(2).toUpperCase();
  int? get _parsed {
    final raw = _hex.text.trim().replaceFirst('#', '');
    final value = raw.length == 6 ? int.tryParse(raw, radix: 16) : null;
    return value == null ? null : 0xff000000 | value;
  }

  @override
  void initState() {
    super.initState();
    _initialHex = _format(widget.controller.themeColorValue);
    _hex = TextEditingController(text: _initialHex)..addListener(_changed);
  }

  void _changed() => setState(() {});
  @override
  void dispose() {
    _hex.dispose();
    super.dispose();
  }

  Future<void> _save({int? preset}) async {
    if (_saving) return;
    final value = preset ?? _parsed;
    if (value == null) {
      setState(() => _error = '请输入 6 位十六进制色值，例如 #5F8068');
      return;
    }
    if (preset != null) _hex.text = _format(preset);
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      final saved = await widget.controller.setThemeColor(value);
      if (!mounted) return;
      if (saved) {
        Navigator.pop(context);
      } else {
        setState(() => _error = '主题颜色尚未保存，色值已保留。请检查存储后重试。');
      }
    } on Object {
      if (mounted) setState(() => _error = '主题颜色尚未保存，色值已保留。请重试。');
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
      title: const Text('选择主题颜色'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AbsorbPointer(
              absorbing: _saving,
              child: Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  for (final color in colors)
                    ColorChoice(
                      key: ValueKey('theme-preset-$color'),
                      value: color,
                      selected: color == _parsed,
                      onSelected: () => _save(preset: color),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('theme-hex-field'),
              controller: _hex,
              enabled: !_saving,
              maxLength: 7,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: '自定义 HEX 色值',
                hintText: '#5F8068',
                prefixIcon: Icon(Icons.colorize_rounded),
              ),
            ),
            if (_error != null)
              Semantics(
                liveRegion: true,
                child: Text(_error!, key: const Key('theme-save-error')),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel-theme-button'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _saving ? null : () => _guard.currentState?.leave(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('save-theme-button'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _saving ? null : _save,
          child: Text(
            _saving
                ? '正在保存'
                : _error == null
                ? '应用'
                : '重试保存',
          ),
        ),
      ],
    ),
  );
}
