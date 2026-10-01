import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:doer/data/database_helper.dart';
import 'package:doer/models/models.dart';
import 'package:doer/orchestration/orchestrator.dart';
import 'package:doer/provider/provider_config_service.dart';
import 'package:doer/slotter/slotter.dart';

/// Live multi-scenario logic tests against the real demo endpoint.
/// Each test seeds fresh state, runs the real pipeline, and audits the
/// result for logic errors.
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  Future<(Orchestrator, DatabaseHelper, Slotter)> setup({
    List<Goal> goals = const [],
    List<BusyBlock> busy = const [],
    UserPreferences? prefs,
  }) async {
    final helper = DatabaseHelper.forTest();
    final configService = _DefaultsOnly(helper);
    final provider = await configService.buildActiveProvider();

    final p = prefs ??
        UserPreferences(
          workStart: '09:00',
          workEnd: '18:00',
          bufferMinutes: 10,
          activeDays: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
          timezone: 'UTC',
        );
    await helper.upsertPreferences(p);
    for (final g in goals) {
      await helper.insertGoal(g);
    }
    if (busy.isNotEmpty) await helper.insertBusyBlocks(busy);

    final slotter = Slotter(p)
      ..allGoals = {for (final g in goals) g.id: g};
    final orchestrator = Orchestrator(
      db: helper,
      providerFactory: () => provider!,
      slotter: slotter,
    )..slotter.allGoals = {for (final g in goals) g.id: g};
    return (orchestrator, helper, slotter);
  }

  String dayStr(DateTime d) =>
      '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

  test('decompose: busy blocks respected, no overlap, within work hours', () async {
    final today = DateTime.now();
    final horizon = [for (var i = 0; i < 7; i++) today.add(Duration(days: i))];

    // Busy 09:00-12:00 and 15:00-17:00 for the next 3 days.
    final busy = <BusyBlock>[];
    for (var i = 0; i < 3; i++) {
      final d = horizon[i];
      busy.add(BusyBlock(
        id: 'b1-$i',
        source: 'cal.ics',
        start: DateTime(d.year, d.month, d.day, 9),
        end: DateTime(d.year, d.month, d.day, 12),
      ));
      busy.add(BusyBlock(
        id: 'b2-$i',
        source: 'cal.ics',
        start: DateTime(d.year, d.month, d.day, 15),
        end: DateTime(d.year, d.month, d.day, 17),
      ));
    }

    final goal = Goal(
      id: 'g1',
      title: 'Learn Rust',
      description: 'Ownership, borrowing, lifetimes, basic programs',
      priority: GoalPriority.P1,
      targetDate: dayStr(today.add(const Duration(days: 6))),
      createdAt: today.toIso8601String(),
    );

    final (orch, helper, _) = await setup(goals: [goal], busy: busy);

    final results = await orch.decompose(goals: [goal]);

    // AUDIT 1: every placed task inside work window.
    for (final r in results.where((r) => r.task.scheduledStart != null)) {
      final s = DateTime.parse(r.task.scheduledStart!);
      final e = DateTime.parse(r.task.scheduledEnd!);
      expect(s.hour, greaterThanOrEqualTo(9), reason: '${r.task.title} starts before 09:00');
      expect(e.hour, lessThan(19), reason: '${r.task.title} ends after 18:00');
      expect(e.isAfter(s), isTrue);
    }

    // AUDIT 2: no overlap with busy blocks (incl. 10min buffer each side).
    for (final r in results.where((r) => r.task.scheduledStart != null)) {
      final s = DateTime.parse(r.task.scheduledStart!);
      final e = DateTime.parse(r.task.scheduledEnd!);
      for (final b in busy) {
        final bufferedStart = b.start.subtract(const Duration(minutes: 10));
        final bufferedEnd = b.end.add(const Duration(minutes: 10));
        final overlaps = s.isBefore(bufferedEnd) && e.isAfter(bufferedStart);
        expect(overlaps, isFalse,
            reason: '${r.task.title} overlaps busy ${b.start}->${b.end}');
      }
    }

    // AUDIT 3: no task-task overlaps.
    final placed = results
        .where((r) => r.task.scheduledStart != null)
        .map((r) => r.task)
        .toList();
    for (var i = 0; i < placed.length; i++) {
      for (var j = i + 1; j < placed.length; j++) {
        final a = placed[i], b = placed[j];
        final aS = DateTime.parse(a.scheduledStart!);
        final aE = DateTime.parse(a.scheduledEnd!);
        final bS = DateTime.parse(b.scheduledStart!);
        final bE = DateTime.parse(b.scheduledEnd!);
        expect(aS.isBefore(bE) && bS.isBefore(aE), isFalse,
            reason: 'tasks overlap: ${a.title} vs ${b.title}');
      }
    }

    // AUDIT 4: DB state matches returned placements.
    final persisted = await helper.getAllTasks();
    expect(persisted.length, results.length);
    for (final t in persisted) {
      final fromResult = results.firstWhere((r) => r.task.id == t.id);
      expect(t.scheduledStart, fromResult.task.scheduledStart,
          reason: 'DB disagrees with placement result for ${t.title}');
      expect(t.recommendedDay, isNotNull);
    }

    await helper.close();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('decompose: dependencies respected across tasks', () async {
    final today = DateTime.now();
    final goal = Goal(
      id: 'g1',
      title: 'Write a research paper',
      description: 'Pick topic, research, outline, draft, revise',
      priority: GoalPriority.P1,
      targetDate: dayStr(today.add(const Duration(days: 6))),
      createdAt: today.toIso8601String(),
    );

    final (orch, helper, _) = await setup(goals: [goal]);
    await orch.decompose(goals: [goal]);

    final persisted = await helper.getAllTasks();
    expect(persisted.length, greaterThan(0));

    // AUDIT: for every dependency pair, dependent is not before prereq.
    for (final t in persisted) {
      for (final prereqId in t.prerequisiteIds) {
        final prereq = persisted.firstWhere(
          (p) => p.id == prereqId,
          orElse: () => fail('prereq $prereqId of ${t.title} not in batch'),
        );
        if (t.scheduledStart != null && prereq.scheduledStart != null) {
          final tDay = DateTime.parse(t.scheduledStart!);
          final pDay = DateTime.parse(prereq.scheduledStart!);
          expect(tDay.isAfter(pDay) || tDay.isAtSameMomentAs(pDay), isTrue,
              reason: '${t.title} scheduled before prereq ${prereq.title}');
        }
      }
    }

    // AUDIT: prereq graph is acyclic in DB.
    final visited = <String>{};
    final inStack = <String>{};
    void dfs(String id, List<Task> tasks) {
      if (inStack.contains(id)) fail('cycle detected at $id');
      if (visited.contains(id)) return;
      inStack.add(id);
      final t = tasks.where((x) => x.id == id).firstOrNull;
      if (t != null) {
        for (final p in t.prerequisiteIds) {
          dfs(p, tasks);
        }
      }
      inStack.remove(id);
      visited.add(id);
    }

    for (final t in persisted) {
      dfs(t.id, persisted);
    }

    await helper.close();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('replan: completed frozen, unfinished re-dated, tips returned', () async {
    final today = DateTime.now();
    final goal = Goal(
      id: 'g1',
      title: 'Learn Rust',
      description: 'ownership basics then practice',
      priority: GoalPriority.P1,
      targetDate: dayStr(today.add(const Duration(days: 6))),
      createdAt: today.toIso8601String(),
    );

    final (orch, helper, _) = await setup(goals: [goal]);
    final results = await orch.decompose(goals: [goal]);
    expect(results, isNotEmpty);

    // Complete the first task.
    final firstId = results.first.task.id;
    await orch.completeTask(firstId);
    final completedBefore = await helper.getTask(firstId);
    expect(completedBefore!.status, TaskStatus.completed);

    // Skip a different task to seed skip_count.
    final secondId = results
        .firstWhere((r) => r.task.id != firstId && r.task.scheduledStart != null)
        .task
        .id;
    await orch.skipTask(secondId);

    // Re-plan.
    final replanResult = await orch.replan();

    // AUDIT 1: completed task untouched.
    final completedAfter = await helper.getTask(firstId);
    expect(completedAfter!.status, TaskStatus.completed);
    expect(completedAfter.scheduledStart, completedBefore.scheduledStart,
        reason: 're-plan mutated a completed task!');

    // AUDIT 2: completed task not re-sent as mutable (check via re-plan result
    // set - completed tasks must not appear in placement results as pending).
    final mutatedCompleted = replanResult.placementResults
        .where((r) => r.task.id == firstId && r.task.status != TaskStatus.completed)
        .toList();
    expect(mutatedCompleted, isEmpty,
        reason: 'completed task appears mutable in re-plan');

    // AUDIT 3: all unfinished tasks still placed or flagged.
    final unfinishedAfter = (await helper.getAllTasks())
        .where((t) => t.status != TaskStatus.completed)
        .toList();
    expect(unfinishedAfter, isNotEmpty);
    for (final t in unfinishedAfter) {
      if (t.scheduledStart == null) {
        // Unscheduled is legal only if no capacity existed; with a free week
        // that's a logic error.
        fail('${t.title} left unscheduled despite free horizon');
      }
    }

    // AUDIT 4: no placement before today.
    final todayStart = DateTime(today.year, today.month, today.day);
    for (final t in unfinishedAfter) {
      final s = DateTime.parse(t.scheduledStart!);
      expect(s.isBefore(todayStart), isFalse,
          reason: '${t.title} scheduled in the past');
    }

    await helper.close();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('skip flow: local re-slot, no LLM, skip_count increments', () async {
    final today = DateTime.now();
    final goal = Goal(
      id: 'g1',
      title: 'Learn Rust',
      description: 'daily practice',
      priority: GoalPriority.P1,
      targetDate: dayStr(today.add(const Duration(days: 6))),
      createdAt: today.toIso8601String(),
    );

    final (orch, helper, _) = await setup(goals: [goal]);
    final results = await orch.decompose(goals: [goal]);

    final target = results
        .firstWhere((r) => r.task.scheduledStart != null)
        .task;
    final before = await helper.getTask(target.id);

    final skipResult = await orch.skipTask(target.id);

    // AUDIT: skip_count incremented.
    expect(skipResult.task.skipCount, before!.skipCount + 1);

    // AUDIT: re-slotted, not deleted.
    expect(skipResult.task.scheduledStart, isNotNull,
        reason: 'skip left task unscheduled');

    // AUDIT: not in the past.
    final todayStart = DateTime(today.year, today.month, today.day);
    final s = DateTime.parse(skipResult.task.scheduledStart!);
    expect(s.isBefore(todayStart), isFalse, reason: 're-slot into the past');

    // AUDIT: persisted.
    final after = await helper.getTask(target.id);
    expect(after!.skipCount, before.skipCount + 1);
    expect(after.scheduledStart, skipResult.task.scheduledStart);

    // AUDIT: no overlap with other placed tasks.
    final others = (await helper.getAllTasks())
        .where((t) => t.id != target.id && t.scheduledStart != null)
        .toList();
    for (final o in others) {
      final oS = DateTime.parse(o.scheduledStart!);
      final oE = DateTime.parse(o.scheduledEnd!);
      final sS = DateTime.parse(after.scheduledStart!);
      final sE = DateTime.parse(after.scheduledEnd!);
      expect(sS.isBefore(oE) && oS.isBefore(sE), isFalse,
          reason: 're-slotted task overlaps ${o.title}');
    }

    await helper.close();
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('multi-goal: P1 before P3 on same day, both scheduled', () async {
    final today = DateTime.now();
    final g1 = Goal(
      id: 'g1',
      title: 'Interview prep',
      description: 'systems design practice',
      priority: GoalPriority.P1,
      targetDate: dayStr(today.add(const Duration(days: 6))),
      createdAt: today.toIso8601String(),
    );
    final g3 = Goal(
      id: 'g3',
      title: 'Learn guitar',
      description: 'chords and strumming',
      priority: GoalPriority.P3,
      targetDate: dayStr(today.add(const Duration(days: 6))),
      createdAt: today.toIso8601String(),
    );

    final (orch, helper, _) = await setup(goals: [g1, g3]);
    await orch.decompose(goals: [g1, g3]);

    final persisted = await helper.getAllTasks();
    expect(persisted.length, greaterThan(0));

    // AUDIT: every task scheduled, none unscheduled, none in past.
    final todayStart = DateTime(today.year, today.month, today.day);
    for (final t in persisted) {
      expect(t.scheduledStart, isNotNull, reason: '${t.title} unscheduled');
      final s = DateTime.parse(t.scheduledStart!);
      expect(s.isBefore(todayStart), isFalse,
          reason: '${t.title} in the past');
      expect(t.goalId, anyOf('g1', 'g3'));
    }

    // AUDIT: priority governs contention for the SAME recommended day.
    // When P1 and P3 tasks share a recommended_day, P1 must get the
    // earlier slot that day. (Cross-day ordering is LLM day-authority,
    // not a priority violation - SPEC R9/R3-Q3.)
    final byRecDay = <String, List<Task>>{};
    for (final t in persisted) {
      byRecDay.putIfAbsent(t.recommendedDay!, () => []).add(t);
    }
    for (final entry in byRecDay.entries) {
      final g1Tasks = entry.value
          .where((t) => t.goalId == 'g1' && t.scheduledStart != null)
          .map((t) => t.scheduledStart!)
          .toList()
        ..sort();
      final g3Tasks = entry.value
          .where((t) => t.goalId == 'g3' && t.scheduledStart != null)
          .map((t) => t.scheduledStart!)
          .toList()
        ..sort();
      if (g1Tasks.isNotEmpty && g3Tasks.isNotEmpty) {
        // Only when both actually landed on that same placed day.
        final g1Day = g1Tasks.first.substring(0, 10);
        final g3Day = g3Tasks.first.substring(0, 10);
        if (g1Day == g3Day) {
          expect(g1Tasks.first.compareTo(g3Tasks.first), lessThan(0),
              reason: 'P3 occupies an earlier slot than P1 on shared '
                  'recommended day ${entry.key}');
        }
      }
    }

    await helper.close();
  }, timeout: const Timeout(Duration(minutes: 10)));
}

class _DefaultsOnly extends ProviderConfigService {
  _DefaultsOnly(DatabaseHelper db) : super(db: db);

  @override
  Future<String?> readKey(String key) async => null;
}
