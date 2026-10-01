import 'package:flutter/material.dart';
import 'package:doer/provider/provider_config_service.dart';

/// Settings screen: provider configuration.
///
/// Demo mode: "Demo endpoint" section - three fields, saved locally.
/// BYOK mode: "Your own provider" section - preset dropdown (OpenAI /
/// Anthropic / Gemini / OpenRouter / Custom); Custom reveals the Base URL
/// field. API key + model name always editable.
/// The API key is stored in flutter_secure_storage (Android Keystore);
/// never in SQLite, never logged.
class ProviderSettingsScreen extends StatefulWidget {
  final ProviderConfigService configService;

  /// Initial values, loaded by the caller (avoids async-in-initState).
  final String initialMode;
  final String initialDemoApiKey;
  final String initialDemoBaseUrl;
  final String initialDemoModel;
  final String? initialByokApiKey;
  final String? initialByokBaseUrl;
  final String? initialByokModel;

  const ProviderSettingsScreen({
    super.key,
    required this.configService,
    required this.initialMode,
    required this.initialDemoApiKey,
    required this.initialDemoBaseUrl,
    required this.initialDemoModel,
    this.initialByokApiKey,
    this.initialByokBaseUrl,
    this.initialByokModel,
  });

  @override
  State<ProviderSettingsScreen> createState() => _ProviderSettingsScreenState();
}

class _ProviderSettingsScreenState extends State<ProviderSettingsScreen> {
  final _demoKeyController = TextEditingController();
  final _demoUrlController = TextEditingController();
  final _demoModelController = TextEditingController();
  final _byokKeyController = TextEditingController();
  final _byokUrlController = TextEditingController();
  final _byokModelController = TextEditingController();

  late String _mode;
  String _byokPreset = 'openai';
  bool _byokUrlVisible = false;
  String? _statusMessage;

  static const _presets = {
    'openai': 'OpenAI',
    'anthropic': 'Anthropic',
    'gemini': 'Google Gemini',
    'openrouter': 'OpenRouter',
    'custom': 'Custom (any OpenAI-compatible / self-hosted vLLM)',
  };

  @override
  void initState() {
    super.initState();
    _mode = widget.initialMode;
    _demoKeyController.text = widget.initialDemoApiKey;
    _demoUrlController.text = widget.initialDemoBaseUrl;
    _demoModelController.text = widget.initialDemoModel;

    if (widget.initialByokApiKey != null &&
        widget.initialByokBaseUrl != null &&
        widget.initialByokModel != null) {
      _byokKeyController.text = widget.initialByokApiKey!;
      _byokUrlController.text = widget.initialByokBaseUrl!;
      _byokModelController.text = widget.initialByokModel!;
      _byokPreset = _presets.keys.firstWhere(
        (p) =>
            p != 'custom' &&
            widget.initialByokBaseUrl!.contains(_presetHost(p)),
        orElse: () => 'custom',
      );
    }
    _byokUrlVisible = _byokPreset == 'custom';
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
    if (_demoUrlController.text.trim().isEmpty ||
        _demoModelController.text.trim().isEmpty) {
      _showStatus('Base URL and model are required.');
      return;
    }
    await widget.configService.saveDemoConfig(
      apiKey: _demoKeyController.text.trim(),
      baseUrl: _demoUrlController.text.trim(),
      model: _demoModelController.text.trim(),
    );
    _showStatus('Demo endpoint saved.');
  }

  Future<void> _saveByok() async {
    final key = _byokKeyController.text.trim();
    final model = _byokModelController.text.trim();
    if (key.isEmpty || model.isEmpty) {
      _showStatus('API key and model are required.');
      return;
    }
    if (_byokPreset == 'custom' && _byokUrlController.text.trim().isEmpty) {
      _showStatus('Custom providers need a Base URL.');
      return;
    }
    await widget.configService.saveByokConfig(
      preset: _byokPreset,
      apiKey: key,
      model: model,
      baseUrl: _byokUrlController.text.trim(),
    );
    _showStatus('Your provider saved and activated.');
  }

  void _showStatus(String message) {
    setState(() => _statusMessage = message);
  }

  @override
  void dispose() {
    _demoKeyController.dispose();
    _demoUrlController.dispose();
    _demoModelController.dispose();
    _byokKeyController.dispose();
    _byokUrlController.dispose();
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
          _field(_demoUrlController, 'Base URL',
              hint: 'https://api.openai.com/v1'),
          _field(_demoKeyController, 'API key',
              hint: 'doer-demo-key-v1-public', obscure: true),
          _field(_demoModelController, 'Model name', hint: 'gpt-4o-mini'),
          const SizedBox(height: 8),
          FilledButton(
            onPressed: _mode == 'demo' ? _saveDemo : null,
            child: const Text('Save demo endpoint'),
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
              _byokUrlVisible = _byokPreset == 'custom';
            }),
          ),
          if (_byokUrlVisible)
            _field(_byokUrlController, 'Base URL',
                hint: 'https://your-host/v1 (OpenAI-compatible)'),
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
