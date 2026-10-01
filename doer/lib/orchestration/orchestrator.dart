import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:collection/collection.dart';
import 'package:uuid/uuid.dart';
import '../models/models.dart';
import '../data/database_helper.dart';
import '../provider/provider.dart';
import '../slotter/slotter.dart';
import '../calendar/calendar_service.dart';
import '../extraction/extraction.dart';

/// Orchestrates the full pipeline: LLM decomposition → slotter → SQLite → calendar.
class Orchestrator {
  final DatabaseHelper db;
  final LlmProvider Function() providerFactory;
  final Slotter slotter;
  final CalendarService? calendar;

  Orchestrator({
    required this.db,
    required this.providerFactory,
    required this.slotter,
    this.calendar,
  });

  static const int horizonDays = 7;

  Map<String, dynamic> get _decomposeSchema => {
    'type': 'object',
    'required': ['tasks'],
    'properties': {
      'tasks': {
        'type': 'array',
        'items': {
          'type': 'object',
          'required': ['task_id','goal_id','title','duration_minutes','recommended_day','prerequisite_ids'],
          'properties': {
            'task_id':          {'type': 'string'},
            'goal_id':          {'type': 'string'},
            'title':            {'type': 'string', 'maxLength': 120},
            'duration_minutes': {'type': 'integer', 'minimum': 5, 'maximum': 480},
            'recommended_day':  {'type': 'string', 'pattern': r'^\d{4}-\d{2}-\d{2}$'},
            'prerequisite_ids': {'type': 'array', 'items': {'type': 'string'}},
          },
        },
      },
    },
  };

  Map<String, dynamic> get _replanSchema => {
    'type': 'object',
    'required': ['tasks'],
    'properties': {
      'tasks': {
        'type': 'array',
        'items': {
          'type': 'object',
          'required': ['task_id','goal_id','title','duration_minutes','recommended_day','prerequisite_ids'],
          'properties': {
            'task_id':          {'type': 'string'},
            'goal_id':          {'type': 'string'},
            'title':            {'type': 'string', 'maxLength': 120},
            'duration_minutes': {'type': 'integer', 'minimum': 5, 'maximum': 480},
            'recommended_day':  {'type': 'string', 'pattern': r'^\d{4}-\d{2}-\d{2}$'},
            'prerequisite_ids': {'type': 'array', 'items': {'type': 'string'}},
          },
        },
      },
      'tips': {'type': 'array', 'items': {'type': 'string'}, 'maxItems': 3},
    },
  };

  /// Build the per-day summary context (compact, no raw intervals).
  Future<List<Map<String, dynamic>>> _buildPerDaySummary(
    DateTime horizonStart,
    List<BusyBlock> busyBlocks,
    List<Task> allTasks,
  ) async {
    final summary = <Map<String, dynamic>>[];

    for (int i = 0; i < horizonDays; i++) {
      final day = DateTime(horizonStart.year, horizonStart.month, horizonStart.day).add(Duration(days: i));
      final dayEnd = day.add(const Duration(days: 1));

      double busyMinutes = 0;
      for (final block in busyBlocks) {
        if (block.start.isBefore(dayEnd) && block.end.isAfter(day)) {
          final s = block.start.isAfter(day) ? block.start : day;
          final e = block.end.isBefore(dayEnd) ? block.end : dayEnd;
          busyMinutes += e.difference(s).inMinutes;
        }
      }

      double placedMinutes = 0;
      for (final task in allTasks) {
        if (task.scheduledStart != null && task.scheduledEnd != null) {
          final s = DateTime.parse(task.scheduledStart!);
          final e = DateTime.parse(task.scheduledEnd!);
          if (s.isBefore(dayEnd) && e.isAfter(day)) {
            placedMinutes += e.difference(s).inMinutes;
          }
        }
      }

      const weekdays = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
      summary.add({
        'date': '${day.year}-${day.month.toString().padLeft(2, '0')}-${day.day.toString().padLeft(2, '0')}',
        'weekday': weekdays[day.weekday - 1],
        'busy_hours': double.parse((busyMinutes / 60).toStringAsFixed(1)),
        'remaining_free_hours': double.parse(((placedMinutes) / 60).toStringAsFixed(1)),
      });
    }

    return summary;
  }

