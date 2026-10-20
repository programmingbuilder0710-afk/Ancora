import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../app_services.dart';
import '../../extraction/extraction.dart';
import '../../models/models.dart';
import '../dialogs.dart';
import '../widgets.dart';
import '../task_details.dart';

class GoalEditScreen extends StatefulWidget {
  final AppServices services;
  final Goal? goal;
  final void Function(Object) onProviderError;
  const GoalEditScreen({
    super.key,
    required this.services,
    this.goal,
    required this.onProviderError,
  });

  @override
  State<GoalEditScreen> createState() => _GoalEditScreenState();
}

class _GoalEditScreenState extends State<GoalEditScreen> {
  final _form = GlobalKey<FormState>();
  final _title = TextEditingController();
  final _description = TextEditingController();
  late DateTime _target;
  GoalPriority _priority = GoalPriority.P2;
  Goal? _goal;
  List<Task> _tasks = [];
  List<Map<String, dynamic>> _documents = [];
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _goal = widget.goal;
    _title.text = _goal?.title ?? '';
    _description.text = _goal?.description ?? '';
    _priority = _goal?.priority ?? GoalPriority.P2;
    final today = DateUtils.dateOnly(DateTime.now());
    _target = _goal == null
        ? DateTime(today.year, today.month, today.day + 7)
        : DateTime.parse(_goal!.targetDate);
    _reload();
  }

  @override
  void dispose() {
    _title.dispose();
    _description.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    if (_goal == null) return;
    try {
      final tasks = await widget.services.db.getTasksByGoal(_goal!.id);
      final docs = await widget.services.db.getDocumentsByGoal(_goal!.id);
      if (mounted) {
        setState(() {
          _tasks = tasks;
          _documents = docs;
        });
      }
    } catch (e) {
      if (mounted) setState(() => _error = e.toString());
    }
  }

  Future<Goal?> _save() async {
    if (!_form.currentState!.validate()) return null;
    if (_target.isBefore(DateUtils.dateOnly(DateTime.now()))) {
      setState(() => _error = 'Target date cannot be before today.');
      return null;
    }
    final goal = Goal(
      id: _goal?.id ?? const Uuid().v4(),
      parentGoalId: _goal?.parentGoalId,
      title: _title.text.trim(),
      description: _description.text.trim(),
      priority: _priority,
      targetDate: DateFormat('yyyy-MM-dd').format(_target),
      status: _goal?.status ?? GoalStatus.active,
      createdAt: _goal?.createdAt ?? DateTime.now().toIso8601String(),
    );
    if (_goal == null) {
      await widget.services.db.insertGoal(goal);
    } else {
      await widget.services.db.updateGoal(goal);
    }
    _goal = goal;
    return goal;
  }

  Future<void> _run(
    Future<void> Function() action, {
    bool provider = false,
  }) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    var demoMode = false;
    try {
      if (provider) demoMode = await widget.services.config.getMode() == 'demo';
      if (mounted) await action();
    } catch (e) {
      if (mounted) {
        setState(
          () => _error = provider
              ? providerErrorMessage(e, demoMode: demoMode)
              : e.toString().replaceFirst(RegExp(r'^Exception: '), ''),
        );
        if (provider) widget.onProviderError(e);
      }
    } finally {
      await _reload();
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _attach() async {
    final goal = await _save();
    if (goal == null) return;
    final picked = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['txt', 'md', 'pdf', 'docx'],
    );
    if (picked == null) return;
    final file = picked.files.single;
    if (file.bytes == null) throw Exception('Could not open ${file.name}');
    final text = await ExtractionService().extractTextFromBytes(
      file.name,
      file.bytes!,
    );
    if (text.trim().isEmpty) {
      throw Exception("Couldn't extract text from ${file.name}");
    }
    await widget.services.db.insertDocument(
      id: const Uuid().v4(),
      goalId: goal.id,
      filename: file.name,
      extractedText: text,
    );
  }

  Future<void> _decompose() async {
    final goal = await _save();
    if (goal == null) return;
    final tasks = await widget.services.db.getTasksByGoal(goal.id);
    if (!mounted) return;
    if (tasks.any((t) => t.status == TaskStatus.pending)) {
      if (!await confirmAction(
        context,
        'This goal already has a plan. Generate more tasks?',
      )) {
        return;
      }
    }
    if (!mounted) return;
    final results = await withProgress(
      context,
      () async =>
          (await widget.services.orchestrator(needsProvider: true))
              .decompose(goals: [goal]),
      label: 'Planning tasks…',
    );
    final own = results.where((r) => r.task.goalId == goal.id);
    final planned = own.where((r) => r.task.scheduledStart != null).length;
    final starts =
        own
            .where((r) => r.task.scheduledStart != null)
            .map((r) => DateTime.parse(r.task.scheduledStart!).toLocal())
            .toList()
          ..sort();
    if (!mounted) return;
    setState(() => _busy = false);
    Navigator.of(context).pop((day: starts.firstOrNull, count: planned));
  }

  Future<void> _pickDate() async {
    final today = DateUtils.dateOnly(DateTime.now());
    final initial = _target.isBefore(today) ? today : _target;
    final value = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: today,
      lastDate: DateTime(initial.year + 100),
    );
    if (value != null && mounted) setState(() => _target = value);
  }

  Future<void> _menu(String value) => _run(() async {
    if (value == 'delete') {
      if (!await confirmAction(
        context,
        'Delete this goal and all its tasks and documents?',
      )) {
        return;
      }
      await widget.services.deleteGoal(_goal!);
    } else {
      await widget.services.db.updateGoal(
        Goal.fromMap({
          ..._goal!.toMap(),
          'status': _goal!.status == GoalStatus.archived
              ? 'active'
              : 'archived',
        }),
      );
    }
    if (mounted) Navigator.of(context).pop();
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final today = DateUtils.dateOnly(DateTime.now());
    final days = DateTime.utc(
      _target.year,
      _target.month,
      _target.day,
    ).difference(DateTime.utc(today.year, today.month, today.day)).inDays;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(_goal == null ? 'New goal' : 'Edit goal'),
          actions: [
            if (_goal != null)
              PopupMenuButton<String>(
                enabled: !_busy,
                tooltip: 'Goal actions',
                onSelected: _menu,
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'archive',
                    child: Text(
                      _goal!.status == GoalStatus.archived
                          ? 'Unarchive'
                          : 'Archive',
                    ),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      'Delete',
                      style: TextStyle(color: theme.colorScheme.error),
                    ),
                  ),
                ],
              ),
          ],
        ),
        bottomNavigationBar: Container(
          decoration: BoxDecoration(
            color: theme.colorScheme.surface,
            border: Border(
              top: BorderSide(color: theme.colorScheme.outlineVariant),
            ),
          ),
          child: SafeArea(
            child: ContentWidth(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 12,
                ),
                child: Row(
                  children: [
                    Expanded(
                      child: OutlinedButton(
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                final goal = await _save();
                                if (goal != null && context.mounted) {
                                  Navigator.of(context).pop();
                                }
                              }),
                        child: const Text('Save'),
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      flex: 2,
                      child: FilledButton.icon(
                        onPressed: _busy
                            ? null
                            : () => _run(_decompose, provider: true),
                        icon: _busy
                            ? const SizedBox(
                                width: 18,
                                height: 18,
                                child: CircularProgressIndicator(
                                  strokeWidth: 2,
                                ),
                              )
                            : const Icon(Icons.auto_awesome, size: 18),
                        label: const Text('Plan tasks'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
        body: ContentWidth(
          child: Form(
            key: _form,
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
              children: [
                if (_error != null) Notice(_error!, error: true),
                const SectionHeader('Goal'),
                TextFormField(
                  controller: _title,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    labelText: 'What do you want to achieve?',
                  ),
                  validator: (value) => value == null || value.trim().isEmpty
                      ? 'Title is required'
                      : null,
                ),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _description,
                  enabled: !_busy,
                  minLines: 3,
                  maxLines: 6,
                  decoration: const InputDecoration(
                    labelText: 'Details',
                    helperText: 'Context helps Doer plan better: current level, constraints, what done looks like.',
                    helperMaxLines: 3,
                  ),
                ),
                const SectionHeader('Priority'),
                SegmentedButton<GoalPriority>(
                  showSelectedIcon: false,
                  segments: const [
                    ButtonSegment(
                      value: GoalPriority.P1,
                      label: Text('P1 · High'),
                    ),
                    ButtonSegment(
                      value: GoalPriority.P2,
                      label: Text('P2 · Medium'),
                    ),
                    ButtonSegment(
                      value: GoalPriority.P3,
                      label: Text('P3 · Low'),
                    ),
                  ],
                  selected: {_priority},
                  onSelectionChanged: _busy
                      ? null
                      : (values) => setState(() => _priority = values.first),
                ),
                const SectionHeader('Target date'),
                SectionCard(
                  children: [
                    ListTile(
                      leading: const Icon(Icons.event),
                      title: Text(DateFormat('EEE, MMM d, y').format(_target)),
                      subtitle: Text(
                        days == 0
                            ? 'Today'
                            : days < 0
                            ? '${-days} days overdue'
                            : 'in $days days',
                      ),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: _busy ? null : _pickDate,
                    ),
                  ],
                ),
                const SectionHeader('Documents'),
                Text(
                  'Notes, syllabi, specs — Doer reads them when planning.',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 12),
                if (_documents.isNotEmpty) ...[
                  SectionCard(
                    children: [
                      for (final doc in _documents)
                        ListTile(
                          leading: Icon(
                            (doc['filename'] as String).toLowerCase().endsWith(
                                  '.pdf',
                                )
                                ? Icons.picture_as_pdf
                                : (doc['filename'] as String)
                                      .toLowerCase()
                                      .endsWith('.docx')
                                ? Icons.article
                                : Icons.description,
                          ),
                          title: Text(doc['filename'] as String),
                          subtitle: Text(
                            '${NumberFormat.decimalPattern().format((doc['extracted_text'] as String).length)} characters',
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 12),
                ],
                OutlinedButton.icon(
                  onPressed: _busy ? null : () => _run(_attach),
                  icon: const Icon(Icons.attach_file),
                  label: const Text('Attach document'),
                ),
                if (_goal != null && _tasks.isNotEmpty) ...[
                  const SectionHeader('Tasks'),
                  SectionCard(
                    children: [
                      for (final task in _tasks)
                        ListTile(
                          onTap: _busy
                              ? null
                              : () async {
                                  final message = await showTaskDetails(
                                    context,
                                    widget.services,
                                    _goal!,
                                    task,
                                  );
                                  await _reload();
                                  if (context.mounted && message != null) {
                                    ScaffoldMessenger.of(context).showSnackBar(
                                      SnackBar(content: Text(message)),
                                    );
                                  }
                                },
                          leading: Icon(switch (task.status) {
                            TaskStatus.completed => Icons.check_circle,
                            TaskStatus.skipped => Icons.skip_next,
                            TaskStatus.pending => Icons.radio_button_unchecked,
                          }, semanticLabel: task.status.name),
                          title: Text(task.title),
                          subtitle: Text(
                            task.scheduledStart == null
                                ? 'Not scheduled'
                                : '${dayClock(context, DateTime.parse(task.scheduledStart!).toLocal())} · ${taskDuration(task.durationMinutes)}',
                            style: task.scheduledStart == null
                                ? TextStyle(color: theme.colorScheme.error)
                                : null,
                          ),
                        ),
                    ],
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
