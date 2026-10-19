import 'package:doer/app_services.dart';
import 'package:doer/calendar/calendar_service.dart';
import 'package:doer/calendar/connected_calendars.dart';
import 'package:http/http.dart' as http;
import 'package:doer/data/database_helper.dart';
import 'package:doer/main.dart';
import 'package:doer/models/models.dart';
import 'package:doer/provider/provider.dart';
import 'package:doer/provider/provider_config_service.dart';
import 'package:doer/ui/agenda/agenda_screen.dart';
import 'package:doer/ui/goals/goal_edit_screen.dart';
import 'package:doer/ui/settings/settings_screen.dart';
import 'package:doer/ui/widgets.dart';
import 'package:doer/ui/onboarding_screen.dart';
import 'package:intl/intl.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

class MemoryConfig extends ProviderConfigService {
  MemoryConfig(DatabaseHelper db) : super(db: db);
  final keys = <String, String>{};
  LlmProvider? provider;
  int builds = 0;

  @override
  Future<String?> readKey(String key) async => keys[key];
  @override
  Future<void> writeKey(String key, String value) async {
    keys[key] = value;
  }

  @override
  Future<LlmProvider?> buildActiveProvider() async {
    builds++;
    return provider;
  }
}

class LocalConnected extends ConnectedCalendars {
  LocalConnected(DatabaseHelper db) : super(client: http.Client(), db: db);
  @override
  Future<String> userId() async => '70c54e12-532f-4aad-a79a-df1c725824a1';
  @override
  Future<String?> syncBusy(DatabaseHelper db) async => null;
}

class FakeProvider implements LlmProvider {
  Object? error;
  Map<String, dynamic> response = {};
  int calls = 0;
  @override
  Future<Map<String, dynamic>> complete({
    required String system,
    required String user,
    required Map<String, dynamic> jsonSchema,
  }) async {
    calls++;
    if (error != null) throw error!;
    return response;
  }
}

class RecordingCalendar extends CalendarService {
  RecordingCalendar() : super('plan');
  final deleted = <String>[];
  final written = <Task>[];
  bool failDelete = false;
  bool failWrite = false;

  @override
  Future<void> deleteEvent(String id) async {
    deleted.add(id);
    if (failDelete) throw Exception('private calendar failure');
  }

  @override
  Future<String> writeTaskEvent(Task task) async {
    written.add(task);
    if (failWrite) throw Exception('private calendar failure');
    return 'new-event';
  }
}

