import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:uuid/uuid.dart';

import '../app_services.dart';
import '../models/models.dart';
import 'calendar_connect.dart';
import 'dialogs.dart';
import 'provider_settings.dart';
import 'schedule_fields.dart';
import 'widgets.dart';

class OnboardingScreen extends StatefulWidget {
  final AppServices services;
  final void Function(DateTime? day, String? message) onFinished;
  const OnboardingScreen({
    super.key,
    required this.services,
    required this.onFinished,
  });
  @override
  State<OnboardingScreen> createState() => _OnboardingScreenState();
}

class _OnboardingScreenState extends State<OnboardingScreen> {
  final _title = TextEditingController(), _details = TextEditingController();
  DateTime _target = DateUtils.dateOnly(DateTime.now())
      .add(const Duration(days: 28));
  late String _start, _end;
  late Set<String> _days;
  int _step = 0;
  bool _busy = false;
  String? _error;
  Goal? _goal;
  List<String> _calendars = [];
  late final AppLifecycleListener _lifecycle;
  @override
  void initState() {
    super.initState();
    final prefs = widget.services.prefs;
    _start = prefs.workStart;
    _end = prefs.workEnd;
    _days = prefs.activeDays.toSet();
    _lifecycle = AppLifecycleListener(onResume: _reloadCalendars);
    _reloadCalendars();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _title.dispose();
    _details.dispose();
    super.dispose();
  }

