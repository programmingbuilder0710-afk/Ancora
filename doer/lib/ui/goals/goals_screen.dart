import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../../app.dart';
import '../../extraction/extraction.dart';
import '../../models/models.dart';
import '../../provider/provider.dart';

/// Goals screen: list with priority chips, target dates, progress
/// (completed/total); create/edit with title, description, priority,
/// target date, document attach; per-goal Decompose action
/// (SPEC 8.1 #2).
class GoalsScreen extends StatefulWidget {
  const GoalsScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<GoalsScreen> createState() => _GoalsScreenState();
}

class _GoalsScreenState extends State<GoalsScreen> {
  List<Goal> _goals = [];
  Map<String, List<Task>> _tasksByGoal = {};
  Map<String, int> _docCounts = {};
  bool _decomposing = false;

  @override
  void initState() {
    super.initState();
    _reload();
    DataReload.revision.addListener(_reload);
  }

  @override
  void dispose() {
    DataReload.revision.removeListener(_reload);
    super.dispose();
  }

  Future<void> _reload() async {
    final goals = await widget.services.db.getAllGoals();
    final tasks = await widget.services.db.getAllTasks();
    final docs = <String, int>{};
    for (final goal in goals) {
      docs[goal.id] =
          (await widget.services.db.getDocumentsByGoal(goal.id)).length;
    }
    if (!mounted) return;
    setState(() {
      _goals = goals;
      _tasksByGoal = {};
      for (final task in tasks) {
        _tasksByGoal.putIfAbsent(task.goalId, () => []).add(task);
      }
      _docCounts = docs;
    });
  }

