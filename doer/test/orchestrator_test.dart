import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:doer/data/database_helper.dart';
import 'package:doer/models/models.dart';
import 'package:doer/orchestration/orchestrator.dart';
import 'package:doer/provider/provider.dart';
import 'package:doer/slotter/slotter.dart';

/// Fake provider: returns a canned task list; records the payloads it saw.
class FakeProvider implements LlmProvider {
  final Map<String, dynamic> response;
  final List<Map<String, dynamic>> receivedSchemas = [];
  final List<String> receivedUsers = [];
  int calls = 0;

  FakeProvider(this.response);

  @override
  Future<Map<String, dynamic>> complete({
    required String system,
    required String user,
    required Map<String, dynamic> jsonSchema,
  }) async {
    calls++;
    receivedSchemas.add(jsonSchema);
    receivedUsers.add(user);
    return response;
  }
}

void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final now = DateTime(2026, 9, 27);

  Goal goal(String id) => Goal(
        id: id,
        title: 'Learn Rust',
        description: 'Finish the rust book',
        priority: GoalPriority.P1,
        targetDate: '2026-10-04',
        createdAt: now.toIso8601String(),
      );

  test('decompose: LLM tasks validated, persisted, placed, and kept monotonic on replan', () async {

    // Use an in-memory override for test isolation.
    // (DatabaseHelper targets the platform DB; for this smoke test we accept a
    // real file-backed DB via sqflite_ffi's temp dir.)
    final helper = DatabaseHelper.forTest();

    await helper.insertGoal(goal('g1'));

    final canned = {
      'tasks': [
        {
          'task_id': 'llm-1',
          'goal_id': 'g1',
          'title': 'Read chapter 1',
          'duration_minutes': 60,
          'recommended_day': '2026-09-28',
          'prerequisite_ids': [],
        },
        {
          'task_id': 'llm-2',
          'goal_id': 'g1',
          'title': 'Read chapter 2',
          'duration_minutes': 60,
          'recommended_day': '2026-09-29',
          'prerequisite_ids': ['llm-1'],
        },
        // Invalid: unknown goal_id — must be silently dropped.
        {
          'task_id': 'llm-3',
          'goal_id': 'nope',
          'title': 'Bogus',
          'duration_minutes': 60,
          'recommended_day': '2026-09-28',
          'prerequisite_ids': [],
        },
      ],
    };

    final provider = FakeProvider(canned);
    final prefs = await _prefsOrDefault(helper);
    final slotter = Slotter(prefs)..allGoals = {'g1': goal('g1')};
    final orchestrator = Orchestrator(
      db: helper,
      providerFactory: () => provider,
      slotter: slotter,
    )..slotter.allGoals = {'g1': goal('g1')};

    // --- Initial decomposition ---
    final results = await orchestrator.decompose(goals: [goal('g1')]);

    // 2 valid tasks (bogus goal dropped), both placed.
    final placed = results.where((r) => r.task.scheduledStart != null).toList();
    expect(placed.length, 2);

    // DB persistence: tasks exist with placements.
    final allTasks = await helper.getAllTasks();
    expect(allTasks.length, 2);
    expect(allTasks.every((t) => t.scheduledStart != null), isTrue);

    // Prereq remapped: llm-1 (now a UUID) must be prereq of the chapter-2 task.
    final ch1 = allTasks.firstWhere((t) => t.title == 'Read chapter 1');
    final ch2 = allTasks.firstWhere((t) => t.title == 'Read chapter 2');
    expect(ch2.prerequisiteIds, [ch1.id]);
    expect(
      DateTime.parse(ch2.scheduledStart!).isAfter(DateTime.parse(ch1.scheduledStart!)) ||
          DateTime.parse(ch2.scheduledStart!).isAtSameMomentAs(DateTime.parse(ch1.scheduledStart!)),
      isTrue,
    );

    // Schema contract: provider received the required JSON schema shape.
    final schema = provider.receivedSchemas.first;
    final itemsProps =
        schema['properties']['tasks']['items']['properties'] as Map<String, dynamic>;
    expect(itemsProps.containsKey('recommended_day'), isTrue);
    expect((schema['properties']['tasks']['items']['required'] as List)
        .contains('recommended_day'), isTrue);

    // User payload carried per-day summary + today + goals.
    final payload = jsonDecode(provider.receivedUsers.first) as Map<String, dynamic>;
    expect(payload.containsKey('per_day_summary'), isTrue);
    expect(payload.containsKey('today'), isTrue);
    expect((payload['goals'] as List).length, 1);

    // --- Complete one task: monotonic freeze ---
    await orchestrator.completeTask(ch1.id);
    final frozen = await helper.getTask(ch1.id);
    expect(frozen!.status, TaskStatus.completed);

    // --- Re-plan: ch2 re-dated by LLM, ch1 never re-sent as mutable ---
    final replanCanned = {
      'tasks': [
        {
          'task_id': ch2.id, // must echo existing UUID
          'goal_id': 'g1',
          'title': 'Read chapter 2',
          'duration_minutes': 90,
          'recommended_day': '2026-09-28',
          'prerequisite_ids': [],
        },
      ],
      'tips': ['Consistency beats intensity.'],
    };
    final replanProvider = FakeProvider(replanCanned);
    final orchestrator2 = Orchestrator(
      db: helper,
      providerFactory: () => replanProvider,
      slotter: Slotter(prefs),
    );
    orchestrator2.slotter.allGoals = {'g1': goal('g1')};
    orchestrator2.slotter.allTasks = await helper.getAllTasks();

    final replanResult = await orchestrator2.replan();

    expect(replanProvider.calls, 1);
    expect(replanResult.tips, ['Consistency beats intensity.']);

    // Re-plan payload: only unfinished tasks mutable, completed only in digest.
    final replanPayload =
        jsonDecode(replanProvider.receivedUsers.first) as Map<String, dynamic>;
    final unfinished = replanPayload['unfinished_tasks'] as List;
    expect(unfinished.length, 1);
    expect(unfinished.first['task_id'], ch2.id);
    expect(unfinished.first['skip_count'], 0);
    expect((replanPayload['completed_digest'] as List).length, 1);

    // ch2 now carries the new recommended_day and a fresh placement.
    final ch2After = await helper.getTask(ch2.id);
    expect(ch2After!.recommendedDay, '2026-10-01');
    expect(ch2After.scheduledStart, isNotNull);
    expect(ch2After.status, TaskStatus.pending);

    // ch1 untouched: still completed, still placed.
    final ch1After = await helper.getTask(ch1.id);
    expect(ch1After!.status, TaskStatus.completed);
    expect(ch1After.scheduledStart, ch1.scheduledStart);

    // --- Skip flow: local re-slot, no LLM ---
    final callsBefore = replanProvider.calls;
    final skipResult = await orchestrator2.skipTask(ch2.id);
    expect(skipResult.task.scheduledStart, isNotNull);
    expect(skipResult.task.skipCount, 1);
    expect(replanProvider.calls, callsBefore); // zero LLM calls

    await helper.close();
  });

  test('replan: user-edited schedule is pinned - never re-cleared, re-slotted, or rewritten', () async {
    final helper = DatabaseHelper.forTest();
    // Goal with a horizon-safe target date: the shared goal() helper pins
    // 2026-10-04 (past), which would cap latestDay before startDay and
    // leave the normal task unplaced regardless of the pin logic.
    final today0 = DateTime.now();
    final target = today0.add(const Duration(days: 6));
    final ueGoal = Goal(
      id: 'g-ue',
      title: 'Learn Rust',
      description: '',
      priority: GoalPriority.P1,
      targetDate:
          '${target.year}-${target.month.toString().padLeft(2, '0')}-${target.day.toString().padLeft(2, '0')}',
      createdAt: today0.toIso8601String(),
    );
    await helper.insertGoal(ueGoal);

    // Horizon-relative fixtures: no hardcoded dates, no clock brittleness.
    final today = DateTime.now();
    String dayKey(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    final day1 = today.add(const Duration(days: 1));
    final day3 = today.add(const Duration(days: 3));

    // Two pending tasks: one user-edited (moved in Google Calendar), one not.
    final edited = Task(
      id: 't-edited',
      goalId: 'g-ue',
      title: 'Edited task',
      durationMinutes: 60,
      recommendedDay: dayKey(day1),
      scheduledStart: '${dayKey(day1)}T15:30:00.000',
      scheduledEnd: '${dayKey(day1)}T16:30:00.000',
      deviceEventId: 'ev-edited',
      userEdited: true,
      createdAt: today.toIso8601String(),
    );
    final normal = Task(
      id: 't-normal',
      goalId: 'g-ue',
      title: 'Normal task',
      durationMinutes: 60,
      recommendedDay: dayKey(day1),
      scheduledStart: '${dayKey(day1)}T09:00:00.000',
      scheduledEnd: '${dayKey(day1)}T10:00:00.000',
      deviceEventId: 'ev-normal',
      createdAt: today.toIso8601String(),
    );
    await helper.insertTask(edited);
    await helper.insertTask(normal);

    // LLM says: move EVERYTHING to day3 (maximally different from edits).
    final provider = FakeProvider({
      'tasks': [
        {
          'task_id': edited.id,
          'goal_id': 'g-ue',
          'title': 'Edited task',
          'duration_minutes': 60,
          'recommended_day': dayKey(day3),
          'prerequisite_ids': [],
        },
        {
          'task_id': normal.id,
          'goal_id': 'g-ue',
          'title': 'Normal task',
          'duration_minutes': 60,
          'recommended_day': dayKey(day3),
          'prerequisite_ids': [],
        },
      ],
      'tips': [],
    });
    final prefs = await helper.getPreferences() ?? UserPreferences(
      workStart: '09:00',
      workEnd: '18:00',
      bufferMinutes: 10,
      activeDays: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
      timezone: 'UTC',
    );
    final orchestrator = Orchestrator(
      db: helper,
      providerFactory: () => provider,
      slotter: Slotter(prefs),
    );
    orchestrator.slotter.allGoals = {'g-ue': ueGoal};
    orchestrator.slotter.allTasks = await helper.getAllTasks();

    await orchestrator.replan();

    // User-edited task: schedule, event id, and flag untouched.
    final editedAfter = await helper.getTask(edited.id);
    expect(editedAfter!.scheduledStart, '${dayKey(day1)}T15:30:00.000');
    expect(editedAfter.scheduledEnd, '${dayKey(day1)}T16:30:00.000');
    expect(editedAfter.deviceEventId, 'ev-edited');
    expect(editedAfter.userEdited, isTrue);
    // The LLM's new recommended_day did NOT import (pin wins).
    expect(editedAfter.recommendedDay, dayKey(day1));

    // Normal task: re-dated per the LLM.
    final normalAfter = await helper.getTask(normal.id);
    expect(normalAfter!.recommendedDay, dayKey(day3));
    expect(normalAfter.scheduledStart, isNotNull);

    await helper.close();
  });

  test('decompose: empty task list fails after exactly one repair retry', () async {
    final helper = DatabaseHelper.forTest();
    await helper.insertGoal(goal('g-bad'));

    final badProvider = _RetryThenFailProvider();
    final prefs = await _prefsOrDefault(helper);

    final orchestrator = Orchestrator(
      db: helper,
      providerFactory: () => badProvider,
      slotter: Slotter(prefs),
    );
    orchestrator.slotter.allGoals = {'g-bad': goal('g-bad')};

    await expectLater(
      orchestrator.decompose(goals: [goal('g-bad')]),
      throwsA(isA<Exception>()),
    );
    // Schema violation + exactly one repair retry = 2 calls.
    expect(badProvider.calls, 2);

    await helper.close();
  });
}

class _RetryThenFailProvider implements LlmProvider {
  int calls = 0;

  @override
  Future<Map<String, dynamic>> complete({
    required String system,
    required String user,
    required Map<String, dynamic> jsonSchema,
  }) async {
    calls++;
    throw SchemaViolationError('bad JSON', 'not json');
  }
}

Future<UserPreferences> _prefsOrDefault(DatabaseHelper helper) async {
  final existing = await helper.getPreferences();
  if (existing != null) return existing;
  final prefs = UserPreferences(
    workStart: '09:00',
    workEnd: '18:00',
    bufferMinutes: 10,
    activeDays: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
    timezone: 'UTC',
  );
  await helper.upsertPreferences(prefs);
  return prefs;
}
