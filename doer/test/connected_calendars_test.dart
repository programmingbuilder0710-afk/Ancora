import 'dart:convert';

import 'package:doer/app_services.dart';
import 'package:doer/calendar/connected_calendars.dart';
import 'package:doer/data/database_helper.dart';
import 'package:doer/extraction/extraction.dart';
import 'package:doer/models/models.dart';
import 'package:doer/slotter/slotter.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class FakeConnected extends ConnectedCalendars {
  final Map<String, String> storage;
  FakeConnected(
    http.Client client,
    DatabaseHelper db, [
    Map<String, String>? storage,
  ]) : storage = storage ?? {},
       super(client: client, db: db, baseUrl: 'https://doer.example');
  @override
  Future<String?> readKey(String key) async => storage[key];
  @override
  Future<void> writeKey(String key, String? value) async {
    if (value == null) {
      storage.remove(key);
    } else {
      storage[key] = value;
    }
  }
}

void main() {
  sqfliteFfiInit();
  late DatabaseHelper db;
  final now = DateTime.now();
  final start = DateTime(now.year, now.month, now.day, 12);
  final end = start.add(const Duration(hours: 1));
  setUp(() async {
    db = DatabaseHelper.forTest();
    await db.getPreferences();
  });
  tearDown(() => db.close());

  test(
    'user identity is stable across concurrent calls and instances',
    () async {
      final client = MockClient((_) async => http.Response('{}', 200));
      final connected = FakeConnected(client, db);
      final ids = await Future.wait([connected.userId(), connected.userId()]);
      expect(ids[0], ids[1]);
      expect(
        ids[0],
        matches(
          RegExp(
            r'^[a-f0-9]{8}-[a-f0-9]{4}-4[a-f0-9]{3}-[89ab][a-f0-9]{3}-[a-f0-9]{12}$',
          ),
        ),
      );
      expect(
        await FakeConnected(client, db, connected.storage).userId(),
        ids[0],
      );
    },
  );

  test(
    'sync replaces connected blocks, preserves imports and stores local times',
    () async {
      for (final source in ['pd:old', 'ics:old', 'import.ics']) {
        await db.insertBusyBlock(
          BusyBlock(id: source, source: source, start: start, end: end),
        );
      }
      final connected = FakeConnected(
        MockClient((request) async {
          expect(request.url.path, '/api/busy');
          final body = jsonDecode(request.body);
          expect(
            body['start'],
            DateTime(now.year, now.month, now.day).toUtc().toIso8601String(),
          );
          return http.Response(
            jsonEncode({
              'blocks': [
                {
                  'source': 'pd:google_calendar:Me',
                  'start': start.toUtc().toIso8601String(),
                  'end': end.toUtc().toIso8601String(),
                },
              ],
              'errors': [],
            }),
            200,
          );
        }),
        db,
      );
      expect(await connected.syncBusy(db), isNull);
      final blocks = await db.getBusyBlocksInRange(start, end);
      expect(
        blocks.map((b) => b.source),
        unorderedEquals(['import.ics', 'pd:google_calendar:Me']),
      );
      final block = blocks.singleWhere((b) => b.source.startsWith('pd:'));
      expect(
        block.start,
        DateTime.parse(start.toUtc().toIso8601String()).toLocal(),
      );
      expect(block.start.isUtc, isFalse);
      final rows = await (await db.database).query(
        'busy_blocks',
        where: 'id = ?',
        whereArgs: [block.id],
      );
      expect(rows.single['start'], start.toIso8601String());
    },
  );

  test(
    'failed sync preserves saved blocks; ICS success permits partial sync',
    () async {
      await db.insertBusyBlock(
        BusyBlock(id: 'old', source: 'pd:old', start: start, end: end),
      );
      final connected = FakeConnected(
        MockClient((request) async {
          if (request.url.path == '/api/ics') {
            expect(request.url.queryParameters['user'], isNotEmpty);
            return http.Response('BEGIN:VCALENDAR\nEND:VCALENDAR', 200);
          }
          return http.Response('{"error":"Unavailable"}', 503);
        }),
        db,
      );
      await expectLater(connected.syncBusy(db), throwsException);
      expect(await db.getBusyBlocksInRange(start, end), hasLength(1));
      await connected.addIcsUrl('webcal://calendar.example/one.ics');
      expect(await connected.icsUrls(), ['https://calendar.example/one.ics']);
      expect(await connected.syncBusy(db), contains('could not sync'));
      // Pipedream failed, so its last snapshot must survive the partial sync.
      expect(
        (await db.getBusyBlocksInRange(start, end)).map((b) => b.source),
        contains('pd:old'),
      );
      await connected.removeIcsUrl('https://calendar.example/one.ics');
      expect(await connected.icsUrls(), isEmpty);
    },
  );

  test('rewrite batches per account, routes old deletes and preserves omitted tasks', () async {
    final requests = <Map<String, dynamic>>[];
    final connected = FakeConnected(
      MockClient((request) async {
        expect(request.url.path, '/api/plan-writes');
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        requests.add(body);
        return http.Response(
          jsonEncode({
            'created': {
              for (final t in body['create']) t['key']: 'event-${t['key']}',
            },
            'errors': [],
          }),
          200,
        );
      }),
      db,
    );
    await connected.setPlanAccountId('new');
    Task task(String id, {bool scheduled = true}) => Task(
      id: id,
      goalId: 'goal',
      title: id,
      durationMinutes: 60,
      createdAt: now.toIso8601String(),
      scheduledStart: scheduled ? start.toIso8601String() : null,
      scheduledEnd: scheduled ? end.toIso8601String() : null,
    );
    final calendar = PipedreamPlanCalendar(connected);
    final result = await calendar.atomicRewrite(
      [
        PlacementResult(task('one')),
        PlacementResult(task('two')),
        PlacementResult(task('unplaced', scheduled: false)),
      ],
      {
        'one': 'pd:old:old-one',
        'two': 'pd:new:old-two',
        'unplaced': 'pd:old:old-three',
        'completed': 'pd:old:keep',
      },
    );
    expect(requests, hasLength(2));
    final old = requests.singleWhere((r) => r['account_id'] == 'old');
    final target = requests.singleWhere((r) => r['account_id'] == 'new');
    expect(old['delete'], ['old-one', 'old-three']);
    expect(old['create'], isEmpty);
    expect(target['delete'], ['old-two']);
    expect((target['create'] as List).map((t) => t['key']), ['one', 'two']);
    expect(target['create'][0]['start'], start.toUtc().toIso8601String());
    expect(result, {'one': 'pd:new:event-one', 'two': 'pd:new:event-two'});
    await calendar.deleteEvent('native-event');
    expect(requests, hasLength(2));
    await connected.setPlanAccountId('third');
    await calendar.deleteEvent('pd:old:old-one');
    expect(requests.last['account_id'], 'old');
  });

  test(
    'changing the plan target moves pending events and clearing removes them',
    () async {
      final requests = <Map<String, dynamic>>[];
      final connected = FakeConnected(
        MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(body);
          return http.Response(
            jsonEncode({
              'created': {
                for (final t in body['create']) t['key']: 'event-${t['key']}',
              },
              'errors': [],
            }),
            200,
          );
        }),
        db,
      );
      final services = await AppServices.load(db: db, initCalendar: false)
        ..connected = connected;
      await db.insertGoal(
        Goal(
          id: 'goal',
          title: 'Goal',
          description: '',
          priority: GoalPriority.P1,
          targetDate: '2026-12-31',
          createdAt: now.toIso8601String(),
        ),
      );
      Task task(String id, {String? event, bool done = false}) => Task(
        id: id,
        goalId: 'goal',
        title: id,
        durationMinutes: 60,
        createdAt: now.toIso8601String(),
        scheduledStart: start.toIso8601String(),
        scheduledEnd: end.toIso8601String(),
        status: done ? TaskStatus.completed : TaskStatus.pending,
        deviceEventId: event,
      );
      await db.insertTasks([
        task('fresh'),
        task('moved', event: 'pd:old:e1'),
        task('done', event: 'pd:old:kept', done: true),
      ]);

      await connected.setPlanAccountId('new');
      await services.projectPlan();
      final old = requests.singleWhere((r) => r['account_id'] == 'old');
      final target = requests.singleWhere((r) => r['account_id'] == 'new');
      expect(old['delete'], ['e1']);
      expect(target['delete'], isEmpty);
      expect(
        (target['create'] as List).map((t) => t['key']).toSet(),
        {'fresh', 'moved'},
      );
      expect((await db.getTask('fresh'))!.deviceEventId, 'pd:new:event-fresh');
      expect((await db.getTask('moved'))!.deviceEventId, 'pd:new:event-moved');
      expect((await db.getTask('done'))!.deviceEventId, 'pd:old:kept');

      requests.clear();
      await connected.setPlanAccountId(null);
      await services.projectPlan();
      expect(requests, hasLength(1));
      expect(requests.single['account_id'], 'new');
      expect(
        (requests.single['delete'] as List).toSet(),
        {'event-fresh', 'event-moved'},
      );
      expect(requests.single['create'], isEmpty);
    },
  );

  test(
    'deleting a pending task removes its event from the plan target',
    () async {
      final requests = <Map<String, dynamic>>[];
      final connected = FakeConnected(
        MockClient((request) async {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          requests.add(body);
          return http.Response(
            jsonEncode({'created': {}, 'errors': []}),
            200,
          );
        }),
        db,
      );
      final services = await AppServices.load(db: db, initCalendar: false)
        ..connected = connected;
      await db.insertGoal(
        Goal(
          id: 'goal',
          title: 'Goal',
          description: '',
          priority: GoalPriority.P1,
          targetDate: '2026-12-31',
          createdAt: now.toIso8601String(),
        ),
      );
      final task = Task(
        id: 'doomed',
        goalId: 'goal',
        title: 'Doomed',
        durationMinutes: 60,
        createdAt: now.toIso8601String(),
        scheduledStart: start.toIso8601String(),
        scheduledEnd: end.toIso8601String(),
        deviceEventId: 'pd:acct:event-1',
      );
      await db.insertTask(task);

      await services.deleteTask(task);
      expect(await db.getTask('doomed'), isNull);
      expect(requests, hasLength(1));
      expect(requests.single['account_id'], 'acct');
      expect(requests.single['delete'], ['event-1']);
      expect(requests.single['create'], isEmpty);
    },
  );

  test(
    'calendar writes throw individually and rewrite tolerates account failures',
    () async {
      final connected = FakeConnected(
        MockClient((_) async => http.Response('{"error":"Offline"}', 503)),
        db,
      );
      await connected.setPlanAccountId('target');
      final task = Task(
        id: 'task',
        goalId: 'goal',
        title: 'Task',
        durationMinutes: 60,
        createdAt: now.toIso8601String(),
        scheduledStart: start.toIso8601String(),
        scheduledEnd: end.toIso8601String(),
      );
      final calendar = PipedreamPlanCalendar(connected);
      expect(
        await calendar.atomicRewrite([PlacementResult(task)], {}),
        isEmpty,
      );
      await expectLater(calendar.writeTaskEvent(task), throwsException);
      await expectLater(
        calendar.deleteEvent('pd:target:event'),
        throwsException,
      );
    },
  );

  test('bytes extraction preserves text and truncation', () async {
    final extraction = ExtractionService();
    expect(
      await extraction.extractTextFromBytes('notes.md', utf8.encode('# Notes')),
      '# Notes',
    );
    expect(
      await extraction.extractTextFromBytes(
        'long.txt',
        utf8.encode('a' * 5001),
      ),
      '${'a' * 5000}\n...[truncated]',
    );
  });
}
