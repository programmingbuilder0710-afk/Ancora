import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doer/provider/provider_config_service.dart';
import 'package:doer/ui/settings/provider_settings_screen.dart';

/// UI-wiring spy: records invocations, returns immediately. No DB, no
/// secure storage, no real async - FakeAsync-safe. Persistence itself is
/// proven by headless service tests.
class SpyConfigService implements ProviderConfigService {
  final saved = <String>[];
  String mode = 'demo';

  @override
  Future<String> getMode() async => mode;

  @override
  Future<({String apiKey, String baseUrl, String model})> getDemoConfig() async =>
      (apiKey: 'demo-key', baseUrl: 'https://demo.example.com/v1', model: 'gpt-4o-mini');

  @override
  Future<({String apiKey, String baseUrl, String model})?> getByokConfig() async =>
      (apiKey: 'byok-key', baseUrl: 'https://api.openai.com/v1', model: 'byok-model');

  @override
  Future<void> saveDemoConfig({
    required String apiKey,
    required String baseUrl,
    required String model,
  }) async {
    saved.add('demo:$baseUrl|$model|$apiKey');
  }

  @override
  Future<void> saveByokConfig({
    required String preset,
    required String apiKey,
    required String model,
    String? baseUrl,
  }) async {
    saved.add('byok:$preset|$model|$apiKey');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  // Robust tap: ensure the target is on-screen and actually hit.
  Future<void> tapVisible(WidgetTester tester, Finder finder) async {
    await tester.ensureVisible(finder);
    await tester.pumpAndSettle();
    await tester.tap(finder, warnIfMissed: false);
    await tester.pumpAndSettle();
  }

  testWidgets('BYOK flow: mode switch, preset dropdown, save captures key+model',
      (tester) async {
    final spy = SpyConfigService();

    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: ProviderSettingsScreen(
        configService: spy,
        initialMode: 'demo',
        initialByokApiKey: 'byok-key',
        initialByokBaseUrl: 'https://api.openai.com/v1',
        initialByokModel: 'byok-model',
      ),
    ));
    await tester.pumpAndSettle();

    // Switch to My provider mode -> BYOK save enabled, demo disabled.
    await tester.tap(find.text('My provider'));
    await tester.pumpAndSettle();

    // No Base URL field exists for the user's provider: preset drives it.
    final keyFields = find.widgetWithText(TextField, 'API key');
    final modelFields = find.widgetWithText(TextField, 'Model name');
    final saveByok = find.text('Save my provider');

    // Validation: empty key blocked, no service call.
    await tester.enterText(keyFields.last, '');
    await tapVisible(tester, saveByok);
    expect(find.text('API key and model are required.'), findsOneWidget);
    expect(spy.saved, isEmpty);

    // Valid save with a preset (openai detected from the seeded host).
    await tester.enterText(keyFields.last, 'sk-test-123');
    await tester.enterText(modelFields.last, 'my-model');
    await tapVisible(tester, saveByok);

    expect(find.text('Your provider saved and activated.'), findsOneWidget);
    expect(spy.saved, contains('byok:openai|my-model|sk-test-123'));
  });

  testWidgets('demo endpoint is fixed: card + activate, no editable fields', (tester) async {
    final spy = SpyConfigService();

    await tester.binding.setSurfaceSize(const Size(800, 2400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: ProviderSettingsScreen(
        configService: spy,
        initialMode: 'demo',
      ),
    ));
    await tester.pumpAndSettle();

    // Read-only endpoint card shows the built-in defaults.
    expect(find.text(ProviderConfigService.defaultDemoBaseUrl), findsOneWidget);
    expect(find.text(ProviderConfigService.defaultDemoModel), findsOneWidget);

    // No demo-editable fields exist.
    expect(find.widgetWithText(TextField, 'Base URL'), findsNothing);
    final saveDemo = find.text('Use demo endpoint');
    await tapVisible(tester, saveDemo);

    expect(find.text('Demo endpoint activated.'), findsOneWidget);
    // Activate persists exactly the built-in defaults.
    expect(spy.saved, contains(
        'demo:${ProviderConfigService.defaultDemoBaseUrl}'
        '|${ProviderConfigService.defaultDemoModel}'
        '|${ProviderConfigService.defaultDemoApiKey}'));
  });
}
