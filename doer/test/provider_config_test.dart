import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:doer/provider/provider_config_service.dart';
import 'package:doer/ui/settings/provider_settings_screen.dart';

/// UI-wiring spy: records invocations, returns immediately. No DB, no
/// secure storage, no real async - FakeAsync-safe. Persistence itself is
/// proven by the headless service tests (provider_service_test.dart).
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
      (apiKey: 'byok-key', baseUrl: 'https://byok.example.com/v1', model: 'byok-model');

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
    saved.add('byok:$preset|$baseUrl|$model|$apiKey');
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  testWidgets('BYOK flow: mode switch, custom preset reveals URL field, save captures inputs', (tester) async {
    final spy = SpyConfigService();

    await tester.pumpWidget(MaterialApp(
      home: ProviderSettingsScreen(
        configService: spy,
        initialMode: 'demo',
        initialDemoApiKey: 'demo-key',
        initialDemoBaseUrl: 'https://demo.example.com/v1',
        initialDemoModel: 'gpt-4o-mini',
        initialByokApiKey: 'byok-key',
        initialByokBaseUrl: 'https://byok.example.com/v1',
        initialByokModel: 'byok-model',
      ),
    ));
    await tester.pumpAndSettle();

    // Switch to My provider mode -> BYOK save enabled, demo disabled.
    await tester.tap(find.text('My provider'));
    await tester.pumpAndSettle();


    // Scroll the BYOK section into view FIRST - lazy ListView builds the
    // BYOK fields only when scrolled to.
    final saveByok = find.text('Save my provider');
    await tester.scrollUntilVisible(
      saveByok,
      200,
      scrollable: find.byType(Scrollable).first,
    );

    final urlFields = find.widgetWithText(TextField, 'Base URL');
    final keyFields = find.widgetWithText(TextField, 'API key');
    final modelFields = find.widgetWithText(TextField, 'Model name');

    await tester.enterText(urlFields.last, 'https://my-vllm.example.com/v1');
    await tester.enterText(keyFields.last, 'sk-test-123');
    await tester.enterText(modelFields.last, 'my-model');
    await tester.tap(saveByok);
    await tester.pumpAndSettle();

    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();

    expect(find.text('Your provider saved and activated.'), findsOneWidget);
    expect(spy.saved, contains('byok:custom|https://my-vllm.example.com/v1|my-model|sk-test-123'));
  });

  testWidgets('demo save captures edited endpoint; validation blocks empty URL', (tester) async {
    final spy = SpyConfigService();

    await tester.pumpWidget(MaterialApp(
      home: ProviderSettingsScreen(
        configService: spy,
        initialMode: 'demo',
        initialDemoApiKey: 'demo-key',
        initialDemoBaseUrl: 'https://demo.example.com/v1',
        initialDemoModel: 'gpt-4o-mini',
      ),
    ));
    await tester.pumpAndSettle();

    expect(find.text('https://demo.example.com/v1'), findsAtLeastNWidgets(1));

    final urlFields = find.widgetWithText(TextField, 'Base URL');
    final modelFields = find.widgetWithText(TextField, 'Model name');

    // Validation first: clear URL, save -> error status, no service call.
    await tester.enterText(urlFields.first, '');
    final saveDemo = find.text('Save demo endpoint');
    await tester.scrollUntilVisible(
      saveDemo,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(saveDemo);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();
    expect(find.text('Base URL and model are required.'), findsOneWidget);
    expect(spy.saved, isEmpty);

    // Now valid save.
    await tester.enterText(urlFields.first, 'https://new-demo.example.com/v1');
    await tester.enterText(modelFields.first, 'demo-model-x');
    await tester.scrollUntilVisible(
      saveDemo,
      200,
      scrollable: find.byType(Scrollable).first,
    );
    await tester.tap(saveDemo);
    await tester.pumpAndSettle();
    await tester.drag(find.byType(ListView), const Offset(0, 600));
    await tester.pumpAndSettle();

    expect(find.text('Demo endpoint saved.'), findsOneWidget);
    expect(spy.saved, contains('demo:https://new-demo.example.com/v1|demo-model-x|demo-key'));
  });
}