  /// Initial decomposition: for a batch of goals.
  Future<List<PlacementResult>> decompose({
    required List<Goal> goals,
  }) async {
    if (goals.isEmpty) return [];
    final provider = providerFactory();

    final now = DateTime.now();
    final horizonStart = DateTime(now.year, now.month, now.day);
    final busyBlocks = await db.getBusyBlocksInRange(horizonStart, horizonStart.add(Duration(days: horizonDays)));
    final allTasks = await db.getAllTasks();

    final perDaySummary = await _buildPerDaySummary(horizonStart, busyBlocks, allTasks);
    final goalsContext = goals.map((g) => {
      'goal_id': g.id,
      'title': g.title,
      'description': g.description,
      'priority': g.priority.name,
      'target_date': g.targetDate,
    }).toList();

    final docsContext = <Map<String, dynamic>>[];
    for (final goal in goals) {
      final docs = await db.getDocumentsByGoal(goal.id);
      for (final doc in docs) {
        docsContext.add({
          'goal_id': goal.id,
          'filename': doc['filename'],
          'extracted_text': doc['extracted_text'],
        });
      }
    }

    final pendingDigest = allTasks
        .where((t) => t.status == TaskStatus.pending && t.scheduledStart != null)
        .map((t) => {
          'task_id': t.id,
          'title': t.title,
          'day': t.scheduledStart!.substring(0, 10),
        }).toList();

    final userContext = {
      'today': '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      'horizon_days': horizonDays,
      'per_day_summary': perDaySummary,
      'goals': goalsContext,
      'documents': docsContext,
      'pending_tasks_digest': pendingDigest,
    };

    final system = '''
You are a scheduling assistant. Given a user's goals, documents, and per-day free time summaries,
decompose each goal into concrete, duration-bounded atomic tasks. Assign each task a
"recommended_day" (ISO YYYY-MM-DD) within the given horizon. Spread sessions instead of cramming.
Respect goal target dates and balance load across goals by priority (P1 > P2 > P3).
Each task must have task_id, goal_id, title, duration_minutes, recommended_day, prerequisite_ids.
prerequisite_ids must reference other task_ids in this same response (empty list if none).
Return only JSON matching the required schema.
''';

    // Attempt 1
    Map<String, dynamic> response;
    try {
      response = await provider.complete(
        system: system,
        user: jsonEncode(userContext),
        jsonSchema: _decomposeSchema,
      );
    } on SchemaViolationError catch (e) {
      // Attempt 2: repair retry with errors appended
      response = await provider.complete(
        system: system,
        user: '${jsonEncode(userContext)}\n\nPrevious attempt failed validation: ${e.message}. '
            'Fix the errors and return only JSON matching the schema.',
        jsonSchema: _decomposeSchema,
      );
    }

    // Validate semantics
    final tasks = _validateAndConvertTasks(response['tasks'] as List, goals);
    if (tasks.isEmpty) {
      throw Exception('LLM returned no valid tasks');
    }

    // Insert into DB
    await db.insertTasks(tasks);

    // Place tasks
    final slotterTasks = await db.getTasksByStatus(TaskStatus.pending);
    final placementResults = slotter.placeTasks(
      tasks: slotterTasks,
      busyBlocks: busyBlocks,
      horizonStart: horizonStart,
      horizonDays: horizonDays,
    );

    // Persist placements
    for (final result in placementResults) {
      if (result.task.scheduledStart != null) {
        await db.updateTask(result.task);
      }
    }

    // Write calendar events
    if (calendar != null) {
      final existingIds = <String, String>{};
      for (final t in allTasks) {
        if (t.deviceEventId != null) existingIds[t.id] = t.deviceEventId!;
      }
      final newIds = await calendar!.atomicRewrite(placementResults, existingIds);
      for (final entry in newIds.entries) {
        final task = placementResults.firstWhere((r) => r.task.id == entry.key).task;
        await db.updateTask(task.copyWith(deviceEventId: entry.value));
      }
    }

    return placementResults;
  }

