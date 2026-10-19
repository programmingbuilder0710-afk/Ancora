import 'package:flutter/material.dart';

import '../../models/models.dart';
import '../widgets.dart';
import '../../orchestration/orchestrator.dart';

class ReplanResultScreen extends StatelessWidget {
  final Map<String, String?> before;
  final ReplanResult result;
  final List<Task> tasks;
  final List<Goal> goals;
  const ReplanResultScreen({
    super.key,
    required this.before,
    required this.result,
    required this.tasks,
    required this.goals,
  });

  String _time(BuildContext context, String? value) => value == null
      ? 'unscheduled'
      : dayClock(context, DateTime.parse(value).toLocal());

  @override
  Widget build(BuildContext context) {
    final moved = tasks.where(
      (t) => before.containsKey(t.id) && before[t.id] != t.scheduledStart,
    );
    final unscheduled = tasks.where(
      (t) => t.scheduledStart == null && t.status != TaskStatus.completed,
    );
    final goalNames = {for (final goal in goals) goal.id: goal.title};
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Re-plan result')),
      body: ContentWidth(
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 16, 20, 32),
          children: [
            Text('Your updated plan', style: theme.textTheme.headlineMedium),
            const SizedBox(height: 24),
            Row(
              children: [
                for (final stat in [
                  ('Re-planned', result.placementResults.length),
                  ('Moved', moved.length),
                  ('Unscheduled', unscheduled.length),
                ])
                  Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: Card(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(
                            vertical: 16,
                            horizontal: 4,
                          ),
                          child: Column(
                            children: [
                              Text(
                                '${stat.$2}',
                                style: theme.textTheme.headlineSmall,
                              ),
                              const SizedBox(height: 4),
                              Text(stat.$1, style: theme.textTheme.labelSmall),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            if (result.tips.isNotEmpty) ...[
              const SizedBox(height: 24),
              Card(
                color: theme.colorScheme.secondaryContainer,
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Icon(
                            Icons.lightbulb_outline,
                            color: theme.colorScheme.onSecondaryContainer,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            'Coaching tips',
                            style: theme.textTheme.titleSmall?.copyWith(
                              color: theme.colorScheme.onSecondaryContainer,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 8),
                      for (final tip in result.tips)
                        Padding(
                          padding: const EdgeInsets.only(top: 8),
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              const Text('•  '),
                              Expanded(
                                child: Text(
                                  tip,
                                  style: theme.textTheme.bodyMedium?.copyWith(
                                    color:
                                        theme.colorScheme.onSecondaryContainer,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ],
            const SectionHeader('Moved'),
            if (moved.isEmpty) const Text('No tasks moved'),
            if (moved.isNotEmpty)
              SectionCard(
                children: [
                  for (final task in moved)
                    ListTile(
                      title: Text(task.title),
                      subtitle: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(goalNames[task.goalId] ?? ''),
                          const SizedBox(height: 4),
                          Text.rich(
                            TextSpan(
                              children: [
                                TextSpan(
                                  text: _time(context, before[task.id]),
                                  style: TextStyle(
                                    decoration: TextDecoration.lineThrough,
                                    color: theme.colorScheme.onSurfaceVariant,
                                  ),
                                ),
                                TextSpan(
                                  text:
                                      ' → ${_time(context, task.scheduledStart)}',
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            if (unscheduled.isNotEmpty) ...[
              const SectionHeader("Couldn't fit"),
              Card(
                color: theme.colorScheme.tertiaryContainer,
                child: Column(
                  children: [
                    for (final task in unscheduled)
                      ListTile(
                        leading: const Icon(Icons.error_outline),
                        title: Text(task.title),
                        subtitle: Text(goalNames[task.goalId] ?? ''),
                      ),
                  ],
                ),
              ),
            ],
            const SizedBox(height: 32),
            FilledButton(
              onPressed: () => Navigator.of(context).pop(),
              child: const Text('Back to agenda'),
            ),
          ],
        ),
      ),
    );
  }
}
