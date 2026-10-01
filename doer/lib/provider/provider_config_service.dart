import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../data/database_helper.dart';
import 'provider.dart';

/// Manages provider configuration: mode (demo/byok), endpoint, model, and
/// the API key (stored ONLY in flutter_secure_storage - never SQLite).
/// Builds the active LlmProvider from current config on every call, so
/// mid-session settings changes take effect without restart.
class ProviderConfigService {
  final DatabaseHelper db;
  final FlutterSecureStorage secureStorage;

  ProviderConfigService({
    required this.db,
    FlutterSecureStorage? storage,
  }) : secureStorage = storage ?? const FlutterSecureStorage();

  static const _keyDemoKey = 'demo_api_key';
  static const _keyDemoUrl = 'demo_base_url';
  static const _keyDemoModel = 'demo_model';
  static const _keyByokKey = 'byok_api_key';

  // Build-time defaults: used when nothing is configured yet. Fresh
  // install works out of the box against these; everything is editable in
  // Settings (the "demo endpoint" is just config the user can replace).
  static const defaultDemoBaseUrl = 'https://openrouter.ai/api/v1';
  static const defaultDemoModel = 'qwen/qwen3.8-27b:free';
  static const defaultDemoApiKey = '';

  /// Storage seam for tests: override read/write instead of the plugin.
  Future<String?> readKey(String key) => secureStorage.read(key: key);
  Future<void> writeKey(String key, String value) =>
      secureStorage.write(key: key, value: value);

  /// Current mode: 'demo' or 'byok' (defaults to 'demo').
  Future<String> getMode() async {
    final config = await db.getProviderConfig();
    return config?['mode'] as String? ?? 'demo';
  }

  /// Full demo config: secure-storage values falling back to defaults.
  Future<({String apiKey, String baseUrl, String model})> getDemoConfig() async {
    final apiKey = await readKey(_keyDemoKey) ?? defaultDemoApiKey;
    final baseUrl = await readKey(_keyDemoUrl) ?? defaultDemoBaseUrl;
    final model = await readKey(_keyDemoModel) ?? defaultDemoModel;
    return (apiKey: apiKey, baseUrl: baseUrl, model: model);
  }

  /// Full BYOK config: preset/base_url/model from provider_config, key from
  /// secure storage. Null = not yet configured.
  Future<({String apiKey, String baseUrl, String model})?> getByokConfig() async {
    final config = await db.getProviderConfig();
    if (config == null) return null;
    if ((config['mode'] as String?) != 'byok') return null;
    final apiKey = await readKey(_keyByokKey);
    if (apiKey == null || apiKey.isEmpty) return null;
    final preset = config['preset'] as String?;
    final baseUrl = (config['base_url'] as String?) ?? _presetBaseUrl(preset);
    final model = config['model'] as String?;
    if (baseUrl == null || baseUrl.isEmpty || model == null || model.isEmpty) {
      return null;
    }
    return (apiKey: apiKey, baseUrl: baseUrl, model: model);
  }

  String? _presetBaseUrl(String? preset) {
    switch (preset) {
      case 'openai':
        return 'https://api.openai.com/v1';
      case 'anthropic':
        return 'https://api.anthropic.com/v1';
      case 'gemini':
        return 'https://generativelanguage.googleapis.com/v1beta/openai';
      case 'openrouter':
        return 'https://openrouter.ai/api/v1';
      default:
        return null; // 'custom' requires explicit base_url
    }
  }

  /// Save demo-mode endpoint config (key stored in secure storage).
  Future<void> saveDemoConfig({
    required String apiKey,
    required String baseUrl,
    required String model,
  }) async {
    await writeKey(_keyDemoKey, apiKey);
    await writeKey(_keyDemoUrl, baseUrl);
    await writeKey(_keyDemoModel, model);
    await db.upsertProviderConfig(
        mode: 'demo', preset: 'demo', baseUrl: baseUrl, model: model);
  }

  /// Save BYOK config. Key goes ONLY to secure storage.
  Future<void> saveByokConfig({
    required String preset,
    required String apiKey,
    required String model,
    String? baseUrl,
  }) async {
    await writeKey(_keyByokKey, apiKey);
    await db.upsertProviderConfig(
      mode: 'byok',
      preset: preset,
      baseUrl: preset == 'custom' ? baseUrl : _presetBaseUrl(preset),
      model: model,
    );
  }

  /// Build the active provider from current configuration, read fresh on
  /// every call (mid-session settings changes take effect immediately).
  /// Demo mode always yields a provider (defaults). BYOK yields null if not
  /// fully configured - callers must prompt the user to Settings.
  Future<LlmProvider?> buildActiveProvider() async {
    final mode = await getMode();
    if (mode == 'byok') {
      final byok = await getByokConfig();
      if (byok == null) return null;
      return OpenAiCompatibleProvider(
        apiKey: byok.apiKey,
        baseUrl: byok.baseUrl,
        model: byok.model,
      );
    }
    final demo = await getDemoConfig();
    return DemoProvider(
      apiKey: demo.apiKey,
      baseUrl: demo.baseUrl,
      model: demo.model,
    );
  }
}
