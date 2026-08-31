import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';

/// Per-call runtime context shared by every LLM adapter.
///
/// Options are immutable and must never be retained by an adapter between
/// calls. Provider-specific request builders decide which supported values are
/// placed on the wire.
class LLMRequestOptions {
  final String? sessionId;
  final String? requestId;
  final String? providerInstanceId;
  final String? thinkingMode;
  final NativeThinkingDirective? thinkingDirective;
  final Duration? timeout;
  final int? maxOutputTokens;

  const LLMRequestOptions({
    this.sessionId,
    this.requestId,
    this.providerInstanceId,
    this.thinkingMode,
    this.thinkingDirective,
    this.timeout,
    this.maxOutputTokens,
  });
}
