import 'package:flutter/foundation.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:http/http.dart' as http;

import 'calendar/connected_calendars.dart';
import 'calendar/plan_calendar.dart';

import 'calendar/calendar_service.dart';
import 'data/database_helper.dart';
import 'models/models.dart';
import 'orchestration/orchestrator.dart';
import 'provider/provider.dart';
import 'provider/provider_config_service.dart';
import 'slotter/slotter.dart';

class ProviderNotConfigured implements Exception {
  final String message = 'Finish provider setup in Settings to plan tasks.';
  @override
  String toString() => message;
}

class AppServices {
  final DatabaseHelper db;
  final ProviderConfigService config;
  UserPreferences prefs;
  CalendarService? calendar;
  String? calendarError;
  ConnectedCalendars? connected;
  String? lastSyncWarning;

  AppServices._(this.db, this.config, this.prefs);

  static Future<AppServices> load({
    DatabaseHelper? db,
    ProviderConfigService? config,
    bool initCalendar = true,
  }) async {
    db ??= DatabaseHelper();
    var prefs = await db.getPreferences();
    if (prefs == null) {
      var zone = 'UTC';
      try {
        zone = (await FlutterTimezone.getLocalTimezone()).identifier;
      } catch (_) {
        // Host tests and unavailable platform channels use UTC.
      }
      prefs = UserPreferences(timezone: zone);
      await db.upsertPreferences(prefs);
    }
    final services = AppServices._(
      db,
      config ?? ProviderConfigService(db: db),
      prefs,
    );
    if (kIsWeb || apiBase.isNotEmpty) {
      services.connected = ConnectedCalendars(client: http.Client(), db: db);
    }
    if (initCalendar && !kIsWeb) {
      try {
        final calendar = CalendarService(
          prefs.planCalendarId,
          preferences: prefs,
        );
        await calendar.initialize();
        if (calendar.planCalendarId != prefs.planCalendarId) {
          prefs = UserPreferences.fromMap({
            ...prefs.toMap(),
            'plan_calendar_id': calendar.planCalendarId,
          });
          await db.upsertPreferences(prefs);
          services.prefs = prefs;
        }
        services.calendar = calendar;
      } catch (_) {
        services.calendarError =
            "Calendar unavailable — tasks won't sync to your device calendar";
      }
    }
    return services;
  }

  Future<bool> usesBuiltInDemo() async =>
      connected != null &&
      await config.getMode() == 'demo' &&
      (await config.getDemoConfig()).apiKey.isEmpty;

  Future<bool> needsOnboarding() async =>
      (await db.getAllGoals(activeOnly: false)).isEmpty &&
      await config.readKey('onboarding_done') != 'true';

  Future<void> finishOnboarding() => config.writeKey('onboarding_done', 'true');

  Future<Orchestrator> orchestrator({bool needsProvider = false}) async {
    final slotter = Slotter(prefs);
    slotter.allGoals = {
      for (final goal in await db.getAllGoals(activeOnly: false)) goal.id: goal,
    };
    slotter.allTasks = await db.getAllTasks();
    LlmProvider Function() factory = () =>
        throw StateError('provider not needed');
    if (needsProvider) {
      try {
        lastSyncWarning = await connected?.syncBusy(db);
      } catch (_) {
        lastSyncWarning =
            'Calendars could not sync. Planning uses saved busy times.';
      }
      final provider = await usesBuiltInDemo()
          ? DemoProvider(
              apiKey: await connected!.userId(),
              baseUrl: (apiBase.isEmpty ? Uri.base : Uri.parse(apiBase))
                  .resolve('/api/llm')
                  .toString(),
              model: 'demo',
            )
          : await config.buildActiveProvider();
      if (provider == null) throw ProviderNotConfigured();
      factory = () => provider;
    }
    return Orchestrator(
      db: db,
      providerFactory: factory,
      slotter: slotter,
      calendar: await _planCalendar(),
    );
  }

  Future<PlanCalendar?> _planCalendar() async {
    if (kIsWeb &&
        connected != null &&
        await connected!.planAccountId() != null) {
      return PipedreamPlanCalendar(connected!);
    }
    return calendar;
  }

  Future<void> renameTask(Task task, String title) async {
    title = title.trim();
    if (title.isEmpty || title.length > 120) {
      throw ArgumentError('Session title must contain 1–120 characters.');
    }
    final current = await db.getTask(task.id);
    if (current == null || current.status != TaskStatus.pending) return;
    var renamed = current.copyWith(title: title);
    await db.updateTask(renamed);
    if (current.deviceEventId == null) return;
    try {
      final plan = await _planCalendar();
      if (plan == null) return;
      await plan.deleteEvent(current.deviceEventId!);
      final afterDelete = await db.getTask(task.id);
      if (afterDelete == null) return;
      renamed = afterDelete.copyWith(clearDeviceEventId: true);
      await db.updateTask(renamed);
      final id = await plan.writeTaskEvent(renamed);
      // Keep any completion that happened while the calendar was responding.
      final latest = await db.getTask(task.id);
      if (latest != null) {
        await db.updateTask(latest.copyWith(deviceEventId: id));
      }
    } catch (_) {
      // SQLite owns the rename; calendar projection is best effort.
    }
  }

  Future<void> deleteTask(Task task) async {
    final current = await db.getTask(task.id);
    if (current == null || current.status != TaskStatus.pending) return;
    if (current.deviceEventId != null) {
      try {
        await (await _planCalendar())?.deleteEvent(current.deviceEventId!);
      } catch (_) {
        // Calendar cleanup must not block local deletion.
      }
    }
    final latest = await db.getTask(task.id);
    if (latest?.status == TaskStatus.pending) await db.deleteTask(task.id);
  }

  Future<void> reloadPrefs() async {
    prefs = (await db.getPreferences())!;
    if (calendar != null) {
      calendar = CalendarService(calendar!.planCalendarId, preferences: prefs);
    }
  }

  Future<void> deleteGoal(Goal goal) async {
    for (final task in await db.getTasksByGoal(goal.id)) {
      if (task.deviceEventId != null) {
        try {
          if (kIsWeb && connected != null) {
            await PipedreamPlanCalendar(connected!)
                .deleteEvent(task.deviceEventId!);
          } else {
            await calendar?.deleteEvent(task.deviceEventId!);
          }
        } catch (_) {
          // Device calendar cleanup is best effort; SQLite owns the goal.
        }
      }
    }
    await db.deleteGoal(goal.id);
  }
}

String providerErrorMessage(Object e, {required bool demoMode}) => switch (e) {
  AuthError() => 'Key invalid or revoked — check your API key in Settings.',
  QuotaError() =>
    demoMode
        ? 'Free planning is unavailable right now — add your own AI key in Settings.'
        : 'Quota exhausted — add credits or switch provider.',
  RateLimitError() => 'Rate limited — try again in a few minutes.',
  NetworkError() =>
    demoMode
        ? freePlanningUnavailable
        : 'Network error — check your connection.',
  ProviderError() =>
    demoMode
        ? freePlanningUnavailable
        : 'Provider unavailable (status ${e.statusCode}) — try again.',
  SchemaViolationError() =>
    'The model returned an invalid response — try again.',
  ProviderNotConfigured() => e.message,
  FormatException() => 'Invalid provider base URL — check Settings.',
  _ => 'Something went wrong. Please try again.',
};

const freePlanningUnavailable =
    'Free planning is unavailable right now — add your own AI key in Settings.';
bool isDemoExhausted(Object e, bool demoMode) =>
    demoMode && (e is QuotaError || e is ProviderError || e is NetworkError);