  /// Full re-plan: explicit user request. LLM re-dates all unfinished tasks.
  Future<ReplanResult> replan() async {
    final provider = providerFactory();

    final now = DateTime.now();
    final horizonStart = DateTime(now.year, now.month, now.day);
    final busyBlocks = await db.getBusyBlocksInRange(horizonStart, horizonStart.add(Duration(days: horizonDays)));
    final allTasks = await db.getAllTasks();
    final allGoalsList = await db.getAllGoals(activeOnly: false);
    final goalsById = {for (final g in allGoalsList) g.id: g};

    final unfinished = allTasks.where((t) => t.status != TaskStatus.completed).toList();
    if (unfinished.isEmpty) {
      return ReplanResult(placementResults: [], tips: []);
    }

    final completedDigest = allTasks
        .where((t) => t.status == TaskStatus.completed)
        .map((t) => {'title': t.title, 'goal_id': t.goalId})
        .toList();

    final perDaySummary = await _buildPerDaySummary(horizonStart, busyBlocks, allTasks);

    final tasksContext = unfinished.map((t) => {
      'task_id': t.id,
      'goal_id': t.goalId,
      'title': t.title,
      'duration_minutes': t.durationMinutes,
      'skip_count': t.skipCount,
      'current_day': t.scheduledStart?.substring(0, 10),
      'pinned_deadline': t.pinnedDeadline,
    }).toList();

    final goalsContext = unfinished
        .map((t) => goalsById[t.goalId])
        .whereType<Goal>()
        .map((g) => {
          'goal_id': g.id,
          'title': g.title,
          'priority': g.priority.name,
          'target_date': g.targetDate,
        }).toList();

    final userContext = {
      'today': '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}',
      'horizon_days': horizonDays,
      'per_day_summary': perDaySummary,
      'unfinished_tasks': tasksContext,
      'goals': goalsContext,
      'completed_digest': completedDigest,
    };

    final system = '''
You are a scheduling assistant performing a re-plan. The user fell behind on some tasks.
Re-date EVERY unfinished task: assign each a new "recommended_day" (ISO YYYY-MM-DD) within the
given horizon. Completed tasks are frozen - do not include them as mutable tasks.
Spread sessions, respect goal target dates, balance load by priority (P1 > P2 > P3).
Each task must have task_id, goal_id, title, duration_minutes, recommended_day, prerequisite_ids.
task_id must match the existing task UUIDs provided. prerequisite_ids must reference other
unfinished task_ids in this response. Optionally provide up to 3 short coaching tips.
Return only JSON matching the required schema.
''';

    // Attempt 1
    Map<String, dynamic> response;
    try {
      response = await provider.complete(
        system: system,
        user: jsonEncode(userContext),
        jsonSchema: _replanSchema,
      );
    } on SchemaViolationError catch (e) {
      // Attempt 2: repair retry
      response = await provider.complete(
        system: system,
        user: '${jsonEncode(userContext)}\n\nPrevious attempt failed validation: ${e.message}. '
            'Fix the errors and return only JSON matching the schema.',
        jsonSchema: _replanSchema,
      );
    }

    // Re-join pinned deadlines by task_id (LLM never echoes client-owned state)
    final tasks = _validateAndConvertTasks(response['tasks'] as List, allGoalsList,
        pinnedDeadlines: {for (final t in unfinished) t.id: t.pinnedDeadline},
        preserveIds: {for (final t in unfinished) t.id});

    if (tasks.isEmpty) {
      throw Exception('LLM returned no valid tasks');
    }

    // Update DB with new dates. copyWith(null) cannot clear scheduledStart/End,
    // so construct the cleared row explicitly before slotting.
    final updatedUnfinished = <Task>[];
    for (final task in tasks) {
      final existing = unfinished.firstWhereOrNull((t) => t.id == task.id);
      if (existing == null) continue; // unknown task_id dropped
      final cleared = Task(
        id: existing.id,
        goalId: existing.goalId,
        title: task.title,
        durationMinutes: task.durationMinutes,
        recommendedDay: task.recommendedDay,
        pinnedDeadline: task.pinnedDeadline,
        prerequisiteIds: task.prerequisiteIds,
        scheduledStart: null,
        scheduledEnd: null,
        status: existing.status,
        adjusted: existing.adjusted,
        skipCount: existing.skipCount,
        deviceEventId: existing.deviceEventId,
        createdAt: existing.createdAt,
      );
      updatedUnfinished.add(cleared);
      await db.updateTask(cleared);
    }

    // Place tasks
    final slotterTasks = await db.getTasksByStatus(TaskStatus.pending);
    final placementResults = slotter.placeTasks(
      tasks: slotterTasks,
      busyBlocks: busyBlocks,
      horizonStart: horizonStart,
      horizonDays: horizonDays,
    );

    // Persist placements
    for (final result in placementResults) {
      if (result.task.scheduledStart != null) {
        await db.updateTask(result.task);
      }
    }

    // Atomic calendar rewrite: delete unfinished events, keep completed, write new
    if (calendar != null) {
      final existingIds = <String, String>{};
      for (final t in unfinished) {
        if (t.deviceEventId != null) existingIds[t.id] = t.deviceEventId!;
      }
      final newIds = await calendar!.atomicRewrite(placementResults, existingIds);
      for (final entry in newIds.entries) {
        final result = placementResults.firstWhere((r) => r.task.id == entry.key);
        await db.updateTask(result.task.copyWith(deviceEventId: entry.value));
      }
    }

    final tips = (response['tips'] as List?)?.map((e) => e.toString()).toList() ?? [];
    return ReplanResult(placementResults: placementResults, tips: tips);
  }

