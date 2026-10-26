import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app.dart';
import '../../models/models.dart';
import '../../provider/provider.dart';

/// Agenda home screen: 7-day swipeable pager over the rolling horizon.
/// Tasks grouped by goal, ordered by time; per-task quick actions
/// Done / Didn't Start; Re-plan action; adjusted / needs-attention
/// markers; calendar-error banner area (SPEC 8.1 #1).
class AgendaScreen extends StatefulWidget {
  const AgendaScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends State<AgendaScreen> {
  static const int horizonDays = 7;

  final PageController _pageController = PageController();
  List<Task> _tasks = [];
  Map<String, Goal> _goalsById = {};
  List<BusyBlock> _busy = [];
  bool _replanning = false;

  @override
  void initState() {
    super.initState();
    _reload();
    DataReload.revision.addListener(_reload);
  }

  @override
  void dispose() {
    DataReload.revision.removeListener(_reload);
    _pageController.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final tasks = await widget.services.db.getAllTasks();
    final goals = await widget.services.db.getAllGoals(activeOnly: false);
    final now = DateTime.now();
    final busy = await widget.services.db.getBusyBlocksInRange(
        DateTime(now.year, now.month, now.day),
        DateTime(now.year, now.month, now.day)
            .add(const Duration(days: horizonDays)));
    if (!mounted) return;
    setState(() {
      _tasks = tasks;
      _goalsById = {for (final g in goals) g.id: g};
      _busy = busy;
    });
  }

  DateTime get _today {
    final now = DateTime.now();
    return DateTime(now.year, now.month, now.day);
  }

  DateTime _dayFor(int index) => _today.add(Duration(days: index));

  String _dayKey(DateTime day) {
    final m = day.month.toString().padLeft(2, '0');
    final d = day.day.toString().padLeft(2, '0');
    return '${day.year}-$m-$d';
  }

  /// Tasks scheduled on [day], ordered by start time. Scheduled strings are
  /// local ISO datetimes whose first 10 chars are the calendar day.
  List<Task> _tasksFor(DateTime day) {
    final prefix = _dayKey(day);
    return _tasks
        .where((t) =>
            t.scheduledStart != null &&
            t.scheduledStart!.startsWith(prefix))
        .toList()
      ..sort((a, b) => a.scheduledStart!.compareTo(b.scheduledStart!));
  }

  Future<void> _completeTask(Task task) async {
    try {
      // Completing never reschedules: no device-calendar refresh needed.
      final orchestrator = await widget.services.buildLocalOrchestrator();
      await orchestrator.completeTask(task.id);
    } on Exception catch (e) {
      _showError('Could not complete: $e');
      return;
    }
    DataReload.bump();
  }

  Future<void> _uncompleteTask(Task task) async {
    if (task.status != TaskStatus.completed) return;
    try {
      final orchestrator =
          await widget.services.buildLocalOrchestrator(refreshBusyBlocks: true);
      final result = await orchestrator.uncompleteTask(task.id);
      final start = result.task.scheduledStart;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(start == null
              ? 'Un-completed — couldn\'t fit, needs attention'
              : 'Un-completed — moved to ${DateFormat('EEE, HH:mm').format(DateTime.parse(start).toLocal())}'),
        ));
      }
    } on Exception catch (e) {
      _showError('Could not un-complete: $e');
      return;
    }
    DataReload.bump();
  }

  Future<void> _skipTask(Task task) async {
    try {
      // Skipping re-slots the task now: refresh device busy blocks first.
      final orchestrator =
          await widget.services.buildLocalOrchestrator(refreshBusyBlocks: true);
      await orchestrator.skipTask(task.id);
    } on Exception catch (e) {
      _showError('Could not re-slot: $e');
      return;
    }
    DataReload.bump();
  }

  /// Manual time change: date + time pickers, then a local moveTask (no
  /// LLM — the user picks the slot). Sets the user_edited pin so
  /// decompose/re-plan keep the chosen time fixed. Callable for any
  /// non-completed task, including needs-attention (unscheduled) ones.
  Future<void> _moveTask(Task task) async {
    if (task.status == TaskStatus.completed) return;
    final today = _today;
    final initialDay = task.scheduledStart != null
        ? DateTime.parse(task.scheduledStart!)
        : today;
    final date = await showDatePicker(
      context: context,
      initialDate: initialDay.isBefore(today) ? today : initialDay,
      firstDate: today,
      // The plan horizon is 7 rolling days; a manual move may not exceed
      // it (the slotter never places beyond it either).
      lastDate: today.add(const Duration(days: horizonDays - 1)),
    );
    if (date == null || !mounted) return;
    final initialTime = task.scheduledStart != null
        ? TimeOfDay.fromDateTime(DateTime.parse(task.scheduledStart!))
        : const TimeOfDay(hour: 9, minute: 0);
    final time = await showTimePicker(
      context: context,
      initialTime: initialTime,
    );
    if (time == null) return;
    final start =
        DateTime(date.year, date.month, date.day, time.hour, time.minute);
    final end = start.add(Duration(minutes: task.durationMinutes));
    try {
      final orchestrator = await widget.services.buildLocalOrchestrator();
      await orchestrator.moveTask(task.id, start: start, end: end);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Moved to ${DateFormat('EEE, MMM d · HH:mm').format(start)}'),
        ));
      }
    } on Exception catch (e) {
      _showError('Could not move: $e');
      return;
    }
    DataReload.bump();
  }

  /// Re-plan: LLM pass over all unfinished tasks. Non-blocking UX — a thin
  /// progress bar shows while the call runs; the shell stays usable.
  Future<void> _replan() async {
    if (_replanning) return;
    setState(() => _replanning = true);
    try {
      final orchestrator = await widget.services.buildLlmOrchestrator();
      if (orchestrator == null) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(const SnackBar(
            content: Text('Provider not configured — open Settings.'),
          ));
        }
        return;
      }
      final result = await orchestrator.replan();
      if (mounted) {
        final tips = result.tips.take(3).toList();
        await showDialog<void>(
          context: context,
          builder: (ctx) => AlertDialog(
            title: const Text('Re-plan complete'),
            content: tips.isEmpty
                ? const Text('Your unfinished tasks were re-dated.')
                : Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final tip in tips)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Text(tip),
                        ),
                    ],
                  ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: const Text('OK'),
              ),
            ],
          ),
        );
      }
    } on LlmProviderException catch (e) {
      if (mounted) _showError(_providerErrorMessage(e));
    } on Exception catch (e) {
      if (mounted) _showError('Re-plan failed: $e');
    } finally {
      if (mounted) setState(() => _replanning = false);
      DataReload.bump();
    }
  }

  static String _providerErrorMessage(LlmProviderException e) {
    if (e is AuthError) return 'Auth failed — check API key in Settings.';
    if (e is RateLimitError) {
      return 'Rate limited — try again in a few minutes.';
    }
    if (e is QuotaError) {
      return 'Demo budget exhausted — add your own provider in Settings.';
    }
    if (e is NetworkError) return 'Network error — check connection.';
    return 'Provider error — try again.';
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final calendarError = widget.services.calendarError;
    return Scaffold(
      appBar: AppBar(
        title: const Text('Doer'),
        bottom: _replanning
            ? const PreferredSize(
                preferredSize: Size.fromHeight(4),
                child: LinearProgressIndicator(minHeight: 4),
              )
            : null,
        actions: [
          IconButton(
            icon: const Icon(Icons.settings),
            tooltip: 'Provider settings',
            onPressed: () async {
              await openProviderSettings(context, widget.services);
              DataReload.bump();
            },
          ),
        ],
      ),
      body: Column(
        children: [
          if (calendarError != null) _CalendarBanner(message: calendarError),
          Expanded(
            child: PageView.builder(
              controller: _pageController,
              itemCount: horizonDays,
              itemBuilder: (context, index) {
                final day = _dayFor(index);
                final tasks = _tasksFor(day);
                // Pending tasks the slotter could not place (SPEC §5.3:
                // nothing ≥ 15-min floor) surface on today's page only.
                final unscheduled = index == 0
                    ? _tasks
                        .where((t) =>
                            t.scheduledStart == null &&
                            t.status == TaskStatus.pending)
                        .toList()
                    : const <Task>[];
                final prefix = _dayKey(day);
                final dayBusy = _busy
                    .where((b) =>
                        b.start.toIso8601String().startsWith(prefix) ||
                        b.end.toIso8601String().startsWith(prefix))
                    .toList()
                  ..sort((a, b) => a.start.compareTo(b.start));
                return _DayPage(
                  day: day,
                  tasks: tasks,
                  busyBlocks: dayBusy,
                  unscheduledTasks: unscheduled,
                  goalsById: _goalsById,
                  isFirstDay: index == 0,
                  onComplete: _completeTask,
                  onUncomplete: _uncompleteTask,
                  onSkip: _skipTask,
                  onMove: _moveTask,
                );
              },
            ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _replanning ? null : _replan,
        icon: _replanning
            ? const SizedBox(
                width: 16,
                height: 16,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Icon(Icons.autorenew),
        label: Text(_replanning ? 'Re-planning…' : 'Re-plan'),
      ),
    );
  }
}

class _CalendarBanner extends StatelessWidget {
  const _CalendarBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Material(
      color: colorScheme.errorContainer,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.warning_amber,
                size: 18, color: colorScheme.onErrorContainer),
            const SizedBox(width: 8),
            Expanded(
              child: Text(message,
                  style: TextStyle(color: colorScheme.onErrorContainer)),
            ),
          ],
        ),
      ),
    );
  }
}

