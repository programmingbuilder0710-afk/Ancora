import 'package:flutter/material.dart';
import 'package:dynamic_color/dynamic_color.dart';


import 'calendar/calendar_service.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'models/models.dart';
import 'orchestration/orchestrator.dart';
import 'provider/provider_config_service.dart';
import 'slotter/slotter.dart';
import 'data/database_helper.dart';
import 'ui/agenda/agenda_screen.dart';
import 'ui/goals/goals_screen.dart';
import 'ui/settings/settings_screen.dart';
import 'ui/settings/provider_settings_screen.dart';

/// Composition root: owns every long-lived service, hydrates Slotter
/// registries before each mutating action (Orchestrator never does), and
/// builds Orchestrators that re-read provider config so mid-session
/// Settings changes take effect (FRONTEND_CONTRACT §11).
class AppServices {
  AppServices({DatabaseHelper? db}) : db = db ?? DatabaseHelper();

  final DatabaseHelper db;
  late final ProviderConfigService configService =
      ProviderConfigService(db: db);
  CalendarService? _calendar;
  String? _calendarError;
  UserPreferences? _prefs;

  Future<void> init() async {
    final stored = await db.getPreferences();
    if (stored == null) {
      _prefs = UserPreferences(timezone: await _deviceTimezone());
      await db.upsertPreferences(_prefs!);
    } else {
      _prefs = stored;
    }
    final calendar =
        CalendarService(_prefs!.planCalendarId, preferences: _prefs);
    try {
      await calendar.initialize();
      _calendar = calendar;
    } on Exception {
      _calendar = null;
      _calendarError = 'Calendar unavailable — tasks stay in the app only.';
    } on Object {
      // Platform-channel failures can throw Errors in tests; calendar is
      // optional by design (degradation matrix) so degrade silently.
      _calendar = null;
      _calendarError = 'Calendar unavailable — tasks stay in the app only.';
    }
    await syncDeviceBusyBlocks();
  }