  /// Skip a task: local, instant, no LLM. Re-slot into nearest feasible day.
  Future<PlacementResult> skipTask(String taskId) async {
    final task = await db.getTask(taskId);
    if (task == null) throw Exception('Task not found: $taskId');
    if (task.status == TaskStatus.completed) {
      throw Exception('Cannot skip a completed task');
    }

    final now = DateTime.now();
    final horizonStart = DateTime(now.year, now.month, now.day);
    final busyBlocks = await db.getBusyBlocksInRange(horizonStart, horizonStart.add(Duration(days: horizonDays)));
    final allTasks = await db.getAllTasks();

    final result = slotter.reSlotSkippedTask(
      task: task,
      busyBlocks: busyBlocks,
      currentTasks: allTasks,
      horizonStart: horizonStart,
      horizonDays: horizonDays,
    );

    // Persist updated task
    await db.updateTask(result.task);

    // Update device calendar event for this task only
    if (calendar != null) {
      if (task.deviceEventId != null) {
        try {
          await calendar!.deleteEvent(task.deviceEventId!);
        } catch (_) {}
      }
      if (result.task.scheduledStart != null && result.task.scheduledEnd != null) {
        try {
          final newId = await calendar!.writeTaskEvent(result.task);
          await db.updateTask(result.task.copyWith(deviceEventId: newId));
        } catch (_) {}
      }
    }

    return result;
  }

  /// Mark a task complete: frozen forever. No re-slotting.
  Future<void> completeTask(String taskId) async {
    final task = await db.getTask(taskId);
    if (task == null) throw Exception('Task not found: $taskId');
    if (task.status == TaskStatus.completed) return;

    await db.updateTask(task.copyWith(status: TaskStatus.completed));
  }

  /// Import a .ics file: parse events to busy blocks, replace (not duplicate)
  /// any previously imported blocks from the same source. Callable from the
  /// Settings ".ics import" action (SPEC 7.2 / 8). Returns imported block count.
  Future<int> importIcsFile(String filePath, String sourceName) async {
    final content = await File(filePath).readAsString();
    final blocks = ExtractionService().parseIcsContent(content, sourceName);
    await db.deleteBusyBlocksBySource(sourceName);
    if (blocks.isNotEmpty) {
      await db.insertBusyBlocks(blocks);
    }
    return blocks.length;
  }

