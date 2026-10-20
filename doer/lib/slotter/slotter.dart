import 'package:collection/collection.dart';
import '../models/models.dart';

class FreeSegment {
  final DateTime start;
  final DateTime end;
  final int durationMinutes;

  FreeSegment(this.start, this.end) : durationMinutes = end.difference(start).inMinutes;
}

class PlacementResult {
  final Task task;
  final bool adjusted;
  final String? note;

  PlacementResult(this.task, {this.adjusted = false, this.note});
}

class Slotter {
  final UserPreferences preferences;

  Slotter(this.preferences);

  Map<String, Goal> allGoals = {};
  List<Task> allTasks = [];

  /// Main entry: place a list of tasks into the rolling horizon.
  /// Ordering: topological levels (prereqs always first); within each level
  /// by goal priority, then recommended_day, then creation order.
  List<PlacementResult> placeTasks({
    required List<Task> tasks,
    required List<BusyBlock> busyBlocks,
    required DateTime horizonStart,
    required int horizonDays,
  }) {
    final occupiedByDay = _buildOccupiedByDay(busyBlocks, horizonStart, horizonDays);
    final freeByDay = _buildFreeSegmentsByDay(occupiedByDay, horizonStart, horizonDays);
    final orderedTasks = _topologicalSort(tasks);

    // Days of every placed task in this batch — prereq guard source of truth.
    final batchPlacedDays = <String, DateTime>{};

    final results = <PlacementResult>[];

    for (final task in orderedTasks) {
      if (task.status != TaskStatus.pending) {
        // Already placed/completed/skipped — frozen history, stays occupied.
        results.add(PlacementResult(task));
        if (task.scheduledStart != null) {
          _addToOccupied(occupiedByDay, task);
          final s = DateTime.parse(task.scheduledStart!);
          batchPlacedDays[task.id] = DateTime(s.year, s.month, s.day);
        }
        continue;
      }

      if (task.userEdited && task.scheduledStart != null) {
        // The user moved this task's event in an external calendar app:
        // the imported schedule is fixed. Occupy the time so other tasks
        // place around it, but never re-slot it.
        results.add(PlacementResult(task));
        _addToOccupied(occupiedByDay, task);
        final s = DateTime.parse(task.scheduledStart!);
        batchPlacedDays[task.id] = DateTime(s.year, s.month, s.day);
        continue;
      }

      final result = _placeSingleTask(
        task,
        occupiedByDay,
        freeByDay,
        horizonStart,
        horizonDays,
        batchPlacedDays,
      );
      results.add(result);

      if (result.task.scheduledStart != null) {
        final s = DateTime.parse(result.task.scheduledStart!);
        batchPlacedDays[result.task.id] = DateTime(s.year, s.month, s.day);
      }
    }

    return results;
  }

  /// Re-slot a single skipped task (local, instant, no LLM).
  PlacementResult reSlotSkippedTask({
    required Task task,
    required List<BusyBlock> busyBlocks,
    required List<Task> currentTasks,
    required DateTime horizonStart,
    required int horizonDays,
  }) {
    final occupiedByDay = _buildOccupiedByDay(busyBlocks, horizonStart, horizonDays);
    final batchPlacedDays = <String, DateTime>{};

    for (final t in currentTasks) {
      if (t.id != task.id && t.scheduledStart != null) {
        _addToOccupied(occupiedByDay, t);
        final s = DateTime.parse(t.scheduledStart!);
        batchPlacedDays[t.id] = DateTime(s.year, s.month, s.day);
      }
    }

    final freeByDay = _buildFreeSegmentsByDay(occupiedByDay, horizonStart, horizonDays);

    final now = DateTime.now();
    final originalDay = task.scheduledStart != null
        ? DateTime.parse(task.scheduledStart!)
        : now;
    final today = DateTime(now.year, now.month, now.day);
    final originalOnlyDay = DateTime(originalDay.year, originalDay.month, originalDay.day);
    final earliestAllowed = originalOnlyDay.isAfter(today) ? originalOnlyDay : today;

    final adjustedTask = task.copyWith(
      status: TaskStatus.pending,
      skipCount: task.skipCount + 1,
      clearSchedule: true,
      clearDeviceEventId: true,
    );

    final recommended = adjustedTask.recommendedDay != null
        ? DateTime.parse(adjustedTask.recommendedDay!)
        : earliestAllowed;
    final effectiveRecommended = recommended.isAfter(earliestAllowed) ? recommended : earliestAllowed;

    final effectiveTask = adjustedTask.copyWith(
      recommendedDay: '${effectiveRecommended.year}-${effectiveRecommended.month.toString().padLeft(2, '0')}-${effectiveRecommended.day.toString().padLeft(2, '0')}',
    );

    return _placeSingleTask(
      effectiveTask,
      occupiedByDay,
      freeByDay,
      horizonStart,
      horizonDays,
      batchPlacedDays,
    );
  }