  /// Refresh busy_blocks from the device's other calendars (NOT "My Plan").
  /// Replaces every stale 'device:'-sourced block in the horizon, keeps
  /// .ics-imported blocks untouched. Best-effort: failures leave previously
  /// synced data in place (degradation matrix — never blocks local ops).
  Future<void> syncDeviceBusyBlocks() async {
    final calendar = _calendar;
    if (calendar == null) return;
    try {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, now.day);
      final end = start.add(const Duration(days: 7));
      final blocks = await calendar.readBusyBlocks(
        start,
        end,
        workStart: prefs.workStart,
        workEnd: prefs.workEnd,
      );
      // Wide discovery window: device-sourced blocks synced on earlier
      // days fall before `start` as the clock rolls; delete-by-source
      // must see them or they accumulate forever.
      final stale = await db.getBusyBlocksInRange(
        start.subtract(const Duration(days: 730)),
        end.add(const Duration(days: 730)),
      );
      for (final block in stale) {
        if (block.source.startsWith('device:')) {
          await db.deleteBusyBlocksBySource(block.source);
        }
      }
      if (blocks.isNotEmpty) {
        await db.insertBusyBlocks(blocks);
      }
    } on Exception {
      // Permission revoked mid-session or provider read failure: keep the
      // previously synced blocks; the next successful sync replaces them.
    }
    await _reconcilePlanEvents();
  }

  /// Reconcile "My Plan" with SQLite, both directions, best-effort:
  ///
  /// - Orphans: device events no live task claims are deleted (goal
  ///   deleted pre-cleanup, or a device_event_id lost across reinstalls).
  /// - External time edits: a tracked event whose device start/end no
  ///   longer match SQLite imports the device time back into the task
  ///   (the user moved it in Google Calendar — the device is the source
  ///   of truth for placement). Completed/skipped tasks are never
  ///   touched (monotonic completion); pending tasks only.
  /// - External deletes: a tracked event that vanished from the device
  ///   clears the task's schedule — it surfaces under "needs attention".
  Future<void> _reconcilePlanEvents() async {
    final calendar = _calendar;
    if (calendar == null) return;
    try {
      final tasks = await db.getAllTasks();
      final byEventId = {
        for (final t in tasks)
          if (t.deviceEventId != null) t.deviceEventId!: t,
      };
      final planId = calendar.planCalendarId;
      final events = await calendar.readPlanEvents(planId);
      final deviceIds = {
        for (final e in events)
          if (e.eventId != null) e.eventId!,
      };

      // Empty read: could be a transient provider hiccup or a stale plan
      // calendar id. NEVER treat it as "user deleted everything" — skip
      // external-delete handling; orphan deletion is safe either way (it
      // iterates events, and an empty list deletes nothing).
      final emptyPlanRead = deviceIds.isEmpty;

      for (final event in events) {
        final id = event.eventId;
        final task = id == null ? null : byEventId[id];
        if (task == null) {
          if (id != null) {
            try {
              await calendar.deleteEvent(id);
            } on Exception {
              // Best-effort; retried on next sync.
            }
          }
          continue;
        }
        // Import external time edits for pending tasks only.
        if (task.status != TaskStatus.pending) continue;
        final evStart = event.start;
        final evEnd = event.end;
        if (evStart == null || evEnd == null) continue;
        final s = DateTime(evStart.year, evStart.month, evStart.day,
            evStart.hour, evStart.minute);
        final e = DateTime(evEnd.year, evEnd.month, evEnd.day,
            evEnd.hour, evEnd.minute);
        final dbStart = task.scheduledStart;
        final dbEnd = task.scheduledEnd;
        final newStart = s.toIso8601String();
        final newEnd = e.toIso8601String();
        if (dbStart == newStart && dbEnd == newEnd) continue;
        try {
          // The device is the source of truth for placement; mark the
          // task user-edited so decompose/re-plan never re-slot it and
          // the slotter keeps the time fixed.
          await db.updateTask(task.copyWith(
            scheduledStart: newStart,
            scheduledEnd: newEnd,
            userEdited: true,
          ));
        } on Exception {
          // Best-effort; retried on next sync.
        }
      }

      // External deletion of a tracked pending task's event: clear the
      // schedule so the agenda shows it under "needs attention". Skipped
      // entirely on an empty read — one transient provider hiccup must
      // never unschedule every tracked task in a single pass.
      if (!emptyPlanRead) {
        for (final entry in byEventId.entries) {
          final task = entry.value;
          if (task.status != TaskStatus.pending) continue;
          if (task.scheduledStart == null) continue;
          if (!deviceIds.contains(entry.key)) {
            try {
              await db.updateTask(task.copyWith(clearSchedule: true));
            } on Exception {
              // Best-effort; retried on next sync.
            }
          }
        }
      }
    } on Exception {
      // Read failure: retry next sync.
    }
  }

  UserPreferences get prefs => _prefs!;

  CalendarService? get calendar => _calendar;
  String? get calendarError => _calendarError;



  /// Persist new preferences and refresh the cached copy. Slotter reads
  /// fresh preferences at every mutating action, so changes apply to the
  /// next decompose/re-plan/skip without restart.
  Future<void> updatePreferences(UserPreferences prefs) async {
    await db.upsertPreferences(prefs);
    _prefs = prefs;
  }

  /// Hydrate both Slotter registries immediately before each
  /// decompose/replan/skip action (Orchestrator never mutates them).
  Future<Slotter> _hydratedSlotter() async {
    final slotter = Slotter(prefs);
    final goals = await db.getAllGoals(activeOnly: false);
    slotter.allGoals = {for (final g in goals) g.id: g};
    slotter.allTasks = await db.getAllTasks();
    return slotter;
  }

  /// Orchestrator for LLM operations. Null when BYOK config is incomplete —
  /// caller routes to provider settings (contract §12).
  Future<Orchestrator?> buildLlmOrchestrator() async {
    final provider = await configService.buildActiveProvider();
    if (provider == null) return null;
    return Orchestrator(
      db: db,
      providerFactory: () => provider,
      slotter: await _refreshedSlotter(),
      calendar: _calendar,
    );
  }

  /// Slotter registries hydrated after a busy-block refresh so placement
  /// always sees current device meetings.
  Future<Slotter> _refreshedSlotter() async {
    await syncDeviceBusyBlocks();
    return _hydratedSlotter();
  }

  /// Orchestrator for local-only ops (never call the provider factory —
  /// contract Pattern B). `skipTask` re-slots immediately, so callers opt
  /// into a device busy refresh; completion and ICS import need no refresh.
  Future<Orchestrator> buildLocalOrchestrator(
          {bool refreshBusyBlocks = false}) async =>
      Orchestrator(
        db: db,
        providerFactory: () => throw StateError('unreachable'),
        slotter: refreshBusyBlocks
            ? await _refreshedSlotter()
            : await _hydratedSlotter(),
        calendar: _calendar,
      );
}

Future<String> _deviceTimezone() async {
  // DateTime.timeZoneName is unreliable on Android (returns GMT+X strings);
  // resolve the IANA zone via the platform channel instead.
  String fallback = 'UTC';
  try {
    final info = await FlutterTimezone.getLocalTimezone();
    if (info.identifier.isNotEmpty) return info.identifier;
  } on Object {
    // fall through to UTC fallback
  }
  return fallback;
}

