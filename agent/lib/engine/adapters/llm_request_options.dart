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

  const LLMRequestOptions({
    this.sessionId,
    this.requestId,
    this.providerInstanceId,
    this.thinkingMode,
    this.timeout,
    this.maxOutputTokens,
    this.cancellationScope,
    this.watchdogs = ProviderWatchdogConfig.defaults,
  });
}
