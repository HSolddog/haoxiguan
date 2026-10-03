import 'package:flutter/material.dart';

import '../services/backup_preview.dart';
import '../state/habit_controller.dart';

class BackupRestoreDialog extends StatefulWidget {
  const BackupRestoreDialog({
    super.key,
    required this.controller,
    required this.raw,
    required this.preview,
  });
  final HabitController controller;
  final String raw;
  final BackupPreview preview;
  @override
  State<BackupRestoreDialog> createState() => BackupRestoreDialogState();
}

class BackupRestoreDialogState extends State<BackupRestoreDialog> {
  bool _saving = false;
  bool _preserveLegacyText = false;
  String? _error;
  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_saving,
    child: AlertDialog(
      title: const Text('恢复预览'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.preview.summary,
              key: const Key('restore-preview-summary'),
            ),
            const SizedBox(height: 16),
            Text(
              '将替换本机 ${widget.controller.habits.length} 个习惯。恢复前会自动保护当前数据；保护失败不会替换。\n\n'
              '恢复为空间副本，默认不连接原同步服务；WebDAV 自动备份需要为新空间重新配置。设备授权、存储密码和系统权限不会导入。',
            ),
            if (widget.preview.requiresCompatibilityConfirmation) ...[
              const SizedBox(height: 16),
              Text(
                widget.preview.compatibilitySummary,
                key: const Key('restore-legacy-text-summary'),
              ),
              CheckboxListTile(
                key: const Key('restore-preserve-legacy-text'),
                value: _preserveLegacyText,
                controlAffinity: ListTileControlAffinity.leading,
                contentPadding: EdgeInsets.zero,
                title: const Text('完整保留这些历史文本'),
                subtitle: const Text('保留全部原文。今后编辑时，标题需为 1–80 个字符，备注最多 2000 字。'),
                onChanged: _saving
                    ? null
                    : (value) => setState(() => _preserveLegacyText = value!),
              ),
            ],
            if (_saving) const LinearProgressIndicator(),
            if (_error != null) Text(_error!, key: const Key('restore-error')),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _saving ? null : () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          key: const Key('confirm-restore-button'),
          onPressed:
              _saving ||
                  (widget.preview.requiresCompatibilityConfirmation &&
                      !_preserveLegacyText)
              ? null
              : () async {
                  setState(() {
                    _saving = true;
                    _error = null;
                  });
                  final success =
                      widget.preview.requiresCompatibilityConfirmation
                      ? await widget.controller.restoreCompatibleBackup(
                          widget.raw,
                        )
                      : await widget.controller.importJson(widget.raw);
                  if (!context.mounted) return;
                  if (success) {
                    Navigator.pop(context, true);
                  } else {
                    setState(() {
                      _saving = false;
                      _error =
                          '${widget.controller.saveError ?? '恢复未完成'}\n已保留这份预览，可重试或取消。';
                    });
                  }
                },
          child: Text(_error == null ? '保护当前数据并恢复' : '重试恢复'),
        ),
      ],
    ),
  );
}