class _DayPage extends StatelessWidget {
  const _DayPage({
    required this.day,
    required this.tasks,
    required this.busyBlocks,
    required this.unscheduledTasks,
    required this.goalsById,
    required this.isFirstDay,
    required this.onComplete,
    required this.onUncomplete,
    required this.onSkip,
    required this.onMove,
  });

  final DateTime day;
  final List<Task> tasks;
  final List<BusyBlock> busyBlocks;
  final List<Task> unscheduledTasks;
  final Map<String, Goal> goalsById;
  final bool isFirstDay;
  final Future<void> Function(Task) onComplete;
  final Future<void> Function(Task) onUncomplete;
  final Future<void> Function(Task) onSkip;
  final Future<void> Function(Task) onMove;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final weekday = DateFormat('EEEE').format(day);
    final dateLabel = DateFormat('MMM d').format(day);
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
          child: Text(
            '$weekday · $dateLabel',
            style: Theme.of(context)
                .textTheme
                .titleMedium
                ?.copyWith(color: colorScheme.primary),
          ),
        ),
        if (tasks.isEmpty && busyBlocks.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Center(
              child: Text(
                isFirstDay
                    ? 'Nothing scheduled today.\nCreate a goal and tap Decompose.'
                    : 'Nothing scheduled this day.',
                textAlign: TextAlign.center,
                style: Theme.of(context)
                    .textTheme
                    .bodyMedium
                    ?.copyWith(color: colorScheme.outline),
              ),
            ),
          ),
        if (busyBlocks.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              'Busy',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: colorScheme.outline),
            ),
          ),
          for (final block in busyBlocks)
            _BusyTile(block: block),
        ],
        for (final entry in _groupedByGoal().entries)
          _GoalGroup(
            goal: goalsById[entry.key],
            tasks: entry.value,
            onComplete: onComplete,
            onUncomplete: onUncomplete,
            onSkip: onSkip,
            onMove: onMove,
          ),
        if (unscheduledTasks.isNotEmpty) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Text(
              'Needs attention',
              style: Theme.of(context)
                  .textTheme
                  .labelLarge
                  ?.copyWith(color: colorScheme.error),
            ),
          ),
          for (final task in unscheduledTasks)
            _TaskTile(
              task: task,
              onComplete: () => onComplete(task),
              onUncomplete: () => onUncomplete(task),
              onSkip: () => onSkip(task),
              onMove: () => onMove(task),
            ),
        ],
      ],
    );
  }

  /// Group by goal preserving the day's time order; goals keyed by id.
  Map<String, List<Task>> _groupedByGoal() {
    final byGoal = <String, List<Task>>{};
    for (final task in tasks) {
      byGoal.putIfAbsent(task.goalId, () => []).add(task);
    }
    return byGoal;
  }
}

