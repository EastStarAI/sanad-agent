import 'dart:convert';

import 'package:http/http.dart' as http;

import '../../core/constants.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';

/// Fetches and parses the OAuth-backed ChatGPT Codex model catalog.
class CodexModelsService {
  final Duration timeout;
  final String clientVersion;

  CodexModelsService({
    this.timeout = const Duration(seconds: 5),
    String? clientVersion,
  }) : clientVersion = clientVersion ?? loadAgentVersion();

  Future<List<ModelOption>> fetch({
    required http.Client client,
    required String baseUrl,
    required String accessToken,
    String provider = 'openai-codex',
  }) async {
    final endpoint = _modelsEndpoint(baseUrl);
    final response = await client
        .get(
          endpoint,
          headers: {
            if (accessToken.isNotEmpty) 'Authorization': 'Bearer $accessToken',
          },
        )
        .timeout(timeout);

    if (response.statusCode != 200) {
      throw CodexModelsException('HTTP ${response.statusCode}');
    }

    final decoded = jsonDecode(response.body);
    if (decoded is! Map) {
      throw const CodexModelsException('response root is not an object');
    }
    final entries = decoded['models'];
    if (entries is! List) {
      throw const CodexModelsException('response does not contain models');
    }

    final records = <_CodexModelRecord>[];
    for (final entry in entries) {
      if (entry is! Map) continue;
      final slug = entry['slug'];
      if (slug is! String || slug.trim().isEmpty) continue;

      final visibility = entry['visibility']?.toString().trim().toLowerCase();
      if (visibility == 'hide' || visibility == 'hidden') continue;

      final displayName = entry['display_name'];
      final priority = entry['priority'];
      final contextWindow = entry['context_window'];
      records.add(
        _CodexModelRecord(
          slug: slug.trim(),
          label: displayName is String && displayName.trim().isNotEmpty
              ? displayName.trim()
              : _formatLabel(slug),
          priority: priority is num ? priority.toInt() : 10000,
          contextWindow: contextWindow is num && contextWindow > 0
              ? contextWindow.toInt()
              : null,
        ),
      );
    }

    records.sort((a, b) {
      final priorityOrder = a.priority.compareTo(b.priority);
      return priorityOrder != 0 ? priorityOrder : a.slug.compareTo(b.slug);
    });

    final seen = <String>{};
    final models = <ModelOption>[];
    for (final record in records) {
      if (!seen.add(record.slug)) continue;
      models.add(
        ModelOption(
          value: record.slug,
          label: record.label,
          provider: provider,
          contextWindow: record.contextWindow,
          supportsReasoning: true,
        ),
      );
    }

    if (models.isEmpty) {
      throw const CodexModelsException('response contains no visible models');
    }
    return _addForwardCompatModels(models, provider: provider);
  }

  Uri _modelsEndpoint(String baseUrl) {
    final normalized = baseUrl.trim().replaceFirst(RegExp(r'/+$'), '');
    if (normalized.isEmpty) {
      throw const CodexModelsException('base URL is empty');
    }
    final uri = Uri.parse('$normalized/models');
    return uri.replace(
      queryParameters: {
        ...uri.queryParameters,
        'client_version': clientVersion,
      },
    );
  }

  static List<ModelOption> _addForwardCompatModels(
    List<ModelOption> models, {
    required String provider,
  }) {
    final ordered = List<ModelOption>.of(models);
    final seen = models.map((model) => model.value).toSet();
    final modelByValue = {for (final m in models) m.value: m};

    for (final rule in _forwardCompatRules) {
      if (seen.contains(rule.model) || !rule.templates.any(seen.contains)) {
        continue;
      }
      final matchedTemplate = rule.inheritTemplateContextWindow
          ? rule.templates.cast<String?>().firstWhere(
              (template) => seen.contains(template),
              orElse: () => null,
            )
          : null;

      ordered.add(
        ModelOption(
          value: rule.model,
          label: _formatLabel(rule.model),
          provider: provider,
          contextWindow: matchedTemplate == null
              ? null
              : modelByValue[matchedTemplate]?.contextWindow,
          supportsReasoning: true,
        ),
      );
      seen.add(rule.model);
    }
    return ordered;
  }

  static String _formatLabel(String slug) => slug
      .trim()
      .split('-')
      .where((part) => part.isNotEmpty)
      .map((part) {
        if (part.toLowerCase() == 'gpt') return 'GPT';
        return '${part[0].toUpperCase()}${part.substring(1)}';
      })
      .join(' ');

  static const _forwardCompatRules = <_ForwardCompatRule>[
    _ForwardCompatRule('gpt-5.6-sol', ['gpt-5.5', 'gpt-5.4']),
    _ForwardCompatRule('gpt-5.6-sol-pro', ['gpt-5.5', 'gpt-5.4']),
    _ForwardCompatRule('gpt-5.6-terra', ['gpt-5.5', 'gpt-5.4']),
    _ForwardCompatRule('gpt-5.6-terra-pro', ['gpt-5.5', 'gpt-5.4']),
    _ForwardCompatRule('gpt-5.6-luna', ['gpt-5.5', 'gpt-5.4']),
    _ForwardCompatRule('gpt-5.6-luna-pro', ['gpt-5.5', 'gpt-5.4']),
    _ForwardCompatRule('gpt-6-astra', [
      'gpt-6-luna',
    ], inheritTemplateContextWindow: true),
    _ForwardCompatRule('gpt-6-sol', [
      'gpt-6-luna',
    ], inheritTemplateContextWindow: true),
    _ForwardCompatRule('gpt-6-sol-pro', [
      'gpt-6-luna',
    ], inheritTemplateContextWindow: true),
    _ForwardCompatRule('gpt-6-luna-pro', [
      'gpt-6-luna',
    ], inheritTemplateContextWindow: true),
    _ForwardCompatRule('gpt-5.5', ['gpt-5.4', 'gpt-5.4-mini', 'gpt-5.3-codex']),
    _ForwardCompatRule('gpt-5.4-mini', ['gpt-5.3-codex']),
    _ForwardCompatRule('gpt-5.4', ['gpt-5.3-codex']),
    _ForwardCompatRule('gpt-5.3-codex-spark', ['gpt-5.3-codex']),
  ];
}

class CodexModelsException implements Exception {
  final String message;

  const CodexModelsException(this.message);

  @override
  String toString() => message;
}

class _CodexModelRecord {
  final String slug;
  final String label;
  final int priority;
  final int? contextWindow;

  const _CodexModelRecord({
    required this.slug,
    required this.label,
    required this.priority,
    required this.contextWindow,
  });
}

class _ForwardCompatRule {
  final String model;
  final List<String> templates;
  final bool inheritTemplateContextWindow;

  const _ForwardCompatRule(
    this.model,
    this.templates, {
    this.inheritTemplateContextWindow = false,
  });
}
