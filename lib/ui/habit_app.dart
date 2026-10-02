import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../models/habit.dart';
import '../state/habit_controller.dart';
import '../models/record_entry.dart';
import 'data_screen.dart';
import 'record_editor.dart';
import 'trash_screen.dart';

const _warmBackground = Color(0xFFF7F5EF);

class HabitApp extends StatelessWidget {
  HabitApp({super.key, required this.controller});
  final _navigator = GlobalKey<NavigatorState>();

  final HabitController controller;

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final request = controller.takePendingRecord();
        if (request != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            final context = _navigator.currentContext;
            final habit = controller.habitById(request.habitId);
            if (context != null && habit != null) {
              showRecordEditor(context, controller, habit, request.date);
            }
          });
        }
        return MaterialApp(
          navigatorKey: _navigator,
          title: '好习惯',
          debugShowCheckedModeBanner: false,
          locale: const Locale('zh', 'CN'),
          supportedLocales: const <Locale>[Locale('zh', 'CN'), Locale('en')],
          localizationsDelegates: const <LocalizationsDelegate<dynamic>>[
            GlobalMaterialLocalizations.delegate,
            GlobalWidgetsLocalizations.delegate,
            GlobalCupertinoLocalizations.delegate,
          ],
          themeMode: switch (controller.appearanceMode) {
            'dark' => ThemeMode.dark,
            'light' => ThemeMode.light,
            _ => ThemeMode.system,
          },
          theme: _theme(Brightness.light, Color(controller.themeColorValue)),
          darkTheme: _theme(Brightness.dark, Color(controller.themeColorValue)),
          builder: (context, child) => Column(
            children: [
              if (controller.saveError != null)
                Material(
                  color: Theme.of(context).colorScheme.errorContainer,
                  child: SafeArea(
                    bottom: false,
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(
                        children: [
                          Expanded(child: Text(controller.saveError!)),
                          TextButton(
                            onPressed: controller.dismissSaveError,
                            child: const Text('知道了'),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              Expanded(child: child ?? const SizedBox.shrink()),
            ],
          ),
          home: controller.loaded
              ? HomeShell(controller: controller)
              : _RecoveryScreen(controller: controller),
        );
      },
    );
  }
}

class _RecoveryScreen extends StatelessWidget {
  const _RecoveryScreen({required this.controller});
  final HabitController controller;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('好习惯')),
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (controller.loading)
              const CircularProgressIndicator()
            else ...[
              const Icon(Icons.shield_outlined, size: 56),
              const SizedBox(height: 20),
              Text(controller.loadError ?? '正在准备本地数据'),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: controller.load,
                child: const Text('重新检查'),
              ),
              if (controller.canRecoverBackup)
                TextButton(
                  onPressed: () async {
                    final confirmed = await showDialog<bool>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('恢复保护副本？'),
                        content: const Text(
                          '保护副本可能较旧，最近记录可能不在其中。恢复前会保留当前源数据；不会删除损坏的源文件。',
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context, false),
                            child: const Text('取消'),
                          ),
                          FilledButton(
                            onPressed: () => Navigator.pop(context, true),
                            child: const Text('确认恢复'),
                          ),
                        ],
                      ),
                    );
                    if (confirmed == true) await controller.recoverBackup();
                  },
                  child: const Text('从保护副本恢复'),
                ),
              TextButton(
                onPressed: () async {
                  try {
                    final sources = await controller.rawSources();
                    if (!context.mounted) return;
                    await showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('原始数据（包含私人记录）'),
                        content: SizedBox(
                          width: 600,
                          child: SingleChildScrollView(
                            child: SelectableText(
                              sources.entries
                                  .map((e) => '${e.key}\n${e.value}')
                                  .join('\n\n'),
                            ),
                          ),
                        ),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('关闭'),
                          ),
                        ],
                      ),
                    );
                  } on Object {
                    if (context.mounted) {
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text('暂时无法读取源文件。请保留应用数据，勿卸载或清除。'),
                        ),
                      );
                    }
                  }
                },
                child: const Text('查看原始数据'),
              ),
            ],
          ],
        ),
      ),
    ),
  );
}

ThemeData _theme(Brightness brightness, Color seedColor) {
  final dark = brightness == Brightness.dark;
  final scheme = ColorScheme.fromSeed(
    seedColor: seedColor,
    brightness: brightness,
    surface: dark ? const Color(0xFF171B18) : _warmBackground,
  );
  return ThemeData(
    useMaterial3: true,
    brightness: brightness,
    colorScheme: scheme,
    scaffoldBackgroundColor: dark ? const Color(0xFF111411) : _warmBackground,
    cardTheme: CardThemeData(
      elevation: 0,
      color: dark ? const Color(0xFF1D221E) : Colors.white,
      margin: EdgeInsets.zero,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
    ),
    inputDecorationTheme: InputDecorationTheme(
      filled: true,
      fillColor: dark ? const Color(0xFF242A25) : const Color(0xFFF0F1EB),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide.none,
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(18),
        borderSide: BorderSide(color: scheme.primary, width: 1.5),
      ),
    ),
    navigationBarTheme: NavigationBarThemeData(
      height: 72,
      backgroundColor: dark ? const Color(0xFF181C19) : Colors.white,
      indicatorColor: scheme.primaryContainer,
      labelTextStyle: WidgetStatePropertyAll(
        TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: scheme.onSurface,
        ),
      ),
    ),
    snackBarTheme: SnackBarThemeData(
      behavior: SnackBarBehavior.floating,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
    ),
  );
}

class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.controller});

  final HabitController controller;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _index = 0;

  @override
  Widget build(BuildContext context) {
    final pages = <Widget>[
      TodayScreen(controller: widget.controller),
      HabitsScreen(controller: widget.controller),
      ReviewScreen(controller: widget.controller),
      SettingsScreen(controller: widget.controller),
    ];
    return Scaffold(
      body: IndexedStack(index: _index, children: pages),
      floatingActionButton: _index <= 1
          ? FloatingActionButton.extended(
              key: const Key('add-habit-button'),
              onPressed: () => showAddHabitSheet(context, widget.controller),
              icon: const Icon(Icons.add_rounded),
              label: const Text('新习惯'),
            )
          : null,
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (value) => setState(() => _index = value),
        destinations: const <NavigationDestination>[
          NavigationDestination(
            icon: Icon(Icons.today_outlined),
            selectedIcon: Icon(Icons.today_rounded),
            label: '今日',
          ),
          NavigationDestination(
            icon: Icon(Icons.checklist_rounded),
            selectedIcon: Icon(Icons.fact_check_rounded),
            label: '习惯',
          ),
          NavigationDestination(
            icon: Icon(Icons.insights_outlined),
            selectedIcon: Icon(Icons.insights_rounded),
            label: '回顾',
          ),
          NavigationDestination(
            icon: Icon(Icons.person_outline_rounded),
            selectedIcon: Icon(Icons.person_rounded),
            label: '数据',
          ),
        ],
      ),
    );
  }
}

class TodayScreen extends StatelessWidget {
  const TodayScreen({super.key, required this.controller});

  final HabitController controller;

