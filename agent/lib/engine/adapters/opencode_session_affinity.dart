/// Conversation affinity required by OpenCode's relay.
///
/// The policy is stateless: callers provide the immutable session identity for
/// each model request. Existing headers win so an explicit caller override is
/// never replaced by the derived default.
const openCodeSessionHeader = 'x-opencode-session';

Map<String, String> withOpenCodeSessionAffinity({
  required Map<String, String> headers,
  required String providerName,
  required String baseUrl,
  required String? sessionId,
}) {
  if (sessionId == null ||
      sessionId.trim().isEmpty ||
      !_isOpenCodeTarget(providerName, baseUrl)) {
    return headers;
  }

  return {openCodeSessionHeader: sessionId, ...headers};
}

bool _isOpenCodeTarget(String providerName, String baseUrl) {
  final normalizedProvider = providerName.trim().toLowerCase();
  if (const {
    'opencode',
    'opencode-go',
    'opencode-zen',
    'opencode-free',
  }.contains(normalizedProvider)) {
    return true;
  }

  final endpoint = Uri.tryParse(baseUrl.trim());
  return endpoint?.host.toLowerCase() == 'opencode.ai';
}
