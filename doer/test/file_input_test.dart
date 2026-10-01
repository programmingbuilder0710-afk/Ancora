import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:doer/data/database_helper.dart';
import 'package:doer/extraction/extraction.dart';
import 'package:doer/models/models.dart';
import 'package:doer/orchestration/orchestrator.dart';
import 'package:doer/slotter/slotter.dart';

/// File-input and storage-integrity edge cases. All hermetic (no network).
void main() {
  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  final service = ExtractionService();
  late Directory tmp;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('doer_files');
  });

  tearDown(() {
    tmp.deleteSync(recursive: true);
  });

  String ics(String events) => 'BEGIN:VCALENDAR\n$events\nEND:VCALENDAR';

  group('file input: .ics edge cases', () {
    test('all-day event (DATE value) marks the full work window busy', () {
      final blocks = service.parseIcsContent(ics('''
BEGIN:VEVENT
DTSTART;VALUE=DATE:20260928
DTEND;VALUE=DATE:20260929
SUMMARY:Conference day
END:VEVENT'''), 'conf.ics');
      expect(blocks.length, 1);
      expect(blocks.first.start.hour, 0);
      // DTEND DATE is exclusive in iCal: a 1-day event ends next day 00:00.
      expect(blocks.first.end.day, 2);
    });

    test('UTC times converted to local', () {
      final blocks = service.parseIcsContent(ics('''
BEGIN:VEVENT
DTSTART:20260929T090000Z
DTEND:20260929T100000Z
SUMMARY:UTC meeting
END:VEVENT'''), 'utc.ics');
      expect(blocks.length, 1);
      // Parsing yields a local DateTime; UTC 09:00 differs from local 09:00
      // unless the test machine is UTC. Verify the round-trip consistency:
      final start = blocks.first.start;
      expect(start.toUtc().toIso8601String(), contains('09:00:00.000Z'));
    });

    test('event without DTEND defaults to 1 hour', () {
      final blocks = service.parseIcsContent(ics('''
BEGIN:VEVENT
DTSTART:20260929T140000
SUMMARY:No end
END:VEVENT'''), 'noend.ics');
      expect(blocks.length, 1);
      expect(blocks.first.end.difference(blocks.first.start).inHours, 1);
    });

    test('DTSTART missing entirely: event skipped, no crash', () {
      final blocks = service.parseIcsContent(ics('''
BEGIN:VEVENT
DTEND:20260929T100000
SUMMARY:Ghost
END:VEVENT'''), 'ghost.ics');
      expect(blocks, isEmpty);
    });

    test('DTEND before DTSTART: skipped as invalid, not negative block', () {
      final blocks = service.parseIcsContent(ics('''
BEGIN:VEVENT
DTSTART:20260929T150000
DTEND:20260929T140000
SUMMARY:Time traveler
END:VEVENT'''), 'rev.ics');
      expect(blocks, isEmpty);
    });

    test('garbage file with no VEVENTs yields nothing, no crash', () {
      final blocks = service.parseIcsContent('not a calendar at all', 'junk.ics');
      expect(blocks, isEmpty);
    });

    test('empty VEVENT blocks are tolerated', () {
      final blocks = service.parseIcsContent(ics('''
BEGIN:VEVENT
END:VEVENT
BEGIN:VEVENT
DTSTART:20260929T090000
DTEND:20260929T100000
SUMMARY:Real
END:VEVENT'''), 'mixed.ics');
      expect(blocks.length, 1);
      expect(blocks.first.source, 'mixed.ics');
    });

    test('CRLF line endings parsed (Windows/Google exports)', () {
      final content = 'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n'
          'DTSTART:20260929T090000\r\nDTEND:20260929T100000\r\n'
          'SUMMARY:CRLF\r\nEND:VEVENT\r\nEND:VCALENDAR\r\n';
      final blocks = service.parseIcsContent(content, 'crlf.ics');
      expect(blocks.length, 1);
    });

    test('folded content lines (RFC 5545 line folding) unfolded', () {
      // Long SUMMARY folded with CRLF + space continuation.
      final content = 'BEGIN:VCALENDAR\r\nBEGIN:VEVENT\r\n'
          'DTSTART:20260929T090000\r\nDTEND:20260929T100000\r\n'
          'SUMMARY:This is a very long summary that\r\n gets folded across lines\r\nEND:VEVENT\r\nEND:VCALENDAR';
      final blocks = service.parseIcsContent(content, 'folded.ics');
      expect(blocks.length, 1);
    });

    test('importIcsFile with an unreadable path throws cleanly', () async {
      final helper = DatabaseHelper.forTest();
      final orchestrator = Orchestrator(
        db: helper,
        providerFactory: () => throw StateError('unreachable'),
        slotter: Slotter(UserPreferences(timezone: 'UTC')),
      );
      await expectLater(
        () => orchestrator.importIcsFile('/nonexistent/path.ics', 'x.ics'),
        throwsA(isA<Exception>()),
      );
      await helper.close();
    });
  });

  group('file input: document extraction', () {
    test('txt extraction reads full text', () async {
      final f = File('${tmp.path}/notes.txt')..writeAsString('Goal context: learn Rust');
      final text = await service.extractText(f);
      expect(text, contains('learn Rust'));
    });

    test('md extraction reads markdown', () async {
      final f = File('${tmp.path}/plan.md')..writeAsString('# Plan\n- own a cat');
      final text = await service.extractText(f);
      expect(text, contains('own a cat'));
    });

    test('binary pdf-looking file with no text layer yields printable chars or empty', () async {
      final f = File('${tmp.path}/fake.pdf')
        ..writeAsBytesSync([0x25, 0x50, 0x44, 0x46, 0x00, 0x01, 0xFF]);
      final text = await service.extractText(f);
      // Must not throw; content is whatever survived the sanitizer.
      expect(text, isA<String>());
    });

    test('unsupported extension returns empty string', () async {
      final f = File('${tmp.path}/data.xyz')..writeAsString('stuff');
      final text = await service.extractText(f);
      expect(text, '');
    });

    test('truncation kicks in past 5000 chars and preserves head', () async {
      final long = 'a' * 6000;
      final f = File('${tmp.path}/big.txt')..writeAsString(long);
      final text = await service.extractText(f);
      expect(text.length, lessThan(5100));
      expect(text.startsWith('aaaa'), isTrue);
      expect(text, contains('[truncated]'));
    });

    test('extracted text persisted to documents table and reusable', () async {
      final helper = DatabaseHelper.forTest();
      final text = 'Rust ownership rules...';
      await helper.insertGoal(Goal(
        id: 'g1',
        title: 'Rust',
        priority: GoalPriority.P1,
        targetDate: '2026-10-04',
        createdAt: DateTime.now().toIso8601String(),
      ));
      await helper.insertDocument(
          id: 'd1', goalId: 'g1', filename: 'rust.txt', extractedText: text);
      final docs = await helper.getDocumentsByGoal('g1');
      expect(docs.length, 1);
      expect(docs.first['extracted_text'], text);

      // Re-extraction is not required - stored text is the canonical copy.
      expect(await helper.getDocumentsByGoal('g1'), isNotEmpty);
      await helper.close();
    });
  });

  group('storage integrity', () {
    test('goal delete does not orphan tasks (FK behavior audit)', () async {
      final helper = DatabaseHelper.forTest();
      final goal = Goal(
        id: 'g1',
        title: 'X',
        priority: GoalPriority.P1,
        targetDate: '2026-10-04',
        createdAt: DateTime.now().toIso8601String(),
      );
      await helper.insertGoal(goal);
      await helper.insertTask(Task(
        id: 't1',
        goalId: 'g1',
        title: 'Task under doomed goal',
        durationMinutes: 30,
        createdAt: DateTime.now().toIso8601String(),
      ));

      // With FK ON + cascading deleteGoal: deleting the goal removes its
      // tasks atomically - no orphans can exist.
      await helper.deleteGoal('g1');
      expect(await helper.getGoal('g1'), isNull);
      expect(await helper.getTask('t1'), isNull,
          reason: 'LOGIC ERROR: task survived goal deletion');
      await helper.close();
    });

    test('busy blocks: range query only returns overlapping blocks', () async {
      final helper = DatabaseHelper.forTest();
      await helper.insertBusyBlocks([
        BusyBlock(
            id: 'a', source: 'x', start: DateTime(2026, 9, 28, 9), end: DateTime(2026, 9, 28, 10)),
        BusyBlock(
            id: 'b', source: 'x', start: DateTime(2026, 10, 5, 9), end: DateTime(2026, 10, 5, 10)),
      ]);
      final inRange = await helper.getBusyBlocksInRange(
          DateTime(2026, 9, 28), DateTime(2026, 9, 29));
      expect(inRange.length, 1);
      expect(inRange.first.id, 'a');
      await helper.close();
    });

    test('duplicate ics import: same source replaced atomically', () async {
      final helper = DatabaseHelper.forTest();
      final orchestrator = Orchestrator(
        db: helper,
        providerFactory: () => throw StateError('unreachable'),
        slotter: Slotter(UserPreferences(timezone: 'UTC')),
      );

      final f1 = File('${tmp.path}/a.ics')..writeAsStringSync(ics('''
BEGIN:VEVENT
DTSTART:20260929T090000
DTEND:20260929T100000
SUMMARY:One
END:VEVENT
BEGIN:VEVENT
DTSTART:20260930T090000
DTEND:20260930T100000
SUMMARY:Two
END:VEVENT'''));
      await orchestrator.importIcsFile(f1.path, 'cal.ics');

      final f2 = File('${tmp.path}/b.ics')..writeAsStringSync(ics('''
BEGIN:VEVENT
DTSTART:20260929T110000
DTEND:20260929T120000
SUMMARY:Replacement
END:VEVENT'''));
      await orchestrator.importIcsFile(f2.path, 'cal.ics');

      final all = await helper.getBusyBlocksInRange(
          DateTime(2026, 9, 1), DateTime(2026, 11, 1));
      expect(all.length, 1, reason: 're-import must fully replace same-source');
      expect(all.first.start.hour, 11);
      await helper.close();
    });

    test('task with nonexistent goal_id cannot insert (FK enforced?)', () async {
      final helper = DatabaseHelper.forTest();
      // SQLite foreign_keys are OFF by default in sqflite; audit actual
      // behavior: can a task row insert with a dangling goal reference?
      var inserted = false;
      try {
        await helper.insertTask(Task(
          id: 'ghost',
          goalId: 'no-such-goal',
          title: 'Ghost task',
          durationMinutes: 30,
          createdAt: DateTime.now().toIso8601String(),
        ));
        inserted = true;
      } catch (_) {}
      expect(inserted, isFalse,
          reason: 'LOGIC ERROR: task inserted with dangling goal_id');
      expect(await helper.getTask('ghost'), isNull);
      await helper.close();
    });

    test('completeTask idempotent; skipTask on completed throws', () async {
      final helper = DatabaseHelper.forTest();
      final goal = Goal(
        id: 'g1',
        title: 'X',
        priority: GoalPriority.P1,
        targetDate: '2026-10-04',
        createdAt: DateTime.now().toIso8601String(),
      );
      await helper.insertGoal(goal);
      await helper.insertTask(Task(
        id: 't1',
        goalId: 'g1',
        title: 'T',
        durationMinutes: 30,
        createdAt: DateTime.now().toIso8601String(),
      ));

      await helper.updateTask((await helper.getTask('t1'))!
          .copyWith(status: TaskStatus.completed));
      // Second completion: no-op, no throw.
      final orchestrator = Orchestrator(
        db: helper,
        providerFactory: () => throw StateError('unreachable'),
        slotter: Slotter(UserPreferences(timezone: 'UTC')),
      );
      await orchestrator.completeTask('t1');
      // Skip on completed: must throw.
      await expectLater(
        () => orchestrator.skipTask('t1'),
        throwsA(isA<Exception>()),
      );
      await helper.close();
    });
  });

  group('calendar generation: slotter boundaries', () {
    final prefs = UserPreferences(
      workStart: '09:00',
      workEnd: '18:00',
      bufferMinutes: 10,
      activeDays: ['mon', 'tue', 'wed', 'thu', 'fri'],
      timezone: 'UTC',
    );

    Slotter slotterWithGoals() {
      final s = Slotter(prefs);
      s.allGoals = {
        'g1': Goal(
          id: 'g1',
          title: 'G',
          priority: GoalPriority.P1,
          targetDate: '2026-10-04',
          createdAt: '2026-09-01T00:00:00',
        ),
      };
      return s;
    }

    test('task exactly filling free segment fits without spill', () {
      final s = slotterWithGoals();
      final results = s.placeTasks(
        tasks: [
          Task(
              id: 't1',
              goalId: 'g1',
              title: 'Exact fit',
              durationMinutes: 540,
              recommendedDay: '2026-09-28',
              createdAt: '2026-09-01'),
        ],
        busyBlocks: [],
        horizonStart: DateTime(2026, 9, 28),
        horizonDays: 7,
      );
      // 09:00-18:00 = 540min. Exact fit should place at 09:00.
      expect(results.first.task.scheduledStart, '2026-09-28T09:00:00.000');
      expect(results.first.adjusted, isFalse);
    });

    test('task longer than any free window compresses to 15min floor or largest segment', () {
      final s = slotterWithGoals();
      final results = s.placeTasks(
        tasks: [
          Task(
              id: 't1',
              goalId: 'g1',
              title: 'Oversized',
              durationMinutes: 480,
              recommendedDay: '2026-09-28',
              pinnedDeadline: '2026-09-28', // must stay on Monday
              createdAt: '2026-09-01'),
        ],
        busyBlocks: [
          BusyBlock(
              id: 'b',
              source: 'x',
              start: DateTime(2026, 9, 28, 12),
              end: DateTime(2026, 9, 28, 18)),
        ],
        horizonStart: DateTime(2026, 9, 28),
        horizonDays: 7,
      );
      // Free: 09:00-12:00 minus buffer 11:50 => ~170min. 480 does not fit.
      final t = results.first.task;
      expect(t.scheduledStart, isNotNull);
      expect(t.durationMinutes, lessThan(480));
      expect(t.durationMinutes, greaterThanOrEqualTo(15));
      expect(results.first.note, 'compressed');
    });

    test('work window crossing midnight is rejected safely', () {
      final badPrefs = UserPreferences(
        workStart: '22:00',
        workEnd: '06:00', // start > end
        bufferMinutes: 10,
        activeDays: ['mon'],
        timezone: 'UTC',
      );
      final s = Slotter(badPrefs);
      s.allGoals = {
        'g1': Goal(
          id: 'g1',
          title: 'G',
          priority: GoalPriority.P1,
          targetDate: '2026-10-04',
          createdAt: '2026-09-01',
        ),
      };
      final results = s.placeTasks(
        tasks: [
          Task(
              id: 't1',
              goalId: 'g1',
              title: 'Night owl',
              durationMinutes: 60,
              recommendedDay: '2026-09-28',
              createdAt: '2026-09-01'),
        ],
        busyBlocks: [],
        horizonStart: DateTime(2026, 9, 28),
        horizonDays: 7,
      );
      // With inverted window, no valid placement must be made; the engine
      // must not place into an inverted (negative) segment.
      final t = results.first.task;
      if (t.scheduledStart != null) {
        final s0 = DateTime.parse(t.scheduledStart!);
        final e0 = DateTime.parse(t.scheduledEnd!);
        expect(e0.isAfter(s0), isTrue,
            reason: 'LOGIC ERROR: inverted work window produced backwards slot');
      }
    });

    test('inactive-days-only prefs leave tasks unscheduled with flag', () {
      final noDays = UserPreferences(
        workStart: '09:00',
        workEnd: '18:00',
        bufferMinutes: 10,
        activeDays: [],
        timezone: 'UTC',
      );
      final s = Slotter(noDays);
      s.allGoals = {
        'g1': Goal(
          id: 'g1',
          title: 'G',
          priority: GoalPriority.P1,
          targetDate: '2026-10-04',
          createdAt: '2026-09-01',
        ),
      };
      final results = s.placeTasks(
        tasks: [
          Task(
              id: 't1',
              goalId: 'g1',
              title: 'Nowhere',
              durationMinutes: 60,
              recommendedDay: '2026-09-28',
              createdAt: '2026-09-01'),
        ],
        busyBlocks: [],
        horizonStart: DateTime(2026, 9, 28),
        horizonDays: 7,
      );
      expect(results.first.task.scheduledStart, isNull);
      expect(results.first.note, 'unscheduled');
    });

    test('bufferMinutes = 0: back-to-back tasks allowed', () {
      final zeroBuffer = UserPreferences(
        workStart: '09:00',
        workEnd: '18:00',
        bufferMinutes: 0,
        activeDays: ['mon'],
        timezone: 'UTC',
      );
      final s = Slotter(zeroBuffer);
      s.allGoals = {
        'g1': Goal(
          id: 'g1',
          title: 'G',
          priority: GoalPriority.P1,
          targetDate: '2026-10-04',
          createdAt: '2026-09-01',
        ),
      };
      final results = s.placeTasks(
        tasks: [
          Task(id: 't1', goalId: 'g1', title: 'First', durationMinutes: 60, recommendedDay: '2026-09-28', createdAt: '2026-09-01'),
          Task(id: 't2', goalId: 'g1', title: 'Second', durationMinutes: 60, recommendedDay: '2026-09-28', createdAt: '2026-09-02'),
        ],
        busyBlocks: [],
        horizonStart: DateTime(2026, 9, 28),
        horizonDays: 7,
      );
      final t1 = results.firstWhere((r) => r.task.id == 't1').task;
      final t2 = results.firstWhere((r) => r.task.id == 't2').task;
      expect(t1.scheduledStart, '2026-09-28T09:00:00.000');
      expect(t2.scheduledStart, '2026-09-28T10:00:00.000',
          reason: 'zero buffer must allow back-to-back');
    });

    test('stress: 100 tasks place in <100ms without overlap', () {
      final s = slotterWithGoals();
      final tasks = [
        for (var i = 0; i < 100; i++)
          Task(
              id: 't$i',
              goalId: 'g1',
              title: 'Task $i',
              durationMinutes: 30,
              recommendedDay: '2026-09-28',
              createdAt: '2026-09-01T00:00:00'),
      ];
      final sw = Stopwatch()..start();
      final results = s.placeTasks(
        tasks: tasks,
        busyBlocks: [],
        horizonStart: DateTime(2026, 9, 28),
        horizonDays: 7,
      );
      sw.stop();
      expect(sw.elapsedMilliseconds, lessThan(100),
          reason: 'SPEC perf target: 100 tasks < 100ms. Took \\${sw.elapsedMilliseconds}ms');

      // No overlaps among placed.
      final placed = results
          .where((r) => r.task.scheduledStart != null)
          .map((r) => r.task)
          .toList();
      for (var i = 0; i < placed.length; i++) {
        for (var j = i + 1; j < placed.length; j++) {
          final a = placed[i], b = placed[j];
          final aS = DateTime.parse(a.scheduledStart!), aE = DateTime.parse(a.scheduledEnd!);
          final bS = DateTime.parse(b.scheduledStart!), bE = DateTime.parse(b.scheduledEnd!);
          expect(aS.isBefore(bE) && bS.isBefore(aE), isFalse,
              reason: 'overlap ${a.id}/${b.id}');
        }
      }
    });
  });
}
