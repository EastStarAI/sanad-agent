/// Per-model wire resolution from the hydrated models.dev catalog (Task 120).
///
/// Some vendors serve individual models on a wire other than the template's
/// own: OpenCode Go serves `gpt-6-luna` on OpenAI Responses and Haiku/MiniMax/
/// Qwen on Anthropic Messages while its other models stay on Chat Completions.
/// The serving vendor's exact models.dev entry declares this per model as
/// `provider.npm` (the AI SDK package) plus `provider.api` (the base URL).
///
/// Resolution is data-only: no model-name table, no guessed endpoint, no
/// provider substitution. A model without both a recognized package and a
/// valid `provider.api` keeps the instance's configured wire and base URL, so
/// unchanged Chat routes keep their exact provider-state issuer.
library;

import '../../engine/adapters/provider_profile.dart';
import 'provider_endpoint_resolver.dart';
import 'provider_instance.dart';
import 'provider_protocol_constants.dart';

/// Reads the serving vendor's exact models.dev entry without I/O.
typedef ModelWireEntryLookup =
    Map<String, dynamic>? Function(String templateId, String modelId);

class ProviderModelWire {
  /// Wire protocol ([ProviderProtocol]).
  final String protocol;

  /// Adapter api mode carried on the derived template.
  final String apiMode;

  /// Normalized catalog `provider.api` base URL.
  final String baseUrl;

  const ProviderModelWire._({
    required this.protocol,
    required this.apiMode,
    required this.baseUrl,
  });

  /// AI SDK package → wire vocabulary. Packages absent here (including
  /// `@ai-sdk/openai-compatible`, the Chat default) never override a route.
  static const _packageWires = <String, ({String protocol, String apiMode})>{
    '@ai-sdk/openai': (
      protocol: ProviderProtocol.openaiCompatible,
      apiMode: 'codex_responses',
    ),
    '@ai-sdk/anthropic': (
      protocol: ProviderProtocol.anthropicCompatible,
      apiMode: 'anthropic_messages',
    ),
  };

  /// The catalog-declared wire for [entry] on [template], or `null` when the
  /// template does not opt in, the package is not a recognized wire, the
  /// declared wire is the template's own, or `provider.api` is missing or
  /// invalid.
  static ProviderModelWire? fromCatalog({
    required ProviderProfile? template,
    required Map<String, dynamic>? entry,
  }) {
    if (template == null || !template.catalogModelWire) return null;
    final provider = entry?['provider'];
    if (provider is! Map) return null;
    final wire = _packageWires[provider['npm']];
    final api = provider['api'];
    if (wire == null || api is! String) return null;
    if (wire.apiMode == template.apiMode &&
        wire.protocol == template.effectiveProtocol) {
      return null;
    }
    try {
      final uri = ProviderEndpointResolver.parseHttpBaseUrl(
        api,
        context: 'catalog provider.api',
      );
      if (uri.scheme != 'https') return null;
    } on FormatException {
      return null;
    }
    return ProviderModelWire._(
      protocol: wire.protocol,
      apiMode: wire.apiMode,
      baseUrl: ProviderEndpointResolver.normalizeBaseUrl(api),
    );
  }

  /// Resolves [modelId]'s wire on [instance] through [lookup].
  static ProviderModelWire? resolve(
    ProviderInstance instance,
    String modelId, {
    required ModelWireEntryLookup? lookup,
  }) {
    if (lookup == null || instance.isCustom || instance.routeTemplate != null) {
      return null;
    }
    return fromCatalog(
      template: instance.template,
      entry: lookup(instance.templateId, modelId),
    );
  }

  /// [instance] viewed through [modelId]'s catalog wire, or [instance] itself
  /// when the model keeps the configured wire.
  static ProviderInstance routeInstance(
    ProviderInstance instance,
    String modelId, {
    required ModelWireEntryLookup? lookup,
  }) {
    final wire = resolve(instance, modelId, lookup: lookup);
    final template = instance.template;
    if (wire == null || template == null) return instance;
    return instance.withRouteTemplate(wire.applyTo(template));
  }

  /// [template] re-pointed at this wire.
  ProviderProfile applyTo(ProviderProfile template) => template.withRouteWire(
    apiMode: apiMode,
    protocol: protocol,
    baseUrl: baseUrl,
  );
}
