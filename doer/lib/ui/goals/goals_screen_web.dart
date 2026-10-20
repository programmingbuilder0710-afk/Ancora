import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../widgets.dart';

import '../../app_services.dart';
import '../../models/models.dart';
import 'goal_edit_screen.dart';

class GoalsScreen extends StatefulWidget {
  final AppServices services;
  final void Function(DateTime?, String?)? onPlanned;
  final void Function(Object) onProviderError;
  const GoalsScreen({
    super.key,
    this.onPlanned,
    required this.services,
    required this.onProviderError,
  });

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  List<Goal> _goals = [];
  Map<String, List<Task>> _tasks = {};
  String? _error;
  bool _loading = true;
  bool _archived = false;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    try {
      final goals = await widget.services.db.getAllGoals(activeOnly: false);
      final tasks = <String, List<Task>>{};
      for (final goal in goals) {
        tasks[goal.id] = await widget.services.db.getTasksByGoal(goal.id);
      }
      if (mounted) {
        setState(() {
          _goals = goals;
          _tasks = tasks;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _edit([Goal? goal]) async {
    final planned = await Navigator.of(context)
        .push<({DateTime? day, int count})>(
          MaterialPageRoute(
            builder: (_) => GoalEditScreen(
              services: widget.services,
              goal: goal,
              onProviderError: widget.onProviderError,
            ),
          ),
        );
    if (planned != null && mounted) {
      widget.onPlanned?.call(planned.day, 'Planned ${planned.count} sessions');
    } else {
      await _reload();
    }
  }

  Widget _goalCard(Goal goal) {
    final theme = Theme.of(context);
    final tasks = _tasks[goal.id]!;
    final done = tasks.where((t) => t.status == TaskStatus.completed).length;
    final date = DateTime.parse(goal.targetDate);
    final today = DateUtils.dateOnly(DateTime.now());
    final days = DateTime.utc(
      date.year,
      date.month,
      date.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    final due = days < 0
        ? 'Overdue · ${DateFormat.MMMd().format(date)}'
        : days == 0
        ? 'Due today'
        : 'Due ${DateFormat.MMMd().format(date)} · $days days left';
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Card(
        child: InkWell(
          onTap: () => _edit(goal),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    PriorityBadge(goal.priority),
                    const SizedBox(width: 12),
                    if (days < 0) ...[
                      Icon(
                        Icons.error_outline,
                        size: 16,
                        color: theme.colorScheme.error,
                      ),
                      const SizedBox(width: 4),
                    ],
                    Expanded(
                      child: Text(
                        due,
                        textAlign: TextAlign.end,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: days < 0
                              ? theme.colorScheme.error
                              : theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(
                  goal.title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.titleMedium,
                ),
                if (goal.description.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    goal.description,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
                const SizedBox(height: 16),
                if (tasks.isNotEmpty) ...[
                  LinearProgressIndicator(
                    value: done / tasks.length,
                    semanticsLabel: '$done of ${tasks.length} done',
                  ),
                  const SizedBox(height: 8),
                ],
                Text(
                  tasks.isEmpty
                      ? 'No tasks yet — open to plan'
                      : '$done of ${tasks.length} done',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(toolbarHeight: 24),
    floatingActionButton: _goals.isEmpty
        ? null
        : FloatingActionButton.extended(
            backgroundColor: Theme.of(context).colorScheme.secondaryContainer,
            foregroundColor: Theme.of(context).colorScheme.onSecondaryContainer,
            onPressed: _edit,
            tooltip: 'Add goal',
            icon: const Icon(Icons.add),
            label: const Text('New goal'),
          ),
    body: _loading
        ? const Center(child: CircularProgressIndicator())
        : ContentWidth(
            child: RefreshIndicator(
              onRefresh: _reload,
              child: ListView(
                physics: const AlwaysScrollableScrollPhysics(),
                padding: const EdgeInsets.fromLTRB(20, 8, 20, 96),
                children: [
                  Text(
                    'Goals',
                    style: Theme.of(context).textTheme.headlineMedium,
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${_goals.where((g) => g.status == GoalStatus.active).length} active',
                    style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 24),
                  if (_goals.any((g) => g.status == GoalStatus.archived)) ...[
                    SegmentedButton<bool>(
                      segments: [
                        const ButtonSegment(
                          value: false,
                          label: Text('Active'),
                        ),
                        ButtonSegment(
                          value: true,
                          label: Text(
                            'Archived (${_goals.where((g) => g.status == GoalStatus.archived).length})',
                          ),
                        ),
                      ],
                      selected: {_archived},
                      onSelectionChanged: (values) =>
                          setState(() => _archived = values.first),
                    ),
                    const SizedBox(height: 24),
                  ],
                  if (_error != null) Notice(_error!, error: true),
                  if (_goals.isEmpty)
                    EmptyState(
                      Icons.flag_outlined,
                      'No goals yet',
                      'Goals with a target date get broken into tasks and scheduled automatically.',
                      action: Tooltip(
                        message: 'Add goal',
                        child: FilledButton.icon(
                          onPressed: _edit,
                          icon: const Icon(Icons.add),
                          label: const Text('New goal'),
                        ),
                      ),
                    ),
                  for (final goal in _goals.where(
                    (g) => (g.status == GoalStatus.archived) == _archived,
                  ))
                    _goalCard(goal),
                ],
              ),
            ),
          ),
  );
}