  Map<DateTime, List<_OccupiedInterval>> _buildOccupiedByDay(
    List<BusyBlock> busyBlocks,
    DateTime horizonStart,
    int horizonDays,
  ) {
    final map = <DateTime, List<_OccupiedInterval>>{};

    for (int i = 0; i < horizonDays; i++) {
      final day = DateTime(horizonStart.year, horizonStart.month, horizonStart.day).add(Duration(days: i));
      map[day] = [];
    }

    for (final block in busyBlocks) {
      final startDay = DateTime(block.start.year, block.start.month, block.start.day);
      final endDay = DateTime(block.end.year, block.end.month, block.end.day);

      if (startDay == endDay) {
        if (map.containsKey(startDay)) {
          map[startDay]!.add(_OccupiedInterval(block.start, block.end));
        }
      } else {
        // Multi-day block. Clamp to the horizon: a block starting before
        // horizonStart (ongoing device event, or an .ics VEVENT spanning
        // today) must still occupy its in-horizon remainder; without the
        // clamp the loop breaks immediately on the missing pre-horizon key
        // and the slotter double-books over it. Entirely pre-horizon
        // blocks are skipped.
        if (endDay.isBefore(horizonStart)) continue;
        final effectiveStart = startDay.isBefore(horizonStart)
            ? DateTime(horizonStart.year, horizonStart.month, horizonStart.day)
            : startDay;
        for (int i = 0; ; i++) {
          final day = effectiveStart.add(Duration(days: i));
          if (!map.containsKey(day)) break;
          final beganBeforeHorizon = i == 0 && startDay.isBefore(horizonStart);
          final segmentStart = beganBeforeHorizon
              ? DateTime(day.year, day.month, day.day)
              : (i == 0 ? block.start : DateTime(day.year, day.month, day.day));
          final segmentEnd = (day == endDay) ? block.end : DateTime(day.year, day.month, day.day).add(const Duration(days: 1));
          map[day]!.add(_OccupiedInterval(segmentStart, segmentEnd));
          if (day == endDay) break;
        }
      }
    }

    for (final day in map.keys) {
      map[day] = _mergeIntervals(map[day]!);
    }

    return map;
  }

  Map<DateTime, List<FreeSegment>> _buildFreeSegmentsByDay(
    Map<DateTime, List<_OccupiedInterval>> occupiedByDay,
    DateTime horizonStart,
    int horizonDays,
  ) {
    final map = <DateTime, List<FreeSegment>>{};

    for (int i = 0; i < horizonDays; i++) {
      final day = DateTime(horizonStart.year, horizonStart.month, horizonStart.day).add(Duration(days: i));

      final weekday = _weekdayToString(day.weekday);
      if (!preferences.activeDays.contains(weekday)) {
        map[day] = [];
        continue;
      }

      final segments = _rebuildFreeSegmentsForDay(day, occupiedByDay[day] ?? [], preferences);
      map[day] = segments;
    }

    return map;
  }

  /// Kahn's algorithm: level 0 = no in-batch prereqs; level N = prereqs all in
  /// earlier levels. Within a level: goal priority, recommended_day, createdAt.
  /// Cyclic remainder (invalid data; DB tasks are pre-validated) is appended
  /// in original order — its prereq edges will simply never resolve.
  List<Task> _topologicalSort(List<Task> tasks) {
    final taskMap = {for (final t in tasks) t.id: t};

    final inBatchPrereqCount = <String, int>{};
    final dependents = <String, List<String>>{};
    for (final t in tasks) {
      final inBatch = t.prerequisiteIds.where(taskMap.containsKey).toSet();
      inBatchPrereqCount[t.id] = inBatch.length;
      for (final p in inBatch) {
        dependents.putIfAbsent(p, () => []).add(t.id);
      }
    }

    var level = tasks
        .where((t) => inBatchPrereqCount[t.id] == 0)
        .toList()
      ..sort(_withinLevelCompare);
    final ordered = [...level];
    final emitted = level.map((t) => t.id).toSet();

    while (level.isNotEmpty) {
      final next = <Task>[];
      for (final t in level) {
        for (final dId in dependents[t.id] ?? const <String>[]) {
          final remaining = inBatchPrereqCount[dId]! - 1;
          inBatchPrereqCount[dId] = remaining;
          if (remaining == 0 && !emitted.contains(dId)) {
            emitted.add(dId);
            next.add(taskMap[dId]!);
          }
        }
      }
      next.sort(_withinLevelCompare);
      ordered.addAll(next);
      level = next;
    }

    // Cyclic remainder, original order.
    for (final t in tasks) {
      if (!emitted.contains(t.id)) ordered.add(t);
    }

    return ordered;
  }

