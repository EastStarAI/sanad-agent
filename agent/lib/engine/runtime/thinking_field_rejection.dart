/// Reactive recovery when a provider rejects the thinking field itself.
///
/// Only an HTTP 400 whose body names a thinking/reasoning request field
/// together with a rejection phrase qualifies. Any other 400 (including
/// history replay errors such as `reasoning_content` or thinking *blocks*) is
/// not a field rejection and is never retried here.
library;

import '../adapters/llm_http_exception.dart';

class ThinkingFieldRejection {
  ThinkingFieldRejection._();

  static final _field = RegExp(
    r'\b(reasoning_effort|reasoning|thinking|enable_thinking|'
    r'chat_template_kwargs|output_config|thinking_config|thinking_budget|'
    r'thinking_level|budget_tokens|effort)\b',
    caseSensitive: false,
  );

  static final _rejection = RegExp(
    r'(not supported|unsupported|does not support|is not allowed|'
    r'not permitted|unrecognized|unrecognised|unknown (field|parameter|argument)|'
    r'extra (inputs|fields) are not permitted|invalid (parameter|value|field)|'
    r'unexpected (field|parameter|keyword))',
    caseSensitive: false,
  );

  static final _historyBlock = RegExp(
    r'reasoning_content|thinking block|redacted_thinking',
    caseSensitive: false,
  );

  /// Whether [error] is a 400 that clearly rejects the thinking field.
  static bool matches(Object error) {
    if (error is! LlmHttpException || error.statusCode != 400) return false;
    final body = error.body;
    if (body.isEmpty || _historyBlock.hasMatch(body)) return false;
    return _field.hasMatch(body) && _rejection.hasMatch(body);
  }
}

/// Session-scoped, in-memory record of thinking selections whose provider
/// rejected the thinking field. The key is route + model + the exact rejected
/// selection id, so only that value is dispatched with the provider default
/// (no thinking field) for the rest of the session; a later, different
/// selection on the same route is still sent. Nothing is persisted and no
/// other session is affected.
class SessionThinkingFieldSuppression {
  final Map<String, Set<String>> _bySession = {};

  static String _key(
    String? providerInstanceId,
    String? modelId,
    String? selectionId,
  ) =>
      '${providerInstanceId?.trim() ?? ''}|${modelId?.trim() ?? ''}|'
      '${selectionId?.trim() ?? ''}';

  void suppress(
    String sessionId,
    String? providerInstanceId,
    String? modelId,
    String? selectionId,
  ) {
    _bySession
        .putIfAbsent(sessionId, () => <String>{})
        .add(_key(providerInstanceId, modelId, selectionId));
  }

  bool isSuppressed(
    String sessionId,
    String? providerInstanceId,
    String? modelId,
    String? selectionId,
  ) =>
      _bySession[sessionId]?.contains(
        _key(providerInstanceId, modelId, selectionId),
      ) ??
      false;

  void clearSession(String sessionId) => _bySession.remove(sessionId);
}
