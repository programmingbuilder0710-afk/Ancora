import 'package:flutter/material.dart';

import '../app_services.dart';
import 'settings/provider_settings_screen.dart';

Future<void> openProviderSettings(
  BuildContext context,
  AppServices services, {
  bool ownKey = false,
}) async {
  final config = services.config;
  final mode = await config.getMode();
  final demo = await config.getDemoConfig();
  final byok = await config.getByokConfig();
  if (!context.mounted) return;
  await Navigator.of(context).push<void>(
    MaterialPageRoute(
      builder: (_) => ProviderSettingsScreen(
        configService: config,
        initialMode: ownKey ? 'byok' : mode,
        initialDemoApiKey: demo.apiKey,
        initialDemoBaseUrl: demo.baseUrl,
        initialDemoModel: demo.model,
        initialByokApiKey: byok?.apiKey,
        initialByokBaseUrl: byok?.baseUrl,
        initialByokModel: byok?.model,
      ),
    ),
  );
}
