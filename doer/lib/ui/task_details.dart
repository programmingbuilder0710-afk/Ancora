import 'dart:async';

import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../app_services.dart';
import '../models/models.dart';
import 'dialogs.dart';
import 'widgets.dart';

Future<String?> showTaskDetails(
  BuildContext context,
  AppServices services,
  Goal goal,
  Task task,
) => showModalBottomSheet<String>(
  context: context,
  isScrollControlled: true,
  showDragHandle: true,
  constraints: const BoxConstraints(maxWidth: 560),
  builder: (_) => _TaskDetails(services: services, goal: goal, task: task),
);

class _TaskDetails extends StatefulWidget {
  final AppServices services;
  final Goal goal;
  final Task task;
  const _TaskDetails({
    required this.services,
    required this.goal,
    required this.task,
  });

  @override
  State<_TaskDetails> createState() => _TaskDetailsState();
}

class _TaskDetailsState extends State<_TaskDetails> {
  late final TextEditingController _title;
  late final Timer _timer;
  bool _renaming = false;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _title = TextEditingController(text: widget.task.title);
    _timer = Timer.periodic(const Duration(minutes: 1), (_) => setState(() {}));
  }

  @override
  void dispose() {
    _timer.cancel();
    _title.dispose();
    super.dispose();
  }

  Future<void> _run(Future<String> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      final message = await action();
      if (mounted) Navigator.pop(context, message);
    } catch (e) {
      if (mounted) {
        setState(() => _error = providerErrorMessage(e, demoMode: false));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  bool get _validTitle =>
      _title.text.trim().isNotEmpty && _title.text.trim().length <= 120;

  void _rename() {
    if (!_validTitle) return;
    _run(() async {
      await widget.services.renameTask(widget.task, _title.text);
      return 'Renamed';
    });
  }

  Future<void> _delete() async {
    if (!await confirmAction(
          context,
          'Delete “${widget.task.title}”? This can\'t be undone.',
        ) ||
        !mounted) {
      return;
    }
    await _run(() async {
      await widget.services.deleteTask(widget.task);
      return 'Session deleted';
    });
  }

  Future<void> _action({required bool done}) => _run(() async {
    final orchestrator = await widget.services.orchestrator();
    if (done) {
      await orchestrator.completeTask(widget.task.id);
      return 'Marked done';
    }
    final result = await orchestrator.skipTask(widget.task.id);
    if (!mounted) return '';
    final start = result.task.scheduledStart;
    return start == null
        ? "Couldn't fit — needs attention"
        : 'Moved to ${dayClock(context, DateTime.parse(start).toLocal())}';
  });

  @override
  Widget build(BuildContext context) {
    final task = widget.task;
    final theme = Theme.of(context);
    final start = task.scheduledStart == null
        ? null
        : DateTime.parse(task.scheduledStart!).toLocal();
    final end = task.scheduledEnd == null
        ? null
        : DateTime.parse(task.scheduledEnd!).toLocal();
    final suggested = task.recommendedDay == null
        ? null
        : DateTime.tryParse(task.recommendedDay!);
    final pending = task.status == TaskStatus.pending;
    final now = DateTime.now();
    final started = start != null && !now.isBefore(start);
    return PopScope(
      canPop: !_busy,
      child: SafeArea(
        child: Padding(
          padding: EdgeInsets.fromLTRB(
            24,
            0,
            24,
            24 + MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    PriorityBadge(widget.goal.priority, compact: true),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        widget.goal.title,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),
                Text(task.title, style: theme.textTheme.headlineSmall),
                const SizedBox(height: 16),
                Text(
                  start == null
                      ? 'Not scheduled'
                      : '${DateFormat('EEE, MMM d').format(start)} · ${clock(context, start)}${end == null ? '' : ' – ${clock(context, end)}'}',
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    Pill(taskDuration(task.durationMinutes)),
                    Pill(switch (task.status) {
                      TaskStatus.pending => 'Pending',
                      TaskStatus.completed => 'Completed',
                      TaskStatus.skipped => 'Skipped',
                    }),
                    if (pending && end != null && !now.isBefore(end))
                      Pill('Missed?', color: theme.colorScheme.tertiary),
                    if (task.skipCount > 0) Pill('Skipped ${task.skipCount}×'),
                  ],
                ),
                if (start != null &&
                    suggested != null &&
                    !DateUtils.isSameDay(start, suggested)) ...[
                  const SizedBox(height: 16),
                  Text(
                    'Suggested for ${DateFormat('EEE').format(suggested)}, moved to fit your free time.',
                  ),
                ] else if (task.adjusted) ...[
                  const SizedBox(height: 16),
                  const Text('Shortened or moved to fit your free time.'),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 16),
                  Notice(_error!, error: true),
                ],
                if (pending) ...[
                  const SizedBox(height: 24),
                  if (_renaming) ...[
                    TextField(
                      controller: _title,
                      enabled: !_busy,
                      autofocus: true,
                      maxLength: 120,
                      textInputAction: TextInputAction.done,
                      decoration: const InputDecoration(
                        labelText: 'Session title',
                      ),
                      onChanged: (_) => setState(() {}),
                      onSubmitted: (_) => _rename(),
                    ),
                    FilledButton(
                      onPressed: _busy || !_validTitle ? null : _rename,
                      child: const Text('Save'),
                    ),
                  ] else
                    OutlinedButton.icon(
                      onPressed: _busy
                          ? null
                          : () => setState(() {
                              _renaming = true;
                              // Select the old title so typing replaces it.
                              _title.selection = TextSelection(
                                baseOffset: 0,
                                extentOffset: _title.text.length,
                              );
                            }),
                      icon: const Icon(Icons.edit_outlined),
                      label: const Text('Rename'),
                    ),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 12,
                    runSpacing: 8,
                    children: [
                      FilledButton.icon(
                        onPressed: _busy ? null : () => _action(done: true),
                        icon: const Icon(Icons.check),
                        label: const Text('Done'),
                      ),
                      if (started)
                        TextButton.icon(
                          onPressed: _busy ? null : () => _action(done: false),
                          icon: const Icon(Icons.redo),
                          label: const Text("Didn't start"),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextButton.icon(
                    onPressed: _busy ? null : _delete,
                    style: TextButton.styleFrom(
                      foregroundColor: theme.colorScheme.error,
                    ),
                    icon: const Icon(Icons.delete_outline),
                    label: const Text('Delete session'),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
