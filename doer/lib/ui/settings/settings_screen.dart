import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../../app.dart';
import '../../models/models.dart';

/// Settings screen (SPEC 8.1 #3): working hours, buffer minutes, active
/// days, timezone display, `.ics` busy-calendar import, and the provider
/// configuration entry point.
///
/// Every control persists immediately via `AppServices.updatePreferences`
/// (SQLite singleton row). Working-hours/buffer/active-day changes take
/// effect on the next decompose/re-plan/skip because AppServices hydrates
/// the Slotter fresh from preferences before every mutating action.
class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key, required this.services});

  final AppServices services;

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  static const _dayKeys = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const _dayLabels = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];

  UserPreferences? _prefs;
  double? _bufferPreview; // local drag preview; persisted only on release
  Map<String, int> _busySources = {}; // source filename -> block count

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload() async {
    final prefs = await widget.services.db.getPreferences();
    final now = DateTime.now();
    final blocks = await widget.services.db
        .getBusyBlocksInRange(now, now.add(const Duration(days: 366)));
    if (!mounted) return;
    setState(() {
      _prefs = prefs;
      final sources = <String, int>{};
      for (final block in blocks) {
        sources[block.source] = (sources[block.source] ?? 0) + 1;
      }
      _busySources = sources;
    });
  }

  Future<void> _update(UserPreferences prefs) async {
    await widget.services.updatePreferences(prefs);
    if (mounted) setState(() => _prefs = prefs);
  }

  Future<void> _pickTime({required bool isStart}) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final current = isStart ? prefs.workStart : prefs.workEnd;
    final parts = current.split(':');
    final picked = await showTimePicker(
      context: context,
      initialTime: TimeOfDay(
          hour: int.parse(parts[0]), minute: int.parse(parts[1])),
    );
    if (picked == null) return;
    final value =
        '${picked.hour.toString().padLeft(2, '0')}:${picked.minute.toString().padLeft(2, '0')}';
    final newMinutes = _startMinutes(value);
    if (isStart && newMinutes >= _startMinutes(prefs.workEnd)) {
      _showError('Work start must be before work end.');
      return;
    }
    if (!isStart && newMinutes <= _startMinutes(prefs.workStart)) {
      _showError('Work end must be after work start.');
      return;
    }
    await _update(isStart
        ? _copy(prefs, workStart: value)
        : _copy(prefs, workEnd: value));
  }

  static int _startMinutes(String hhmm) {
    final parts = hhmm.split(':');
    return int.parse(parts[0]) * 60 + int.parse(parts[1]);
  }


  UserPreferences _copy(UserPreferences prefs,
      {String? workStart, String? workEnd, int? bufferMinutes}) {
    return UserPreferences(
      workStart: workStart ?? prefs.workStart,
      workEnd: workEnd ?? prefs.workEnd,
      bufferMinutes: bufferMinutes ?? prefs.bufferMinutes,
      activeDays: prefs.activeDays,
      timezone: prefs.timezone,
      planCalendarId: prefs.planCalendarId,
    );
  }

  Future<void> _toggleDay(String day) async {
    final prefs = _prefs;
    if (prefs == null) return;
    final days = [...prefs.activeDays];
    final active = days.contains(day);
    if (active) {
      days.remove(day);
    } else {
      days.add(day);
    }
    if (days.isEmpty) {
      _showError('At least one active day is required.');
      return;
    }
    await _update(UserPreferences(
      workStart: prefs.workStart,
      workEnd: prefs.workEnd,
      bufferMinutes: prefs.bufferMinutes,
      activeDays: days,
      timezone: prefs.timezone,
      planCalendarId: prefs.planCalendarId,
    ));
  }

  Future<void> _setBuffer(double value) async {
    final prefs = _prefs;
    if (prefs == null) return;
    await _update(_copy(prefs, bufferMinutes: value.round()));
  }

  /// `.ics` import (SPEC 7.2): parse VEVENTs into busy blocks, replacing
  /// any previously imported blocks from the same file. Local-only.
  Future<void> _importIcs() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: ['ics'],
    );
    if (result == null) return;
    final path = result.files.single.path;
    if (path == null) return;
    final name = result.files.single.name;
    try {
      final orchestrator = await widget.services.buildLocalOrchestrator();
      final count = await orchestrator.importIcsFile(path, name);
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(
        content: Text(count == 0
            ? 'No calendar events found in "$name".'
            : 'Imported $count busy block${count == 1 ? '' : 's'} from "$name".'),
      ));
      await _reload();
    } on Exception catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text('Import failed: $e')));
      }
    }
  }

  Future<void> _deleteSource(String source) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Remove "$source"?'),
        content:
            const Text('All busy blocks imported from this file are deleted.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(ctx).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await widget.services.db.deleteBusyBlocksBySource(source);
    await _reload();
  }

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final prefs = _prefs;
    final colorScheme = Theme.of(context).colorScheme;
    if (prefs == null) {
      return const Scaffold(
        body: Center(child: CircularProgressIndicator()),
      );
    }
    final timezoneWarning = widget.services.calendar?.timezoneWarning;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(
        padding: const EdgeInsets.only(bottom: 32),
        children: [
          _section('Working hours'),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Work start'),
            trailing: Text(prefs.workStart,
                style: Theme.of(context).textTheme.titleMedium),
            onTap: () => _pickTime(isStart: true),
          ),
          ListTile(
            leading: const Icon(Icons.schedule),
            title: const Text('Work end'),
            trailing: Text(prefs.workEnd,
                style: Theme.of(context).textTheme.titleMedium),
            onTap: () => _pickTime(isStart: false),
          ),
          _section('Buffer between events'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: Slider(
                    value: _bufferPreview ?? prefs.bufferMinutes.toDouble(),
                    min: 0,
                    max: 60,
                    divisions: 12,
                    label:
                        '${(_bufferPreview ?? prefs.bufferMinutes).round()} min',
                    onChanged: (v) => setState(() => _bufferPreview = v),
                    onChangeEnd: (v) {
                      setState(() => _bufferPreview = null);
                      _setBuffer(v);
                    },
                  ),
                ),
                SizedBox(
                  width: 56,
                  child: Text('${(_bufferPreview ?? prefs.bufferMinutes).round()} min',
                      textAlign: TextAlign.end,
                      style: Theme.of(context).textTheme.titleSmall),
                ),
              ],
            ),
          ),
          _section('Active days'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Wrap(
              spacing: 8,
              children: [
                for (var i = 0; i < _dayKeys.length; i++)
                  FilterChip(
                    label: Text(_dayLabels[i]),
                    selected: prefs.activeDays.contains(_dayKeys[i]),
                    onSelected: (_) => _toggleDay(_dayKeys[i]),
                  ),
              ],
            ),
          ),
          _section('Timezone'),
          ListTile(
            leading: const Icon(Icons.public),
            title: Text(prefs.timezone),
            subtitle: timezoneWarning != null
                ? Text(timezoneWarning,
                    style: TextStyle(color: colorScheme.error))
                : const Text('Captured from this device at setup.'),
          ),
          _section('Busy calendar imports (.ics)'),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: OutlinedButton.icon(
              onPressed: _importIcs,
              icon: const Icon(Icons.file_upload),
              label: const Text('Import .ics file'),
            ),
          ),
          if (_busySources.isNotEmpty)
            for (final source in _busySources.keys)
              ListTile(
                leading: const Icon(Icons.event_busy),
                title: Text(source),
                subtitle:
                    Text('${_busySources[source]} busy block${_busySources[source] == 1 ? '' : 's'}'),
                trailing: IconButton(
                  tooltip: 'Remove',
                  icon: const Icon(Icons.delete_outline),
                  onPressed: () => _deleteSource(source),
                ),
              ),
          _section('Provider'),
          ListTile(
            leading: const Icon(Icons.tune),
            title: const Text('LLM provider settings'),
            subtitle: const Text(
                'Free demo endpoint or your own key (BYOK). Keys live in '
                'Keystore, never in SQLite.'),
            trailing: const Icon(Icons.chevron_right),
            onTap: () => openProviderSettings(context, widget.services),
          ),
        ],
      ),
    );
  }

  Widget _section(String title) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 24, 16, 8),
      child: Text(
        title,
        style: Theme.of(context)
            .textTheme
            .labelLarge
            ?.copyWith(color: Theme.of(context).colorScheme.primary),
      ),
    );
  }
}
