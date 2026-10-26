import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';

import '../calendar_connect.dart';
import '../schedule_fields.dart';
import '../provider_settings.dart';

import '../../calendar/connected_calendars.dart';
import '../dialogs.dart';
import '../widgets.dart';

import '../../app_services.dart';
import '../../models/models.dart';

class SettingsScreen extends StatefulWidget {
  final AppServices services;
  const SettingsScreen({super.key, required this.services});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  List<CalendarAccount> _accounts = [];
  List<String> _icsUrls = [];
  String? _planAccount;
  late final AppLifecycleListener _lifecycle;
  final _timezone = TextEditingController();
  late String _start;
  late String _end;
  late int _buffer;
  late Set<String> _days;
  String _provider = 'Loading…';
  String _model = '';
  String? _scheduleError;
  bool _saving = false;
  bool _notConfigured = false;
  Map<String, int> _sources = {};
  String? _error;
  bool _busy = false;
  static const _notConfiguredMessage =
      'Calendar connections are not configured on this server';
  static const _week = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];

  @override
  void initState() {
    super.initState();
    final prefs = widget.services.prefs;
    _start = prefs.workStart;
    _end = prefs.workEnd;
    _buffer = prefs.bufferMinutes;
    _days = prefs.activeDays.toSet();
    _timezone.text = prefs.timezone;
    _lifecycle = AppLifecycleListener(
      onResume: () {
        if (mounted && widget.services.connected != null) _run(_reload);
      },
    );
    _run(_reload);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _timezone.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final config = widget.services.config;
    final mode = await config.getMode();
    final builtIn = await widget.services.usesBuiltInDemo();
    final model = mode == 'demo'
        ? (await config.getDemoConfig()).model
        : (await config.getByokConfig())?.model ?? 'Setup incomplete';
    final blocks = await widget.services.db.getBusyBlocksInRange(
      DateTime(2000),
      DateTime(2100),
    );
    final sources = <String, int>{};
    for (final block in blocks) {
      sources.update(block.source, (n) => n + 1, ifAbsent: () => 1);
    }
    final connected = widget.services.connected;
    List<CalendarAccount> accounts = _accounts;
    List<String> urls = _icsUrls;
    String? target = _planAccount;
    String? error;
    if (connected != null) {
      urls = await connected.icsUrls();
      target = await connected.planAccountId();
      try {
        accounts = await connected.accounts();
      } catch (e) {
        error = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
      }
    }
    if (mounted) {
      setState(() {
        _accounts = accounts;
        _icsUrls = urls;
        _planAccount = target;
        _notConfigured = error == _notConfiguredMessage;
        _error =
            (_notConfigured ? null : error) ??
            (kIsWeb && Uri.base.queryParameters.containsKey('connect_error')
                ? 'Calendar connection did not finish. Try connecting again.'
                : null);
        _provider = builtIn
            ? 'Free (built-in)'
            : mode == 'demo'
            ? 'Demo (free, limited)'
            : 'Your provider';
        _model = builtIn ? 'Shared quota — add your own key anytime' : model;
        _sources = sources;
      });
    }
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
      if (mounted) {
        final message = e.toString().replaceFirst(RegExp(r'^Exception: '), '');
        setState(() {
          if (message == _notConfiguredMessage) {
            _notConfigured = true;
          } else {
            _error = message;
          }
        });
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String message) {
    if (mounted) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _openProvider() async {
    await openProviderSettings(context, widget.services);
    await _reload();
  }

  Future<bool> _save() async {
    setState(() {
      _saving = true;
      _scheduleError = null;
    });
    try {
      final error = scheduleError(_start, _end, _days);
      if (error != null) throw Exception(error);
      if (_timezone.text.trim().isEmpty) {
        throw Exception('Enter an IANA timezone.');
      }
      await widget.services.db.upsertPreferences(
        UserPreferences(
          workStart: _start,
          workEnd: _end,
          bufferMinutes: _buffer,
          activeDays: _week.where(_days.contains).toList(),
          timezone: _timezone.text.trim(),
          planCalendarId: widget.services.prefs.planCalendarId,
        ),
      );
      await widget.services.reloadPrefs();
      return true;
    } catch (e) {
      if (mounted) {
        setState(
          () => _scheduleError = e.toString().replaceFirst(
            RegExp(r'^Exception: '),
            '',
          ),
        );
      }
      return false;
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _editTimezone() async {
    final previous = _timezone.text;
    var saving = false;
    String? error;
    final saved = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, update) => AlertDialog(
          title: const Text('Timezone'),
          content: TextField(
            controller: _timezone,
            enabled: !saving,
            decoration: InputDecoration(
              labelText: 'Timezone (IANA)',
              hintText: 'America/Los_Angeles',
              errorText: error,
            ),
          ),
          actions: [
            TextButton(
              onPressed: saving
                  ? null
                  : () => Navigator.pop(dialogContext, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: saving
                  ? null
                  : () async {
                      update(() => saving = true);
                      final success = await _save();
                      if (!dialogContext.mounted) return;
                      if (success) {
                        Navigator.pop(dialogContext, true);
                      } else {
                        update(() {
                          saving = false;
                          error = _scheduleError;
                        });
                      }
                    },
              child: const Text('Save'),
            ),
          ],
        ),
      ),
    );
    if (saved == true) {
      _message('Saved');
    } else {
      if (mounted) {
        setState(() {
          _timezone.text = previous;
          if (_scheduleError == 'Enter an IANA timezone.') {
            _scheduleError = null;
          }
        });
      }
    }
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
    try {
      final count = await (await widget.services.orchestrator())
          .importIcsContent(utf8.decode(file.bytes!), file.name);
      _message('Imported $count busy periods from ${file.name}');
    } finally {
      await _reload();
    }
  }

  Future<void> _showConnect() async {
    await showCalendarConnect(
      context,
      widget.services,
      notConfigured: _notConfigured,
    );
    await _run(_reload);
  }

  Widget _accountTile(CalendarAccount account) => ListTile(
    leading: CircleAvatar(
      child: Text(account.app == 'google_calendar' ? 'G' : 'O'),
    ),
    title: Text(account.name),
    subtitle: Text(
      '${account.app == 'google_calendar' ? 'Google Calendar' : 'Outlook'}${_planAccount == account.id ? ' · Plan goes here' : ''}',
    ),
    trailing: PopupMenuButton<String>(
      tooltip: 'Calendar actions',
      enabled: !_busy,
      onSelected: (value) => _run(() async {
        if (value == 'plan') {
          await widget.services.connected!.setPlanAccountId(
            _planAccount == account.id ? null : account.id,
          );
          await widget.services.projectPlan();
        } else {
          if (!await confirmAction(context, 'Disconnect ${account.name}?')) {
            return;
          }
          await widget.services.connected!.disconnect(account.id);
        }
        await _reload();
      }),
      itemBuilder: (_) => [
        if (kIsWeb)
          CheckedPopupMenuItem(
            value: 'plan',
            checked: _planAccount == account.id,
            child: const Text('Write my plan here'),
          ),
        const PopupMenuItem(value: 'disconnect', child: Text('Disconnect')),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final valueStyle = theme.textTheme.bodyLarge?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
      fontWeight: FontWeight.w400,
    );
    final scheduleEnabled = !_saving && !_busy;
    return Scaffold(
      appBar: AppBar(toolbarHeight: 24),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
          children: [
            Text('Settings', style: theme.textTheme.headlineMedium),
            if (_error != null) ...[
              const SizedBox(height: 16),
              Notice(_error!, error: true),
            ],
            const SectionHeader('AI provider'),
            SectionCard(
              children: [
                ListTile(
                  leading: CircleAvatar(
                    backgroundColor: theme.colorScheme.secondaryContainer,
                    child: Icon(
                      Icons.settings,
                      color: theme.colorScheme.onSecondaryContainer,
                    ),
                  ),
                  title: Text(_provider),
                  subtitle: Text(_model),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _run(_openProvider),
                ),
              ],
            ),
            const SectionHeader('When Doer can schedule'),
            SectionCard(
              children: [
                WorkHours(
                  start: _start,
                  end: _end,
                  enabled: scheduleEnabled,
                  onChanged: (start, end) {
                    setState(() {
                      _start = start;
                      _end = end;
                    });
                    _save();
                  },
                ),
                ListTile(
                  title: const Text('Buffer between tasks'),
                  trailing: DropdownButton<int>(
                    value: _buffer,
                    style: valueStyle,
                    underline: const SizedBox.shrink(),
                    items: [
                      for (final value in {
                        ...[0, 5, 10, 15, 30],
                        _buffer,
                      }.toList()..sort())
                        DropdownMenuItem(
                          value: value,
                          child: Text('$value min'),
                        ),
                    ],
                    onChanged: scheduleEnabled
                        ? (value) {
                            setState(() => _buffer = value!);
                            _save();
                          }
                        : null,
                  ),
                ),
                ActiveDays(
                  days: _days,
                  enabled: scheduleEnabled,
                  onChanged: (days) {
                    setState(() => _days = days);
                    _save();
                  },
                ),
                ListTile(
                  title: const Text('Timezone'),
                  trailing: ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 200),
                    child: Tooltip(
                      message: _timezone.text,
                      child: Text(
                        _timezone.text,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: valueStyle,
                      ),
                    ),
                  ),
                  onTap: scheduleEnabled ? _editTimezone : null,
                ),
              ],
            ),
            if (_scheduleError != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Notice(_scheduleError!, error: true),
              ),
            if (widget.services.calendar?.timezoneWarning != null)
              Notice(widget.services.calendar!.timezoneWarning!),
            if (widget.services.calendarError != null) ...[
              const SizedBox(height: 24),
              Notice(widget.services.calendarError!),
            ],
            if (widget.services.connected != null) ...[
              SectionHeader(
                'Calendars',
                trailing: _busy
                    ? const SizedBox(
                        width: 48,
                        height: 48,
                        child: Center(
                          child: SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      )
                    : IconButton(
                        tooltip: 'Sync now',
                        icon: const Icon(Icons.sync),
                        onPressed: () => _run(() async {
                          final warning = await widget.services.connected!
                              .syncBusy(widget.services.db);
                          widget.services.lastSyncWarning = warning;
                          await _reload();
                          _message(warning ?? 'Calendars synced');
                        }),
                      ),
              ),
              SectionCard(
                children: [
                  if (_notConfigured)
                    const ListTile(
                      leading: Icon(Icons.info_outline),
                      title: Text(
                        "Calendar connections aren't set up on this server.",
                      ),
                    ),
                  for (final account in _accounts) _accountTile(account),
                  if (_accounts.isNotEmpty &&
                      !_accounts.any((a) => a.id == _planAccount))
                    ListTile(
                      leading: const Icon(Icons.info_outline),
                      title: Text(
                        'Your plan is not written to a calendar yet. Open ⋮ on an account and choose "Write my plan here".',
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.add_link),
                    title: const Text('Connect a calendar'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: _busy ? null : _showConnect,
                  ),
                  for (final url in _icsUrls)
                    ListTile(
                      leading: const Icon(Icons.link),
                      title: Text(Uri.parse(url).host),
                      subtitle: Text(
                        url,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      trailing: IconButton(
                        tooltip: 'Remove subscription',
                        icon: const Icon(Icons.delete_outline),
                        onPressed: _busy
                            ? null
                            : () => _run(() async {
                                await widget.services.connected!.removeIcsUrl(
                                  url,
                                );
                                await _reload();
                              }),
                      ),
                    ),
                  if (widget.services.lastSyncWarning != null)
                    ListTile(
                      leading: const Icon(Icons.warning_amber_rounded),
                      title: Text(
                        widget.services.lastSyncWarning!,
                        style: theme.textTheme.bodySmall,
                      ),
                    ),
                ],
              ),
            ],
            const SectionHeader('Busy time'),
            Text(
              'Imported calendar time is kept free when planning.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: 12),
            SectionCard(
              children: [
                ListTile(
                  leading: const Icon(Icons.upload_file),
                  title: const Text('Import an .ics file'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _busy ? null : () => _run(_import),
                ),
                for (final source in _sources.entries)
                  ListTile(
                    title: Text(busySourceName(source.key)),
                    subtitle: Text('${source.value} busy periods'),
                    trailing: IconButton(
                      tooltip: 'Remove',
                      icon: const Icon(Icons.delete_outline),
                      onPressed: _busy
                          ? null
                          : () => _run(() async {
                              await widget.services.db.deleteBusyBlocksBySource(
                                source.key,
                              );
                              await _reload();
                            }),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
