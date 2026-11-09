import 'package:logging/logging.dart';
import '../core/agent_runtime_service.dart';
import '../core/di.dart';
import '../core/models/agent_response.dart';
import '../core/models/message.dart';
import '../engine/adapters/llm_adapter.dart';
import '../engine/adapters/llm_http_exception.dart';
import '../engine/adapters/llm_request_options.dart';
import '../engine/runtime/llm_route_snapshot.dart';
import 'models/session_state.dart';
import 'session_manager.dart';

/// The exact provider-bound route one title request must use.
///
/// [adapter] is the provider adapter that owns the session's model, and
/// [providerInstanceId] keeps usage and thinking attribution on that same
/// instance. A title request is never sent when this route cannot be resolved.
typedef TitleRoute = ({
  LLMAdapter adapter,
  String? modelOverride,
  String? providerInstanceId,
});

class TitleService {
  static final Logger _logger = Logger('TitleService');
  static const Duration _defaultRequestTimeout = Duration(seconds: 30);
  static const int _maxOutputTokens = 500;

  final LLMAdapter? _adapter;
  final Duration _requestTimeout;
  final Expando<bool> _omitsUnsupportedOutputBound = Expando<bool>();
  final TitleRoute? Function(String sessionId, String? modelOverride)?
  _sessionRouteResolver;

  TitleService({
    LLMAdapter? adapter,
    Duration requestTimeout = _defaultRequestTimeout,
    TitleRoute? Function(String sessionId, String? modelOverride)?
    sessionRouteResolver,
  }) : _adapter = adapter,
       _requestTimeout = requestTimeout,
       _sessionRouteResolver = sessionRouteResolver;

  /// Generates a short, descriptive title for the conversation based on user and assistant message.
  /// If the LLM call fails, falls back to the user message snippet.
  ///
  /// Returns `null` when no provider-bound route can be resolved for the
  /// session. That is a deliberate skip: no request is sent, because pairing a
  /// session model with another provider's adapter is a guaranteed provider
  /// error (the model does not exist there), and the pending title must stay
  /// eligible instead of being finalized from a failed call.
  Future<String?> generateTitle({
    required String sessionId,
    required String userMessage,
    required String assistantResponse,
    String? modelOverride,
    LLMRouteSnapshot? route,
  }) async {
    final resolvedRoute = route == null
        ? _sessionRouteResolver?.call(sessionId, modelOverride) ??
              _resolveSessionRoute(sessionId, modelOverride)
        : (
            adapter: route.adapter,
            modelOverride: route.modelOverride,
            providerInstanceId: route.providerInstanceId,
          );

    if (resolvedRoute == null) {
      _logger.info(
        'Skipping title generation for session $sessionId: '
        'no provider route is resolvable.',
      );
      return null;
    }

    try {
      _logger.info('🏷️ Generating intelligent title for session: $sessionId');

      final messages = [
        Message(
          role: MessageRole.system,
          content:
              'Generate a short, stable, and descriptive conversation title (3-7 words). '
              'Capture the user\'s primary topic or intent from the first user message and the assistant\'s final response. '
              'Language rule: Generate the title in the SAME LANGUAGE as the user\'s original message. '
              'If the user writes in Arabic, respond in Arabic. If in English, respond in English. '
              'Reply with the TITLE ONLY. No quotes, prefixes, explanations, or trailing punctuation.',
        ),
        Message(
          role: MessageRole.user,
          content:
              'User: ${userMessage.length > 500 ? userMessage.substring(0, 500) : userMessage}\n'
              'Assistant: ${assistantResponse.length > 500 ? assistantResponse.substring(0, 500) : assistantResponse}',
        ),
      ];

      final response = await _generateBoundedResponse(
        adapter: resolvedRoute.adapter,
        messages: messages,
        modelOverride: resolvedRoute.modelOverride,
        sessionId: sessionId,
        providerInstanceId: resolvedRoute.providerInstanceId,
      );

      final rawContent = response.message.content ?? '';
      final title = _cleanTitle(rawContent);

      if (title.isNotEmpty) {
        _logger.info("🏷️ Generated session title: '$title'");
        return title;
      }
    } catch (e) {
      _logger.warning('⚠️ Title generation failed: $e');
    }

    // Fallback logic: Use the first part of the user message
    final fallbackTitle = _generateFallbackTitle(userMessage);
    _logger.info(
      "🏷️ Falling back to user message for title: '$fallbackTitle'",
    );
    return fallbackTitle;
  }