  int _withinLevelCompare(Task a, Task b) {
    final ga = allGoals[a.goalId];
    final gb = allGoals[b.goalId];
    if (ga != null && gb != null) {
      final p = ga.priority.index.compareTo(gb.priority.index);
      if (p != 0) return p;
    }
    final da = a.recommendedDay ?? '9999-12-31';
    final db = b.recommendedDay ?? '9999-12-31';
    final d = da.compareTo(db);
    if (d != 0) return d;
    return a.createdAt.compareTo(b.createdAt);
  }

  /// Earliest allowed day given prerequisite placements: in-batch placements
  /// first (source of truth during placement), then externally known tasks.
  DateTime _earliestPrereqDay(Task task, Map<String, DateTime> batchPlacedDays, DateTime today) {
    var earliest = today;
    for (final prereqId in task.prerequisiteIds) {
      DateTime? prereqDay = batchPlacedDays[prereqId];
      prereqDay ??= allTasks
          .firstWhereOrNull((t) => t.id == prereqId)
          ?.let((t) => t.scheduledStart != null ? DateTime.parse(t.scheduledStart!) : null)
          ?.let((s) => DateTime(s.year, s.month, s.day));
      if (prereqDay != null && prereqDay.isAfter(earliest)) {
        earliest = prereqDay;
      }
    }
    return earliest;
  }

  PlacementResult _placeSingleTask(
    Task task,
    Map<DateTime, List<_OccupiedInterval>> occupiedByDay,
    Map<DateTime, List<FreeSegment>> freeByDay,
    DateTime horizonStart,
    int horizonDays,
    Map<String, DateTime> batchPlacedDays,
  ) {
    DateTime latestDay;
    if (task.pinnedDeadline != null) {
      latestDay = DateTime.parse(task.pinnedDeadline!);
    } else {
      final goal = allGoals[task.goalId];
      if (goal != null) {
        latestDay = DateTime.parse(goal.targetDate);
      } else {
        latestDay = horizonStart.add(Duration(days: horizonDays - 1));
      }
    }

    final horizonEnd = horizonStart.add(Duration(days: horizonDays - 1));
    if (latestDay.isAfter(horizonEnd)) latestDay = horizonEnd;

    DateTime startDay;
    if (task.recommendedDay != null) {
      startDay = DateTime.parse(task.recommendedDay!);
    } else {
      final now = DateTime.now();
      startDay = DateTime(now.year, now.month, now.day);
    }

    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    if (startDay.isBefore(today)) startDay = today;

    // Full-duration search.
    for (int dayOffset = 0; ; dayOffset++) {
      final day = startDay.add(Duration(days: dayOffset));
      if (day.isAfter(latestDay)) break;
      if (!freeByDay.containsKey(day)) continue;

      final earliestPrereqDay = _earliestPrereqDay(task, batchPlacedDays, today);
      if (day.isBefore(earliestPrereqDay)) continue;

      for (final segment in freeByDay[day]!) {
        if (segment.durationMinutes >= task.durationMinutes) {
          final scheduledStart = segment.start;
          final scheduledEnd = segment.start.add(Duration(minutes: task.durationMinutes));
          final adjusted = task.recommendedDay != null &&
              DateTime.parse(task.recommendedDay!).day != day.day;

          final placedTask = task.copyWith(
            scheduledStart: scheduledStart.toIso8601String(),
            scheduledEnd: scheduledEnd.toIso8601String(),
            adjusted: adjusted,
          );

          _addToOccupied(occupiedByDay, placedTask);
          freeByDay[day] = _rebuildFreeSegmentsForDay(day, occupiedByDay[day]!, preferences);

          return PlacementResult(
            placedTask,
            adjusted: adjusted,
            note: adjusted ? 'spilled_to_next_day' : null,
          );
        }
      }
    }

    // Compression search: largest remaining segment through latest day, floor 15 min.
    DateTime? bestDay;
    FreeSegment? bestSegment;

    for (int dayOffset = 0; ; dayOffset++) {
      final day = startDay.add(Duration(days: dayOffset));
      if (day.isAfter(latestDay)) break;
      if (!freeByDay.containsKey(day)) continue;

      final earliestPrereqDay = _earliestPrereqDay(task, batchPlacedDays, today);
      if (day.isBefore(earliestPrereqDay)) continue;

      for (final segment in freeByDay[day]!) {
        if (segment.durationMinutes >= 15 &&
            (bestSegment == null || segment.durationMinutes > bestSegment.durationMinutes)) {
          bestSegment = segment;
          bestDay = day;
        }
      }
    }

    if (bestSegment != null && bestDay != null) {
      final compressedDuration = bestSegment.durationMinutes.clamp(15, task.durationMinutes);
      final scheduledStart = bestSegment.start;
      final scheduledEnd = scheduledStart.add(Duration(minutes: compressedDuration));

      final placedTask = task.copyWith(
        scheduledStart: scheduledStart.toIso8601String(),
        scheduledEnd: scheduledEnd.toIso8601String(),
        durationMinutes: compressedDuration,
        adjusted: true,
      );

      _addToOccupied(occupiedByDay, placedTask);
      freeByDay[bestDay] = _rebuildFreeSegmentsForDay(bestDay, occupiedByDay[bestDay]!, preferences);

      return PlacementResult(placedTask, adjusted: true, note: 'compressed');
    }

    return PlacementResult(
      task.copyWith(clearSchedule: true),
      adjusted: true,
      note: 'unscheduled',
    );
  }