  @override
  Widget build(BuildContext context) {
    final today = controller.today;
    final habits = controller.todayHabits;
    final groupedHabits = <String, List<Habit>>{};
    for (final habit in habits) {
      groupedHabits.putIfAbsent(habit.category, () => <Habit>[]).add(habit);
    }
    final completed = controller.completedCount(today);
    final progress = controller.dayProgress(today);
    return SafeArea(
      child: CustomScrollView(
        key: const PageStorageKey<String>('today-scroll'),
        slivers: <Widget>[
          SliverPadding(
            padding: const EdgeInsets.fromLTRB(20, 24, 20, 12),
            sliver: SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    _greeting(),
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.8,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    _fullDate(today),
                    style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 22),
                  _ProgressCard(
                    completed: completed,
                    total: habits.length,
                    progress: progress,
                  ),
                  const SizedBox(height: 28),
                  Row(
                    children: <Widget>[
                      Text(
                        '今日应做',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                      const Spacer(),
                      Text(
                        '$completed/${habits.length}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.primary,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
          if (habits.isEmpty && controller.periodHabits.isEmpty)
            SliverFillRemaining(
              hasScrollBody: false,
              child: _EmptyState(
                emoji: '🌱',
                title: '今天没有安排',
                subtitle: '给自己留一点空白，或者创建一个很小的新习惯。',
                actionLabel: '创建第一个习惯',
                onAction: () => showAddHabitSheet(context, controller),
              ),
            )
          else
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 4, 20, 16),
              sliver: SliverList.list(
                children: <Widget>[
                  for (final entry in groupedHabits.entries)
                    _TodayCategorySection(
                      category: entry.key,
                      habits: entry.value,
                      date: today,
                      controller: controller,
                    ),
                  if (habits.isNotEmpty && completed == habits.length)
                    const _AllDoneCard(),
                  if (controller.periodHabits.isNotEmpty) ...[
                    const SizedBox(height: 24),
                    Text(
                      '本周 / 本月可安排',
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 8),
                      child: Text('按整个周期达标；未记录的一天不单独算失败。'),
                    ),
                    for (final habit in controller.periodHabits)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 12),
                        child: HabitCard(
                          habit: habit,
                          date: today,
                          controller: controller,
                        ),
                      ),
                  ],
                  const SizedBox(height: 110),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _TodayCategorySection extends StatelessWidget {
  const _TodayCategorySection({
    required this.category,
    required this.habits,
    required this.date,
    required this.controller,
  });

  final String category;
  final List<Habit> habits;
  final DateTime date;
  final HabitController controller;

  @override
  Widget build(BuildContext context) {
    final completed = habits.where((habit) => habit.isCompletedOn(date)).length;
    final collapsed = controller.isTodayCategoryCollapsed(category);
    return Padding(
      key: Key('today-category-$category'),
      padding: EdgeInsets.only(bottom: collapsed ? 12 : 22),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            key: Key('today-category-toggle-$category'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => controller.toggleTodayCategory(category),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.folder_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      category,
                      style: Theme.of(context).textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                  Text(
                    '$completed/${habits.length}',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    collapsed
                        ? Icons.chevron_right_rounded
                        : Icons.expand_more_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed) ...<Widget>[
            const SizedBox(height: 6),
            for (var index = 0; index < habits.length; index++) ...<Widget>[
              if (index > 0) const SizedBox(height: 12),
              HabitCard(
                habit: habits[index],
                date: date,
                controller: controller,
              ),
            ],
          ],
        ],
      ),
    );
  }
}

class _ProgressCard extends StatelessWidget {
  const _ProgressCard({
    required this.completed,
    required this.total,
    required this.progress,
  });

  final int completed;
  final int total;
  final double progress;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    return Card(
      color: colors.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: <Widget>[
            SizedBox(
              width: 68,
              height: 68,
              child: Stack(
                alignment: Alignment.center,
                children: <Widget>[
                  CircularProgressIndicator(
                    value: total == 0 ? 0 : progress,
                    strokeWidth: 8,
                    strokeCap: StrokeCap.round,
                    backgroundColor: colors.onPrimaryContainer.withValues(
                      alpha: 0.12,
                    ),
                  ),
                  Text(
                    '${(progress * 100).round()}%',
                    style: const TextStyle(fontWeight: FontWeight.w800),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    total == 0
                        ? '今天适合休息'
                        : completed == total
                        ? '今天已经圆满完成'
                        : '慢慢来，完成一点也很好',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                      color: colors.onPrimaryContainer,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Text(
                    total == 0 ? '没有必须完成的任务' : '已完成 $completed 项，共 $total 项',
                    style: TextStyle(
                      color: colors.onPrimaryContainer.withValues(alpha: 0.72),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class HabitCard extends StatelessWidget {
  const HabitCard({
    super.key,
    required this.habit,
    required this.date,
    required this.controller,
  });

  final Habit habit;
  final DateTime date;
  final HabitController controller;

  @override
  Widget build(BuildContext context) {
    final color = Color(habit.colorValue);
    final completed = habit.isCompletedOn(date);
    final note = habit.noteOn(date);
    return Semantics(
      button: true,
      label: '${habit.title}，${completed ? '已完成' : '待完成'}',
      child: Card(
        child: InkWell(
          borderRadius: BorderRadius.circular(24),
          onTap: () => showHabitDetail(context, controller, habit.id),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 14),
            child: Row(
              children: <Widget>[
                Container(
                  width: 52,
                  height: 52,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(17),
                  ),
                  child: Text(
                    habit.emoji,
                    style: const TextStyle(fontSize: 25),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        habit.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(
                              fontWeight: FontWeight.w800,
                              decoration: completed
                                  ? TextDecoration.lineThrough
                                  : null,
                            ),
                      ),
                      if (habit.recordType != 'boolean')
                        Text(
                          '${habit.valueLabel(habit.valueOn(date))} / ${habit.valueLabel(habit.planOn(date).dailyTarget)}',
                        ),
                      if (habit.planOn(date).flexible)
                        Text(
                          '${habit.planOn(date).kind == 'week' ? '本周' : '本月'} ${habit.periodResult(date).completed}/${habit.periodResult(date).expected} 天',
                        ),
                      const SizedBox(height: 5),
                      Row(
                        children: <Widget>[
                          Icon(
                            habit.reminderTime == null
                                ? Icons.calendar_today_outlined
                                : Icons.notifications_none_rounded,
                            size: 15,
                            color: Theme.of(
                              context,
                            ).colorScheme.onSurfaceVariant,
                          ),
                          const SizedBox(width: 5),
                          Flexible(
                            child: Text(
                              habit.reminderTime ?? executionLabel(habit),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: Theme.of(context).textTheme.bodySmall
                                  ?.copyWith(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurfaceVariant,
                                  ),
                            ),
                          ),
                          if (note != null) ...<Widget>[
                            const SizedBox(width: 8),
                            Icon(
                              Icons.sticky_note_2_outlined,
                              size: 15,
                              color: color,
                            ),
                          ],
                        ],
                      ),
                    ],
                  ),
                ),
                IconButton(
                  tooltip: '记录备注',
                  onPressed: () =>
                      _showNoteDialog(context, controller, habit, date),
                  icon: const Icon(Icons.edit_note_rounded),
                ),
                AnimatedSwitcher(
                  duration: const Duration(milliseconds: 220),
                  child: IconButton.filled(
                    key: Key('complete-${habit.id}-$completed'),
                    tooltip: habit.recordType == 'boolean'
                        ? (completed ? '撤销完成' : '完成')
                        : '记录数值',
                    style: IconButton.styleFrom(
                      backgroundColor: completed
                          ? color
                          : color.withValues(alpha: 0.12),
                      foregroundColor: completed ? Colors.white : color,
                    ),
                    onPressed: () {
                      HapticFeedback.lightImpact();
                      if (habit.recordType == 'boolean') {
                        controller.toggleCompletion(habit.id, date);
                      } else {
                        showRecordEditor(context, controller, habit, date);
                      }
                    },
                    icon: Icon(
                      habit.recordType != 'boolean'
                          ? Icons.add_rounded
                          : completed
                          ? Icons.check_rounded
                          : Icons.circle_outlined,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class HabitsScreen extends StatelessWidget {
  const HabitsScreen({super.key, required this.controller});

  final HabitController controller;

  @override
  Widget build(BuildContext context) {
    final active = controller.activeHabits;
    final archived = controller.archivedHabits;
    return SafeArea(
      child: ListView(
        key: const PageStorageKey<String>('habits-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 120),
        children: <Widget>[
          Text(
            '我的习惯',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '把目标变小，把重复变得容易。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          if (active.isEmpty)
            _EmptyState(
              emoji: '🪴',
              title: '还没有进行中的习惯',
              subtitle: '从一个每天两分钟就能完成的小行动开始。',
              actionLabel: '创建习惯',
              onAction: () => showAddHabitSheet(context, controller),
            )
          else
            for (final category in controller.categories)
              _HabitsCategorySection(
                category: category,
                activeHabits: active,
                controller: controller,
              ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: Text('回收站 · ${controller.trashedHabits.length}'),
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute<void>(
                builder: (_) => TrashScreen(controller: controller),
              ),
            ),
          ),
          if (archived.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 4),
              title: Text('已归档 · ${archived.length}'),
              children: archived
                  .map(
                    (habit) => ListTile(
                      leading: Text(
                        habit.emoji,
                        style: const TextStyle(fontSize: 24),
                      ),
                      title: Text(habit.title),
                      trailing: Wrap(
                        children: <Widget>[
                          TextButton(
                            onPressed: () =>
                                controller.toggleArchived(habit.id),
                            child: const Text('恢复'),
                          ),
                          IconButton(
                            tooltip: '移入回收站',
                            onPressed: () =>
                                _confirmDeleteHabit(context, controller, habit),
                            icon: const Icon(Icons.delete_outline_rounded),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
            ),
          ],
        ],
      ),
    );
  }
}

class _HabitsCategorySection extends StatelessWidget {
  const _HabitsCategorySection({
    required this.category,
    required this.activeHabits,
    required this.controller,
  });

  final String category;
  final List<Habit> activeHabits;
  final HabitController controller;

  @override
  Widget build(BuildContext context) {
    final habits = activeHabits
        .where((habit) => habit.category == category)
        .toList(growable: false);
    final collapsed = controller.isHabitCategoryCollapsed(category);
    return Padding(
      key: Key('habits-category-$category'),
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        children: <Widget>[
          InkWell(
            key: Key('habits-category-toggle-$category'),
            borderRadius: BorderRadius.circular(14),
            onTap: () => controller.toggleHabitCategory(category),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(4, 12, 4, 10),
              child: Row(
                children: <Widget>[
                  Icon(
                    Icons.folder_outlined,
                    size: 18,
                    color: Theme.of(context).colorScheme.primary,
                  ),
                  const SizedBox(width: 7),
                  Expanded(
                    child: Text(
                      category,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    '${habits.length}',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    collapsed
                        ? Icons.chevron_right_rounded
                        : Icons.expand_more_rounded,
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ],
              ),
            ),
          ),
          if (!collapsed)
            for (final habit in habits)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: _ManageHabitCard(
                  habit: habit,
                  controller: controller,
                  index: activeHabits.indexOf(habit),
                  total: activeHabits.length,
                ),
              ),
        ],
      ),
    );
  }
}

class _ManageHabitCard extends StatelessWidget {
  const _ManageHabitCard({
    required this.habit,
    required this.controller,
    required this.index,
    required this.total,
  });

  final Habit habit;
  final HabitController controller;
  final int index;
  final int total;

  @override
  Widget build(BuildContext context) {
    final color = Color(habit.colorValue);
    return Card(
      key: Key('manage-habit-${habit.id}'),
      child: InkWell(
        borderRadius: BorderRadius.circular(24),
        onTap: () => showHabitDetail(context, controller, habit.id),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: <Widget>[
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.14),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Text(habit.emoji, style: const TextStyle(fontSize: 24)),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            habit.title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                        if (habit.isPaused) ...<Widget>[
                          const SizedBox(width: 8),
                          _SmallBadge(label: '已暂停', color: color),
                        ],
                        const SizedBox(width: 8),
                        Flexible(
                          child: _SmallBadge(
                            label: habit.category,
                            color: color,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 5),
                    Text(
                      '${executionLabel(habit)} · 近30天 ${(controller.completionRate(habit) * 100).round()}%',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              PopupMenuButton<String>(
                tooltip: '管理习惯',
                onSelected: (value) {
                  switch (value) {
                    case 'edit':
                      showAddHabitSheet(context, controller, habit: habit);
                      break;
                    case 'up':
                      controller.reorderActive(index, index - 1);
                      break;
                    case 'down':
                      controller.reorderActive(index, index + 2);
                      break;
                    case 'delete':
                      _confirmDeleteHabit(context, controller, habit);
                      break;
                  }
                },
                itemBuilder: (context) => <PopupMenuEntry<String>>[
                  const PopupMenuItem<String>(
                    value: 'edit',
                    child: ListTile(
                      leading: Icon(Icons.edit_outlined),
                      title: Text('编辑'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                  if (index > 0)
                    const PopupMenuItem<String>(
                      value: 'up',
                      child: ListTile(
                        leading: Icon(Icons.arrow_upward_rounded),
                        title: Text('上移'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  if (index < total - 1)
                    const PopupMenuItem<String>(
                      value: 'down',
                      child: ListTile(
                        leading: Icon(Icons.arrow_downward_rounded),
                        title: Text('下移'),
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  const PopupMenuDivider(),
                  const PopupMenuItem<String>(
                    value: 'delete',
                    child: ListTile(
                      leading: Icon(Icons.delete_outline_rounded),
                      title: Text('删除'),
                      contentPadding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class ReviewScreen extends StatelessWidget {
  const ReviewScreen({super.key, required this.controller});

  final HabitController controller;

  @override
  Widget build(BuildContext context) {
    final habits = controller.habits;
    final days = controller.reviewDays;
    final completed = controller.completedTotalInRange(days: days);
    final scheduled = controller.expectedTotalInRange(days: days);
    final rate = scheduled == 0 ? 0.0 : completed / scheduled;
    final periodLabel = _reviewPeriodLabel(days);
    return SafeArea(
      child: ListView(
        key: const PageStorageKey<String>('review-scroll'),
        padding: const EdgeInsets.fromLTRB(20, 24, 20, 40),
        children: <Widget>[
          Text(
            '回顾',
            style: Theme.of(context).textTheme.headlineMedium?.copyWith(
              fontWeight: FontWeight.w800,
              letterSpacing: -0.8,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            '截至昨天已结算；包括归档和回收站历史。',
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 24),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<int>(
              segments: const <ButtonSegment<int>>[
                ButtonSegment(value: 7, label: Text('周')),
                ButtonSegment(value: 30, label: Text('月')),
                ButtonSegment(value: 90, label: Text('季度')),
                ButtonSegment(value: 365, label: Text('年')),
              ],
              selected: <int>{days},
              onSelectionChanged: (value) =>
                  controller.setReviewDays(value.first),
            ),
          ),
          const SizedBox(height: 18),
          Row(
            children: <Widget>[
              Expanded(
                child: _MetricCard(
                  icon: Icons.auto_graph_rounded,
                  value: scheduled == 0 ? '—' : '${(rate * 100).round()}%',
                  label: '已结算日计划达标率',
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: _MetricCard(
                  icon: Icons.check_circle_outline_rounded,
                  value: '$completed',
                  label: '已结算达标日',
                ),
              ),
            ],
          ),
          const SizedBox(height: 26),
          Text(
            '$periodLabel日计划日历',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(18),
              child: _Heatmap(controller: controller, days: days),
            ),
          ),
          const SizedBox(height: 26),
          Text(
            '每个习惯',
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 12),
          ...habits.map(
            (habit) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _HabitInsightCard(
                habit: habit,
                controller: controller,
                days: days,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Heatmap extends StatelessWidget {
  const _Heatmap({required this.controller, required this.days});

  final HabitController controller;
  final int days;

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).colorScheme;
    final dates = List<DateTime>.generate(
      days,
      (index) => controller.today.subtract(Duration(days: days - 1 - index)),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 7,
            crossAxisSpacing: 8,
            mainAxisSpacing: 8,
          ),
          itemCount: dates.length,
          itemBuilder: (context, index) {
            final day = dates[index];
            final progress = controller.dayProgress(day);
            final scheduled = controller.scheduledCount(day);
            return Tooltip(
              message:
                  '${day.month}月${day.day}日 · ${(progress * 100).round()}%',
              child: Container(
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: scheduled == 0
                      ? colors.surfaceContainerHighest
                      : Color.lerp(
                          colors.primaryContainer,
                          colors.primary,
                          progress,
                        ),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '${day.day}',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: progress > 0.55
                        ? colors.onPrimary
                        : colors.onSurfaceVariant,
                  ),
                ),
              ),
            );
          },
        ),
        const SizedBox(height: 12),
        Text(
          '颜色越深，代表当天完成比例越高。',
          style: Theme.of(
            context,
          ).textTheme.bodySmall?.copyWith(color: colors.onSurfaceVariant),
        ),
      ],
    );
  }
}

class _HabitInsightCard extends StatelessWidget {
  const _HabitInsightCard({
    required this.habit,
    required this.controller,
    required this.days,
  });

  final Habit habit;
  final HabitController controller;
  final int days;

  @override
  Widget build(BuildContext context) {
    final color = Color(habit.colorValue);
    final rate = controller.completionRate(habit, days: days);
    return Card(
      child: InkWell(
        key: Key('review-habit-${habit.id}'),
        borderRadius: BorderRadius.circular(24),
        onTap: () => showHabitDetail(context, controller, habit.id),
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Column(
            children: <Widget>[
              Row(
                children: <Widget>[
                  Text(habit.emoji, style: const TextStyle(fontSize: 25)),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      habit.title,
                      style: const TextStyle(fontWeight: FontWeight.w800),
                    ),
                  ),
                  Text(
                    '${(rate * 100).round()}%',
                    style: TextStyle(fontWeight: FontWeight.w800, color: color),
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.chevron_right_rounded, size: 20),
                ],
              ),
              const SizedBox(height: 14),
              LinearProgressIndicator(
                value: rate,
                minHeight: 8,
                borderRadius: BorderRadius.circular(8),
                color: color,
                backgroundColor: color.withValues(alpha: 0.12),
              ),
              const SizedBox(height: 12),
              Row(
                children: <Widget>[
                  Text(
                    '当前连续 ${controller.currentStreak(habit)} ${habit.planOn(controller.today).kind == 'week'
                        ? '周'
                        : habit.planOn(controller.today).kind == 'month'
                        ? '月'
                        : '次计划'}',
                  ),
                  const Spacer(),
                  Text('最佳 ${controller.bestStreak(habit)} 次'),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _MetricCard extends StatelessWidget {
  const _MetricCard({
    required this.icon,
    required this.value,
    required this.label,
  });

  final IconData icon;
  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 14),
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 3),
            Text(
              label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class SettingsScreen extends StatelessWidget {
  const SettingsScreen({super.key, required this.controller});
  final HabitController controller;
  @override
  Widget build(BuildContext context) => DataScreen(
    controller: controller,
    onTheme: () => _showThemeDialog(context, controller),
    onReview: () => _showReviewPeriodDialog(context, controller),
    onLegacyRestore: () => _showImportDialog(context, controller),
  );
}

class _AllDoneCard extends StatelessWidget {
  const _AllDoneCard();

  @override
  Widget build(BuildContext context) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(22),
        child: Row(
          children: <Widget>[
            const Text('✨', style: TextStyle(fontSize: 30)),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    '今天已经很好了',
                    style: Theme.of(context).textTheme.titleMedium?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '去享受完成后的轻松吧。',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.emoji,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  final String emoji;
  final String title;
  final String subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          Text(emoji, style: const TextStyle(fontSize: 54)),
          const SizedBox(height: 16),
          Text(
            title,
            textAlign: TextAlign.center,
            style: Theme.of(
              context,
            ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 18),
          FilledButton.tonal(onPressed: onAction, child: Text(actionLabel)),
        ],
      ),
    );
  }
}

class _SmallBadge extends StatelessWidget {
  const _SmallBadge({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: color,
        ),
      ),
    );
  }
}

Future<void> showAddHabitSheet(
  BuildContext context,
  HabitController controller, {
  Habit? habit,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => AddHabitSheet(controller: controller, habit: habit),
  );
}

class AddHabitSheet extends StatefulWidget {
  const AddHabitSheet({super.key, required this.controller, this.habit});

  final HabitController controller;
  final Habit? habit;

  @override
  State<AddHabitSheet> createState() => _AddHabitSheetState();
}

class _AddHabitSheetState extends State<AddHabitSheet> {
  static const _emojis = <String>[
    '🌱',
    '📖',
    '💧',
    '🏃',
    '🧘',
    '✍️',
    '🥗',
    '🌙',
    '☀️',
    '⏰',
    '🎯',
    '💪',
    '🚴',
    '🏊',
    '🧗',
    '⚽',
    '🏸',
    '🎵',
    '🎨',
    '📷',
    '💻',
    '📝',
    '🗣️',
    '🧠',
    '💊',
    '🪥',
    '🧹',
    '🍎',
    '🥛',
    '☕',
    '🚭',
    '💰',
    '📵',
    '🛏️',
    '🙏',
    '❤️',
    '👨‍👩‍👧',
    '🌳',
    '🐾',
    '✨',
  ];
  static const _colors = <int>[
    0xFF5F8068,
    0xFF4D7C91,
    0xFFD1815C,
    0xFF806A9A,
    0xFFB18B40,
    0xFFBA4A68,
    0xFF6B5EA8,
    0xFF31857A,
    0xFF2F6DB0,
    0xFFE05D44,
    0xFF9A6B3D,
    0xFF5C6F7B,
  ];

  final _titleController = TextEditingController();
  final _categoryController = TextEditingController();
  final _unitController = TextEditingController(text: '次');
  final _dailyTargetController = TextEditingController(text: '1');
  final _targetSecondsController = TextEditingController(text: '0');
  String _recordType = 'boolean';
  Set<int> _weekdays = {1, 2, 3, 4, 5, 6, 7};
  late String _emoji;
  late int _color;
  late String _scheduleType;
  late int _scheduleCount;
  TimeOfDay? _reminder;
  bool _saving = false;

  bool get _editing => widget.habit != null;

  @override
  void initState() {
    super.initState();
    final habit = widget.habit;
    _titleController.text = habit?.title ?? '';
    _categoryController.text = habit?.category ?? '未分类';
    _recordType = habit?.recordType ?? 'boolean';
    _weekdays = {
      ...habit?.weekdays ?? {1, 2, 3, 4, 5, 6, 7},
    };
    _unitController.text = habit?.unit ?? '次';
    _dailyTargetController.text = habit == null
        ? '1'
        : habit.recordType == 'duration'
        ? '${habit.dailyTarget ~/ 60}'
        : formatFixed(habit.dailyTarget, scale: habit.scale);
    _targetSecondsController.text = habit?.recordType == 'duration'
        ? '${habit!.dailyTarget % 60}'
        : '0';
    _emoji = habit?.emoji ?? _emojis.first;
    _color = habit?.colorValue ?? _colors.first;
    _scheduleType = habit?.scheduleType ?? 'daily';
    _scheduleCount = habit?.scheduleCount ?? 1;
    final reminder = habit?.reminderTime?.split(':');
    if (reminder != null && reminder.length == 2) {
      _reminder = TimeOfDay(
        hour: int.parse(reminder[0]),
        minute: int.parse(reminder[1]),
      );
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _categoryController.dispose();
    _unitController.dispose();
    _dailyTargetController.dispose();
    _targetSecondsController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedPadding(
      duration: const Duration(milliseconds: 180),
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              _editing ? '编辑习惯' : '创建一个小习惯',
              style: Theme.of(
                context,
              ).textTheme.headlineSmall?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 6),
            Text(
              '从足够容易开始，比一开始做到完美更重要。',
              style: TextStyle(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 20),
            TextField(
              key: const Key('habit-title-field'),
              controller: _titleController,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(
                labelText: '习惯名称',
                hintText: '例如：睡前阅读 10 分钟',
                prefixIcon: Icon(Icons.edit_outlined),
              ),
              onSubmitted: (_) => _save(),
            ),
            const SizedBox(height: 12),
            TextField(
              key: const Key('habit-category-field'),
              controller: _categoryController,
              textInputAction: TextInputAction.next,
              decoration: InputDecoration(
                labelText: '分类',
                hintText: '例如：健康、学习、生活',
                prefixIcon: const Icon(Icons.folder_outlined),
                suffixIcon: PopupMenuButton<String>(
                  tooltip: '选择已有分类',
                  icon: const Icon(Icons.arrow_drop_down_rounded),
                  onSelected: (value) => _categoryController.text = value,
                  itemBuilder: (context) => widget.controller.categories
                      .map(
                        (value) => PopupMenuItem<String>(
                          value: value,
                          child: Text(value),
                        ),
                      )
                      .toList(),
                ),
              ),
            ),
            const SizedBox(height: 16),
            DropdownButtonFormField<String>(
              key: const Key('record-type-field'),
              initialValue: _recordType,
              decoration: const InputDecoration(labelText: '记录方式'),
              items: const [
                DropdownMenuItem(value: 'boolean', child: Text('完成 / 未完成')),
                DropdownMenuItem(value: 'count', child: Text('计数')),
                DropdownMenuItem(value: 'duration', child: Text('手动时长')),
              ],
              onChanged: _editing
                  ? null
                  : (value) => setState(() {
                      _recordType = value!;
                      _dailyTargetController.text = value == 'duration'
                          ? '20'
                          : '1';
                    }),
            ),
            if (_recordType != 'boolean') ...[
              const SizedBox(height: 12),
              if (_recordType == 'count')
                TextField(
                  controller: _unitController,
                  enabled: !_editing,
                  maxLength: 20,
                  decoration: const InputDecoration(labelText: '单位，例如 杯、页'),
                ),
              TextField(
                key: const Key('daily-target-field'),
                controller: _dailyTargetController,
                keyboardType: const TextInputType.numberWithOptions(
                  decimal: true,
                ),
                decoration: InputDecoration(
                  labelText: _recordType == 'duration' ? '每日目标（分钟，整数）' : '每日目标',
                ),
              ),
              if (_recordType == 'duration')
                TextField(
                  controller: _targetSecondsController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(labelText: '目标秒数（0–59）'),
                ),
            ],
            if (_editing)
              const Padding(
                padding: EdgeInsets.only(top: 12),
                child: Text('记录类型和单位保持不变。日计划调整明天生效；周/月计划在下个周期生效。'),
              ),
            const SizedBox(height: 22),
            const Text('选择图标', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: _emojis.map((emoji) {
                final selected = emoji == _emoji;
                return InkWell(
                  borderRadius: BorderRadius.circular(16),
                  onTap: () => setState(() => _emoji = emoji),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 160),
                    width: 48,
                    height: 48,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: selected
                          ? Color(_color).withValues(alpha: 0.18)
                          : Theme.of(
                              context,
                            ).colorScheme.surfaceContainerHighest,
                      borderRadius: BorderRadius.circular(16),
                      border: selected
                          ? Border.all(color: Color(_color), width: 1.5)
                          : null,
                    ),
                    child: Text(emoji, style: const TextStyle(fontSize: 24)),
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 22),
            const Text('主题颜色', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            Wrap(
              spacing: 12,
              children: _colors.map((value) {
                final selected = value == _color;
                return InkWell(
                  borderRadius: BorderRadius.circular(20),
                  onTap: () => setState(() => _color = value),
                  child: Container(
                    width: 36,
                    height: 36,
                    decoration: BoxDecoration(
                      color: Color(value),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected
                            ? Theme.of(context).colorScheme.onSurface
                            : Colors.transparent,
                        width: 3,
                      ),
                    ),
                    child: selected
                        ? const Icon(
                            Icons.check_rounded,
                            color: Colors.white,
                            size: 20,
                          )
                        : null,
                  ),
                );
              }).toList(),
            ),
            const SizedBox(height: 22),
            const Text('执行频次', style: TextStyle(fontWeight: FontWeight.w800)),
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: _scheduleType,
              decoration: const InputDecoration(labelText: '计划'),
              items: const [
                DropdownMenuItem(value: 'daily', child: Text('每天')),
                DropdownMenuItem(value: 'weekdays', child: Text('指定星期')),
                DropdownMenuItem(value: 'week', child: Text('每周 N 天')),
                DropdownMenuItem(value: 'month', child: Text('每月 N 天')),
              ],
              onChanged: (value) => setState(() {
                _scheduleType = value!;
                _scheduleCount = _scheduleCount.clamp(
                  1,
                  value == 'week' ? 7 : 31,
                );
                if (value == 'daily' || value == 'weekdays') _scheduleCount = 1;
              }),
            ),
            if (_scheduleType == 'weekdays')
              Wrap(
                spacing: 6,
                children: [
                  for (var day = 1; day <= 7; day++)
                    FilterChip(
                      label: Text('周${chineseWeekdays[day - 1]}'),
                      selected: _weekdays.contains(day),
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _weekdays.add(day);
                        } else {
                          _weekdays.remove(day);
                        }
                      }),
                    ),
                ],
              ),
            if (_scheduleType == 'week' ||
                _scheduleType == 'month') ...<Widget>[
              const SizedBox(height: 16),
              Card(
                color: Theme.of(context).colorScheme.surfaceContainerHighest,
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _scheduleType == 'week'
                            ? '每周任意 $_scheduleCount 天'
                            : '每月任意 $_scheduleCount 天',
                        style: const TextStyle(fontWeight: FontWeight.w800),
                      ),
                      const SizedBox(height: 4),
                      const Text('不固定具体日期，在周期内自由安排。'),
                      Slider(
                        value: _scheduleCount.toDouble(),
                        min: 1,
                        max: _scheduleType == 'week' ? 7 : 31,
                        divisions: _scheduleType == 'week' ? 6 : 30,
                        label: '$_scheduleCount 天',
                        onChanged: (value) =>
                            setState(() => _scheduleCount = value.round()),
                      ),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          const Text('1 天'),
                          Text(_scheduleType == 'week' ? '7 天' : '31 天'),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ],
            const SizedBox(height: 16),
            Card(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              child: ListTile(
                leading: const Icon(Icons.notifications_none_rounded),
                title: const Text('提醒时间'),
                subtitle: Text(
                  _reminder == null ? '暂不提醒' : _formatTime(_reminder!),
                ),
                trailing: _reminder == null
                    ? const Icon(Icons.chevron_right_rounded)
                    : IconButton(
                        tooltip: '清除提醒',
                        onPressed: () => setState(() => _reminder = null),
                        icon: const Icon(Icons.close_rounded),
                      ),
                onTap: () async {
                  final selected = await showTimePicker(
                    context: context,
                    initialTime:
                        _reminder ?? const TimeOfDay(hour: 21, minute: 30),
                  );
                  if (selected != null) setState(() => _reminder = selected);
                },
              ),
            ),
            const SizedBox(height: 22),
            if (_editing && widget.habit!.legacyRewardBalance != null)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('旧版奖励已保留，可在数据页只读查看。'),
              ),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                key: const Key('save-habit-button'),
                onPressed: _saving ? null : _save,
                icon: _saving
                    ? const SizedBox.square(
                        dimension: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.add_rounded),
                label: Padding(
                  padding: EdgeInsets.symmetric(vertical: 13),
                  child: Text(_editing ? '保存修改' : '开始这个习惯'),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _save() async {
    final title = _titleController.text.trim();
    if (title.isEmpty || title.length > 80) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('习惯名称需要 1–80 个字符')));
      return;
    }
    int dailyTarget = 1;
    final scale = _recordType == 'count' ? widget.habit?.scale ?? 1000 : 1;
    try {
      if (_recordType == 'count') {
        dailyTarget = parseFixed(_dailyTargetController.text, scale: scale);
      }
      if (_recordType == 'duration') {
        final minutes = int.parse(_dailyTargetController.text);
        final seconds = int.parse(_targetSecondsController.text);
        if (minutes < 0 || seconds < 0 || seconds > 59) {
          throw const FormatException('目标时长无效');
        }
        dailyTarget = minutes * 60 + seconds;
      }
      if (dailyTarget < 1 ||
          (_scheduleType == 'weekdays' && _weekdays.isEmpty)) {
        throw const FormatException('目标需大于 0，并至少选择一个星期');
      }
    } on FormatException catch (error) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text(error.message)));
      return;
    }
    setState(() => _saving = true);
    final reminderTime = _reminder == null ? null : _formatTime(_reminder!);
    bool saved;
    if (_editing) {
      saved = await widget.controller.updateHabit(
        habitId: widget.habit!.id,
        title: title,
        emoji: _emoji,
        colorValue: _color,
        weekdays: _weekdays,
        scheduleType: _scheduleType,
        scheduleCount: _scheduleCount,
        dailyTarget: dailyTarget,
        reminderTime: reminderTime,
        category: _categoryController.text,
      );
    } else {
      saved = await widget.controller.addHabit(
        recordType: _recordType,
        unit: _recordType == 'duration' ? '秒' : _unitController.text.trim(),
        scale: scale,
        title: title,
        emoji: _emoji,
        colorValue: _color,
        weekdays: _weekdays,
        scheduleType: _scheduleType,
        scheduleCount: _scheduleCount,
        dailyTarget: dailyTarget,
        reminderTime: reminderTime,
        category: _categoryController.text,
      );
    }
    if (!mounted) return;
    if (!saved) {
      setState(() => _saving = false);
      return;
    }
    Navigator.pop(context);
    if (reminderTime != null) {
      await widget.controller.requestReminderPermission();
    }
  }
}

Future<void> showHabitDetail(
  BuildContext context,
  HabitController controller,
  String habitId,
) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    builder: (context) => FractionallySizedBox(
      heightFactor: 0.88,
      child: HabitDetailSheet(controller: controller, habitId: habitId),
    ),
  );
}

class HabitDetailSheet extends StatefulWidget {
  const HabitDetailSheet({
    super.key,
    required this.controller,
    required this.habitId,
  });

  final HabitController controller;
  final String habitId;

  @override
  State<HabitDetailSheet> createState() => _HabitDetailSheetState();
}

class _HabitDetailSheetState extends State<HabitDetailSheet> {
  late DateTime _visibleMonth;

  HabitController get controller => widget.controller;

  @override
  void initState() {
    super.initState();
    final today = controller.today;
    _visibleMonth = DateTime(today.year, today.month);
  }

  void _changeMonth(int delta) {
    final candidate = DateTime(_visibleMonth.year, _visibleMonth.month + delta);
    final current = DateTime(controller.today.year, controller.today.month);
    if (candidate.isAfter(current)) return;
    setState(() => _visibleMonth = candidate);
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final habit = controller.habitById(widget.habitId);
        if (habit == null) return const SizedBox.shrink();
        final color = Color(habit.colorValue);
        final firstDay = DateTime(_visibleMonth.year, _visibleMonth.month);
        final dayCount = DateTime(
          _visibleMonth.year,
          _visibleMonth.month + 1,
          0,
        ).day;
        final leadingBlanks = firstDay.weekday - 1;
        final cellCount = ((leadingBlanks + dayCount + 6) ~/ 7) * 7;
        final isCurrentMonth =
            _visibleMonth.year == controller.today.year &&
            _visibleMonth.month == controller.today.month;
        final noteEntries = habit.notes.entries.toList()
          ..sort((left, right) => right.key.compareTo(left.key));
        return ListView(
          key: const Key('habit-detail-scroll'),
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          children: <Widget>[
            Row(
              children: <Widget>[
                Container(
                  width: 58,
                  height: 58,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.14),
                    borderRadius: BorderRadius.circular(19),
                  ),
                  child: Text(
                    habit.emoji,
                    style: const TextStyle(fontSize: 29),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        habit.title,
                        style: Theme.of(context).textTheme.headlineSmall
                            ?.copyWith(fontWeight: FontWeight.w900),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${habit.category} · ${executionLabel(habit)}${habit.reminderTime == null ? '' : ' · ${habit.reminderTime}'}',
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (habit.isPaused) _SmallBadge(label: '已暂停', color: color),
              ],
            ),
            const SizedBox(height: 28),
            Row(
              children: <Widget>[
                Expanded(
                  child: _DetailMetric(
                    value:
                        '${(controller.completionRate(habit, days: controller.reviewDays) * 100).round()}%',
                    label: _reviewPeriodLabel(controller.reviewDays),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DetailMetric(
                    value: '${controller.currentStreak(habit)}',
                    label: '当前连续',
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: _DetailMetric(
                    value: '${controller.bestStreak(habit)}',
                    label: '历史最佳',
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            if (habit.effortEnabled)
              Card(
                color: color.withValues(alpha: 0.09),
                child: Padding(
                  padding: const EdgeInsets.all(18),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Icon(Icons.bolt_rounded, color: color),
                          const SizedBox(width: 8),
                          Text(
                            '${controller.effortPoints(habit)} 努力值',
                            style: const TextStyle(
                              fontSize: 17,
                              fontWeight: FontWeight.w900,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '完成一次 +${habit.rewardPoints} · ${habit.rewardPeriod == 'month' ? '每月' : '每周'}目标 ${habit.targetCount} 次 · 未达标每次 -${habit.penaltyPoints}',
                      ),
                      if (habit.wishEnabled &&
                          habit.wishTitle.isNotEmpty) ...<Widget>[
                        const SizedBox(height: 14),
                        Text(
                          '🎁 ${habit.wishTitle}',
                          style: const TextStyle(fontWeight: FontWeight.w800),
                        ),
                        const SizedBox(height: 8),
                        LinearProgressIndicator(
                          value:
                              (controller.effortPoints(habit) /
                                      habit.wishTarget)
                                  .clamp(0.0, 1.0),
                          minHeight: 8,
                          borderRadius: BorderRadius.circular(8),
                          color: color,
                        ),
                        const SizedBox(height: 5),
                        Text(
                          '${controller.effortPoints(habit)} / ${habit.wishTarget} 努力值',
                          style: Theme.of(context).textTheme.bodySmall,
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            const SizedBox(height: 28),
            Row(
              children: <Widget>[
                IconButton(
                  tooltip: '上个月',
                  onPressed: () => _changeMonth(-1),
                  icon: const Icon(Icons.chevron_left_rounded),
                ),
                Expanded(
                  child: Text(
                    '${_visibleMonth.year} 年 ${_visibleMonth.month} 月',
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: '下个月',
                  onPressed: isCurrentMonth ? null : () => _changeMonth(1),
                  icon: const Icon(Icons.chevron_right_rounded),
                ),
              ],
            ),
            Text(
              '点击日期记录，长按设置或取消休息日',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 10),
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(
                  children: <Widget>[
                    Row(
                      children: chineseWeekdays
                          .map(
                            (label) => Expanded(
                              child: Text(
                                label,
                                textAlign: TextAlign.center,
                                style: Theme.of(context).textTheme.bodySmall
                                    ?.copyWith(fontWeight: FontWeight.w700),
                              ),
                            ),
                          )
                          .toList(),
                    ),
                    const SizedBox(height: 10),
                    GridView.builder(
                      shrinkWrap: true,
                      physics: const NeverScrollableScrollPhysics(),
                      gridDelegate:
                          const SliverGridDelegateWithFixedCrossAxisCount(
                            crossAxisCount: 7,
                            mainAxisExtent: 50,
                            crossAxisSpacing: 5,
                            mainAxisSpacing: 7,
                          ),
                      itemCount: cellCount,
                      itemBuilder: (context, index) {
                        final dayNumber = index - leadingBlanks + 1;
                        if (dayNumber < 1 || dayNumber > dayCount) {
                          return const SizedBox.shrink();
                        }
                        final day = DateTime.utc(
                          _visibleMonth.year,
                          _visibleMonth.month,
                          dayNumber,
                        );
                        final scheduled = habit.isScheduledOn(day);
                        final completed = habit.isCompletedOn(day);
                        final backfilled = habit.isBackfilledOn(day);
                        final available =
                            !habit.inTrash &&
                            !day.isBefore(dateOnly(habit.createdAt)) &&
                            !day.isAfter(controller.today);
                        final isToday =
                            dateKey(day) == dateKey(controller.today);
                        return Semantics(
                          button: available,
                          label:
                              '${day.month}月${day.day}日，${completed
                                  ? '已完成'
                                  : scheduled
                                  ? '待完成'
                                  : '非计划日'}',
                          child: InkWell(
                            borderRadius: BorderRadius.circular(13),
                            onLongPress: available
                                ? () async {
                                    final rest = habit.exemptions.contains(
                                      dateKey(day),
                                    );
                                    final confirmed = await showDialog<bool>(
                                      context: context,
                                      builder: (context) => AlertDialog(
                                        title: Text(
                                          '${dateKey(day)} ${rest ? '取消休息' : '设为休息日'}？',
                                        ),
                                        content: const Text(
                                          '已记录的内容会保留。休息日不计入应完成数量。',
                                        ),
                                        actions: [
                                          TextButton(
                                            onPressed: () =>
                                                Navigator.pop(context, false),
                                            child: const Text('取消'),
                                          ),
                                          FilledButton(
                                            onPressed: () =>
                                                Navigator.pop(context, true),
                                            child: const Text('确认'),
                                          ),
                                        ],
                                      ),
                                    );
                                    if (confirmed == true) {
                                      await controller.toggleRest(
                                        habit.id,
                                        day,
                                      );
                                    }
                                  }
                                : null,
                            onTap: available
                                ? () {
                                    if (habit.recordType == 'boolean') {
                                      controller.toggleCompletion(
                                        habit.id,
                                        day,
                                      );
                                    } else {
                                      showRecordEditor(
                                        context,
                                        controller,
                                        habit,
                                        day,
                                      );
                                    }
                                  }
                                : null,
                            child: Container(
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: completed
                                    ? color
                                    : scheduled
                                    ? color.withValues(alpha: 0.11)
                                    : Colors.transparent,
                                borderRadius: BorderRadius.circular(13),
                                border: isToday
                                    ? Border.all(color: color, width: 1.5)
                                    : null,
                              ),
                              child: Stack(
                                alignment: Alignment.center,
                                children: <Widget>[
                                  Text(
                                    '$dayNumber',
                                    style: TextStyle(
                                      fontWeight: isToday
                                          ? FontWeight.w900
                                          : FontWeight.w600,
                                      color: completed ? Colors.white : null,
                                    ),
                                  ),
                                  if (backfilled)
                                    Positioned(
                                      right: 3,
                                      bottom: 2,
                                      child: Text(
                                        '补',
                                        style: TextStyle(
                                          fontSize: 9,
                                          color: completed
                                              ? Colors.white
                                              : color,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 22),
            Row(
              children: <Widget>[
                Text(
                  '每日备注',
                  style: Theme.of(
                    context,
                  ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800),
                ),
                const Spacer(),
                Text(
                  '${noteEntries.length} 条',
                  style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    color: Theme.of(context).colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            Card(
              key: const Key('habit-note-history'),
              child: noteEntries.isEmpty
                  ? const Padding(
                      padding: EdgeInsets.all(18),
                      child: Row(
                        children: <Widget>[
                          Icon(Icons.edit_note_rounded),
                          SizedBox(width: 10),
                          Expanded(child: Text('还没有备注，打卡时写下一点感受吧。')),
                        ],
                      ),
                    )
                  : Column(
                      children: <Widget>[
                        for (
                          var index = 0;
                          index < noteEntries.length;
                          index++
                        ) ...<Widget>[
                          if (index > 0) const Divider(height: 1),
                          Builder(
                            builder: (context) {
                              final entry = noteEntries[index];
                              final day = DateTime.parse(entry.key);
                              final completed = habit.isCompletedOn(day);
                              return ListTile(
                                leading: Container(
                                  width: 46,
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 7,
                                  ),
                                  decoration: BoxDecoration(
                                    color: color.withValues(alpha: 0.11),
                                    borderRadius: BorderRadius.circular(13),
                                  ),
                                  child: Column(
                                    mainAxisSize: MainAxisSize.min,
                                    children: <Widget>[
                                      Text(
                                        '${day.month}月',
                                        style: const TextStyle(fontSize: 10),
                                      ),
                                      Text(
                                        '${day.day}',
                                        style: const TextStyle(
                                          fontWeight: FontWeight.w900,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                title: Text(entry.value),
                                subtitle: Text(completed ? '当天已完成' : '当天未打卡'),
                                trailing: const Icon(
                                  Icons.chevron_right_rounded,
                                ),
                                onTap: () => _showNoteDialog(
                                  context,
                                  controller,
                                  habit,
                                  day,
                                ),
                              );
                            },
                          ),
                        ],
                      ],
                    ),
            ),
            const SizedBox(height: 22),
            Card(
              child: Column(
                children: <Widget>[
                  ListTile(
                    leading: const Icon(Icons.edit_outlined),
                    title: const Text('编辑习惯'),
                    subtitle: Text(
                      habit.hasPendingPlan(controller.today)
                          ? '新计划 ${dateKey(habit.effectivePlans.last.from)} 生效'
                          : '修改名称、计划、颜色和提醒',
                    ),
                    onTap: () async {
                      await showAddHabitSheet(
                        context,
                        controller,
                        habit: habit,
                      );
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      habit.isPaused
                          ? Icons.play_arrow_rounded
                          : Icons.pause_rounded,
                    ),
                    title: Text(habit.isPaused ? '恢复习惯' : '暂停习惯'),
                    subtitle: Text(
                      habit.isPaused ? '暂停期间不会被算作失败' : '旅行、生病或休息时可以暂停',
                    ),
                    onTap: () => controller.togglePaused(habit.id),
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      habit.archived
                          ? Icons.unarchive_outlined
                          : Icons.archive_outlined,
                    ),
                    title: Text(habit.archived ? '恢复到习惯列表' : '归档习惯'),
                    subtitle: const Text('明天起停用，历史记录继续保留'),
                    onTap: () async {
                      await controller.toggleArchived(habit.id);
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                  const Divider(height: 1),
                  ListTile(
                    leading: Icon(
                      Icons.delete_forever_outlined,
                      color: Theme.of(context).colorScheme.error,
                    ),
                    title: Text(
                      '删除习惯',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                    subtitle: const Text('移入回收站，至少保留 30 天，可随时恢复'),
                    onTap: () async {
                      await _confirmDeleteHabit(context, controller, habit);
                      if (context.mounted &&
                          (controller.habitById(habit.id)?.inTrash ?? true)) {
                        Navigator.pop(context);
                      }
                    },
                  ),
                ],
              ),
            ),
          ],
        );
      },
    );
  }
}

class _DetailMetric extends StatelessWidget {
  const _DetailMetric({required this.value, required this.label});

  final String value;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Card(
      color: Theme.of(context).colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 15, horizontal: 8),
        child: Column(
          children: <Widget>[
            Text(
              value,
              style: Theme.of(
                context,
              ).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w900),
            ),
            const SizedBox(height: 3),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

Future<void> _showNoteDialog(
  BuildContext context,
  HabitController controller,
  Habit habit,
  DateTime date,
) async {
  final textController = TextEditingController(text: habit.noteOn(date));
  var saving = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: Text('${habit.emoji} ${dateKey(date)} 备注'),
        content: TextField(
          controller: textController,
          autofocus: true,
          maxLines: 3,
          maxLength: 2000,
          decoration: const InputDecoration(hintText: '简单记下感受或完成情况'),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    setState(() => saving = true);
                    final saved = await controller.setNote(
                      habit.id,
                      date,
                      textController.text,
                    );
                    if (!context.mounted) return;
                    if (saved) {
                      Navigator.pop(context);
                    } else {
                      setState(() => saving = false);
                    }
                  },
            child: Text(saving ? '正在保存' : '保存'),
          ),
        ],
      ),
    ),
  );
  // Dialog widgets can still be alive during their reverse transition.
}

Future<void> _showImportDialog(
  BuildContext context,
  HabitController controller,
) async {
  final textController = TextEditingController();
  var saving = false;
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        title: const Text('恢复旧 JSON 数据'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('这会替换当前数据。确认恢复前会自动保留当前数据保护副本。'),
              const SizedBox(height: 12),
              TextField(
                controller: textController,
                maxLines: 6,
                decoration: const InputDecoration(hintText: '粘贴完整的旧版 JSON'),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: saving ? null : () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: saving
                ? null
                : () async {
                    setState(() => saving = true);
                    final saved = await controller.importJson(
                      textController.text,
                    );
                    if (!context.mounted) return;
                    if (saved) {
                      Navigator.pop(context);
                    } else {
                      setState(() => saving = false);
                    }
                  },
            child: Text(saving ? '正在恢复' : '确认替换并恢复'),
          ),
        ],
      ),
    ),
  );
}

Future<void> _confirmDeleteHabit(
  BuildContext context,
  HabitController controller,
  Habit habit,
) async {
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: const Text('删除这个习惯？'),
      content: Text('“${habit.title}”及记录将移入回收站，至少保留 30 天。永久删除需要在回收站另行确认。'),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(context, false),
          child: const Text('取消'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.error,
          ),
          onPressed: () => Navigator.pop(context, true),
          child: const Text('移入回收站'),
        ),
      ],
    ),
  );
  if (confirmed == true) await controller.deleteHabit(habit.id);
}

Future<void> _showReviewPeriodDialog(
  BuildContext context,
  HabitController controller,
) async {
  final value = await showDialog<int>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('默认回顾周期'),
      children: <Widget>[
        for (final days in const <int>[7, 30, 90, 365])
          ListTile(
            leading: Icon(
              days == controller.reviewDays
                  ? Icons.radio_button_checked_rounded
                  : Icons.radio_button_unchecked_rounded,
            ),
            title: Text(_reviewPeriodLabel(days)),
            onTap: () => Navigator.pop(context, days),
          ),
      ],
    ),
  );
  if (value != null) await controller.setReviewDays(value);
}

Future<void> _showThemeDialog(
  BuildContext context,
  HabitController controller,
) async {
  const colors = <int>[
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
  final hexController = TextEditingController(
    text: controller.themeColorValue
        .toRadixString(16)
        .padLeft(8, '0')
        .substring(2)
        .toUpperCase(),
  );
  await showDialog<void>(
    context: context,
    builder: (dialogContext) => AlertDialog(
      title: const Text('选择主题颜色'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: colors
                  .map(
                    (value) => InkWell(
                      borderRadius: BorderRadius.circular(24),
                      onTap: () async {
                        await controller.setThemeColor(value);
                        if (dialogContext.mounted) Navigator.pop(dialogContext);
                      },
                      child: Container(
                        width: 42,
                        height: 42,
                        decoration: BoxDecoration(
                          color: Color(value),
                          shape: BoxShape.circle,
                          border: Border.all(
                            color: value == controller.themeColorValue
                                ? Theme.of(dialogContext).colorScheme.onSurface
                                : Colors.transparent,
                            width: 3,
                          ),
                        ),
                      ),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 20),
            TextField(
              controller: hexController,
              maxLength: 7,
              textCapitalization: TextCapitalization.characters,
              decoration: const InputDecoration(
                labelText: '自定义 HEX 色值',
                hintText: '#5F8068',
                prefixIcon: Icon(Icons.colorize_rounded),
              ),
            ),
          ],
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.pop(dialogContext),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: () async {
            final raw = hexController.text.trim().replaceFirst('#', '');
            final parsed = raw.length == 6
                ? int.tryParse(raw, radix: 16)
                : null;
            if (parsed == null) {
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('请输入 6 位十六进制色值，例如 #5F8068')),
              );
              return;
            }
            await controller.setThemeColor(0xFF000000 | parsed);
            if (dialogContext.mounted) Navigator.pop(dialogContext);
          },
          child: const Text('应用'),
        ),
      ],
    ),
  );
  hexController.dispose();
}

String _reviewPeriodLabel(int days) => switch (days) {
  7 => '近 1 周',
  30 => '近 1 月',
  90 => '近 1 季度',
  365 => '近 1 年',
  _ => '近 $days 天',
};

String _greeting() {
  final hour = DateTime.now().hour;
  if (hour < 11) return '早上好';
  if (hour < 18) return '下午好';
  return '晚上好';
}

String _fullDate(DateTime date) =>
    '${date.month}月${date.day}日 · 周${chineseWeekdays[date.weekday - 1]}';

String _formatTime(TimeOfDay value) =>
    '${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
