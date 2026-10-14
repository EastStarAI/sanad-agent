import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';

/// Provider-neutral summarizer contract (Plan 53c Gate C3).
abstract class CompactionSummarizer {
  Future<String> summarize({required String prompt});
}

class CompactionProviderRequest {
  final List<Message> baseProjection;
  final List<ToolSchema> tools;
  final RouteSignature routeSignature;
  final LLMRequestOptions options;
  final String instruction;

  CompactionProviderRequest({
    required List<Message> baseProjection,
    required List<ToolSchema> tools,
    required this.routeSignature,
    required this.options,
    required this.instruction,
  }) : baseProjection = List.unmodifiable(baseProjection),
       tools = List.unmodifiable(tools);

  List<Message> get appendedProjection => List.unmodifiable([
    ...baseProjection,
    Message(role: MessageRole.user, content: instruction),
  ]);

  CompactionProviderRequest withInstruction(String value) =>
      CompactionProviderRequest(
        baseProjection: baseProjection,
        tools: tools,
        routeSignature: routeSignature,
        options: options,
        instruction: value,
      );
}

class CompactionProviderResult {
  final String content;
  final Map<String, dynamic>? usage;
  final Duration duration;

  const CompactionProviderResult({
    required this.content,
    required this.usage,
    required this.duration,
  });
}

abstract interface class ProviderProjectionCompactionSummarizer {
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  );
}

class CompactionInvalidProviderResponse implements Exception {
  final String reason;
  final Map<String, dynamic>? usage;
  final Duration? duration;

  const CompactionInvalidProviderResponse(
    this.reason, {
    this.usage,
    this.duration,
  });
}

class CompactionRouteChanged implements Exception {
  const CompactionRouteChanged();
}

class CompactionProviderOverflow implements Exception {
  const CompactionProviderOverflow();
}

/// Production summarizer. It uses the exact resolved route and appends one
/// ephemeral user instruction without persisting either side of the exchange.
class ProviderBackedCompactionSummarizer
    implements CompactionSummarizer, ProviderProjectionCompactionSummarizer {
  final AgentRuntimeService _runtime;

  ProviderBackedCompactionSummarizer(this._runtime);

  @override
  Future<String> summarize({required String prompt}) {
    throw UnsupportedError(
      'provider-backed compaction requires a provider projection',
    );
  }

  @override
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  ) async {
    _assertRoute(request);
    final turnAdapter = _runtime.adapterForTurn(
      request.routeSignature,
      sessionId: request.options.sessionId ?? '',
      requestId: request.options.requestId,
    );
    final stopwatch = Stopwatch()..start();
    late AgentResponse response;
    try {
      response = await turnAdapter.generateResponse(
        request.appendedProjection,
        tools: request.tools,
        modelOverride: request.routeSignature.modelId,
        options: request.options,
      );
    } on LlmHttpException catch (error) {
      final reason = RuntimeFailureReason.classify(
        statusCode: error.statusCode,
        body: error.body,
      );
      if (reason == RuntimeFailureReason.contextOverflow) {
        throw const CompactionProviderOverflow();
      }
      rethrow;
    }
    stopwatch.stop();
    _assertRoute(request);
    final invalidReason = _invalidResponseReason(response);
    if (invalidReason != null) {
      throw CompactionInvalidProviderResponse(
        invalidReason,
        usage: response.usage == null
            ? null
            : Map<String, dynamic>.unmodifiable(response.usage!),
        duration: stopwatch.elapsed,
      );
    }
    return CompactionProviderResult(
      content: response.message.content ?? '',
      usage: response.usage == null
          ? null
          : Map<String, dynamic>.unmodifiable(response.usage!),
      duration: stopwatch.elapsed,
    );
  }

  void _assertRoute(CompactionProviderRequest request) {
    final current = _runtime.resolveSignature(
      providerId: request.routeSignature.providerInstanceId,
      modelId: request.routeSignature.modelId,
    );
    if (current != request.routeSignature) throw const CompactionRouteChanged();
  }

  static String? _invalidResponseReason(AgentResponse response) {
    if (response.isToolCall ||
        (response.message.toolCalls?.isNotEmpty ?? false)) {
      return 'summarization response attempted a tool call';
    }
    if (response.finishReason == LLMFinishReason.incomplete ||
        response.finishReason == LLMFinishReason.length ||
        response.finishReason == LLMFinishReason.failed ||
        response.finishReason == LLMFinishReason.cancelled) {
      return 'summarization response was not complete';
    }
    if ((response.message.content ?? '').trim().isEmpty) {
      return 'summarization response was empty';
    }
    return null;
  }
}

/// Deterministic summarizer for tests and offline validation only.
///
/// Never invokes tools. Strips secret-shaped spans before returning text.
class StructuredCompactionSummarizer implements CompactionSummarizer {
  static const SecretsRedactor _redactor = SecretsRedactor();

  @override
  Future<String> summarize({required String prompt}) async {
    if (prompt.contains('tool_call_request') ||
        prompt.contains('"name": "tool"')) {
      throw StateError('compaction summarizer must not execute tools');
    }
    final goalMatch = RegExp(
      r'goal:\s*(.+)',
      caseSensitive: false,
    ).firstMatch(prompt);
    final pathMatch = RegExp(
      r'path:\s*(.+)',
      caseSensitive: false,
    ).firstMatch(prompt);
    final blockerMatch = RegExp(
      r'blocker:\s*(.+)',
      caseSensitive: false,
    ).firstMatch(prompt);
    final goal = goalMatch?.group(1)?.trim() ?? 'Continue current task';
    final path = pathMatch?.group(1)?.trim();
    final blocker = blockerMatch?.group(1)?.trim() ?? 'None recorded.';
    final body =
        '''
Current Goal and Success Criteria: $goal
Active Constraints and User Preferences: Preserve existing user preferences.
Completed Work and Verified Results: Prior work captured in checkpoint.
Current State and In-Progress Work: Awaiting next safe action.
Key Decisions and Rationale: Continue with validated plan.
Blockers, Errors, and Unresolved Questions: $blocker
Pending User Asks: None.
Relevant Files, Symbols, IDs, and External State: ${path ?? 'none'}
Remaining Work and Safest Next Action: Execute the next verified step toward the goal.
Critical Context That Must Not Be Lost: $goal
''';
    return _redactor.redact(body);
  }
}
