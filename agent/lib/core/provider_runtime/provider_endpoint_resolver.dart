import 'provider_protocol_constants.dart';

/// Centralized service to normalize URLs and resolve endpoints for OpenAI and
/// Anthropic protocols (Plan 29 §10.1).
class ProviderEndpointResolver {
  ProviderEndpointResolver._();

  static const _configPrefixes = <String>[
    'url ',
    'base_url ',
    'base-url ',
    'endpoint ',
  ];

  /// Cleans and normalizes the base URL by trimming spaces, stripping common
  /// config-file prefixes, and removing trailing slashes.
  static String normalizeBaseUrl(String baseUrl) {
    var url = baseUrl.trim();
    final lowered = url.toLowerCase();
    for (final prefix in _configPrefixes) {
      if (lowered.startsWith(prefix)) {
        url = url.substring(prefix.length).trim();
        break;
      }
    }
    while (url.endsWith('/')) {
      url = url.substring(0, url.length - 1);
    }
    return url;
  }

  /// Parses a provider base URL and returns a validated http/https [Uri].
  static Uri parseHttpBaseUrl(
    String baseUrl, {
    String context = 'provider base URL',
  }) {
    final normalized = normalizeBaseUrl(baseUrl);
    if (normalized.isEmpty) {
      throw FormatException('Invalid $context: value is empty.');
    }

    final uri = Uri.tryParse(normalized);
    if (uri == null || !uri.hasScheme || uri.host.isEmpty) {
      throw FormatException('Invalid $context: expected an http or https URL.');
    }
    if (uri.scheme != 'http' && uri.scheme != 'https') {
      throw FormatException(
        'Invalid $context: unsupported scheme "${uri.scheme}".',
      );
    }
    return uri;
  }

  /// Resolves the models endpoint for the given base URL and protocol.
  /// - OpenAI-compatible: appends `/models` to the normalized base.
  /// - Anthropic-compatible: appends `/models` if ending in `/v1`, else `/v1/models`.
  static Uri resolveModelsEndpoint(String baseUrl, String protocol) {
    final normalized = normalizeBaseUrl(baseUrl);
    if (protocol == ProviderProtocol.anthropicCompatible) {
      if (normalized.endsWith('/v1')) {
        return parseHttpBaseUrl('$normalized/models');
      }
      return parseHttpBaseUrl('$normalized/v1/models');
    }
    if (normalized.endsWith('/models')) {
      return parseHttpBaseUrl(normalized);
    }
    return parseHttpBaseUrl('$normalized/models');
  }

  /// OpenAI-compatible model discovery candidates.
  static List<Uri> resolveOpenAiModelsEndpointCandidates(String baseUrl) {
    final normalized = normalizeBaseUrl(baseUrl);
    final primary = resolveModelsEndpoint(
      normalized,
      ProviderProtocol.openaiCompatible,
    );
    if (normalized.endsWith('/v1') || normalized.endsWith('/models')) {
      return [primary];
    }
    final fallback = parseHttpBaseUrl('$normalized/v1/models');
    return [primary, fallback];
  }

  /// Resolves the chat/messages endpoint for the given base URL and protocol.
  /// - OpenAI-compatible: appends `/chat/completions` (or `/responses` for codex).
  /// - Anthropic-compatible: appends `/messages` if ending in `/v1`, else `/v1/messages`.
  static Uri resolveChatEndpoint(String baseUrl, String protocol) {
    final normalized = normalizeBaseUrl(baseUrl);
    if (protocol == ProviderProtocol.anthropicCompatible) {
      if (normalized.endsWith('/v1')) {
        return parseHttpBaseUrl('$normalized/messages');
      }
      return parseHttpBaseUrl('$normalized/v1/messages');
    }
    if (normalized.endsWith('/chat/completions')) {
      return parseHttpBaseUrl(normalized);
    }
    return parseHttpBaseUrl('$normalized/chat/completions');
  }
}
