import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../../app_services.dart';
import '../../models/models.dart';
import '../../orchestration/orchestrator.dart';
import '../dialogs.dart';
import '../widgets.dart';
import '../task_details.dart';
import '../replan/replan_result_screen.dart';

class AgendaScreen extends StatefulWidget {
  final AppServices services;
  final DateTime? initialDay;
  final void Function(Object) onProviderError;
  final VoidCallback onAddGoal;
  const AgendaScreen({
    super.key,
    this.initialDay,
    required this.services,
    required this.onProviderError,
    required this.onAddGoal,
  });

  @override
  State<AgendaScreen> createState() => _AgendaScreenState();
}

class _AgendaScreenState extends State<AgendaScreen> {
  List<Goal> _goals = [];
  List<Task> _tasks = [];
  List<BusyBlock> _busyBlocks = [];
  DateTime _day = DateUtils.dateOnly(DateTime.now());
  bool _loading = true;
  bool _busy = false;
  String? _error;
  final _pendingDone = <String>{};
  late final AppLifecycleListener _lifecycle;
  late final Timer _clockTimer;

  Future<void> _commit(String id) async {
    if (!_pendingDone.remove(id)) return;
    try {
      await (await widget.services.orchestrator()).completeTask(id);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(providerErrorMessage(e, demoMode: false))),
        );
      }
    }
    if (mounted) await _reload();
  }

  void _commitAll() {
    for (final id in _pendingDone.toList()) {
      unawaited(_commit(id));
    }
  }

  void _onBackground() {
    _commitAll();
    if (mounted) ScaffoldMessenger.of(context).clearSnackBars();
  }

  @override
  void dispose() {
    _commitAll();
    _clockTimer.cancel();
    _lifecycle.dispose();
    super.dispose();
  }

  void _markDone(Task task) {
    setState(() => _pendingDone.add(task.id));
    final messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger
        .showSnackBar(
          SnackBar(
            content: const Text('Marked done'),
            persist: false,
            duration: const Duration(seconds: 5),
            action: SnackBarAction(
              label: 'Undo',
              onPressed: () {
                if (mounted) setState(() => _pendingDone.remove(task.id));
              },
            ),
          ),
        )
        .closed
        .then((_) => _commit(task.id));
  }

  @override
  void initState() {
    super.initState();
    _day = DateUtils.dateOnly(widget.initialDay ?? DateTime.now());
    _lifecycle = AppLifecycleListener(
      onHide: _onBackground,
      onPause: _onBackground,
      onResume: _syncCalendars,
    );
    _clockTimer = Timer.periodic(
      const Duration(minutes: 1),
      (_) => setState(() {}),
    );
    _reload().then((_) => _syncCalendars());
  }

  /// Pulls connected-calendar and subscription busy time, so edits made in
  /// Google/Outlook show up without visiting Settings.
  Future<void> _syncCalendars() async {
    final connected = widget.services.connected;
    if (connected == null) return;
    try {
      widget.services.lastSyncWarning = await connected.syncBusy(
        widget.services.db,
      );
    } catch (_) {
      widget.services.lastSyncWarning =
          'Calendars could not sync. Planning uses saved busy times.';
    }
    if (mounted) await _reload();
  }

  Future<void> _reload() async {
    try {
      final goals = await widget.services.db.getAllGoals(activeOnly: false);
      final tasks = await widget.services.db.getAllTasks();
      final today = DateUtils.dateOnly(DateTime.now());
      final busy = await widget.services.db.getBusyBlocksInRange(
        today,
        today.add(const Duration(days: Orchestrator.horizonDays)),
      );
      if (mounted) {
        setState(() {
          _goals = goals;
          _tasks = tasks;
          _busyBlocks = busy;
          _error = null;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() => _error = providerErrorMessage(e, demoMode: false));
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _taskAction(Task task, {required bool done}) async {
    if (done) {
      _markDone(task);
      return;
    }
    setState(() => _busy = true);
    try {
      final orchestrator = await widget.services.orchestrator();
      {
        final result = await orchestrator.skipTask(task.id);
        final start = result.task.scheduledStart;
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                start == null
                    ? "Couldn't fit — needs attention"
                    : 'Moved to ${dayClock(context, DateTime.parse(start).toLocal())}',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(providerErrorMessage(e, demoMode: false))),
        );
      }
    } finally {
      await _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _uncompleteTask(Task task) async {
    if (!await confirmAction(
          context,
          'Un-complete "${task.title}"? It becomes pending and is re-slotted '
          'into free time.',
        ) ||
        !mounted) {
      return;
    }
    setState(() => _busy = true);
    try {
      final orchestrator = await widget.services.orchestrator();
      final result = await orchestrator.uncompleteTask(task.id);
      final start = result.task.scheduledStart;
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              start == null
                  ? "Un-completed — couldn't fit, needs attention"
                  : 'Un-completed — moved to ${dayClock(context, DateTime.parse(start).toLocal())}',
            ),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(providerErrorMessage(e, demoMode: false))),
        );
      }
    } finally {
      await _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _replan() async {
    if (!await confirmAction(context, 'Re-plan all unfinished tasks?') ||
        !mounted) {
      return;
    }
    await Future.wait(_pendingDone.toList().map(_commit));
    if (!mounted) return;
    setState(() => _busy = true);
    var demoMode = false;
    try {
      demoMode = await widget.services.config.getMode() == 'demo';
      final before = {
        for (final t in await widget.services.db.getAllTasks())
          t.id: t.scheduledStart,
      };
      if (!mounted) return;
      final result = await withProgress(
        context,
        () async =>
            (await widget.services.orchestrator(needsProvider: true)).replan(),
      );
      await _reload();
      if (!mounted) return;
      await Navigator.of(context).push<void>(
        MaterialPageRoute(
          builder: (_) => ReplanResultScreen(
            before: before,
            result: result,
            tasks: _tasks,
            goals: _goals,
          ),
        ),
      );
    } catch (e) {
      await _reload();
      if (mounted) {
        setState(() => _error = providerErrorMessage(e, demoMode: demoMode));
        widget.onProviderError(e);
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _openTask(Task task) async {
    // Flush the undo window before showing an immutable completed session.
    await _commit(task.id);
    final current = await widget.services.db.getTask(task.id);
    if (!mounted || current == null) return;
    final message = await showTaskDetails(
      context,
      widget.services,
      _goals.firstWhere((g) => g.id == task.goalId),
      current,
    );
    await _reload();
    if (mounted && message != null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Widget _taskRow(Task task) {
    final completed =
        task.status == TaskStatus.completed || _pendingDone.contains(task.id);
    final pending = task.status == TaskStatus.pending && !completed;
    final theme = Theme.of(context);
    final now = DateTime.now();
    final started = !now.isBefore(DateTime.parse(task.scheduledStart!));
    final missed =
        pending &&
        task.scheduledEnd != null &&
        !now.isBefore(DateTime.parse(task.scheduledEnd!));
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Opacity(
        opacity: completed ? 0.6 : 1,
        child: Card(
          child: InkWell(
            onTap: _busy ? null : () => _openTask(task),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 64),
                // Stretch so the time column top-aligns with the title while the
                // trailing Done button stays centered.
                child: IntrinsicHeight(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      SizedBox(
                        width: 84,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              clock(
                                context,
                                DateTime.parse(task.scheduledStart!).toLocal(),
                              ),
                              maxLines: 1,
                              softWrap: false,
                              style: theme.textTheme.titleSmall?.copyWith(
                                color: completed
                                    ? theme.colorScheme.onSurfaceVariant
                                    : null,
                              ),
                            ),
                            if (task.scheduledEnd != null)
                              Text(
                                clock(
                                  context,
                                  DateTime.parse(task.scheduledEnd!).toLocal(),
                                ),
                                maxLines: 1,
                                softWrap: false,
                                style: theme.textTheme.labelSmall?.copyWith(
                                  color: theme.colorScheme.onSurfaceVariant,
                                ),
                              ),
                          ],
                        ),
                      ),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              task.title,
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: theme.textTheme.bodyLarge?.copyWith(
                                decoration: completed
                                    ? TextDecoration.lineThrough
                                    : null,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Expanded(
                                  child: Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    crossAxisAlignment:
                                        WrapCrossAlignment.center,
                                    children: [
                                      Text(
                                        taskDuration(task.durationMinutes),
                                        style: theme.textTheme.bodySmall
                                            ?.copyWith(
                                              color: theme
                                                  .colorScheme
                                                  .onSurfaceVariant,
                                            ),
                                      ),
                                      if (task.adjusted)
                                        const Tooltip(
                                          message: 'Moved or shortened to fit your free time',
                                          child: Pill(
                                            'Moved to fit',
                                            icon: Icons.swap_horiz,
                                          ),
                                        ),
                                      if (missed)
                                        Pill(
                                          'Missed?',
                                          color: theme.colorScheme.tertiary,
                                        ),
                                      if (task.skipCount > 0)
                                        Pill('Skipped ${task.skipCount}×'),
                                    ],
                                  ),
                                ),
                                if (pending && started)
                                  TextButton.icon(
                                    style: TextButton.styleFrom(
                                      minimumSize: const Size(48, 48),
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 4,
                                      ),
                                      textStyle: theme.textTheme.labelSmall,
                                    ),
                                    onPressed: _busy
                                        ? null
                                        : () => _taskAction(task, done: false),
                                    icon: const Icon(Icons.redo, size: 16),
                                    label: const Text("Didn't start"),
                                  ),
                              ],
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      Center(
                        child: SizedBox(
                          width: 48,
                          height: 48,
                          child: completed
                              ? IconButton(
                                  tooltip: 'Completed — tap to undo',
                                  onPressed: _busy
                                      ? null
                                      : () => _uncompleteTask(task),
                                  icon: Icon(
                                    Icons.check_circle,
                                    color: theme.colorScheme.primary,
                                    semanticLabel: 'Completed',
                                  ),
                                )
                              : pending
                              ? IconButton.filledTonal(
                                  tooltip: 'Done',
                                  onPressed: _busy
                                      ? null
                                      : () => _taskAction(task, done: true),
                                  icon: const Icon(Icons.check),
                                )
                              : null,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _dayCell(DateTime day) {
    final selected = DateUtils.isSameDay(_day, day);
    final scheme = Theme.of(context).colorScheme;
    final color = selected
        ? scheme.onPrimary
        : DateUtils.isSameDay(day, DateTime.now())
        ? scheme.primary
        : scheme.onSurfaceVariant;
    final pending = _tasks.any(
      (t) =>
          t.status == TaskStatus.pending &&
          t.scheduledStart != null &&
          DateUtils.isSameDay(DateTime.parse(t.scheduledStart!).toLocal(), day),
    );
    return Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 2),
        child: Semantics(
          label: DateFormat('EEE d').format(day),
          selected: selected,
          button: true,
          child: Material(
            color: selected ? scheme.primary : scheme.surfaceContainerLow,
            borderRadius: BorderRadius.circular(12),
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => setState(() => _day = day),
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Column(
                    children: [
                      Text(
                        DateFormat('EEE').format(day),
                        style: Theme.of(context).textTheme.labelSmall
                            ?.copyWith(color: color),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        '${day.day}',
                        style: Theme.of(context).textTheme.titleMedium
                            ?.copyWith(color: color),
                      ),
                      const SizedBox(height: 4),
                      Container(
                        width: 4,
                        height: 4,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          color: pending ? color : Colors.transparent,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final today = DateUtils.dateOnly(DateTime.now());
    final theme = Theme.of(context);
    final attention = _tasks.where(
      (t) => t.scheduledStart == null && t.status != TaskStatus.completed,
    );
    final dayTasks =
        _tasks
            .where(
              (t) =>
                  t.scheduledStart != null &&
                  DateUtils.isSameDay(
                    DateTime.parse(t.scheduledStart!).toLocal(),
                    _day,
                  ),
            )
            .toList()
          ..sort(
            (a, b) =>
                DateTime.parse(a.scheduledStart!)
                    .compareTo(DateTime.parse(b.scheduledStart!)),
          );
    final done = dayTasks
        .where(
          (t) =>
              (t.status == TaskStatus.completed || _pendingDone.contains(t.id)),
        )
        .length;
    final later =
        _tasks
            .where((t) => t.scheduledStart != null)
            .map(
              (t) => DateUtils.dateOnly(
                DateTime.parse(t.scheduledStart!).toLocal(),
              ),
            )
            .where(
              (d) =>
                  d.isAfter(_day) &&
                  d.isBefore(
                    today.add(const Duration(days: Orchestrator.horizonDays)),
                  ),
            )
            .toList()
          ..sort();
    final next = later.firstOrNull;
    final minutes = dayTasks.fold(0, (n, t) => n + t.durationMinutes);
    final dayEnd = DateTime(_day.year, _day.month, _day.day + 1);
    final dayBusy =
        _busyBlocks
            .where((b) => b.start.isBefore(dayEnd) && b.end.isAfter(_day))
            .toList()
          ..sort((a, b) => a.start.compareTo(b.start));
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ContentWidth(
              child: RefreshIndicator(
                onRefresh: _reload,
                child: ListView(
                  physics: const AlwaysScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(20, 32, 20, 32),
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Text(
                            DateUtils.isSameDay(_day, today)
                                ? 'Today'
                                : _day.difference(today).inDays == 1
                                ? 'Tomorrow'
                                : DateFormat('EEEE').format(_day),
                            style: theme.textTheme.headlineMedium,
                          ),
                        ),
                        if (_goals.isNotEmpty)
                          FilledButton.tonalIcon(
                            onPressed: _busy ? null : _replan,
                            icon: const Icon(Icons.autorenew, size: 18),
                            label: const Text('Re-plan'),
                          ),
                      ],
                    ),
                    const SizedBox(height: 4),
                    Text(
                      // The weekday is already the title on other days.
                      DateFormat(
                        _day.difference(today).inDays > 1
                            ? 'MMM d'
                            : 'EEEE, MMM d',
                      ).format(_day),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    if (_goals.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Text(
                        dayTasks.isEmpty
                            ? 'Nothing scheduled'
                            : '${dayTasks.length} tasks · ${taskDuration(minutes)} · $done done',
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: theme.colorScheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                    if (dayTasks.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      LinearProgressIndicator(
                        value: done / dayTasks.length,
                        semanticsLabel:
                            '$done of ${dayTasks.length} tasks done',
                      ),
                    ],
                    const SizedBox(height: 24),
                    if (_error != null) ...[
                      Notice(_error!, error: true),
                      const SizedBox(height: 16),
                    ],
                    if (_goals.isEmpty)
                      EmptyState(
                        Icons.flag_outlined,
                        'Plan your first goal',
                        'Tell Doer what you want to achieve. It breaks it into tasks and fits them into your week.',
                        action: FilledButton(
                          onPressed: widget.onAddGoal,
                          child: const Text('Add a goal'),
                        ),
                      )
                    else ...[
                      Row(
                        children: [
                          for (var i = 0; i < Orchestrator.horizonDays; i++)
                            _dayCell(
                              DateTime(today.year, today.month, today.day + i),
                            ),
                        ],
                      ),
                      if (attention.isNotEmpty) ...[
                        const SizedBox(height: 24),
                        Card(
                          color: theme.colorScheme.tertiaryContainer,
                          child: ExpansionTile(
                            shape: const Border(),
                            collapsedShape: const Border(),
                            leading: Icon(
                              Icons.error_outline,
                              color: theme.colorScheme.onTertiaryContainer,
                            ),
                            textColor: theme.colorScheme.onTertiaryContainer,
                            collapsedTextColor:
                                theme.colorScheme.onTertiaryContainer,
                            title: Text(
                              "${attention.length} ${attention.length == 1 ? 'task' : 'tasks'} couldn't fit this week",
                              style: theme.textTheme.titleSmall,
                            ),
                            subtitle: const Text(
                              'Re-plan or free up time in Settings.',
                            ),
                            children: [
                              for (final task in attention)
                                ListTile(
                                  onTap: _busy ? null : () => _openTask(task),
                                  title: Text(task.title),
                                  subtitle: Text(
                                    _goals
                                        .firstWhere((g) => g.id == task.goalId)
                                        .title,
                                  ),
                                ),
                            ],
                          ),
                        ),
                      ],
                      if (dayBusy.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.only(top: 24, bottom: 4),
                          child: Text('Busy', style: theme.textTheme.titleSmall),
                        ),
                        for (final block in dayBusy)
                          _BusyTile(block: block, day: _day),
                      ],
                      if (dayTasks.isEmpty)
                        const EmptyState(
                          Icons.wb_sunny_outlined,
                          'Nothing scheduled',
                          'Pick another day, or re-plan to fill your week.',
                        ),
                      if (dayTasks.isEmpty && next != null)
                        FilledButton.tonal(
                          onPressed: () => setState(() => _day = next),
                          child: Text(
                            'Next: ${DateFormat('EEE d').format(next)} · ${later.where((d) => d == next).length} sessions',
                          ),
                        ),
                      for (final goal in _goals)
                        if (dayTasks.any((t) => t.goalId == goal.id)) ...[
                          Padding(
                            padding: const EdgeInsets.only(top: 24, bottom: 12),
                            child: Row(
                              children: [
                                PriorityBadge(goal.priority, compact: true),
                                const SizedBox(width: 8),
                                Expanded(
                                  child: Text(
                                    goal.title,
                                    style: theme.textTheme.titleSmall,
                                  ),
                                ),
                                const SizedBox(width: 8),
                                Text(
                                  '${dayTasks.where((t) => t.goalId == goal.id && (t.status == TaskStatus.completed || _pendingDone.contains(t.id))).length}/${dayTasks.where((t) => t.goalId == goal.id).length}',
                                  style: theme.textTheme.labelSmall?.copyWith(
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                              ],
                            ),
                          ),
                          for (final task in dayTasks.where(
                            (t) => t.goalId == goal.id,
                          ))
                            _taskRow(task),
                        ],
                    ],
                  ],
                ),
              ),
            ),
    );
  }
}

/// Read-only busy time from a connected calendar, subscription, or .ics
/// import, clipped to the selected day. Web free/busy data carries no
/// event titles, so untitled blocks show their source instead.
class _BusyTile extends StatelessWidget {
  const _BusyTile({required this.block, required this.day});

  final BusyBlock block;
  final DateTime day;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final dayEnd = DateTime(day.year, day.month, day.day + 1);
    final start = block.start.isBefore(day) ? day : block.start;
    final end = block.end.isAfter(dayEnd) ? dayEnd : block.end;
    final time = start == day && end == dayEnd
        ? 'All day'
        : '${DateFormat.jm().format(start)} – ${DateFormat.jm().format(end)}';
    final title = block.title?.isNotEmpty == true ? block.title! : 'Busy';
    return Opacity(
      opacity: 0.75,
      child: ListTile(
        dense: true,
        contentPadding: EdgeInsets.zero,
        leading: Icon(Icons.event_busy, color: theme.colorScheme.outline),
        title: Text(title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text(
          busySourceName(block.source),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
        ),
        trailing: Text(
          time,
          style: theme.textTheme.bodySmall?.copyWith(
            color: theme.colorScheme.outline,
          ),
        ),
      ),
    );
  }
}
