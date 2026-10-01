
import 'package:flutter_test/flutter_test.dart';

import 'package:doer/data/database_helper.dart';
import 'package:doer/models/models.dart';
import 'package:doer/orchestration/orchestrator.dart';
import 'package:doer/provider/provider_config_service.dart';
import 'package:doer/slotter/slotter.dart';

void main() {
  test('live demo endpoint: decompose end-to-end against OpenRouter', () async {
    final helper = DatabaseHelper.forTest();
    // Fresh-install emulation: no secure-storage values -> defaults used.
    final configService = _DefaultsOnlyConfigService(helper);

    // Build the provider from the demo defaults the user just set.
    final provider = await configService.buildActiveProvider();
    expect(provider, isNotNull, reason: 'demo config must build a provider');

    // Seed a goal.
    final goal = Goal(
      id: 'g1',
      title: 'Learn Rust basics',
      description: 'Understand ownership and write simple programs',
      priority: GoalPriority.P1,
      targetDate: DateTime.now().add(const Duration(days: 6)).toIso8601String().substring(0, 10),
      createdAt: DateTime.now().toIso8601String(),
    );
    await helper.insertGoal(goal);

    final prefs = UserPreferences(
      workStart: '09:00',
      workEnd: '18:00',
      bufferMinutes: 10,
      activeDays: ['mon', 'tue', 'wed', 'thu', 'fri', 'sat', 'sun'],
      timezone: 'UTC',
    );
    await helper.upsertPreferences(prefs);

    final slotter = Slotter(prefs)..allGoals = {'g1': goal};
    final orchestrator = Orchestrator(
      db: helper,
      providerFactory: () => provider!,
      slotter: slotter,
    );

    // LIVE call: decompose the goal through the demo endpoint.
    final results = await orchestrator.decompose(goals: [goal]);

    // Real model output: tasks generated, schema-validated, placed.
    expect(results, isNotEmpty, reason: 'model must return >= 1 task');

    final placed = results.where((r) => r.task.scheduledStart != null).toList();
    // ignore: avoid_print
    print('LIVE RESULT: ${results.length} tasks, ${placed.length} placed');
    for (final r in results) {
      // ignore: avoid_print
      print('  - [${r.task.recommendedDay}] ${r.task.title} '
          '(${r.task.durationMinutes}min) ${r.task.scheduledStart ?? 'UNPLACED'} '
          '${r.adjusted ? "[adjusted:${r.note}]" : ""}');
    }

    // Structural checks against real model output.
    expect(placed.length, greaterThan(0), reason: 'at least one task must be placed');
    for (final r in placed) {
      final s = DateTime.parse(r.task.scheduledStart!);
      final e = DateTime.parse(r.task.scheduledEnd!);
      expect(e.isAfter(s), isTrue);
      expect(s.hour, greaterThanOrEqualTo(9), reason: 'inside work window');
      expect(e.hour, lessThan(19), reason: 'inside work window');
    }

    // Verify tasks persisted with LLM-recommended days.
    final persisted = await helper.getAllTasks();
    expect(persisted.length, results.length);
    for (final t in persisted) {
      expect(t.recommendedDay, isNotNull, reason: 'LLM must assign recommended_day');
    }

    await helper.close();
  }, timeout: const Timeout(Duration(minutes: 4)));
}

/// Fresh-install double: secure storage reads return null so the demo
/// defaults (the values the user just set) are used.
class _DefaultsOnlyConfigService extends ProviderConfigService {
  _DefaultsOnlyConfigService(DatabaseHelper db) : super(db: db);

  @override
  Future<String?> readKey(String key) async => null;
}