  Future<AgentResponse> _generateBoundedResponse({
    required LLMAdapter adapter,
    required List<Message> messages,
    required String? modelOverride,
    required String sessionId,
    required String? providerInstanceId,
  }) async {
    final shouldBoundOutput = _omitsUnsupportedOutputBound[adapter] != true;
    try {
      return await _requestTitleResponse(
        adapter: adapter,
        messages: messages,
        modelOverride: modelOverride,
        sessionId: sessionId,
        providerInstanceId: providerInstanceId,
        maxOutputTokens: shouldBoundOutput ? _maxOutputTokens : null,
      );
    } on LlmHttpException catch (error) {
      if (!shouldBoundOutput || !_rejectsOutputTokenParameter(error)) {
        rethrow;
      }
      _omitsUnsupportedOutputBound[adapter] = true;
      _logger.info(
        'Title provider rejected its output-token parameter; retrying once without the optional bound.',
      );
      return _requestTitleResponse(
        adapter: adapter,
        messages: messages,
        modelOverride: modelOverride,
        sessionId: sessionId,
        providerInstanceId: providerInstanceId,
        maxOutputTokens: null,
      );
    }
  }

  Future<AgentResponse> _requestTitleResponse({
    required LLMAdapter adapter,
    required List<Message> messages,
    required String? modelOverride,
    required String sessionId,
    required String? providerInstanceId,
    required int? maxOutputTokens,
  }) {
    return adapter
        .generateResponse(
          messages,
          modelOverride: modelOverride,
          options: LLMRequestOptions(
            sessionId: sessionId,
            providerInstanceId: providerInstanceId,
            timeout: _requestTimeout,
            maxOutputTokens: maxOutputTokens,
          ),
        )
        .timeout(_requestTimeout);
  }

  bool _rejectsOutputTokenParameter(LlmHttpException error) {
    if (error.statusCode != 400) return false;
    final body = error.body.toLowerCase();
    final rejectsParameter =
        body.contains('unsupported parameter') ||
        body.contains('unknown parameter') ||
        body.contains('unrecognized parameter');
    return rejectsParameter &&
        (body.contains('max_output_tokens') ||
            body.contains('max_completion_tokens') ||
            body.contains('max_tokens'));
  }

  /// Restores title work that was interrupted after the terminal response was
  /// committed. Existing/manual titles remain protected by the pending-state
  /// compare-and-set, and only sessions whose own provider route is still
  /// resolvable are attempted.
  Future<int> recoverPendingTitles() async {
    if (!getIt.isRegistered<SessionManager>()) return 0;
    final sessionManager = getIt<SessionManager>();
    var updatedCount = 0;
    for (final session in sessionManager.getPendingTitleSessions()) {
      final exchange = _firstPersistedExchange(session);
      if (exchange == null) continue;
      final expectedTitle = session.title;
      final title = await generateTitle(
        sessionId: session.sessionId,
        userMessage: exchange.userMessage,
        assistantResponse: exchange.assistantResponse,
        modelOverride: session.model,
      );
      if (title == null) continue;
      final updated = sessionManager.updateSessionTitleIfCurrent(
        session.sessionId,
        expectedTitle: expectedTitle,
        title: title,
      );
      if (updated) updatedCount++;
    }
    if (updatedCount > 0) {
      _logger.info('Recovered $updatedCount pending session title(s).');
    }
    return updatedCount;
  }

  ({String userMessage, String assistantResponse})? _firstPersistedExchange(
    SessionState session,
  ) {
    String? userMessage;
    String? assistantResponse;
    for (final message in session.messages) {
      final content = message.content?.trim();
      if (content == null || content.isEmpty) continue;
      if (userMessage == null && message.role == MessageRole.user) {
        userMessage = content;
        continue;
      }
      if (userMessage != null && message.role == MessageRole.assistant) {
        assistantResponse = content;
        break;
      }
    }
    if (userMessage == null || assistantResponse == null) return null;
    return (userMessage: userMessage, assistantResponse: assistantResponse);
  }

