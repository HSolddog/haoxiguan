import 'package:flutter/material.dart';

import '../models/habit.dart';
import '../state/habit_controller.dart';

class TrashScreen extends StatelessWidget {
  const TrashScreen({super.key, required this.controller, this.onExport});
  final HabitController controller;
  final VoidCallback? onExport;
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
                          onPressed: () => controller.restoreHabit(habit.id),
                          child: const Text('恢复习惯'),
                        ),
                        TextButton(
                          onPressed: () async {
                            final confirmed = await showDialog<bool>(
                              context: context,
                              builder: (context) => AlertDialog(
                                title: Text('永久删除“${habit.title}”？'),
                                content: Text(
                                  '将永久删除 ${habit.entries.where((e) => !e.deleted).length} 条记录、${habit.notes.length} 条备注及计划历史，无法撤销。需要保留时，请先到“数据”页导出完整备份。',
                                ),
                                actions: [
                                  if (onExport != null)
                                    TextButton(
                                      key: const Key('export-before-delete'),
                                      onPressed: () {
                                        Navigator.pop(context, false);
                                        onExport!();
                                      },
                                      child: const Text('先导出完整备份'),
                                    ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.pop(context, false),
                                    child: const Text('取消，保留数据'),
                                  ),
                                  FilledButton(
                                    onPressed: () =>
                                        Navigator.pop(context, true),
                                    child: const Text('永久删除'),
                                  ),
                                ],
                              ),
                            );
                            if (confirmed == true) {
                              await controller.permanentlyDeleteHabit(habit.id);
                            }
                          },
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