/// Read-only busy event from another calendar app. Shows the real event
/// title when the block carries one; all-day expansions keep their
/// source-only label.
class _BusyTile extends StatelessWidget {
  const _BusyTile({required this.block});

  final BusyBlock block;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final start = DateFormat('HH:mm').format(block.start);
    final end = DateFormat('HH:mm').format(block.end);
    final label = block.title?.isNotEmpty == true
        ? block.title!
        : 'Busy (imported)';
    return Opacity(
      opacity: 0.75,
      child: ListTile(
        dense: true,
        leading: Icon(Icons.event_busy, size: 20, color: colorScheme.outline),
        title: Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodyMedium,
        ),
        trailing: Text('$start-$end',
            style: Theme.of(context)
                .textTheme
                .bodySmall
                ?.copyWith(color: colorScheme.outline)),
      ),
    );
  }
}

class _GoalGroup extends StatelessWidget {
  const _GoalGroup({
    required this.goal,
    required this.tasks,
    required this.onComplete,
    required this.onSkip,
    required this.onUncomplete,
    required this.onMove,
  });

  final Goal? goal;
  final List<Task> tasks;
  final Future<void> Function(Task) onComplete;
  final Future<void> Function(Task) onUncomplete;
  final Future<void> Function(Task) onSkip;
  final Future<void> Function(Task) onMove;


  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
          child: Row(
            children: [
              Icon(Icons.flag, size: 16, color: colorScheme.primary),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  goal?.title ?? 'Unknown goal',
                  style: Theme.of(context)
                      .textTheme
                      .labelLarge
                      ?.copyWith(color: colorScheme.primary),
                ),
              ),
            ],
          ),
        ),
        for (final task in tasks)
          _TaskTile(
            task: task,
            onComplete: () => onComplete(task),
            onUncomplete: () => onUncomplete(task),
            onSkip: () => onSkip(task),
            onMove: () => onMove(task),
          ),
      ],
    );
  }
}