  /// Validate and convert raw LLM task list to domain Tasks.
  /// Enforces: horizon bounds, known goal_ids, prerequisite graph integrity.
  List<Task> _validateAndConvertTasks(
    List<dynamic> rawTasks,
    List<Goal> goals,
    {Map<String, String?> pinnedDeadlines = const {},
     Set<String> preserveIds = const {}}
  ) {
    final goalsById = {for (final g in goals) g.id: g};
    final now = DateTime.now();
    final horizonStart = DateTime(now.year, now.month, now.day);
    final horizonEnd = horizonStart.add(Duration(days: horizonDays - 1));

    final uuid = const Uuid();
    final validTasks = <Task>[];
    final idMap = <String, String>{}; // LLM task_id -> our UUID

    // First pass: create tasks with new UUIDs
    for (final raw in rawTasks) {
      try {
        final taskId = raw['task_id'] as String;
        final goalId = raw['goal_id'] as String;
        final title = raw['title'] as String;
        final duration = raw['duration_minutes'] as int;
        final recommendedDay = raw['recommended_day'] as String;
        final prereqs = (raw['prerequisite_ids'] as List).map((e) => e.toString()).toList();

        if (!goalsById.containsKey(goalId)) continue;
        if (duration < 5 || duration > 480) continue;

        final dayDate = DateTime.tryParse(recommendedDay);
        if (dayDate == null) continue;
        if (dayDate.isBefore(horizonStart) || dayDate.isAfter(horizonEnd)) continue;

        final ourId = preserveIds.contains(taskId) ? taskId : uuid.v4();
        idMap[taskId] = ourId;

        validTasks.add(Task(
          id: ourId,
          goalId: goalId,
          title: title,
          durationMinutes: duration,
          recommendedDay: recommendedDay,
          pinnedDeadline: pinnedDeadlines[taskId],
          prerequisiteIds: prereqs,
          createdAt: now.toIso8601String(),
        ));
      } catch (_) {
        continue;
      }
    }

    // Second pass: remap prereqs to our UUIDs, drop self/cyclic/unknown references
    for (final task in validTasks) {
      final remapped = <String>[];
      for (final prereq in task.prerequisiteIds) {
        final mapped = idMap[prereq];
        if (mapped != null && mapped != task.id) {
          remapped.add(mapped);
        }
        // unknown/self references dropped silently
      }
      task.prerequisiteIds.clear();
      task.prerequisiteIds.addAll(remapped);
    }

    // Third pass: Kahn's algorithm over in-batch prereq graph. Tasks never
    // emitted are cyclic — strip their in-batch prereq edges and KEEP the
    // tasks (SPEC §4.4: drop the back-edge, not the task).
    final inBatchPrereqCount = <String, int>{};
    final dependents = <String, List<String>>{};
    for (final t in validTasks) {
      inBatchPrereqCount[t.id] = t.prerequisiteIds.length;
      for (final p in t.prerequisiteIds) {
        dependents.putIfAbsent(p, () => []).add(t.id);
      }
    }

    final queue = validTasks
        .where((t) => inBatchPrereqCount[t.id] == 0)
        .map((t) => t.id)
        .toList();
    final emitted = <String>{...queue};
    while (queue.isNotEmpty) {
      final current = queue.removeAt(0);
      for (final dId in dependents[current] ?? const <String>[]) {
        final remaining = (inBatchPrereqCount[dId] ?? 0) - 1;
        inBatchPrereqCount[dId] = remaining;
        if (remaining == 0 && !emitted.contains(dId)) {
          emitted.add(dId);
          queue.add(dId);
        }
      }
    }

    for (final t in validTasks) {
      if (!emitted.contains(t.id)) {
        // Cyclic: strip in-batch edges, keep the task.
        t.prerequisiteIds.clear();
      }
    }

    return validTasks;
  }
}

class ReplanResult {
  final List<PlacementResult> placementResults;
  final List<String> tips;

  ReplanResult({required this.placementResults, required this.tips});
}
