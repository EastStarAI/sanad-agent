import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';

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
  final NativeThinkingDirective? thinkingDirective;
  final Duration? timeout;
  final int? maxOutputTokens;
  final RunCancellationScope? cancellationScope;
  final ProviderWatchdogConfig watchdogs;
  final ModelCapabilityOverride? routeCapabilitySnapshot;
  final RouteCapabilityProfile? routeCapabilityProfile;
  final AttachmentStore? attachmentStore;
  final http.Client Function()? requestClientFactory;

  const LLMRequestOptions({
    this.sessionId,
    this.requestId,
    this.providerInstanceId,
    this.thinkingMode,
    this.thinkingDirective,
    this.timeout,
    this.maxOutputTokens,
    this.cancellationScope,
    this.watchdogs = ProviderWatchdogConfig.defaults,
    this.routeCapabilitySnapshot,
    this.routeCapabilityProfile,
    this.attachmentStore,
    this.requestClientFactory,
  });

  ModelCapabilityOverride? get effectiveRouteCapabilitySnapshot =>
      routeCapabilityProfile?.rawOverride ?? routeCapabilitySnapshot;

  LLMRequestOptions copyWith({
    String? sessionId,
    String? requestId,
    String? providerInstanceId,
    String? thinkingMode,
    NativeThinkingDirective? thinkingDirective,
    Duration? timeout,
    int? maxOutputTokens,
    RunCancellationScope? cancellationScope,
    ProviderWatchdogConfig? watchdogs,
    ModelCapabilityOverride? routeCapabilitySnapshot,
    RouteCapabilityProfile? routeCapabilityProfile,
    AttachmentStore? attachmentStore,
    http.Client Function()? requestClientFactory,
  }) {
    return LLMRequestOptions(
      sessionId: sessionId ?? this.sessionId,
      requestId: requestId ?? this.requestId,
      providerInstanceId: providerInstanceId ?? this.providerInstanceId,
      thinkingMode: thinkingMode ?? this.thinkingMode,
      thinkingDirective: thinkingDirective ?? this.thinkingDirective,
      timeout: timeout ?? this.timeout,
      maxOutputTokens: maxOutputTokens ?? this.maxOutputTokens,
      cancellationScope: cancellationScope ?? this.cancellationScope,
      watchdogs: watchdogs ?? this.watchdogs,
      routeCapabilitySnapshot:
          routeCapabilitySnapshot ?? this.routeCapabilitySnapshot,
      routeCapabilityProfile:
          routeCapabilityProfile ?? this.routeCapabilityProfile,
      attachmentStore: attachmentStore ?? this.attachmentStore,
      requestClientFactory: requestClientFactory ?? this.requestClientFactory,
    );
  }

  Map<String, dynamic> toSafeDumpOptions({
    bool? stream,
    String? protocol,
  }) {
    final directive = _describeThinkingDirective(thinkingDirective);
    return <String, dynamic>{
      'thinking_mode': ?thinkingMode,
      'thinking_directive': ?directive,
      'timeout_ms': ?timeout?.inMilliseconds,
      'max_output_tokens': ?maxOutputTokens,
      'stream': ?stream,
      'protocol': ?protocol,
    };
  }

  static Map<String, dynamic>? _describeThinkingDirective(
    NativeThinkingDirective? d,
  ) {
    if (d == null || d is UseProviderDefault) return null;
    return switch (d) {
      OpenAiEffortDirective(:final effort) => {
        'type': 'openai_effort',
        'effort': effort,
      },
      ResponsesReasoningDirective(:final effort, :final summary) => {
        'type': 'responses_reasoning',
        'effort': effort,
        'summary': summary,
      },
      AnthropicBudgetDirective(:final budgetTokens) => {
        'type': 'anthropic_budget',
        'budget_tokens': budgetTokens,
      },
      AnthropicAdaptiveDirective(:final effort) => {
        'type': 'anthropic_adaptive',
        'effort': effort,
      },
      GoogleBudgetDirective(:final budget) => {
        'type': 'google_budget',
        'budget': budget,
      },
      GoogleLevelDirective(:final level) => {
        'type': 'google_level',
        'level': level,
      },
      ThinkingToggleDirective(:final enabled) => {
        'type': 'toggle',
        'enabled': enabled,
      },
      _ => {'type': d.runtimeType.toString()},
    };
  }
}
