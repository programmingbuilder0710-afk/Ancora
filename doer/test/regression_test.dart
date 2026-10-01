import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

import 'package:doer/data/database_helper.dart';
import 'package:doer/models/models.dart';
import 'package:doer/orchestration/orchestrator.dart';
import 'package:doer/provider/provider.dart';
import 'package:doer/slotter/slotter.dart';

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

  group('updateTask strictness', () {
    test('updateTask with unknown id no-ops, never inserts an orphan row', () async {
      final helper = DatabaseHelper.forTest();
      await helper.insertGoal(goal('g1'));

      final orphan = Task(
        id: 'no-such-task',
        goalId: 'g1',
        title: 'Orphan',
        durationMinutes: 60,
        createdAt: now.toIso8601String(),
      );
      final affected = await helper.updateTask(orphan);
      expect(affected, 0);

      final all = await helper.getAllTasks();
      expect(all.length, 0);
      expect(await helper.getTask('no-such-task'), isNull);

      await helper.close();
    });
  });

  group('cycle handling in _validateAndConvertTasks (via decompose)', () {
    test('cyclic tasks are kept with back-edges stripped, not dropped', () async {
      final helper = DatabaseHelper.forTest();
      await helper.insertGoal(goal('g1'));

      final canned = {
        'tasks': [
          {
            'task_id': 'a',
            'goal_id': 'g1',
            'title': 'Task A',
            'duration_minutes': 30,
            'recommended_day': '2026-09-29',
            'prerequisite_ids': ['b'],
          },
          {
            'task_id': 'b',
            'goal_id': 'g1',
            'title': 'Task B',
            'duration_minutes': 30,
            'recommended_day': '2026-09-30',
            'prerequisite_ids': ['a'],
          },
          {
            'task_id': 'c',
            'goal_id': 'g1',
            'title': 'Task C',
            'duration_minutes': 30,
            'recommended_day': '2026-09-28',
            'prerequisite_ids': ['a'],
          },
        ],
      };

      final provider = _FakeProvider(canned);
      final prefs = UserPreferences(
        workStart: '09:00',
        workEnd: '18:00',
        bufferMinutes: 10,
        activeDays: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
        timezone: 'UTC',
      );
      await helper.upsertPreferences(prefs);
      final slotter = Slotter(prefs)..allGoals = {'g1': goal('g1')};

      final orchestrator = Orchestrator(
        db: helper,
        providerFactory: () => provider,
        slotter: slotter,
      );

      final results = await orchestrator.decompose(goals: [goal('g1')]);

      final persisted = await helper.getAllTasks();
      expect(persisted.length, 3, reason: 'cyclic tasks must be kept, not dropped');

      final a = persisted.firstWhere((t) => t.title == 'Task A');
      final b = persisted.firstWhere((t) => t.title == 'Task B');
      final c = persisted.firstWhere((t) => t.title == 'Task C');

      expect(a.prerequisiteIds, isEmpty);
      expect(b.prerequisiteIds, isEmpty);
      expect(a.scheduledStart, isNotNull);
      expect(b.scheduledStart, isNotNull);
      expect(c.scheduledStart, isNotNull);
      expect(results.where((r) => r.task.scheduledStart != null).length, 3);

      await helper.close();
    });
  });

  group('.ics import wiring', () {
    late Directory tmp;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('doer_ics_test');
    });

    tearDown(() {
      tmp.deleteSync(recursive: true);
    });

    test('import replaces same-source blocks; decompose receives busy time', () async {
      final helper = DatabaseHelper.forTest();
      final prefs = UserPreferences(
        workStart: '09:00',
        workEnd: '18:00',
        bufferMinutes: 10,
        activeDays: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
        timezone: 'UTC',
      );
      await helper.upsertPreferences(prefs);
      final slotter = Slotter(prefs)..allGoals = {'g1': goal('g1')};

      final orchestrator = Orchestrator(
        db: helper,
        providerFactory: () => throw StateError('not needed'),
        slotter: slotter,
      );

      final f1 = File('${tmp.path}/work.ics');
      f1.writeAsStringSync('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260929T090000
DTEND:20260929T110000
SUMMARY:Standup
END:VEVENT
BEGIN:VEVENT
DTSTART:20260929T140000
DTEND:20260929T153000
SUMMARY:1:1 sync
END:VEVENT
END:VCALENDAR
''');

      final count1 = await orchestrator.importIcsFile(f1.path, 'work.ics');
      expect(count1, 2);

      var blocks = await helper.getBusyBlocksInRange(
        DateTime(2026, 9, 29),
        DateTime(2026, 9, 30),
      );
      expect(blocks.length, 2);

      final f2 = File('${tmp.path}/work_v2.ics');
      f2.writeAsStringSync('''
BEGIN:VCALENDAR
BEGIN:VEVENT
DTSTART:20260929T130000
DTEND:20260929T140000
SUMMARY:Only meeting
END:VEVENT
END:VCALENDAR
''');

      final count2 = await orchestrator.importIcsFile(f2.path, 'work.ics');
      expect(count2, 1);

      blocks = await helper.getBusyBlocksInRange(
        DateTime(2026, 9, 29),
        DateTime(2026, 9, 30),
      );
      expect(blocks.length, 1, reason: 're-import must replace, not duplicate');
      expect(blocks.first.start.hour, 13);

      final provider = _FakeProvider({
        'tasks': [
          {
            'task_id': 't1',
            'goal_id': 'g1',
            'title': 'Study',
            'duration_minutes': 60,
            'recommended_day': '2026-09-29',
            'prerequisite_ids': [],
          },
        ],
      });
      final orchestrator2 = Orchestrator(
        db: helper,
        providerFactory: () => provider,
        slotter: slotter,
      );
      await helper.insertGoal(goal('g1'));
      await orchestrator2.decompose(goals: [goal('g1')]);

      final payload = provider.lastUserPayload;
      expect(payload, isNotNull);
      final summary = payload!['per_day_summary'] as List;
      final tuesday = summary.firstWhere((d) => d['date'] == '2026-09-29');
      expect(tuesday['busy_hours'], 1.0);

      await helper.close();
    });
  });

  group('demo provider degradation mapping', () {
    test('401 from MockClient surfaces as QuotaError for demo-mode config', () async {
      final mock = MockClient((request) async {
        return http.Response('{"error": "invalid key"}', 401);
      });
      final demo = DemoProvider(
        apiKey: 'demo-key',
        baseUrl: 'https://example.com/v1',
        model: 'demo-model',
        client: mock,
      );
      await expectLater(
        () => demo.complete(
          system: 's',
          user: 'u',
          jsonSchema: {'type': 'object', 'properties': {}},
        ),
        throwsA(isA<QuotaError>()),
      );
    });

    test('402 from MockClient stays QuotaError for demo-mode config', () async {
      final mock = MockClient((request) async {
        return http.Response('{"error": "quota exceeded"}', 402);
      });
      final demo = DemoProvider(
        apiKey: 'demo-key',
        baseUrl: 'https://example.com/v1',
        model: 'demo-model',
        client: mock,
      );
      await expectLater(
        () => demo.complete(
          system: 's',
          user: 'u',
          jsonSchema: {'type': 'object', 'properties': {}},
        ),
        throwsA(isA<QuotaError>()),
      );
    });
  });
}

class _FakeProvider implements LlmProvider {
  final Map<String, dynamic> response;
  Map<String, dynamic>? lastUserPayload;

  _FakeProvider(this.response);

  @override
  Future<Map<String, dynamic>> complete({
    required String system,
    required String user,
    required Map<String, dynamic> jsonSchema,
  }) async {
    lastUserPayload = _tryDecode(user);
    return response;
  }

  static Map<String, dynamic>? _tryDecode(String s) {
    try {
      return Map<String, dynamic>.from(jsonDecode(s) as Map);
    } catch (_) {
      return null;
    }
  }
}