  /// Cleans the generated title to match the Python agent's cleaning logic.
  String _cleanTitle(String rawContent) {
    // 1. Remove reasoning tags <think>...</think>
    var title = rawContent.replaceAll(
      RegExp(
        r'<(?:mm:)?(think|thinking|thought|reasoning)\b[^>]*>.*?</(?:mm:)?\1>',
        caseSensitive: false,
        dotAll: true,
      ),
      '',
    );

    // 2. Strip standard html tags
    title = title.replaceAll(RegExp(r'<[^>]*>'), '').trim();

    // 3. Strip quotes/punctuation first so that ^ anchor matches prefix labels inside quotes
    title = title
        .replaceAll(
          RegExp(r'^[\u0022\u0027“‘”“‘’]+|[\u0022\u0027”’”“‘’]+$'),
          '',
        )
        .trim();

    // 4. Strip prefix labels like 'Title:', 'العنوان:', 'Thread Title:'
    title = title
        .replaceAll(
          RegExp(
            r'^\s*(title|thread title|العنوان)\s*[:：-]\s*',
            caseSensitive: false,
          ),
          '',
        )
        .trim();

    // 5. Normalize spaces and strip quotes/punctuation again
    title = title.replaceAll(RegExp(r'\s+'), ' ').trim();
    title = title
        .replaceAll(
          RegExp(r'^[\u0022\u0027“‘”“‘’]+|[\u0022\u0027”’”“‘’]+$'),
          '',
        )
        .trim();

    // 6. Trim trailing punctuation
    title = title.replaceAll(RegExp(r'[ .،,؛;:：-]+$'), '').trim();

    // Limit length to 80 chars
    if (title.length > 80) {
      title = title.substring(0, 80).trim();
    }
    return title;
  }

  String _generateFallbackTitle(String userMessage) {
    final clean = userMessage.trim();
    if (clean.isEmpty) return 'Chat';

    final firstLine = clean.split('\n').first;
    if (firstLine.length > 60) {
      return '${firstLine.substring(0, 57).trim()}...';
    }
    return firstLine;
  }

  /// Resolves the provider-bound route a title request must use.
  ///
  /// The live session signature is authoritative when this process ran a turn
  /// for the session. After a daemon restart no turn has run, so the route is
  /// rebuilt from the session's own persisted provider instance and model;
  /// [AgentRuntimeService.defaultAdapter] is never used, because a default
  /// provider cannot serve another instance's model. Returns `null` when the
  /// session's own route cannot be resolved, so the caller skips the request.
  TitleRoute? _resolveSessionRoute(String sessionId, String? modelOverride) {
    // When an explicit adapter was injected (tests), use it directly.
    if (_adapter != null) {
      return (
        adapter: _adapter,
        modelOverride: modelOverride,
        providerInstanceId: null,
      );
    }
    if (!getIt.isRegistered<AgentRuntimeService>()) {
      _logger.warning(
        'No AgentRuntimeService available for title generation; skipping.',
      );
      return null;
    }

    final runtime = getIt<AgentRuntimeService>();
    final signature =
        runtime.sessionSignature(sessionId) ??
        _persistedSessionSignature(runtime, sessionId, modelOverride);
    if (signature == null) return null;

    try {
      return (
        adapter: runtime.adapterFor(signature),
        modelOverride: signature.modelId,
        providerInstanceId: signature.providerInstanceId,
      );
    } catch (error) {
      _logger.warning(
        'Title route for session $sessionId could not be built: $error',
      );
      return null;
    }
  }

  /// Rebuilds the signature of a session that has not run a turn in this
  /// process from the provider instance and model it persisted.
  RouteSignature? _persistedSessionSignature(
    AgentRuntimeService runtime,
    String sessionId,
    String? modelOverride,
  ) {
    if (!getIt.isRegistered<SessionManager>()) return null;
    final session = getIt<SessionManager>().getSessionRecord(sessionId);
    final providerInstanceId = session?.providerId?.trim();
    if (providerInstanceId == null || providerInstanceId.isEmpty) {
      _logger.info(
        'Session $sessionId has no persisted provider instance; skipping title.',
      );
      return null;
    }
    final explicitModel = modelOverride?.trim();
    final modelId = explicitModel != null && explicitModel.isNotEmpty
        ? explicitModel
        : session?.model.trim();
    if (modelId == null || modelId.isEmpty) {
      _logger.info(
        'Session $sessionId has no persisted model; skipping title.',
      );
      return null;
    }
    try {
      return runtime.resolveSignature(
        providerId: providerInstanceId,
        modelId: modelId,
      );
    } catch (error) {
      _logger.warning(
        'Session $sessionId provider route is unavailable: $error',
      );
      return null;
    }
  }
}