/// UI reload trigger: screens listen and reload SQLite-backed lists after
/// every successful mutation (no streams/ChangeNotifier per repo rules).
abstract final class DataReload {
  static final ValueNotifier<int> revision = ValueNotifier(0);

  static void bump() => revision.value++;
}

/// Re-syncs device busy blocks whenever the app returns to the
/// foreground, so edits/deletes made in other calendar apps (Google
/// Calendar etc.) are reflected in Doer without a cold start.
class BusySyncObserver with WidgetsBindingObserver {
  BusySyncObserver(this._services);

  final AppServices _services;
  bool _registered = false;

  void register() {
    if (_registered) return;
    WidgetsBinding.instance.addObserver(this);
    _registered = true;
  }

  void dispose() {
    if (_registered) {
      WidgetsBinding.instance.removeObserver(this);
      _registered = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _services.syncDeviceBusyBlocks().then((_) => DataReload.bump());
    }
  }
}

class DoerApp extends StatelessWidget {
  const DoerApp({super.key, this.services});

  /// Injectable for tests; null builds a production composition root.
  final AppServices? services;

  @override
  Widget build(BuildContext context) {
    return DynamicColorBuilder(
      builder: (lightDynamic, darkDynamic) {
        final light =
            lightDynamic ?? ColorScheme.fromSeed(seedColor: Colors.green);
        final dark = darkDynamic ??
            ColorScheme.fromSeed(
              seedColor: Colors.green,
              brightness: Brightness.dark,
            );
        return MaterialApp(
          title: 'Doer',
          theme: ThemeData(colorScheme: light, useMaterial3: true),
          darkTheme: ThemeData(colorScheme: dark, useMaterial3: true),
          home: services == null
              ? const Bootstrap()
              : HomeShell(services: services!),
        );
      },
    );
  }
}

/// Loads services, then shows the shell. No gate: the agenda opens even if
/// provider or calendar are unavailable (SPEC §8 degradation matrix).
class Bootstrap extends StatefulWidget {
  const Bootstrap({super.key});

  @override
  State<Bootstrap> createState() => _BootstrapState();
}

class _BootstrapState extends State<Bootstrap> {
  final AppServices _services = AppServices();

  @override
  void initState() {
    super.initState();
    () async {
      await _services.init();
      if (mounted) {
        Navigator.of(context).pushReplacement(MaterialPageRoute<void>(
          builder: (_) => HomeShell(services: _services),
        ));
      }
    }();
  }

  @override
  Widget build(BuildContext context) {
    return const Scaffold(body: Center(child: CircularProgressIndicator()));
  }
}

/// Bottom-nav shell: Agenda (home) / Goals.
class HomeShell extends StatefulWidget {
  const HomeShell({super.key, required this.services});

  final AppServices services;

  @override
  State<HomeShell> createState() => _HomeShellState();
}

class _HomeShellState extends State<HomeShell> {
  int _tab = 0;
  late final BusySyncObserver _busySync =
      BusySyncObserver(widget.services);

  @override
  void initState() {
    super.initState();
    _busySync.register();
  }

  @override
  void dispose() {
    _busySync.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _tab,
        children: [
          AgendaScreen(services: widget.services),
          GoalsScreen(services: widget.services),
          SettingsScreen(services: widget.services),
        ],
      ),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _tab,
        onDestinationSelected: (i) => setState(() => _tab = i),
        destinations: const [
          NavigationDestination(
            icon: Icon(Icons.calendar_today_outlined),
            selectedIcon: Icon(Icons.calendar_today),
            label: 'Agenda',
          ),
          NavigationDestination(
            icon: Icon(Icons.flag_outlined),
            selectedIcon: Icon(Icons.flag),
            label: 'Goals',
          ),
          NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}

/// Opens provider settings: loads initial values first because
/// ProviderSettingsScreen requires synchronous construction data
/// (contract recipe). Settings screen hosts its own app bar.
Future<void> openProviderSettings(
    BuildContext context, AppServices services) async {
  final config = services.configService;
  final mode = await config.getMode();
  final byok = await config.getByokConfig();
  if (!context.mounted) return;
  await Navigator.of(context).push(MaterialPageRoute<void>(
    fullscreenDialog: true,
    builder: (_) => ProviderSettingsScreen(
      configService: config,
      initialMode: mode,
      initialByokApiKey: byok?.apiKey,
      initialByokBaseUrl: byok?.baseUrl,
      initialByokModel: byok?.model,
    ),
  ));
}
