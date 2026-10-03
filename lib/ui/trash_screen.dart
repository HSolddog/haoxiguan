import 'package:flutter/material.dart';

import '../models/habit.dart';
import '../state/habit_controller.dart';

class TrashScreen extends StatefulWidget {
  const TrashScreen({super.key, required this.controller, this.onExport});
  final HabitController controller;
  final VoidCallback? onExport;
  @override
  State<TrashScreen> createState() => _TrashScreenState();
}

enum _TrashAction { delete, export }

class _TrashScreenState extends State<TrashScreen> {
  bool _busy = false;
  String? _error;
  HabitController get controller => widget.controller;

  Future<void> _restore(String id) async {
    if (!mounted || _busy) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final saved = await controller.restoreHabit(id);
      if (mounted && route?.isCurrent == true && !saved) {
        setState(() => _error = controller.saveError ?? '恢复未完成，原数据已保留，请重试。');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _delete(Habit habit) async {
    if (!mounted || _busy) return;
    final route = ModalRoute.of(context);
    if (route?.isCurrent != true) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var answered = false;
    void answer(BuildContext dialogContext, _TrashAction? result) {
      if (answered ||
          !dialogContext.mounted ||
          ModalRoute.of(dialogContext)?.isCurrent != true) {
        return;
      }
      answered = true;
      Navigator.pop(dialogContext, result);
    }

    try {
      final action = await showDialog<_TrashAction>(
        context: context,
        builder: (context) => AlertDialog(
          title: Text('永久删除“${habit.title}”？'),
          content: Text(
            '将永久删除 ${habit.entries.where((e) => !e.deleted).length} 条记录、${habit.notes.length} 条备注及计划历史，无法撤销。需要保留时，请先到“数据”页导出完整备份。',
          ),
          actions: [
            if (widget.onExport != null)
              TextButton(
                key: const Key('export-before-delete'),
                onPressed: () => answer(context, _TrashAction.export),
                child: const Text('先导出完整备份'),
              ),
            TextButton(
              onPressed: () => answer(context, null),
              child: const Text('取消，保留数据'),
            ),
            FilledButton(
              onPressed: () => answer(context, _TrashAction.delete),
              child: const Text('永久删除'),
            ),
          ],
        ),
      );
      if (!mounted || route?.isCurrent != true) return;
      if (action == _TrashAction.export) {
        widget.onExport?.call();
      } else if (action == _TrashAction.delete) {
        final saved = await controller.permanentlyDeleteHabit(habit.id);
        if (mounted && route?.isCurrent == true && !saved) {
          setState(() => _error = controller.saveError ?? '删除未完成，原数据已保留，请重试。');
        }
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => AnimatedBuilder(
    animation: controller,
    builder: (context, _) => Scaffold(
      appBar: AppBar(title: const Text('回收站')),
      body: ListView(
        padding: const EdgeInsets.all(20),
        children: [
          const Text(
            '删除的习惯至少保留 30 天。当前版本不会自动清理，你可以恢复或明确永久删除。外部备份中的副本不受这里的删除影响。',
          ),
          const SizedBox(height: 16),
          if (_error != null) Semantics(liveRegion: true, child: Text(_error!)),
          if (controller.trashedHabits.isEmpty)
            const Center(child: Text('回收站是空的')),
          for (final habit in controller.trashedHabits)
            Card(
              child: Padding(
                padding: const EdgeInsets.all(12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '${habit.emoji} ${habit.title}',
                      style: Theme.of(context).textTheme.titleMedium,
                    ),
                    Text(
                      '移入于 ${dateKey(habit.deletedAt!)} · ${habit.entries.where((e) => !e.deleted).length} 条记录',
                    ),
                    Wrap(
                      spacing: 12,
                      children: [
                        TextButton(
                          onPressed: _busy ? null : () => _restore(habit.id),
                          child: const Text('恢复习惯'),
                        ),
                        TextButton(
                          onPressed: _busy ? null : () => _delete(habit),
                          child: const Text('永久删除'),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    ),
  );
}