  Future<void> _openEditor([Goal? goal]) async {
    final saved = await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => Dialog.fullscreen(
        child: GoalEditorDialog(services: widget.services, goal: goal),
      ),
    );
    if (saved == true) DataReload.bump();
  }

  Future<void> _deleteGoal(Goal goal) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Delete "${goal.title}"?'),
        content: const Text(
            'This permanently deletes the goal, its tasks, and attached '
            'documents. Its events are also removed from the "My Plan" '
            'calendar.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    // Delete the goal's device-calendar events first (best-effort, same
    // swallow pattern as every other calendar write), then the SQLite rows
    // (FK cascade removes tasks + documents).
    final calendar = widget.services.calendar;
    if (calendar != null) {
      try {
        final tasks = await widget.services.db.getTasksByGoal(goal.id);
        for (final task in tasks) {
          if (task.deviceEventId != null) {
            try {
              await calendar.deleteEvent(task.deviceEventId!);
            } on Exception {
              // Best-effort: a missing/already-deleted event must not
              // block the goal delete.
            }
          }
        }
      } on Exception {
        // Calendar read failure: proceed with local delete.
      }
    }
    await widget.services.db.deleteGoal(goal.id);
    DataReload.bump();
  }

  /// Decompose a single goal: non-blocking; the list stays usable while the
  /// LLM runs (progress bar overlays the top of the list).
  Future<void> _decompose(Goal goal) async {
    if (_decomposing) return;
    setState(() => _decomposing = true);
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
      final results = await orchestrator.decompose(goals: [goal]);
      if (mounted) {
        // decompose() returns every pending task; scope the summary to
        // this goal so the message reflects this goal's work only.
        final mine =
            results.where((r) => r.task.goalId == goal.id).toList();
        final placed =
            mine.where((r) => r.task.scheduledStart != null).length;
        final unscheduled =
            mine.where((r) => r.task.scheduledStart == null).length;
        final adjusted = mine.where((r) => r.adjusted).length;
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content: Text(
              'Placed $placed task${placed == 1 ? '' : 's'}'
              '${adjusted > 0 ? ' ($adjusted adjusted)' : ''}'
              '${unscheduled > 0 ? ', $unscheduled need attention' : ''}.'),
        ));
      }
    } on LlmProviderException catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(_providerErrorMessage(e))));
      }
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Decompose failed: $e')));
      }
    } finally {
      if (mounted) setState(() => _decomposing = false);
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Goals')),
      body: _buildBody(context),
      floatingActionButton: FloatingActionButton(
        onPressed: () => _openEditor(),
        tooltip: 'New goal',
        child: const Icon(Icons.add),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    if (_goals.isEmpty) {
      return Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.flag_outlined,
                size: 64, color: Theme.of(context).colorScheme.outline),
            const SizedBox(height: 16),
            Text(
              'No goals yet.\nTap + to describe what you want to achieve.',
              textAlign: TextAlign.center,
              style: Theme.of(context)
                  .textTheme
                  .bodyMedium
                  ?.copyWith(color: Theme.of(context).colorScheme.outline),
            ),
          ],
        ),
      );
    }
    return Stack(
      children: [
        ListView.builder(
          padding: const EdgeInsets.only(bottom: 96),
          itemCount: _goals.length,
          itemBuilder: (context, index) {
            final goal = _goals[index];
            final tasks = _tasksByGoal[goal.id] ?? const <Task>[];
            final completed =
                tasks.where((t) => t.status == TaskStatus.completed).length;
            return _GoalCard(
              goal: goal,
              taskCount: tasks.length,
              completedCount: completed,
              docCount: _docCounts[goal.id] ?? 0,
              onDecompose: () => _decompose(goal),
              onEdit: () => _openEditor(goal),
              onDelete: () => _deleteGoal(goal),
            );
          },
        ),
        if (_decomposing)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(minHeight: 4),
          ),
      ],
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({
    required this.goal,
    required this.taskCount,
    required this.completedCount,
    required this.docCount,
    required this.onDecompose,
    required this.onEdit,
    required this.onDelete,
  });

  final Goal goal;
  final int taskCount;
  final int completedCount;
  final int docCount;
  final VoidCallback onDecompose;
  final VoidCallback onEdit;
  final VoidCallback onDelete;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final priorityColor = switch (goal.priority) {
      GoalPriority.P1 => colorScheme.error,
      GoalPriority.P2 => colorScheme.tertiary,
      GoalPriority.P3 => colorScheme.outline,
    };
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: priorityColor.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    goal.priority.name,
                    style: Theme.of(context)
                        .textTheme
                        .labelSmall
                        ?.copyWith(color: priorityColor),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    goal.title,
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                PopupMenuButton<String>(
                  onSelected: (action) {
                    switch (action) {
                      case 'edit':
                        onEdit();
                      case 'delete':
                        onDelete();
                    }
                  },
                  itemBuilder: (ctx) => const [
                    PopupMenuItem(value: 'edit', child: Text('Edit')),
                    PopupMenuItem(value: 'delete', child: Text('Delete')),
                  ],
                ),
              ],
            ),
            if (goal.description.isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  goal.description,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colorScheme.outline),
                ),
              ),
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.event, size: 14, color: colorScheme.outline),
                const SizedBox(width: 4),
                Text(
                  goal.targetDate,
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colorScheme.outline),
                ),
                const SizedBox(width: 16),
                Icon(Icons.task_alt, size: 14, color: colorScheme.outline),
                const SizedBox(width: 4),
                Text(
                  taskCount == 0 ? 'no tasks yet' : '$completedCount/$taskCount done',
                  style: Theme.of(context)
                      .textTheme
                      .bodySmall
                      ?.copyWith(color: colorScheme.outline),
                ),
                if (docCount > 0) ...[
                  const SizedBox(width: 16),
                  Icon(Icons.description, size: 14, color: colorScheme.outline),
                  const SizedBox(width: 4),
                  Text(
                    '$docCount doc${docCount == 1 ? '' : 's'}',
                    style: Theme.of(context)
                        .textTheme
                        .bodySmall
                        ?.copyWith(color: colorScheme.outline),
                  ),
                ],
                const Spacer(),
                FilledButton.tonal(
                  onPressed: onDecompose,
                  child: const Text('Decompose'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Create/edit sheet: title, description, priority, target date, document
/// attach. The document is extracted immediately and stored on save; the
/// next decompose() picks it up.
class GoalEditorDialog extends StatefulWidget {
  const GoalEditorDialog({super.key, required this.services, this.goal});

  final AppServices services;
  final Goal? goal;

  @override
  State<GoalEditorDialog> createState() => _GoalEditorDialogState();
}

class _GoalEditorDialogState extends State<GoalEditorDialog> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _descriptionController = TextEditingController();
  final _extraction = ExtractionService();

  late GoalPriority _priority;
  DateTime? _targetDate;
  final List<(String, String)> _pickedDocs = []; // (filename, path)
  final List<String> _existingDocs = []; // read-only names, edit mode
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final goal = widget.goal;
    if (goal != null) {
      _titleController.text = goal.title;
      _descriptionController.text = goal.description;
      _priority = goal.priority;
      _targetDate = DateTime.tryParse(goal.targetDate);
      // List already-attached documents read-only; editing never deletes
      // stored docs (re-decompose reuses their extracted text).
      () async {
        final docs = await widget.services.db.getDocumentsByGoal(goal.id);
        if (mounted) setState(() => _existingDocs.addAll(docs.map((d) => d['filename'] as String)));
      }();
    } else {
      _priority = GoalPriority.P2;
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _pickDocument() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['txt', 'md', 'pdf', 'docx'],
    );
    if (result == null) return;
    final path = result.files.single.path;
    if (path == null) return;
    final name = result.files.single.name;
    try {
      final text = await _extraction.extractText(File(path));
      if (!mounted) return;
      if (text.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(
          content:
              Text('Could not extract text from "$name" (unsupported/empty).'),
        ));
        return;
      }
      setState(() => _pickedDocs.add((name, path)));
    } on Exception {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Could not read "$name".')));
      }
    }
  }

  Future<void> _pickTargetDate() async {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final date = await showDatePicker(
      context: context,
      initialDate: _targetDate != null && !_targetDate!.isBefore(today)
          ? _targetDate!
          : today.add(const Duration(days: 7)),
      firstDate: today,
      lastDate: today.add(const Duration(days: 365)),
    );
    if (date != null) setState(() => _targetDate = date);
  }

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    if (_targetDate == null) {
      ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Pick a target date.')));
      return;
    }
    setState(() => _saving = true);
    try {
      final date = _targetDate!;
      final dayKey =
          '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
      final existing = widget.goal;
      final db = widget.services.db;
      Goal goal;
      if (existing == null) {
        goal = Goal(
          id: const Uuid().v4(),
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          priority: _priority,
          targetDate: dayKey,
          createdAt: DateTime.now().toIso8601String(),
        );
        await db.insertGoal(goal);
      } else {
        goal = Goal(
          id: existing.id,
          parentGoalId: existing.parentGoalId,
          title: _titleController.text.trim(),
          description: _descriptionController.text.trim(),
          priority: _priority,
          targetDate: dayKey,
          status: existing.status,
          createdAt: existing.createdAt,
        );
        await db.updateGoal(goal);
      }
      for (final (name, path) in _pickedDocs) {
        final text = await _extraction.extractText(File(path));
        if (text.isEmpty) continue;
        await db.insertDocument(
          id: const Uuid().v4(),
          goalId: goal.id,
          filename: name,
          extractedText: text,
        );
      }
      if (mounted) Navigator.of(context).pop(true);
    } on Exception catch (e) {
      if (mounted) {
        setState(() => _saving = false);
        ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Could not save goal: $e')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isNew = widget.goal == null;
    return Scaffold(
      appBar: AppBar(
        title: Text(isNew ? 'New goal' : 'Edit goal'),
        actions: [
          TextButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
        ],
      ),
      body: Form(
        key: _formKey,
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            TextFormField(
              controller: _titleController,
              decoration: const InputDecoration(
                labelText: 'Title',
                border: OutlineInputBorder(),
              ),
              validator: (value) => (value == null || value.trim().isEmpty)
                  ? 'Title is required'
                  : null,
            ),
            const SizedBox(height: 16),
            TextFormField(
              controller: _descriptionController,
              decoration: const InputDecoration(
                labelText: 'Description (optional)',
                border: OutlineInputBorder(),
                alignLabelWithHint: true,
              ),
              maxLines: 4,
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Text('Priority',
                    style: Theme.of(context).textTheme.labelLarge),
                const SizedBox(width: 16),
                SegmentedButton<GoalPriority>(
                  segments: const [
                    ButtonSegment(value: GoalPriority.P1, label: Text('P1')),
                    ButtonSegment(value: GoalPriority.P2, label: Text('P2')),
                    ButtonSegment(value: GoalPriority.P3, label: Text('P3')),
                  ],
                  selected: {_priority},
                  onSelectionChanged: (set) =>
                      setState(() => _priority = set.first),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: 'Target date',
                      border: OutlineInputBorder(),
                    ),
                    child: Text(_targetDate != null
                        ? DateFormat('EEE, MMM d, yyyy').format(_targetDate!)
                        : 'Not set'),
                  ),
                ),
                const SizedBox(width: 8),
                IconButton.outlined(
                  tooltip: 'Pick date',
                  onPressed: _pickTargetDate,
                  icon: const Icon(Icons.calendar_month),
                ),
              ],
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: _pickDocument,
              icon: const Icon(Icons.attach_file),
              label: const Text('Attach document'),
            ),
            for (final (name, _) in _pickedDocs)
              ListTile(
                leading: const Icon(Icons.description),
                title: Text(name),
                dense: true,
              ),
            for (final name in _existingDocs)
              ListTile(
                leading: const Icon(Icons.history_edu),
                title: Text(name),
                subtitle: const Text('attached'),
                dense: true,
              ),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(isNew ? 'Create goal' : 'Save changes'),
            ),
          ],
        ),
      ),
    );
  }
}
