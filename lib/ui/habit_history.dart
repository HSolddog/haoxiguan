import 'package:flutter/material.dart';

import '../models/habit.dart';
import '../models/history_review.dart';
import '../models/plan.dart';
import '../state/habit_controller.dart';

class HabitHistorySummary extends StatelessWidget {
  const HabitHistorySummary({
    super.key,
    required this.controller,
    required this.habit,
    required this.days,
  });
  final HabitController controller;
  final Habit habit;
  final int days;

  @override
  Widget build(BuildContext context) {
    final groups = controller.historyGroups(habit, days: days);
    final unit = reviewUnit(reviewKind(habit.planOn(controller.today)));
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('按周期结束日纳入已结算历史；日、周、月分别计算。'),
        if (habit.effectivePlans.any((p) => p.legacyInferred))
          const Text('升级前目标历史可能不完整；推断的旧计划已保留标记。'),
        if (groups.isEmpty) const Text('暂无已结算计划'),
        for (final group in groups) ...[
          const SizedBox(height: 12),
          Text(
            '${_kindLabel(group.kind)} · ${group.rate == null ? '暂无已结算计划' : '${(group.rate! * 100).round()}%（${group.completed}/${group.expected}）'}',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (group.kind != 'day' && group.settled.isNotEmpty)
            ExpansionTile(
              key: PageStorageKey('settled-${habit.id}-${group.kind}-$days'),
              tilePadding: EdgeInsets.zero,
              title: Text('查看 ${group.settled.length} 个已结算周期'),
              children: [
                for (final r in group.settled.reversed)
                  _PeriodRow(result: r, inProgress: false),
              ],
            ),
          for (final r in group.inProgress)
            _PeriodRow(result: r, inProgress: true),
        ],
        const SizedBox(height: 12),
        const Text('连续统计采用当前同类计划，休息周期跳过。'),
        Wrap(
          spacing: 20,
          runSpacing: 8,
          children: [
            Text('当前连续 ${controller.currentStreak(habit)} $unit'),
            Text('历史最佳 ${controller.bestStreak(habit)} $unit'),
          ],
        ),
      ],
    );
  }
}

String _kindLabel(String kind) => switch (kind) {
  'week' => '周计划',
  'month' => '月计划',
  _ => '日计划',
};

class _PeriodRow extends StatelessWidget {
  const _PeriodRow({required this.result, required this.inProgress});
  final PlanResult result;
  final bool inProgress;
  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '${dateKey(result.start)}${result.start == result.end ? '' : ' 至 ${dateKey(result.end)}'}\n'
        '完成 ${result.completed} 天 / 实际目标 ${result.expected} 天 · '
        '${inProgress
            ? '进行中（未结算）'
            : result.met
            ? '已达标'
            : '未达标'}'
        '${result.expected < result.plan.periodTarget ? '\n配置目标 ${result.plan.periodTarget} 天；本周期仅 ${result.availableDays} 个有效日期。开始前、暂停、休息和归档区间均已排除。' : ''}',
      ),
    ),
  );
}

Future<bool> showStartDateCorrection(
  BuildContext context,
  HabitController controller,
  Habit habit,
) async {
  final date = await showDatePicker(
    context: context,
    initialDate: calendarDay(habit.createdAt, -1),
    firstDate: DateTime.utc(1900),
    lastDate: calendarDay(habit.createdAt, -1),
    helpText: '选择真实的历史开始日期',
  );
  if (date == null || !context.mounted) return false;
  final preview = controller.previewStartDateCorrection(habit.id, date);
  var saving = false;
  String? error;
  return await showDialog<bool>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setState) => PopScope(
            canPop: !saving,
            child: AlertDialog(
              title: const Text('历史校正影响预览'),
              content: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('开始日期：${dateKey(habit.createdAt)} → ${dateKey(date)}'),
                    Text(
                      '新增可补录范围：${dateKey(preview.from)} 至 ${dateKey(preview.through)}',
                    ),
                    const SizedBox(height: 12),
                    const Text(
                      '这段历史沿用最早的计划。历史应完成数量和首个周期目标可能增加；现有记录、备注和实际录入时间保持不变。',
                    ),
                    for (final kind in const ['day', 'week', 'month']) ...[
                      Text(
                        '${_kindLabel(kind)}已结算：'
                        '${_denominator(preview.before, kind)} → ${_denominator(preview.after, kind)}',
                      ),
                      for (final r
                          in preview.after
                              .where((g) => g.kind == kind)
                              .expand((g) => [...g.settled, ...g.inProgress])
                              .where((r) => !r.start.isAfter(habit.createdAt)))
                        if (r.plan.flexible)
                          _PeriodRow(
                            result: r,
                            inProgress: !r.end.isBefore(controller.today),
                          ),
                    ],
                    if (error != null)
                      Text(
                        error!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: saving
                      ? null
                      : () => Navigator.pop(context, false),
                  child: const Text('取消'),
                ),
                FilledButton(
                  key: const Key('confirm-start-correction'),
                  onPressed: saving
                      ? null
                      : () async {
                          setState(() => saving = true);
                          final saved = await controller
                              .confirmStartDateCorrection(preview);
                          if (!context.mounted) return;
                          if (saved) {
                            Navigator.pop(context, true);
                          } else {
                            setState(() {
                              saving = false;
                              error = controller.saveError;
                            });
                          }
                        },
                  child: Text(saving ? '正在保存' : '确认校正，再补录'),
                ),
              ],
            ),
          ),
        ),
      ) ??
      false;
}

String _denominator(List<HistoryGroup> groups, String kind) {
  final group = groups.where((g) => g.kind == kind).firstOrNull;
  return '${group?.completed ?? 0}/${group?.expected ?? 0}';
}