  Future<void> _reloadCalendars() async {
    final connected = widget.services.connected;
    final names = <String>[];
    if (connected != null) {
      names.addAll(
        (await connected.icsUrls()).map((url) => Uri.parse(url).host),
      );
      try {
        names.addAll((await connected.accounts()).map((a) => a.name));
      } catch (_) {
        // Optional connections may not be configured; the connect sheet explains this.
      }
    }
    final blocks = await widget.services.db.getBusyBlocksInRange(
      DateTime(2000),
      DateTime(2100),
    );
    names.addAll(
      blocks
          .where(
            (b) => !b.source.startsWith('pd:') && !b.source.startsWith('ics:'),
          )
          .map((b) => b.source)
          .toSet(),
    );
    if (mounted) setState(() => _calendars = names);
  }

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await action();
    } catch (e) {
      final demo = await widget.services.config.getMode() == 'demo';
      if (mounted) {
        setState(() => _error = providerErrorMessage(e, demoMode: demo));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _finish([DateTime? day, String? message]) async {
    await widget.services.finishOnboarding();
    if (mounted) widget.onFinished(day, message);
  }

  Future<void> _next() async {
    if (_step == 1) {
      final error = scheduleError(_start, _end, _days);
      if (error != null) {
        setState(() => _error = error);
        return;
      }
      await widget.services.db.upsertPreferences(
        UserPreferences.fromMap({
          ...widget.services.prefs.toMap(),
          'work_start': _start,
          'work_end': _end,
          'active_days': jsonEncode(
            ActiveDays.week.where(_days.contains).toList(),
          ),
        }),
      );
      await widget.services.reloadPrefs();
    }
    if (mounted) setState(() => _step++);
  }

  Future<void> _plan() async {
    final goal = Goal(
      id: _goal?.id ?? const Uuid().v4(),
      title: _title.text.trim(),
      description: _details.text.trim(),
      priority: GoalPriority.P1,
      targetDate: DateFormat('yyyy-MM-dd').format(_target),
      createdAt: _goal?.createdAt ?? DateTime.now().toIso8601String(),
    );
    if (_goal == null) {
      await widget.services.db.insertGoal(goal);
    } else {
      await widget.services.db.updateGoal(goal);
    }
    _goal = goal;
    if (!mounted) return;
    final results = await withProgress(
      context,
      () async =>
          (await widget.services.orchestrator(needsProvider: true))
              .decompose(goals: [goal]),
    );
    final starts =
        results
            .where(
              (r) => r.task.goalId == goal.id && r.task.scheduledStart != null,
            )
            .map((r) => DateTime.parse(r.task.scheduledStart!).toLocal())
            .toList()
          ..sort();
    await _finish(
      starts.firstOrNull,
      'Planned ${starts.length} sessions for “${goal.title}”',
    );
  }

  Future<void> _import() async {
    final picked = await FilePicker.platform.pickFiles(
      withData: true,
      type: FileType.custom,
      allowedExtensions: ['ics'],
    );
    if (picked == null) return;
    final file = picked.files.single;
    if (file.bytes == null) throw Exception('Could not open ${file.name}');
    await (await widget.services.orchestrator()).importIcsContent(
      utf8.decode(file.bytes!),
      file.name,
    );
    await _reloadCalendars();
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy,
    child: Scaffold(
      appBar: AppBar(
        leading: _step == 0
            ? null
            : BackButton(
                onPressed: _busy
                    ? null
                    : () => setState(() {
                        _step--;
                        _error = null;
                      }),
              ),
        title: Text('${_step + 1} of 3'),
        actions: [
          TextButton(
            onPressed: _busy ? null : () => _run(_finish),
            child: const Text('Skip setup'),
          ),
        ],
      ),
      body: SafeArea(
        child: ContentWidth(
          child: ListView(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 32),
            children: [
              LinearProgressIndicator(value: (_step + 1) / 3),
              const SizedBox(height: 32),
              Text(
                [
                  'What are you working toward?',
                  'When can you work on it?',
                  'Keep your existing plans free',
                ][_step],
                style: Theme.of(context).textTheme.headlineMedium,
              ),
              const SizedBox(height: 24),
              if (_step == 0) ...[
                TextField(
                  controller: _title,
                  textInputAction: TextInputAction.next,
                  onSubmitted: (_) {
                    if (!_busy && _title.text.trim().isNotEmpty) _run(_next);
                  },
                  enabled: !_busy,
                  onChanged: (_) => setState(() {}),
                  decoration: const InputDecoration(
                    labelText: 'Your goal',
                    hintText: 'e.g. Run a half marathon',
                  ),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  runSpacing: 4,
                  children: [
                    for (final title in [
                      'Run a half marathon',
                      'Ship my portfolio site',
                      'Learn conversational Spanish',
                    ])
                      ActionChip(
                        label: Text(title),
                        onPressed: () => setState(() => _title.text = title),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _details,
                  minLines: 3,
                  maxLines: 5,
                  decoration: const InputDecoration(
                    labelText: 'Details (optional)',
                    hintText: 'Anything Doer should know? Current level, constraints, what done looks like.',
                  ),
                ),
                const SizedBox(height: 24),
                SectionCard(
                  children: [
                    ListTile(
                      title: const Text('Target date'),
                      subtitle: Text(DateFormat.yMMMd().format(_target)),
                      trailing: const Icon(Icons.calendar_today),
                      onTap: () async {
                        final today = DateUtils.dateOnly(DateTime.now());
                        final date = await showDatePicker(
                          context: context,
                          initialDate: _target.isBefore(today)
                              ? today
                              : _target,
                          firstDate: today,
                          lastDate: DateTime(today.year + 100),
                        );
                        if (date != null && mounted) {
                          setState(() => _target = date);
                        }
                      },
                    ),
                  ],
                ),
              ],
              if (_step == 1) ...[
                const Text('Doer only schedules sessions inside this window.'),
                const SizedBox(height: 24),
                SectionCard(
                  children: [
                    WorkHours(
                      start: _start,
                      end: _end,
                      onChanged: (a, b) => setState(() {
                        _start = a;
                        _end = b;
                      }),
                    ),
                    ActiveDays(
                      days: _days,
                      onChanged: (days) => setState(() => _days = days),
                    ),
                  ],
                ),
              ],
              if (_step == 2) ...[
                const Text(
                  'Connect a calendar or import busy time. You can also do this later in Settings.',
                ),
                const SizedBox(height: 24),
                SectionCard(
                  children: [
                    if (widget.services.connected != null) ...[
                      for (final entry in {
                        'google_calendar': 'Google Calendar',
                        'microsoft_outlook_calendar': 'Outlook',
                      }.entries)
                        ListTile(
                          leading: const Icon(Icons.calendar_month),
                          title: Text(entry.value),
                          trailing: const Icon(Icons.chevron_right),
                          onTap: _busy
                              ? null
                              : () => _run(
                                  () => connectCalendar(
                                    context,
                                    widget.services,
                                    entry.key,
                                  ),
                                ),
                        ),
                      ListTile(
                        leading: const Icon(Icons.link),
                        title: const Text('Add a calendar link (.ics)'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: _busy
                            ? null
                            : () => _run(() async {
                                await showCalendarConnect(
                                  context,
                                  widget.services,
                                  initialLink: true,
                                );
                                await _reloadCalendars();
                              }),
                      ),
                    ],
                    ListTile(
                      leading: const Icon(Icons.upload_file),
                      title: const Text('Import an .ics file'),
                      onTap: _busy ? null : () => _run(_import),
                    ),
                    for (final name in _calendars)
                      ListTile(
                        leading: const Icon(Icons.check),
                        title: Text(name),
                      ),
                  ],
                ),
                const SizedBox(height: 24),
                const Text(
                  'Your goal details go to the AI to draft sessions. Your plan stays on this device.',
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 24),
                Notice(_error!, error: true),
                if (_step == 2)
                  TextButton(
                    onPressed: _busy
                        ? null
                        : () => openProviderSettings(
                            context,
                            widget.services,
                            ownKey: true,
                          ),
                    child: const Text('Use my own AI key'),
                  ),
              ],
              const SizedBox(height: 32),
              FilledButton(
                onPressed: _busy || (_step == 0 && _title.text.trim().isEmpty)
                    ? null
                    : () => _run(_step == 2 ? _plan : _next),
                child: Text(
                  _step == 2
                      ? (_error == null ? 'Plan my week' : 'Try again')
                      : 'Next',
                ),
              ),
            ],
          ),
        ),
      ),
    ),
  );
}
