import '../runtime/run_cancellation_scope.dart';
import 'provider_watchdog_config.dart';

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
  final Duration? timeout;
  final int? maxOutputTokens;
  final RunCancellationScope? cancellationScope;
  final ProviderWatchdogConfig watchdogs;

  /// True when this model call continues a turn after tool results.
  ///
  /// Copilot maps this to `x-initiator: agent`. The first model request of a
  /// user turn, and steer/incomplete continuations, keep the default `false`.
  final bool afterToolResults;

  const LLMRequestOptions({
    this.sessionId,
    this.requestId,
    this.providerInstanceId,
    this.thinkingMode,
    this.timeout,
    this.maxOutputTokens,
    this.cancellationScope,
    this.watchdogs = ProviderWatchdogConfig.defaults,
    this.afterToolResults = false,
  });
}
