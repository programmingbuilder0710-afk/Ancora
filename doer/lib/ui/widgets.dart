import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/models.dart';

class PriorityBadge extends StatelessWidget {
  final GoalPriority priority;
  final bool compact;
  const PriorityBadge(this.priority, {super.key, this.compact = false});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final (color, background, label) = switch (priority) {
      GoalPriority.P1 => (scheme.error, scheme.errorContainer, 'High'),
      GoalPriority.P2 => (scheme.tertiary, scheme.tertiaryContainer, 'Medium'),
      GoalPriority.P3 => (scheme.secondary, scheme.secondaryContainer, 'Low'),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(20),
      ),
      child: Text(
        compact ? priority.name : '${priority.name} · $label',
        style: Theme.of(context).textTheme.labelSmall?.copyWith(color: color),
      ),
    );
  }
}

class SectionHeader extends StatelessWidget {
  final String title;
  final Widget? trailing;
  const SectionHeader(this.title, {super.key, this.trailing});

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(top: 24, bottom: 8),
    child: Row(
      children: [
        Expanded(
          child: Text(
            title,
            style: Theme.of(context).textTheme.labelLarge
                ?.copyWith(color: Theme.of(context).colorScheme.primary),
          ),
        ),
        ?trailing,
      ],
    ),
  );
}

class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String message;
  final Widget? action;
  const EmptyState(
    this.icon,
    this.title,
    this.message, {
    super.key,
    this.action,
  });

  @override
  Widget build(BuildContext context) => Center(
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Column(
          children: [
            Container(
              width: 72,
              height: 72,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                color: Theme.of(context).colorScheme.secondaryContainer,
              ),
              child: Icon(
                icon,
                size: 32,
                color: Theme.of(context).colorScheme.onSecondaryContainer,
              ),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    ),
  );
}

class SectionCard extends StatelessWidget {
  final List<Widget> children;
  const SectionCard({super.key, required this.children});

  @override
  Widget build(BuildContext context) => Card(
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var i = 0; i < children.length; i++) ...[
          if (i > 0) const Divider(height: 1, indent: 16, endIndent: 16),
          children[i],
        ],
      ],
    ),
  );
}

class Pill extends StatelessWidget {
  final String label;
  final IconData? icon;
  final Color? color;
  const Pill(this.label, {super.key, this.icon, this.color});

  @override
  Widget build(BuildContext context) {
    final foreground = color ?? Theme.of(context).colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: foreground.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 14, color: foreground),
            const SizedBox(width: 4),
          ],
          Text(
            label,
            style: Theme.of(context).textTheme.labelSmall
                ?.copyWith(color: foreground),
          ),
        ],
      ),
    );
  }
}

// Shared by every scrollable screen and the editor's sticky action bar.
class ContentWidth extends StatelessWidget {
  final Widget child;
  const ContentWidth({super.key, required this.child});
  @override
  Widget build(BuildContext context) => Align(
    alignment: Alignment.topCenter,
    heightFactor: 1,
    child: ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 720),
      child: child,
    ),
  );
}

class Notice extends StatelessWidget {
  final String message;
  final bool error;
  const Notice(this.message, {super.key, this.error = false});
  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Card(
      color: error ? scheme.errorContainer : scheme.secondaryContainer,
      child: ListTile(
        leading: Icon(
          error ? Icons.error_outline : Icons.info_outline,
          color: error ? scheme.onErrorContainer : scheme.onSecondaryContainer,
        ),
        title: Text(
          message,
          style: Theme.of(context).textTheme.bodySmall?.copyWith(
            color: error
                ? scheme.onErrorContainer
                : scheme.onSecondaryContainer,
          ),
        ),
      ),
    );
  }
}

String taskDuration(int minutes) => minutes < 60
    ? '$minutes min'
    : '${minutes ~/ 60}h${minutes % 60 == 0 ? '' : ' ${minutes % 60}m'}';

String clock(BuildContext context, DateTime time) =>
    MaterialLocalizations.of(context).formatTimeOfDay(
      TimeOfDay.fromDateTime(time),
      alwaysUse24HourFormat: MediaQuery.alwaysUse24HourFormatOf(context),
    );

String dayClock(BuildContext context, DateTime time) =>
    '${DateFormat('EEE').format(time)} ${clock(context, time)}';
