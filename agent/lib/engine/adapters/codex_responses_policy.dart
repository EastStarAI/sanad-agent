import '../../capabilities/models/tool_schema.dart';
import 'provider_profile.dart';

/// Provider-specific wire policy for Responses-compatible transports.
///
/// Protocol conversion stays in the codec; endpoint quirks stay here so they
/// never leak into the provider-neutral runner or BaseOpenAIAdapter.
class CodexResponsesPolicy {
  final bool sanitizeSlashEnums;

  const CodexResponsesPolicy._({required this.sanitizeSlashEnums});

  factory CodexResponsesPolicy.forProfile(ProviderProfile profile) {
    return CodexResponsesPolicy._(
      sanitizeSlashEnums: profile.name == 'xai-oauth',
    );
  }

  /// True when the Responses host accepts the standard `prompt_cache_key`
  /// body field. xAI documents the field for its raw Responses HTTP body, so
  /// xAI keeps it; GitHub-hosted Responses endpoints remain excluded by the
  /// endpoint policy and never receive a field their request schema does not
  /// accept.
  bool promptCacheKeySupportedForHost(String baseUrl) {
    final host = Uri.tryParse(baseUrl.trim())?.host.toLowerCase() ?? '';
    if (host.isEmpty) return true;
    return !_promptCacheKeyUnsupportedHosts.any(
      (denied) => host == denied || host.endsWith('.$denied'),
    );
  }

  /// Applies the endpoint-shaped cache-routing quirk to a built request body:
  /// unsupported hosts drop the routing field instead of failing dispatch.
  void applyCacheRouting(Map<String, dynamic> body, {required String baseUrl}) {
    if (!promptCacheKeySupportedForHost(baseUrl)) {
      body.remove('prompt_cache_key');
    }
  }

  /// Registrable hosts whose Responses schema excludes the routing field.
  /// Exact and dot-suffix matching keeps unrelated lookalike domains out.
  static const _promptCacheKeyUnsupportedHosts = {
    'api.github.com',
    'github.ai',
    'githubcopilot.com',
  };

  List<ToolSchema>? normalizeTools(List<ToolSchema>? tools) {
    if (!sanitizeSlashEnums || tools == null || tools.isEmpty) return tools;
    return tools
        .map(
          (tool) => ToolSchema(
            name: tool.name,
            description: tool.description,
            parameters: _sanitizeMap(tool.parameters),
          ),
        )
        .toList(growable: false);
  }

  static Map<String, dynamic> _sanitizeMap(Map<String, dynamic> source) {
    final result = <String, dynamic>{};
    for (final entry in source.entries) {
      if (entry.key == 'enum' && entry.value is List) {
        final values = (entry.value as List)
            .where((value) => value is! String || !value.contains('/'))
            .toList(growable: false);
        if (values.isNotEmpty) result[entry.key] = values;
        continue;
      }
      result[entry.key] = _sanitizeValue(entry.value);
    }
    return result;
  }

  static dynamic _sanitizeValue(dynamic value) {
    if (value is Map) {
      return _sanitizeMap(value.map((key, nested) => MapEntry('$key', nested)));
    }
    if (value is List) {
      return value.map(_sanitizeValue).toList(growable: false);
    }
    return value;
  }
}
