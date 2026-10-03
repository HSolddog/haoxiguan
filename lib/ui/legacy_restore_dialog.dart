import 'package:flutter/material.dart';

import '../data/snapshot_codec.dart';
import '../services/backup_preview.dart';
import '../state/habit_controller.dart';
import 'backup_restore_dialog.dart';
import 'unsaved_changes_guard.dart';

Future<void> showLegacyRestoreDialog(
  BuildContext context,
  HabitController controller,
) => showDialog<void>(
  context: context,
  builder: (_) => _LegacyRestoreDialog(controller: controller),
);

class _LegacyRestoreDialog extends StatefulWidget {
  const _LegacyRestoreDialog({required this.controller});
  final HabitController controller;

  @override
  State<_LegacyRestoreDialog> createState() => _LegacyRestoreDialogState();
}

class _LegacyRestoreDialogState extends State<_LegacyRestoreDialog> {
  final _guard = GlobalKey<UnsavedChangesGuardState>();
  final _text = TextEditingController();
  bool _previewing = false;
  String? _error;
  bool get _dirty => _text.text.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _text.addListener(_changed);
  }

  void _changed() => setState(() {});

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _preview() async {
    if (_previewing) return;
    setState(() {
      _previewing = true;
      _error = null;
    });
    try {
      final raw = _text.text;
      final preview = BackupPreview.fromSnapshot(raw);
      final restored = await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (_) => BackupRestoreDialog(
          controller: widget.controller,
          raw: raw,
          preview: preview,
        ),
      );
      if (mounted && restored == true) {
        Navigator.pop(context);
      }
    } on UnsupportedSnapshotVersion catch (error) {
      if (mounted) setState(() => _error = '$error\n粘贴内容已保留，本机数据未改变。');
    } on Object {
      if (mounted) {
        setState(() => _error = '内容未通过校验。请粘贴完整、受支持的 JSON 后重试。当前输入已保留，本机数据未改变。');
      }
    } finally {
      if (mounted) setState(() => _previewing = false);
    }
  }

  @override
  Widget build(BuildContext context) => UnsavedChangesGuard(
    key: _guard,
    dirty: _dirty,
    isDirty: () => _dirty,
    saving: _previewing,
    isSaving: () => _previewing,
    child: AlertDialog(
      title: const Text('恢复旧 JSON 数据'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('先粘贴完整内容进行校验与预览。确认恢复前，本机数据不会被替换。'),
            const SizedBox(height: 12),
            TextField(
              key: const Key('legacy-json-field'),
              controller: _text,
              enabled: !_previewing,
              minLines: 3,
              maxLines: 6,
              decoration: const InputDecoration(
                labelText: '旧版 JSON',
                hintText: '粘贴完整的旧版 JSON',
              ),
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Semantics(
                liveRegion: true,
                child: Text(_error!, key: const Key('legacy-json-error')),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          key: const Key('cancel-legacy-json-button'),
          style: TextButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _previewing ? null : () => _guard.currentState?.leave(),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('preview-legacy-json-button'),
          style: FilledButton.styleFrom(minimumSize: const Size(48, 48)),
          onPressed: _previewing ? null : _preview,
          child: Text(_previewing ? '正在预览' : '校验并预览'),
        ),
      ],
    ),
  );
}
