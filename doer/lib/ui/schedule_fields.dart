import 'package:flutter/material.dart';

import 'widgets.dart';

String? scheduleError(String start, String end, Set<String> days) =>
    start.compareTo(end) >= 0
    ? 'Work start must be before work end.'
    : days.isEmpty
    ? 'Choose at least one active day.'
    : null;

class WorkHours extends StatefulWidget {
  final String start, end;
  final bool enabled;
  final void Function(String, String) onChanged;
  const WorkHours({
    super.key,
    required this.start,
    required this.end,
    this.enabled = true,
    required this.onChanged,
  });

  @override
  State<WorkHours> createState() => _WorkHoursState();
}

class _WorkHoursState extends State<WorkHours> {
  static const _presets = [
    ('Early mornings', '06:00', '09:00'),
    ('Daytime', '09:00', '17:00'),
    ('Evenings', '18:00', '22:00'),
  ];
  bool _custom = false;

  @override
  void didUpdateWidget(WorkHours oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.start != widget.start || oldWidget.end != widget.end) {
      _custom = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    final match = _presets
        .where((p) => p.$2 == widget.start && p.$3 == widget.end)
        .firstOrNull;
    final custom = _custom || match == null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 8,
            runSpacing: 4,
            children: [
              for (final preset in _presets)
                ChoiceChip(
                  label: Text(preset.$1),
                  selected: !custom && match == preset,
                  onSelected: !widget.enabled
                      ? null
                      : (_) {
                          setState(() => _custom = false);
                          widget.onChanged(preset.$2, preset.$3);
                        },
                ),
              ChoiceChip(
                label: const Text('Custom'),
                selected: custom,
                onSelected: !widget.enabled
                    ? null
                    : (_) => setState(() => _custom = true),
              ),
            ],
          ),
        ),
        // Show what the preset actually means in the user's clock format.
        if (!custom)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
            child: Text(
              '${clock(context, _at(widget.start))} – ${clock(context, _at(widget.end))}',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        if (custom)
          for (final isStart in [true, false])
            ListTile(
              title: Text(isStart ? 'Start' : 'End'),
              trailing: Text(
                clock(
                  context,
                  DateTime.parse(
                    '2000-01-01T${isStart ? widget.start : widget.end}:00',
                  ),
                ),
                style: Theme.of(context).textTheme.bodyLarge?.copyWith(
                  color: Theme.of(context).colorScheme.onSurfaceVariant,
                ),
              ),
              onTap: !widget.enabled
                  ? null
                  : () async {
                      final parts = (isStart ? widget.start : widget.end)
                          .split(':')
                          .map(int.parse)
                          .toList();
                      final time = await showTimePicker(
                        context: context,
                        initialTime: TimeOfDay(
                          hour: parts[0],
                          minute: parts[1],
                        ),
                      );
                      if (time == null || !mounted) return;
                      final value =
                          '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}';
                      widget.onChanged(
                        isStart ? value : widget.start,
                        isStart ? widget.end : value,
                      );
                    },
            ),
      ],
    );
  }
}

class ActiveDays extends StatelessWidget {
  final Set<String> days;
  final bool enabled;
  final ValueChanged<Set<String>> onChanged;
  const ActiveDays({
    super.key,
    required this.days,
    this.enabled = true,
    required this.onChanged,
  });
  static const week = ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'];
  static const names = [
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('Active days'),
          const SizedBox(height: 4),
          Text(
            'Include weekends if you can.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              for (var i = 0; i < 7; i++)
                Expanded(
                  child: Tooltip(
                    message: names[i],
                    child: Semantics(
                      label: names[i],
                      selected: days.contains(week[i]),
                      button: true,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(24),
                        onTap: !enabled
                            ? null
                            : () {
                                final updated = {...days};
                                if (!updated.remove(week[i])) {
                                  updated.add(week[i]);
                                }
                                onChanged(updated);
                              },
                        child: SizedBox(
                          height: 48,
                          child: Center(
                            child: Container(
                              width: 40,
                              height: 40,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color: days.contains(week[i])
                                    ? scheme.primary
                                    : scheme.surfaceContainerHighest,
                              ),
                              child: ExcludeSemantics(
                                child: Text(
                                  names[i][0],
                                  style: TextStyle(
                                    color: days.contains(week[i])
                                        ? scheme.onPrimary
                                        : scheme.onSurfaceVariant,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

DateTime _at(String hhmm) {
  final parts = hhmm.split(':').map(int.parse).toList();
  return DateTime(2000, 1, 1, parts[0], parts[1]);
}
