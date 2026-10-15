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
}
