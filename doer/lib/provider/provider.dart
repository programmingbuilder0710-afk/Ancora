import 'dart:convert';
import 'package:http/http.dart' as http;

abstract class LlmProviderException implements Exception {
  final String message;
  LlmProviderException(this.message);
  @override
  String toString() => message;
}

class AuthError extends LlmProviderException {
  AuthError(super.message);
}

class RateLimitError extends LlmProviderException {
  RateLimitError(super.message);
}

class QuotaError extends LlmProviderException {
  QuotaError(super.message);
}

class NetworkError extends LlmProviderException {
  NetworkError(super.message);
}

class SchemaViolationError extends LlmProviderException {
  final String rawResponse;
  SchemaViolationError(super.message, this.rawResponse);
}

class ProviderError extends LlmProviderException {
  final int statusCode;
  ProviderError(this.statusCode, super.message);
}

abstract class LlmProvider {
  Future<Map<String, dynamic>> complete({
    required String system,
    required String user,
    required Map<String, dynamic> jsonSchema,
  });
}

class OpenAiCompatibleProvider implements LlmProvider {
  final String apiKey;
  final String baseUrl;
  final String model;
  final http.Client _client;

  /// Rate-limit (429) retries with exponential backoff. Shared free-tier
  /// pools (OpenRouter :free) throttle intermittently; bounded retries
  /// absorb it without surfacing user-visible errors.
  static const maxRateLimitRetries = 3;
  static const initialBackoff = Duration(seconds: 20);

  OpenAiCompatibleProvider({
    required this.apiKey,
    required this.baseUrl,
    required this.model,
    http.Client? client,
  }) : _client = client ?? http.Client();

  @override
  Future<Map<String, dynamic>> complete({
    required String system,
    required String user,
    required Map<String, dynamic> jsonSchema,
  }) async {
    final uri = Uri.parse('$baseUrl/chat/completions');

    final body = {
      'model': model,
      'messages': [
        {'role': 'system', 'content': system},
        {'role': 'user', 'content': user},
      ],
      'response_format': {
        'type': 'json_schema',
        'json_schema': {
          'name': 'response',
          'strict': true,
          'schema': jsonSchema,
        },
      },
      'temperature': 0.2,
    };

    http.Response res;
    var attempt = 0;
    var backoff = initialBackoff;
    while (true) {
      try {
        res = await _client.post(
          uri,
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $apiKey',
          },
          body: jsonEncode(body),
        );
      } catch (e) {
        throw NetworkError('Network request failed: $e');
      }

      if (res.statusCode != 429) break;
      attempt++;
      if (attempt > maxRateLimitRetries) {
        throw RateLimitError(
            'Rate limit exceeded after $maxRateLimitRetries retries');
      }
      await Future<void>.delayed(backoff);
      backoff *= 2;
    }

    if (res.statusCode == 401 || res.statusCode == 403) {
      throw AuthError('Authentication failed: Invalid API key or access denied');
    } else if (res.statusCode == 429) {
      throw RateLimitError('Rate limit exceeded: Please wait or switch provider');
    } else if (res.statusCode == 402) {
      throw QuotaError('Quota exhausted: Check billing or switch provider');
    } else if (res.statusCode >= 500) {
      throw ProviderError(res.statusCode, 'Provider error: ${res.body}');
    } else if (res.statusCode != 200) {
      throw ProviderError(res.statusCode, 'Unexpected error: ${res.body}');
    }

    try {
      final json = jsonDecode(res.body);
      final content = json['choices'][0]['message']['content'];
      return jsonDecode(content) as Map<String, dynamic>;
    } catch (e) {
      throw SchemaViolationError('Failed to parse response as JSON: $e', res.body);
    }
  }
}

/// Demo-mode provider: reads its endpoint/key/model from the same
/// provider_config the user edits in Settings (flutter_secure_storage for
/// the key), with build-time defaults for first-run. Auth/quota failures
/// against a demo-mode config surface as demo-budget exhaustion
/// (QuotaError) so the SPEC 4.4 degradation banner fires instead of a
/// confusing raw auth error.
class DemoProvider extends OpenAiCompatibleProvider {
  DemoProvider({
    required super.apiKey,
    required super.baseUrl,
    required super.model,
    super.client,
  });

  @override
  Future<Map<String, dynamic>> complete({
    required String system,
    required String user,
    required Map<String, dynamic> jsonSchema,
  }) async {
    try {
      return await super.complete(
        system: system,
        user: user,
        jsonSchema: jsonSchema,
      );
    } on AuthError {
      throw QuotaError(
          'Demo budget exhausted - add your own provider in Settings');
    } on QuotaError {
      rethrow;
    }
  }
}