class _TaskTile extends StatelessWidget {
  const _TaskTile({
    required this.task,
    required this.onComplete,
    required this.onUncomplete,
    required this.onSkip,
    required this.onMove,
  });

  final Task task;
  final VoidCallback onComplete;
  final VoidCallback onUncomplete;
  final VoidCallback onSkip;
  final VoidCallback onMove;


  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final start = task.scheduledStart != null
        ? DateFormat('HH:mm').format(DateTime.parse(task.scheduledStart!))
        : null;
    final end = task.scheduledEnd != null
        ? DateFormat('HH:mm').format(DateTime.parse(task.scheduledEnd!))
        : null;
    final done = task.status == TaskStatus.completed;
    final skipped = task.status == TaskStatus.skipped;
    final unscheduled = task.scheduledStart == null;

    return ListTile(
      leading: start != null
          ? SizedBox(
              width: 48,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    start,
                    maxLines: 1,
                    style: Theme.of(context).textTheme.titleSmall?.copyWith(
                          color: done || skipped
                              ? colorScheme.outline
                              : colorScheme.primary,
                          decoration: done || skipped
                              ? TextDecoration.lineThrough
                              : null,
                        ),
                  ),
                  if (end != null && end != start)
                    Text(
                      end,
                      maxLines: 1,
                      style: Theme.of(context).textTheme.bodySmall?.copyWith(
                            color: colorScheme.outline,
                          ),
                    ),
                ],
              ),
            )
          : null,
      title: Text(
        task.title,
        style: TextStyle(
          decoration: done || skipped ? TextDecoration.lineThrough : null,
          color: done || skipped ? colorScheme.outline : null,
        ),
      ),
      subtitle: (unscheduled || task.adjusted || task.skipCount > 0)
          ? Wrap(
              spacing: 6,
              runSpacing: 4,
              children: [
                if (unscheduled)
                  _Marker(label: 'needs attention', color: colorScheme.error),
                if (task.adjusted && !unscheduled)
                  _Marker(label: 'adjusted', color: colorScheme.tertiary),
                if (task.skipCount > 0)
                  _Marker(
                    label: 'skipped ×${task.skipCount}',
                    color: colorScheme.secondary,
                  ),
              ],
            )
          : null,
      trailing: done
          ? IconButton(
              tooltip: 'Completed — tap to undo',
              icon: Icon(Icons.check_circle, color: colorScheme.primary),
              onPressed: onUncomplete,
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                IconButton(
                  tooltip: 'Done',
                  icon: const Icon(Icons.check),
                  onPressed: onComplete,
                ),
                IconButton(
                  tooltip: "Didn't Start",
                  icon: const Icon(Icons.skip_next),
                  onPressed: onSkip,
                ),
                IconButton(
                  tooltip: 'Change time',
                  icon: const Icon(Icons.edit_calendar),
                  onPressed: onMove,
                ),
              ],
            ),
    );
  }
}

class _Marker extends StatelessWidget {
  const _Marker({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        border: Border.all(color: color),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Text(
        label,
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}
