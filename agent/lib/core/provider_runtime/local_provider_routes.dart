// Local/self-hosted provider route identification.
//
// A route serves a model the user runs on this machine when it uses a local
// engine template or its endpoint is loopback. Those routes cannot borrow a
// cloud catalog window: their real window lives in the running engine, so an
// unresolved window must stay small instead of inheriting the global cap
// (`context.maxLimit`).

/// One owner for "is this route local/self-hosted?".
///
/// Engine template names are the supported local engines; a `custom` template
/// pointed at a loopback endpoint counts too, because that is a self-hosted
/// server by the same evidence. A remote self-hosted endpoint (LAN or public
/// host) is deliberately treated as a cloud route: nothing local can be probed
/// and the global cap stays a safe upper bound.
abstract final class LocalProviderRoutes {
  LocalProviderRoutes._();

  /// Local engine templates that serve models from this machine.
  static const Set<String> engineTemplateNames = {
    'ollama',
    'lm-studio',
    'llama-cpp',
  };

  /// Loopback hosts, including the IPv6 forms an OpenAI-compatible base URL may
  /// carry.
  static const Set<String> loopbackHosts = {
    'localhost',
    '127.0.0.1',
    '::1',
    '0.0.0.0',
    '[::1]',
  };

  /// Whether [templateId] is one of the local engine templates.
  static bool isEngineTemplate(String templateId) =>
      engineTemplateNames.contains(templateId.trim().toLowerCase());

  /// Whether [baseUrl] points at a loopback endpoint.
  static bool isLoopbackBaseUrl(String? baseUrl) {
    if (baseUrl == null || baseUrl.trim().isEmpty) return false;
    final uri = Uri.tryParse(baseUrl.trim());
    final host = uri?.host.toLowerCase();
    if (host == null || host.isEmpty) return false;
    if (loopbackHosts.contains(host)) return true;
    // An IPv4 loopback address in any 127.0.0.0/8 form.
    return host.startsWith('127.');
  }

  /// Whether the route identified by [templateId] and [baseUrl] is local.
  static bool isLocalRoute({required String templateId, String? baseUrl}) =>
      isEngineTemplate(templateId) || isLoopbackBaseUrl(baseUrl);
}