  void _addToOccupied(
    Map<DateTime, List<_OccupiedInterval>> occupiedByDay,
    Task task,
  ) {
    if (task.scheduledStart == null || task.scheduledEnd == null) return;
    final start = DateTime.parse(task.scheduledStart!);
    final end = DateTime.parse(task.scheduledEnd!);
    final day = DateTime(start.year, start.month, start.day);
    if (occupiedByDay.containsKey(day)) {
      occupiedByDay[day]!.add(_OccupiedInterval(start, end));
      occupiedByDay[day] = _mergeIntervals(occupiedByDay[day]!);
    }
  }

  List<FreeSegment> _rebuildFreeSegmentsForDay(
    DateTime day,
    List<_OccupiedInterval> occupied,
    UserPreferences prefs,
  ) {
    final workStartParts = prefs.workStart.split(':');
    final workEndParts = prefs.workEnd.split(':');
    final workStart = DateTime(day.year, day.month, day.day,
        int.parse(workStartParts[0]), int.parse(workStartParts[1]));
    final workEnd = DateTime(day.year, day.month, day.day,
        int.parse(workEndParts[0]), int.parse(workEndParts[1]));

    final segments = <FreeSegment>[];
    DateTime cursor = workStart;
    // Never schedule into time that has already passed today. Round up to the
    // next 5 minutes so new sessions start on a readable time.
    final now = DateTime.now();
    if (day.year == now.year && day.month == now.month && day.day == now.day) {
      final rounded = DateTime(now.year, now.month, now.day, now.hour,
          (now.minute ~/ 5 + 1) * 5);
      if (rounded.isAfter(cursor)) cursor = rounded;
    }

    for (final interval in occupied) {
      final bufferedStart = interval.start.subtract(Duration(minutes: prefs.bufferMinutes));
      final bufferedEnd = interval.end.add(Duration(minutes: prefs.bufferMinutes));

      if (cursor.isBefore(bufferedStart)) {
        segments.add(FreeSegment(cursor, bufferedStart));
      }
      cursor = cursor.isAfter(bufferedEnd) ? cursor : bufferedEnd;
    }

    if (cursor.isBefore(workEnd)) {
      segments.add(FreeSegment(cursor, workEnd));
    }

    return segments;
  }

  List<_OccupiedInterval> _mergeIntervals(List<_OccupiedInterval> intervals) {
    if (intervals.isEmpty) return [];
    intervals.sort((a, b) => a.start.compareTo(b.start));
    final merged = [_OccupiedInterval(intervals[0].start, intervals[0].end)];
    for (int i = 1; i < intervals.length; i++) {
      final last = merged.last;
      final current = intervals[i];
      if (current.start.isBefore(last.end) || current.start.isAtSameMomentAs(last.end)) {
        merged.last = _OccupiedInterval(last.start,
            current.end.isAfter(last.end) ? current.end : last.end);
      } else {
        merged.add(current);
      }
    }
    return merged;
  }

  String _weekdayToString(int weekday) {
    const days = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
    return days[weekday - 1];
  }
}

class _OccupiedInterval {
  final DateTime start;
  final DateTime end;

  _OccupiedInterval(this.start, this.end);
}

extension _Let<T> on T {
  R let<R>(R Function(T) f) => f(this);
}