// FFI runs outside FakeAsync; pump until the requested UI state is visible.
Future<void> waitFor(WidgetTester tester, bool Function() ready) async {
  await tester.runAsync(() async {
    for (var i = 0; i < 300; i++) {
      await tester.pump(const Duration(milliseconds: 50));
      if (ready()) return;
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
  });
  expect(ready(), isTrue, reason: 'UI did not finish its database operation');
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  GoogleFonts.config.allowRuntimeFetching = false;
  sqfliteFfiInit();
  databaseFactory = databaseFactoryFfi;
  late DatabaseHelper db;
  late MemoryConfig config;
  late AppServices services;
  late DateTime today;
  late Goal goal;
  late Task task;

  setUp(() async {
    db = DatabaseHelper.forTest();
    config = MemoryConfig(db);
    config.keys['onboarding_done'] = 'true';
    services = await AppServices.load(
      db: db,
      config: config,
      initCalendar: false,
    );
    today = DateUtils.dateOnly(DateTime.now());
    goal = Goal(
      id: 'goal',
      title: 'Learn Flutter',
      priority: GoalPriority.P1,
      targetDate: DateTime(
        today.year,
        today.month,
        today.day + 6,
      ).toIso8601String().substring(0, 10),
      createdAt: today.toIso8601String(),
    );
    task = Task(
      id: 'task',
      goalId: goal.id,
      title: 'Build a widget',
      durationMinutes: 30,
      recommendedDay: today.toIso8601String().substring(0, 10),
      scheduledStart:
          (DateTime.now().subtract(const Duration(minutes: 30)).isBefore(today)
                  ? today
                  : DateTime.now().subtract(const Duration(minutes: 30)))
              .toIso8601String(),
      scheduledEnd:
          (DateTime.now().subtract(const Duration(minutes: 30)).isBefore(today)
                  ? today
                  : DateTime.now().subtract(const Duration(minutes: 30)))
              .add(const Duration(minutes: 30))
              .toIso8601String(),
      createdAt: today.toIso8601String(),
    );
  });

  tearDown(() async {
    await db.close();
  });

  Future<void> seed() async {
    await db.upsertPreferences(
      UserPreferences(
        timezone: 'UTC',
        activeDays: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
      ),
    );
    await services.reloadPrefs();
    await db.insertGoal(goal);
    await db.insertTask(task);
  }

  test(
    'built-in demo uses install identity and custom configurations stay direct',
    () async {
      services.connected = LocalConnected(db);
      expect(await services.usesBuiltInDemo(), isTrue);
      final provider =
          (await services.orchestrator(needsProvider: true)).providerFactory()
              as DemoProvider;
      expect(provider.apiKey, await services.connected!.userId());
      expect(Uri.parse(provider.baseUrl).path, '/api/llm');
      expect(provider.model, 'demo');
      expect(config.builds, 0);
      config.keys['demo_api_key'] = 'custom';
      config.provider = FakeProvider();
      expect(await services.usesBuiltInDemo(), isFalse);
      expect(
        (await services.orchestrator(needsProvider: true)).providerFactory(),
        same(config.provider),
      );
      config.keys['demo_api_key'] = '';
      await db.upsertProviderConfig(mode: 'byok');
      expect(await services.usesBuiltInDemo(), isFalse);
    },
  );

  test('defaults persist and timezone channel falls back to UTC', () async {
    expect(services.prefs.timezone, 'UTC');
    expect(services.prefs.workStart, '09:00');
    expect(services.prefs.workEnd, '18:00');
    expect(services.prefs.activeDays, ['mon', 'tue', 'wed', 'thu', 'fri']);
    expect((await db.getPreferences())!.bufferMinutes, 10);
    expect(config.builds, 0);
  });

  test('device IANA timezone is captured only for new preferences', () async {
    const channel = MethodChannel('flutter_timezone');
    var calls = 0;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          expect(call.method, 'getLocalTimezone');
          calls++;
          return 'Asia/Kolkata';
        });
    final fresh = DatabaseHelper.forTest();
    try {
      final first = await AppServices.load(db: fresh, initCalendar: false);
      expect(first.prefs.timezone, 'Asia/Kolkata');
      await AppServices.load(db: fresh, initCalendar: false);
      expect(calls, 1);
    } finally {
      await fresh.close();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    }
  });

  test('calendar failure leaves local services usable', () async {
    final loaded = await AppServices.load(db: db, config: config);
    expect(loaded.calendar, isNull);
    expect(loaded.calendarError, contains('Calendar unavailable'));
    await loaded.orchestrator();
    expect(config.builds, 0);
  });

  test(
    'registries include archived goals and refresh for every operation',
    () async {
      await seed();
      final archived = Goal.fromMap({
        ...goal.toMap(),
        'id': 'archive',
        'status': 'archived',
      });
      await db.insertGoal(archived);
      final first = await services.orchestrator();
      expect(first.slotter.allGoals.keys, containsAll(['goal', 'archive']));
      expect(first.slotter.allTasks.single.id, task.id);
      await first.completeTask(task.id);
      final second = await services.orchestrator();
      expect(second.slotter.allTasks.single.status, TaskStatus.completed);
      expect(config.builds, 0);
      await expectLater(
        services.orchestrator(needsProvider: true),
        throwsA(isA<ProviderNotConfigured>()),
      );
      final provider = FakeProvider();
      config.provider = provider;
      expect(
        (await services.orchestrator(needsProvider: true)).providerFactory(),
        same(provider),
      );
    },
  );

  test(
    'reloadPrefs reconstructs calendar with saved id and timezone',
    () async {
      services.calendar = CalendarService('plan', preferences: services.prefs);
      await db.upsertPreferences(
        UserPreferences(timezone: 'Asia/Kolkata', planCalendarId: 'plan'),
      );
      await services.reloadPrefs();
      expect(services.calendar!.planCalendarId, 'plan');
      expect(services.calendar!.resolvedTimezone, 'Asia/Kolkata');
    },
  );

  test(
    'deleteGoal tolerates calendar failures and surfaces child-goal FK errors',
    () async {
      await seed();
      services.calendar = CalendarService('plan', preferences: services.prefs);
      await db.updateTask(task.copyWith(deviceEventId: 'event'));
      await db.insertGoal(
        Goal.fromMap({
          ...goal.toMap(),
          'id': 'child',
          'parent_goal_id': goal.id,
        }),
      );
      await expectLater(services.deleteGoal(goal), throwsA(anything));
      expect(await db.getGoal(goal.id), isNotNull);
      await db.deleteGoal('child');
      await services.deleteGoal(goal);
      expect(await db.getGoal(goal.id), isNull);
      expect(await db.getAllTasks(), isEmpty);
    },
  );

  test('provider errors and demo exhaustion have actionable messages', () {
    final quota = QuotaError('raw');
    expect(
      providerErrorMessage(quota, demoMode: true),
      'Free planning is unavailable right now — add your own AI key in Settings.',
    );
    expect(
      providerErrorMessage(quota, demoMode: false),
      'Quota exhausted — add credits or switch provider.',
    );
    expect(isDemoExhausted(quota, true), isTrue);
    expect(isDemoExhausted(quota, false), isFalse);
    expect(isDemoExhausted(AuthError('raw'), true), isFalse);
    for (final entry in <Object, String>{
      AuthError('raw'):
          'Key invalid or revoked — check your API key in Settings.',
      RateLimitError('raw'): 'Rate limited — try again in a few minutes.',
      NetworkError('raw'): 'Network error — check your connection.',
      ProviderError(503, 'raw'):
          'Provider unavailable (status 503) — try again.',
      SchemaViolationError('raw', ''):
          'The model returned an invalid response — try again.',
      const FormatException(): 'Invalid provider base URL — check Settings.',
      ProviderNotConfigured():
          'Finish provider setup in Settings to plan tasks.',
      Exception('Other failure'): 'Something went wrong. Please try again.',
    }.entries) {
      expect(providerErrorMessage(entry.key, demoMode: false), entry.value);
    }
  });

  test('rename rewrites the calendar event and preserves task facts', () async {
    await seed();
    final calendar = RecordingCalendar();
    services.calendar = calendar;
    await db.updateTask(task.copyWith(deviceEventId: 'old-event'));
    await services.renameTask(task, '  A better title  ');
    final renamed = (await db.getTask(task.id))!;
    expect(renamed.title, 'A better title');
    expect(renamed.deviceEventId, 'new-event');
    expect(renamed.scheduledStart, task.scheduledStart);
    expect(renamed.status, TaskStatus.pending);
    expect(calendar.deleted, ['old-event']);
    expect(calendar.written.single.title, 'A better title');
    await services.deleteTask(renamed);
    expect(calendar.deleted, ['old-event', 'new-event']);
    expect(await db.getTask(task.id), isNull);
  });

  test('calendar failures never block rename or delete', () async {
    await seed();
    final calendar = RecordingCalendar()..failDelete = true;
    services.calendar = calendar;
    await db.updateTask(task.copyWith(deviceEventId: 'old-event'));
    await services.renameTask(task, 'Renamed locally');
    expect((await db.getTask(task.id))!.title, 'Renamed locally');
    expect(calendar.written, isEmpty);
    calendar.failDelete = false;
    calendar.failWrite = true;
    await services.renameTask(task, 'Still saved locally');
    expect((await db.getTask(task.id))!.title, 'Still saved locally');
    expect((await db.getTask(task.id))!.deviceEventId, isNull);
    await db.updateTask(
      (await db.getTask(task.id))!.copyWith(deviceEventId: 'event'),
    );
    calendar.failDelete = true;
    await services.deleteTask(task);
    expect(await db.getTask(task.id), isNull);
  });

  test(
    'task mutations reject invalid titles and keep completed rows immutable',
    () async {
      await seed();
      await expectLater(services.renameTask(task, '   '), throwsArgumentError);
      await expectLater(
        services.renameTask(task, 'x' * 121),
        throwsArgumentError,
      );
      await db.updateTask(task.copyWith(status: TaskStatus.completed));
      await services.renameTask(task, 'Must not change');
      await services.deleteTask(task);
      final completed = (await db.getTask(task.id))!;
      expect(completed.title, task.title);
      expect(completed.status, TaskStatus.completed);
    },
  );

  testWidgets('shell opens the empty agenda and navigates to goals', (
    tester,
  ) async {
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(
      tester,
      () => find.text('Plan your first goal').evaluate().isNotEmpty,
    );
    expect(find.text('Re-plan'), findsNothing);
    expect(find.text('Nothing scheduled'), findsNothing);
    await tester.tap(find.text('Add a goal'));
    await waitFor(
      tester,
      () => find.text('No goals yet').evaluate().isNotEmpty,
    );
    expect(find.byTooltip('Add goal'), findsOneWidget);
  });

  for (final done in [true, false]) {
    testWidgets(
      done
          ? 'Agenda groups today task and Done persists completion'
          : "Didn't start increments skipCount without a provider",
      (tester) async {
        await tester.runAsync(seed);
        await tester.pumpWidget(
          MaterialApp(
            home: AgendaScreen(
              services: services,
              onProviderError: (_) {},
              onAddGoal: () {},
            ),
          ),
        );
        await waitFor(
          tester,
          () => find.text(task.title).evaluate().isNotEmpty,
        );
        expect(find.text(goal.title), findsOneWidget);
        expect(find.text('P1'), findsOneWidget);
        expect(
          find.text(
            clock(
              tester.element(find.byType(AgendaScreen)),
              DateTime.parse(task.scheduledStart!),
            ),
          ),
          findsOneWidget,
        );
        expect(find.text('30 min'), findsOneWidget);
        await tester.tap(
          done ? find.byTooltip('Done') : find.text("Didn't start"),
        );
        await tester.pumpAndSettle();
        await waitFor(
          tester,
          () => done
              ? find.byIcon(Icons.check_circle).evaluate().isNotEmpty
              // The session may move to a later day (e.g. when run after
              // working hours), so wait for the confirmation, not today's list.
              : find.textContaining('Moved to').evaluate().isNotEmpty ||
                    find.textContaining("Couldn't fit").evaluate().isNotEmpty,
        );
        if (done) {
          expect(
            (await tester.runAsync(() => db.getTask(task.id)))!.status,
            TaskStatus.pending,
          );
          await tester.pump(const Duration(seconds: 6));
          await tester.pumpAndSettle();
          await tester.runAsync(() async {
            for (var i = 0; i < 100; i++) {
              await tester.pump(const Duration(milliseconds: 100));
              if ((await db.getTask(task.id))!.status == TaskStatus.completed) {
                break;
              }
              await Future<void>.delayed(const Duration(milliseconds: 10));
            }
          });
        }
        final updated = await tester.runAsync(() => db.getTask(task.id));
        if (done) {
          expect(updated!.status, TaskStatus.completed);
          expect(
            find.text(
              clock(
                tester.element(find.byType(AgendaScreen)),
                DateTime.parse(task.scheduledStart!),
              ),
            ),
            findsOneWidget,
          );
          expect(
            find.text(
              clock(
                tester.element(find.byType(AgendaScreen)),
                DateTime.parse(task.scheduledEnd!),
              ),
            ),
            findsOneWidget,
          );
          expect(find.byIcon(Icons.check_circle), findsOneWidget);
        } else {
          expect(updated!.skipCount, 1);
          expect(updated.status, TaskStatus.pending);
        }
        expect(config.builds, 0);
      },
    );
  }

  Future<void> openAgenda(WidgetTester tester) async {
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(tester, () => find.text(task.title).evaluate().isNotEmpty);
  }

  Future<void> openDetails(WidgetTester tester) async {
    await openAgenda(tester);
    await tester.tap(find.text(task.title));
    await waitFor(tester, () => find.byType(BottomSheet).evaluate().isNotEmpty);
    await tester.pumpAndSettle();
  }

  testWidgets("future session shows Done but hides Didn't start", (
    tester,
  ) async {
    final start = DateTime.now().add(const Duration(hours: 2));
    if (!DateUtils.isSameDay(start, today)) {
      markTestSkipped('Two hours ahead crosses midnight.');
      return;
    }
    task = task.copyWith(
      scheduledStart: start.toIso8601String(),
      scheduledEnd: start.add(const Duration(minutes: 30)).toIso8601String(),
    );
    await tester.runAsync(seed);
    await openAgenda(tester);
    expect(find.byTooltip('Done'), findsOneWidget);
    expect(find.text("Didn't start"), findsNothing);
    expect(find.text('Missed?'), findsNothing);
    await tester.tap(find.text(task.title));
    await waitFor(tester, () => find.text('Rename').evaluate().isNotEmpty);
    expect(find.text('Done'), findsOneWidget);
    expect(find.text("Didn't start"), findsNothing);
  });

  testWidgets('past session shows both actions and Missed after end', (
    tester,
  ) async {
    final now = DateTime.now();
    final start = now.subtract(const Duration(minutes: 45));
    task = task.copyWith(
      scheduledStart: start.toIso8601String(),
      scheduledEnd: now.subtract(const Duration(minutes: 15)).toIso8601String(),
    );
    await tester.runAsync(seed);
    await tester.pumpWidget(
      MaterialApp(
        home: AgendaScreen(
          services: services,
          initialDay: start,
          onProviderError: (_) {},
          onAddGoal: () {},
        ),
      ),
    );
    await waitFor(tester, () => find.text(task.title).evaluate().isNotEmpty);
    expect(find.byTooltip('Done'), findsOneWidget);
    expect(find.text("Didn't start"), findsOneWidget);
    expect(find.text('Missed?'), findsOneWidget);
    await tester.tap(find.text(task.title));
    await waitFor(tester, () => find.text('Rename').evaluate().isNotEmpty);
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text("Didn't start"),
      ),
      findsOneWidget,
    );
    expect(
      find.descendant(
        of: find.byType(BottomSheet),
        matching: find.text('Missed?'),
      ),
      findsOneWidget,
    );
  });

  testWidgets('details rename validates and persists through keyboard Save', (
    tester,
  ) async {
    await tester.runAsync(seed);
    await openDetails(tester);
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '   ');
    await tester.pump();
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Save'))
          .onPressed,
      isNull,
    );
    await tester.enterText(find.byType(TextField), 'Practice Flutter layouts');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await waitFor(tester, () => find.text('Renamed').evaluate().isNotEmpty);
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.text('Practice Flutter layouts'), findsOneWidget);
    expect(
      (await tester.runAsync(() => db.getTask(task.id)))!.title,
      'Practice Flutter layouts',
    );
    expect(config.builds, 0);
  });

  testWidgets('details delete confirms and removes the row', (tester) async {
    await tester.runAsync(seed);
    await openDetails(tester);
    await tester.tap(find.text('Delete session'));
    await tester.pumpAndSettle();
    expect(
      find.text('Delete “${task.title}”? This can\'t be undone.'),
      findsOneWidget,
    );
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(await tester.runAsync(() => db.getTask(task.id)), isNotNull);
    await tester.tap(find.text('Delete session'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await waitFor(
      tester,
      () => find.text('Session deleted').evaluate().isNotEmpty,
    );
    expect(await tester.runAsync(() => db.getTask(task.id)), isNull);
    expect(find.text(task.title), findsNothing);
    expect(config.builds, 0);
  });

  testWidgets('completed details are read-only', (tester) async {
    task = task.copyWith(status: TaskStatus.completed);
    await tester.runAsync(seed);
    await openDetails(tester);
    expect(find.text('Rename'), findsNothing);
    expect(find.text('Delete session'), findsNothing);
    expect(find.text('Done'), findsNothing);
    expect(find.text("Didn't start"), findsNothing);
    expect(find.text('Completed'), findsOneWidget);
  });

  testWidgets('goal editor task rows open the same editable details', (
    tester,
  ) async {
    tester.view.physicalSize = const Size(800, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await tester.runAsync(seed);
    await tester.pumpWidget(
      MaterialApp(
        home: GoalEditScreen(
          services: services,
          goal: goal,
          onProviderError: (_) {},
        ),
      ),
    );
    await waitFor(tester, () => find.text(task.title).evaluate().isNotEmpty);
    await tester.ensureVisible(find.text(task.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text(task.title));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).last, 'Corrected session');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await waitFor(tester, () => find.text('Renamed').evaluate().isNotEmpty);
    expect(find.text('Corrected session'), findsOneWidget);
  });

  testWidgets('Evenings in Settings persists the availability preset', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(services: services)),
    );
    await waitFor(
      tester,
      () => find.text('Demo (free, limited)').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Evenings'));
    await waitFor(tester, () => services.prefs.workStart == '18:00');
    final prefs = await tester.runAsync(db.getPreferences);
    expect(prefs!.workStart, '18:00');
    expect(prefs.workEnd, '22:00');
    expect(
      tester
          .widget<ChoiceChip>(find.widgetWithText(ChoiceChip, 'Evenings'))
          .selected,
      isTrue,
    );
    expect(find.text('Start'), findsNothing);
    await tester.tap(find.text('Custom'));
    await tester.pumpAndSettle();
    expect(find.text('Start'), findsOneWidget);
    expect(
      find.text(
        clock(
          tester.element(find.byType(SettingsScreen)),
          DateTime(2000, 1, 1, 18),
        ),
      ),
      findsOneWidget,
    );
  });

  for (final use24h in [false, true]) {
    testWidgets('clock follows platform 24-hour preference: $use24h', (
      tester,
    ) async {
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(alwaysUse24HourFormat: use24h),
            child: Builder(
              builder: (context) =>
                  Text(dayClock(context, DateTime(2026, 10, 19, 10, 35))),
            ),
          ),
        ),
      );
      expect(find.text(use24h ? 'Mon 10:35' : 'Mon 10:35 AM'), findsOneWidget);
    });
  }

  testWidgets('Undo restores pending without committing', (tester) async {
    await tester.runAsync(seed);
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(tester, () => find.byTooltip('Done').evaluate().isNotEmpty);
    await tester.tap(find.byTooltip('Done'));
    await tester.pumpAndSettle();
    expect(
      (await tester.runAsync(() => db.getTask(task.id)))!.status,
      TaskStatus.pending,
    );
    await tester.tap(find.text('Undo'));
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpAndSettle();
    expect(
      (await tester.runAsync(() => db.getTask(task.id)))!.status,
      TaskStatus.pending,
    );
    expect(find.byTooltip('Done'), findsOneWidget);
  });

  testWidgets('multiple pending dones commit on background', (tester) async {
    await tester.runAsync(() async {
      await seed();
      await db.insertTask(Task.fromMap({...task.toMap(), 'id': 'second'}));
    });
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(tester, () => find.byTooltip('Done').evaluate().length == 2);
    await tester.tap(find.byTooltip('Done').first);
    await tester.pump();
    await tester.tap(find.byTooltip('Done').first);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    await tester.runAsync(() async {
      for (var i = 0; i < 100; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if ((await db.getAllTasks()).every(
          (t) => t.status == TaskStatus.completed,
        )) {
          break;
        }
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
    });
    final tasks = await tester.runAsync(db.getAllTasks);
    expect(tasks!.every((t) => t.status == TaskStatus.completed), isTrue);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await waitFor(
      tester,
      () => find.text('2 tasks · 1h · 2 done').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
  });

  testWidgets('onboarding skips once', (tester) async {
    config.keys.remove('onboarding_done');
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(
      tester,
      () => find.byType(OnboardingScreen).evaluate().isNotEmpty,
    );
    expect(
      tester
          .widget<FilledButton>(find.widgetWithText(FilledButton, 'Next'))
          .onPressed,
      isNull,
    );
    await tester.tap(find.text('Skip setup'));
    await waitFor(
      tester,
      () => find.text('Plan your first goal').evaluate().isNotEmpty,
    );
    expect(config.keys['onboarding_done'], 'true');
  });

  testWidgets('onboarding retries without duplicating its goal', (
    tester,
  ) async {
    config.keys.remove('onboarding_done');
    final provider = FakeProvider()..error = QuotaError('unavailable');
    config.provider = provider;
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(
      tester,
      () => find.text('Run a half marathon').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Run a half marathon'));
    await tester.pumpAndSettle();
    await tester.ensureVisible(find.text('Next'));
    await tester.tap(find.text('Next'));
    await waitFor(
      tester,
      () => find.text('When can you work on it?').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Next'));
    await waitFor(
      tester,
      () => find.text('Plan my week').evaluate().isNotEmpty,
    );
    await tester.ensureVisible(find.text('Plan my week'));
    await tester.tap(find.text('Plan my week'));
    await waitFor(tester, () => find.text('Try again').evaluate().isNotEmpty);
    final goals = await tester.runAsync(() => db.getAllGoals());
    expect(goals, hasLength(1));
    expect(goals!.single.priority, GoalPriority.P1);
    provider.error = null;
    provider.response = {
      'tasks': [
        {
          'task_id': 'first',
          'goal_id': goals.single.id,
          'title': 'Easy run',
          'duration_minutes': 30,
          'recommended_day': DateFormat('yyyy-MM-dd').format(today),
          'prerequisite_ids': <String>[],
        },
      ],
    };
    await tester.ensureVisible(find.text('Try again'));
    await tester.tap(find.text('Try again'));
    await waitFor(
      tester,
      () => find.byType(AgendaScreen).evaluate().isNotEmpty,
    );
    expect(await tester.runAsync(() => db.getAllGoals()), hasLength(1));
    expect(config.keys['onboarding_done'], 'true');
    await waitFor(tester, () => find.text('Easy run').evaluate().isNotEmpty);
  });

  testWidgets('archived filter opens a goal and offers Unarchive', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await seed();
      await db.updateGoal(
        Goal.fromMap({...goal.toMap(), 'status': 'archived'}),
      );
    });
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(tester, () => find.text(task.title).evaluate().isNotEmpty);
    await tester.tap(find.text('Goals'));
    await waitFor(
      tester,
      () => find.text('Archived (1)').evaluate().isNotEmpty,
    );
    expect(find.text(goal.title), findsNothing);
    await tester.tap(find.text('Archived (1)'));
    await tester.pumpAndSettle();
    await tester.tap(find.text(goal.title));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Goal actions'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Unarchive'));
    await waitFor(tester, () => find.byType(GoalEditScreen).evaluate().isEmpty);
    expect(
      (await tester.runAsync(() => db.getGoal(goal.id)))!.status,
      GoalStatus.active,
    );
  });

  testWidgets('GoalEdit create validates title and saves a goal', (
    tester,
  ) async {
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(
      tester,
      () => find.text('Plan your first goal').evaluate().isNotEmpty,
    );
    await tester.tap(find.text('Add a goal'));
    await waitFor(
      tester,
      () => find.text('No goals yet').evaluate().isNotEmpty,
    );
    await tester.tap(find.byTooltip('Add goal'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();
    expect(find.text('Title is required'), findsOneWidget);
    await tester.enterText(
      find.widgetWithText(TextFormField, 'What do you want to achieve?'),
      'Run a 5K',
    );
    await tester.tap(find.text('Save'));
    await waitFor(tester, () => find.byType(GoalEditScreen).evaluate().isEmpty);
    final goals = await tester.runAsync(() => db.getAllGoals());
    expect(goals!.single.title, 'Run a 5K');
    expect(goals.single.priority, GoalPriority.P2);
    expect(DateTime.parse(goals.single.targetDate).isBefore(today), isFalse);
  });

  testWidgets('replan demo quota shows banner and opens Settings', (
    tester,
  ) async {
    await tester.runAsync(seed);
    config.provider = FakeProvider()..error = QuotaError('budget');
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(tester, () => find.text(task.title).evaluate().isNotEmpty);
    await tester.tap(find.text('Re-plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await waitFor(
      tester,
      () => find.byType(MaterialBanner).evaluate().isNotEmpty,
    );
    expect(
      find.text(
        'Free planning is unavailable right now — add your own AI key in Settings.',
      ),
      findsNWidgets(2),
    );
    await tester.tap(find.text('Open Settings'));
    await waitFor(
      tester,
      () => find.textContaining('Demo (free, limited)').evaluate().isNotEmpty,
    );
    expect(find.byType(SettingsScreen), findsOneWidget);
    await tester.tap(find.text('Dismiss'));
    await tester.pumpAndSettle();
    expect(find.byType(MaterialBanner), findsNothing);
  });

  testWidgets('decompose confirms existing plan and returns planned count', (
    tester,
  ) async {
    await tester.runAsync(seed);
    final provider = FakeProvider()
      ..response = {
        'tasks': [
          {
            'task_id': 'new',
            'goal_id': goal.id,
            'title': 'Try layouts',
            'duration_minutes': 30,
            'recommended_day': today.toIso8601String().substring(0, 10),
            'prerequisite_ids': <String>[],
          },
        ],
      };
    config.provider = provider;
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(tester, () => find.text(task.title).evaluate().isNotEmpty);
    await tester.tap(find.widgetWithText(NavigationDestination, 'Goals'));
    await waitFor(
      tester,
      () => find.textContaining('0 of 1 done').evaluate().isNotEmpty,
    );
    await tester.tap(find.text(goal.title));
    await waitFor(
      tester,
      () => find.byType(GoalEditScreen).evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await waitFor(tester, () {
      final list = tester.widget<ListView>(
        find.descendant(
          of: find.byType(GoalEditScreen),
          matching: find.byType(ListView),
        ),
      );
      return (list.childrenDelegate as SliverChildListDelegate).children.any(
        (child) => child is SectionHeader && child.title == 'Tasks',
      );
    });
    await tester.scrollUntilVisible(
      find.text(task.title),
      200,
      scrollable: find
          .descendant(
            of: find.byType(GoalEditScreen),
            matching: find.byType(Scrollable),
          )
          .first,
    );
    await tester.tap(find.text('Plan tasks'));
    await waitFor(
      tester,
      () => find
          .text('This goal already has a plan. Generate more tasks?')
          .evaluate()
          .isNotEmpty,
    );
    expect(provider.calls, 0);
    await tester.tap(find.text('Continue'));
    await waitFor(tester, () => find.byType(GoalEditScreen).evaluate().isEmpty);
    final tasks = await tester.runAsync(() => db.getTasksByGoal(goal.id));
    expect(tasks, hasLength(2));
    expect(tasks!.every((t) => t.scheduledStart != null), isTrue);
    expect(provider.calls, 1);
    await tester.tap(find.text('Agenda'));
    await waitFor(tester, () => find.text('Try layouts').evaluate().isNotEmpty);
  });

  testWidgets('replan shows moved times and tips then refreshes agenda', (
    tester,
  ) async {
    await tester.runAsync(seed);
    final tomorrow = DateTime(today.year, today.month, today.day + 1);
    config.provider = FakeProvider()
      ..response = {
        'tasks': [
          {
            'task_id': task.id,
            'goal_id': goal.id,
            'title': task.title,
            'duration_minutes': 30,
            'recommended_day': DateFormat('yyyy-MM-dd').format(tomorrow),
            'prerequisite_ids': <String>[],
          },
        ],
        'tips': ['Keep a steady pace.'],
      };
    await tester.pumpWidget(MyApp(services: services));
    await waitFor(tester, () => find.text(task.title).evaluate().isNotEmpty);
    await tester.tap(find.text('Re-plan'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Continue'));
    await waitFor(
      tester,
      () => find.text('Re-plan result').evaluate().isNotEmpty,
    );
    expect(find.text('Keep a steady pace.'), findsOneWidget);
    expect(find.text('Re-planned'), findsOneWidget);
    expect(find.text('1'), findsNWidgets(2));
    expect(find.textContaining('→', findRichText: true), findsOneWidget);
    expect(find.text("Couldn't fit"), findsNothing);
    expect(find.text('0'), findsOneWidget);
    await tester.ensureVisible(find.text('Back to agenda'));
    await tester.tap(find.text('Back to agenda'));
    await waitFor(
      tester,
      () => find.text('Nothing scheduled').evaluate().isNotEmpty,
    );
    await tester.pumpAndSettle();
    await tester.tap(
      find.bySemanticsLabel(DateFormat('EEE d').format(tomorrow)),
    );
    await tester.pumpAndSettle();
    expect(find.text(task.title), findsOneWidget);
  });

  testWidgets('schedule rejects an empty active-week selection', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(services: services)),
    );
    await waitFor(
      tester,
      () => find.textContaining('Demo (free, limited)').evaluate().isNotEmpty,
    );
    for (final day in [
      'Monday',
      'Tuesday',
      'Wednesday',
      'Thursday',
      'Friday',
    ]) {
      await tester.ensureVisible(find.byTooltip(day));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip(day));
      if (day != 'Friday') {
        await waitFor(
          tester,
          () =>
              services.prefs.activeDays.length ==
              5 -
                  ['Monday', 'Tuesday', 'Wednesday', 'Thursday'].indexOf(day) -
                  1,
        );
      }
      await tester.pumpAndSettle();
    }
    await tester.ensureVisible(find.text('Choose at least one active day.'));
    expect(find.text('Choose at least one active day.'), findsOneWidget);
    final prefs = await tester.runAsync(db.getPreferences);
    expect(prefs!.activeDays, ['fri']);
  });

  testWidgets('schedule save preserves calendar id and reloads preferences', (
    tester,
  ) async {
    await tester.runAsync(() async {
      await db.upsertPreferences(
        UserPreferences(timezone: 'UTC', planCalendarId: 'plan'),
      );
      await services.reloadPrefs();
    });
    await tester.pumpWidget(
      MaterialApp(home: SettingsScreen(services: services)),
    );
    await waitFor(
      tester,
      () => find.textContaining('Demo (free, limited)').evaluate().isNotEmpty,
    );
    await tester.scrollUntilVisible(
      find.text('Timezone'),
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.pumpAndSettle();
    await tester.tap(find.text('Timezone'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Asia/Kolkata');
    await tester.tap(find.text('Save'));
    await waitFor(tester, () => find.text('Saved').evaluate().isNotEmpty);
    expect(services.prefs.timezone, 'Asia/Kolkata');
    expect(services.prefs.planCalendarId, 'plan');
  });

  testWidgets(
    'timezone auto-save rejects blank input without changing stored preferences',
    (tester) async {
      await tester.pumpWidget(
        MaterialApp(home: SettingsScreen(services: services)),
      );
      await waitFor(
        tester,
        () => find.text('Demo (free, limited)').evaluate().isNotEmpty,
      );
      await tester.ensureVisible(find.text('Timezone'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Timezone'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), '   ');
      await tester.tap(find.text('Save'));
      await tester.pumpAndSettle();
      expect(
        find.descendant(
          of: find.byType(AlertDialog),
          matching: find.text('Enter an IANA timezone.'),
        ),
        findsOneWidget,
      );
      expect((await tester.runAsync(db.getPreferences))!.timezone, 'UTC');
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(find.text('UTC'), findsOneWidget);
    },
  );

  for (final width in [430.0, 1280.0]) {
    testWidgets('shell adapts navigation at width $width in dark mode', (
      tester,
    ) async {
      tester.view.physicalSize = Size(width, 932);
      tester.view.devicePixelRatio = 1;
      tester.platformDispatcher.platformBrightnessTestValue = Brightness.dark;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
      await tester.runAsync(seed);
      await tester.pumpWidget(MyApp(services: services));
      await waitFor(tester, () => find.text(task.title).evaluate().isNotEmpty);
      expect(
        find.byType(NavigationRail),
        width >= 840 ? findsOneWidget : findsNothing,
      );
      expect(
        find.byType(NavigationBar),
        width < 840 ? findsOneWidget : findsNothing,
      );
      expect(
        Theme.of(tester.element(find.byType(AgendaScreen))).brightness,
        Brightness.dark,
      );
      expect(tester.takeException(), isNull);
    });
  }
}
