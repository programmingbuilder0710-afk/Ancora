import 'package:flutter/material.dart';
import 'package:doer/provider/provider_config_service.dart';

/// Settings screen: provider configuration.
///
/// Demo mode: a fixed, read-only endpoint (build-time defaults) with a
/// single activate button — no editable fields.
/// BYOK mode: "Your own provider" section - preset dropdown (OpenAI /
/// Anthropic / Gemini / OpenRouter); the preset's base URL is applied
/// automatically. API key + model name are the only other options.
/// The API key is stored in flutter_secure_storage (Android Keystore);
/// never in SQLite, never logged.
class ProviderSettingsScreen extends StatefulWidget {
  final ProviderConfigService configService;

  /// Initial values, loaded by the caller (avoids async-in-initState).
  final String initialMode;

  /// Accepted for API compatibility with the merged PR's caller; the
  /// demo endpoint is fixed, so these values are ignored.
  final String? initialDemoApiKey;
  final String? initialDemoBaseUrl;
  final String? initialDemoModel;
  final String? initialByokApiKey;
  final String? initialByokBaseUrl;
  final String? initialByokModel;

  const ProviderSettingsScreen({
    super.key,
    required this.configService,
    required this.initialMode,
    this.initialDemoApiKey,
    this.initialDemoBaseUrl,
    this.initialDemoModel,
    this.initialByokApiKey,
    this.initialByokBaseUrl,
    this.initialByokModel,
  });

  @override
  State<ProviderSettingsScreen> createState() => _ProviderSettingsScreenState();
}

class _ProviderSettingsScreenState extends State<ProviderSettingsScreen> {
  final _byokKeyController = TextEditingController();
  final _byokModelController = TextEditingController();

  late String _mode;
  String _byokPreset = 'openai';
  String? _statusMessage;

  static const _presets = {
    'openai': 'OpenAI',
    'anthropic': 'Anthropic',
    'gemini': 'Google Gemini',
    'openrouter': 'OpenRouter',
  };

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;

    if (widget.initialByokApiKey != null &&
        widget.initialByokBaseUrl != null &&
        widget.initialByokModel != null) {
      _byokKeyController.text = widget.initialByokApiKey!;
      _byokModelController.text = widget.initialByokModel!;
      _byokPreset = _presets.keys.firstWhere(
        (p) => widget.initialByokBaseUrl!.contains(_presetHost(p)),
        orElse: () => 'openrouter',
      );
    }
  }

  String _presetHost(String preset) {
    switch (preset) {
      case 'openai':
        return 'api.openai.com';
      case 'anthropic':
        return 'api.anthropic.com';
      case 'gemini':
        return 'generativelanguage.googleapis.com';
      case 'openrouter':
        return 'openrouter.ai';
      default:
        return '';
    }
  }

  Future<void> _saveDemo() async {
    // Demo endpoint is fixed: persist the built-in defaults (any
    // previously stored demo values are overwritten by them).
    await widget.configService.saveDemoConfig(
      apiKey: ProviderConfigService.defaultDemoApiKey,
      baseUrl: ProviderConfigService.defaultDemoBaseUrl,
      model: ProviderConfigService.defaultDemoModel,
    );
    _showStatus('Demo endpoint activated.');
  }

  Future<void> _saveByok() async {
    final key = _byokKeyController.text.trim();
    final model = _byokModelController.text.trim();
    if (key.isEmpty || model.isEmpty) {
      _showStatus('API key and model are required.');
      return;
    }
    await widget.configService.saveByokConfig(
      preset: _byokPreset,
      apiKey: key,
      model: model,
    );
    _showStatus('Your provider saved and activated.');
  }

  void _showStatus(String message) {
    setState(() => _statusMessage = message);
  }

  @override
  void dispose() {
    _byokKeyController.dispose();
    _byokModelController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Provider Settings')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          if (_statusMessage != null)
            Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: Text(
                _statusMessage!,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.primary,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),

          Text('Active mode', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 4),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(value: 'demo', label: Text('Demo')),
              ButtonSegment(value: 'byok', label: Text('My provider')),
            ],
            selected: {_mode},
            onSelectionChanged: (selection) =>
                setState(() => _mode = selection.first),
          ),
          const SizedBox(height: 4),
          Text(
            _mode == 'demo'
                ? 'Demo mode: uses the demo endpoint below. Budget is '
                    'hard-capped by the provider. When exhausted, add your '
                    'own provider here.'
                : 'Your provider: app calls YOUR endpoint directly. Your '
                    'key stays on this device (Keystore-encrypted).',
            style: Theme.of(context).textTheme.bodySmall,
          ),
          const SizedBox(height: 16),

          Text('Demo endpoint', style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          Card(
            margin: EdgeInsets.zero,
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(ProviderConfigService.defaultDemoBaseUrl),
                  const SizedBox(height: 2),
                  Text(
                    ProviderConfigService.defaultDemoModel,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _mode == 'demo' ? _saveDemo : null,
            child: const Text('Use demo endpoint'),
          ),
          const Divider(height: 32),

          Text('Your own provider',
              style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: _byokPreset,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Provider preset'),
            items: _presets.entries
                .map((e) => DropdownMenuItem(
                      value: e.key,
                      child: Text(
                        e.value,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ))
                .toList(),
            onChanged: (value) => setState(() {
              _byokPreset = value ?? 'openai';
            }),
          ),
          _field(_byokKeyController, 'API key', obscure: true),
          _field(_byokModelController, 'Model name', hint: 'model-id'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _mode == 'byok' ? _saveByok : null,
            child: const Text('Save my provider'),
          ),
        ],
      ),
    );
  }

  Widget _field(TextEditingController controller, String label,
      {String? hint, bool obscure = false}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: TextField(
        controller: controller,
        decoration: InputDecoration(
          labelText: label,
          hintText: hint,
          border: const OutlineInputBorder(),
        ),
        obscureText: obscure,
      ),
    );
  }
}
