import 'dart:convert';

import 'package:http/http.dart' as http;

/// Transport injected by the adapter so the probe rules stay pure.
typedef ContextProbeGet = Future<http.Response> Function(Uri url);

/// Context-window probe rules for the local OpenAI-compatible engines.
///
/// Both engines expose their loaded window outside the OpenAI surface, so the
/// adapter supplies the transport and this owner holds the endpoint and payload
/// rules together with the bounded timeout.
abstract final class ContextWindowProbes {
  const ContextWindowProbes._();

  /// Probe timeout; a hung local server must never stall model discovery.
  static const Duration timeout = Duration(seconds: 2);

  /// LM Studio reports loaded instance windows from its native REST API.
  static Future<int?> lmStudio({
    required String baseUrl,
    required String model,
    required ContextProbeGet get,
    required void Function(String message) onWarning,
  }) async {
    try {
      final response = await get(Uri.parse('$baseUrl/api/v1/models'));
      if (response.statusCode != 200) return null;
      final models = jsonDecode(response.body)['models'] as List?;
      for (final entry in models ?? const []) {
        if (entry is! Map) continue;
        final key = entry['key'] ?? entry['id'];
        if (key != model) continue;
        final instances = entry['loaded_instances'] as List?;
        final config = instances == null || instances.isEmpty
            ? null
            : instances.first['config'];
        final tokens = config is Map ? config['context_length'] : null;
        if (tokens is num && tokens > 0) return tokens.toInt();
      }
    } catch (error) {
      onWarning('Failed to probe LM Studio context limit: $error');
    }
    return null;
  }

  /// llama.cpp exposes `n_ctx` from its props endpoint; the served path varies
  /// with how the server was mounted under `/v1`.
  static Future<int?> llamaCpp({
    required String baseUrl,
    required String model,
    required ContextProbeGet get,
    required void Function(String message) onWarning,
  }) async {
    final serverRoot = baseUrl.replaceAll('/v1', '').replaceAll('/v1/', '');
    final candidates = [
      Uri.parse('$baseUrl/props'),
      Uri.parse('$serverRoot/v1/props'),
      Uri.parse('$serverRoot/props'),
    ];
    try {
      for (final url in candidates) {
        try {
          final response = await get(url);
          if (response.statusCode != 200) continue;
          final settings = jsonDecode(response.body)['default_generation_settings'];
          final tokens = settings is Map ? settings['n_ctx'] : null;
          if (tokens is num && tokens > 0) return tokens.toInt();
        } catch (_) {
          // A missing mount is expected; try the next candidate.
        }
      }
    } catch (error) {
      onWarning('Failed to probe llama.cpp context limit: $error');
    }
    return null;
  }

  /// The probe for [templateId], or `null` when the route has no local probe.
  static Future<int?> forTemplate({
    required String templateId,
    required String baseUrl,
    required String model,
    required ContextProbeGet get,
    required void Function(String message) onWarning,
  }) async => switch (templateId) {
    'lm-studio' => lmStudio(
      baseUrl: baseUrl,
      model: model,
      get: get,
      onWarning: onWarning,
    ),
    'llama-cpp' => llamaCpp(
      baseUrl: baseUrl,
      model: model,
      get: get,
      onWarning: onWarning,
    ),
    _ => null,
  };
}
