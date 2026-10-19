import 'package:flutter_test/flutter_test.dart';
import 'package:doer/models/models.dart';
import 'package:doer/slotter/slotter.dart';

void main() {
  final prefs = UserPreferences(
    workStart: '09:00',
    workEnd: '18:00',
    bufferMinutes: 10,
    activeDays: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
    timezone: 'UTC',
  );

  // Fixed "today" for deterministic tests: 2026-09-28 (Monday)
  final horizonStart = DateTime(2026, 9, 28);

  Goal goalP1(String id, {String target = '2026-10-04'}) => Goal(
    id: id,
    title: 'Goal $id',
    priority: GoalPriority.P1,
    targetDate: target,
    createdAt: '2026-09-27T00:00:00',
  );

  Task task(
    String id,
    String goalId,
    String day, {
    int duration = 60,
    List<String> prereqs = const [],
  }) => Task(
    id: id,
    goalId: goalId,
    title: 'Task $id',
    durationMinutes: duration,
    recommendedDay: day,
    prerequisiteIds: prereqs,
    createdAt: '2026-09-27T00:00:00',
  );

  test('never places a session in time that has already passed today', () {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final iso = today.toIso8601String().substring(0, 10);
    // Whole-day window so the only constraint is "not before now".
    final slotter = Slotter(UserPreferences(
      workStart: '00:00',
      workEnd: '23:59',
      bufferMinutes: 0,
      activeDays: const ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
      timezone: 'UTC',
    ));
    final results = slotter.placeTasks(
      tasks: [task('now1', 'g1', iso, duration: 15)],
      busyBlocks: [],
      horizonStart: today,
      horizonDays: 7,
    );
    final start = DateTime.parse(results.single.task.scheduledStart!);
    expect(start.isBefore(now), isFalse, reason: 'placed at $start, now is $now');
  });

  group('free-segment construction and placement', () {
    test('places task on recommended day in earliest free segment', () {
      final slotter = Slotter(prefs);
      slotter.allGoals = {'g1': goalP1('g1')};
      slotter.allTasks = [];

      final results = slotter.placeTasks(
        tasks: [task('t1', 'g1', '2026-09-29')],
        busyBlocks: [],
        horizonStart: horizonStart,
        horizonDays: 7,
      );

      final placed = results.first;
      expect(placed.task.scheduledStart, isNotNull);
      // Work window starts 09:00 - first slot
      expect(placed.task.scheduledStart, '2026-09-29T09:00:00.000');
      expect(placed.task.scheduledEnd, '2026-09-29T10:00:00.000');
      expect(placed.adjusted, isFalse);
    });

    test('respects busy blocks - places after buffered busy interval', () {
      final slotter = Slotter(prefs);
      slotter.allGoals = {'g1': goalP1('g1')};
      slotter.allTasks = [];

      final busy = [
        BusyBlock(
          id: 'b1',
          source: 'test.ics',
          start: DateTime(2026, 9, 29, 9),
          end: DateTime(2026, 9, 29, 12),
        ),
      ];

      final results = slotter.placeTasks(
        tasks: [task('t1', 'g1', '2026-09-29')],
        busyBlocks: busy,
        horizonStart: horizonStart,
        horizonDays: 7,
      );

      // Busy ends 12:00, buffer 10min → task starts 12:10
      expect(results.first.task.scheduledStart, '2026-09-29T12:10:00.000');
    });

    test('spills forward when day is full', () {
      final slotter = Slotter(prefs);
      slotter.allGoals = {'g1': goalP1('g1')};
      slotter.allTasks = [];

      // 9 hours of busy blocks on 09-29 fills the whole work window
      final busy = [
        BusyBlock(
          id: 'b1',
          source: 'test.ics',
          start: DateTime(2026, 9, 29, 8),
          end: DateTime(2026, 9, 29, 19),
        ),
      ];

      final results = slotter.placeTasks(
        tasks: [task('t1', 'g1', '2026-09-29')],
        busyBlocks: busy,
        horizonStart: horizonStart,
        horizonDays: 7,
      );

      // Must spill to next day
      expect(results.first.task.scheduledStart!.startsWith('2026-09-30'), isTrue);
      expect(results.first.adjusted, isTrue);
      expect(results.first.note, 'spilled_to_next_day');
    });

    test('compresses when no full-duration segment exists before latest day', () {
      final slotter = Slotter(prefs);
      slotter.allGoals = {'g1': goalP1('g1', target: '2026-09-29')};
      slotter.allTasks = [];

      // 30-minute free window on 09-29; latest day = target = 09-29
      final busy = [
        BusyBlock(
          id: 'b1',
          source: 'test.ics',
          start: DateTime(2026, 9, 29, 9, 30),
          end: DateTime(2026, 9, 29, 19),
        ),
      ];

      final results = slotter.placeTasks(
        tasks: [task('t1', 'g1', '2026-09-29', duration: 120)],
        busyBlocks: busy,
        horizonStart: horizonStart,
        horizonDays: 7,
      );

      final t = results.first.task;
      expect(t.scheduledStart, isNotNull);
      // Placed within 09:00-09:30 window minus buffer → 20 min available
      final placed = DateTime.parse(t.scheduledStart!);
      expect(placed.day, 29);
      // Compressed to fit the free window (20 min = 9:00→9:20 after 10min buffer)
      expect(t.durationMinutes, lessThan(120));
      expect(t.durationMinutes, greaterThanOrEqualTo(15));
      expect(results.first.note, 'compressed');
    });

    test('dependency: dependent task never placed before prerequisite', () {
      final slotter = Slotter(prefs);
      slotter.allGoals = {'g1': goalP1('g1')};
      slotter.allTasks = [];

      final results = slotter.placeTasks(
        tasks: [
          task('t2', 'g1', '2026-09-28', prereqs: ['t1']),
          task('t1', 'g1', '2026-09-30'),
        ],
        busyBlocks: [],
        horizonStart: horizonStart,
        horizonDays: 7,
      );

      final t1 = results.firstWhere((r) => r.task.id == 't1').task;
      final t2 = results.firstWhere((r) => r.task.id == 't2').task;

      // t1 on 09-30 → t2 must be >= 09-30
      expect(t1.scheduledStart!.substring(0, 10), '2026-09-30');
      expect(t2.scheduledStart!.substring(0, 10).compareTo('2026-09-30'), greaterThanOrEqualTo(0));
    });

    test('P1 goal tasks placed before P3 when days collide', () {
      final slotter = Slotter(prefs);
      slotter.allGoals = {
        'g1': goalP1('g1'),
        'g3': Goal(
          id: 'g3',
          title: 'Goal g3',
          priority: GoalPriority.P3,
          targetDate: '2026-10-04',
          createdAt: '2026-09-27T00:00:00',
        ),
      };
      slotter.allTasks = [];

      final results = slotter.placeTasks(
        tasks: [
          task('t3', 'g3', '2026-09-28'),
          task('t1', 'g1', '2026-09-28'),
        ],
        busyBlocks: [],
        horizonStart: horizonStart,
        horizonDays: 7,
      );

      final t1 = results.firstWhere((r) => r.task.id == 't1').task;
      final t3 = results.firstWhere((r) => r.task.id == 't3').task;

      // P1 task occupies 09:00-10:00; P3 must come after
      expect(t1.scheduledStart, '2026-09-28T09:00:00.000');
      expect(t3.scheduledStart, '2026-09-28T10:10:00.000');
    });
  });

  group('inactive days', () {
    test('skips inactive weekdays entirely', () {
      final workdayPrefs = UserPreferences(
        workStart: '09:00',
        workEnd: '18:00',
        bufferMinutes: 10,
        activeDays: ['mon'], // Only Monday active
        timezone: 'UTC',
      );
      final slotter = Slotter(workdayPrefs);
      slotter.allGoals = {'g1': goalP1('g1')};
      slotter.allTasks = [];

      final results = slotter.placeTasks(
        tasks: [task('t1', 'g1', '2026-09-29')], // Tuesday - inactive
        busyBlocks: [],
        horizonStart: horizonStart,
        horizonDays: 7,
      );

      // Tuesday inactive → spills to next Monday? No - horizon is 7 days from 09-28 (Mon)
      // Only 09-28 is active Monday in horizon [09-28, 10-05)
      final t = results.first.task;
      if (t.scheduledStart != null) {
        expect(DateTime.parse(t.scheduledStart!).weekday, equals(DateTime.monday));
      } else {
        expect(results.first.note, 'unscheduled');
      }
    });
  });
}
