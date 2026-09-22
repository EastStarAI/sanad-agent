import 'dart:async';

import '../../capabilities/models/tool_schema.dart';
import '../../core/models/agent_response.dart';
import '../../core/models/message.dart';
import '../../core/provider_runtime/provider_rate_limiter.dart';
import '../../interfaces/platforms/sanad_gateway/capabilities.dart';
import 'llm_adapter.dart';
import 'llm_request_options.dart';
import 'provider_request_cancelled_exception.dart';

/// Callback invoked when the rate limiter blocks a request. The runtime uses
/// it to broadcast a `session.runtime_notice` (Plan 30 §6.3, §4.1). Returns a
/// future that the wrapper awaits before retrying — the runtime may keep the
/// notice live until retry completes, then emit `cleared`.
typedef RuntimeNoticeEmitter =
    Future<void> Function({
      required String providerInstanceId,
      required Duration retryAfter,
      int? limit,
    });

/// A transparent [LLMAdapter] wrapper that enforces a per-instance rate limit
/// before delegating to the inner adapter (Plan 30 §6.3).
///
/// The wrapper stays provider-agnostic: it does not re-implement any adapter
/// logic, it only gates entry with [ProviderRateLimiter]. When the limiter
/// blocks, it:
/// 1. Calls [onRateLimited] so the runtime can broadcast a runtime notice.
/// 2. Awaits the cancellable [cancelToken]; if cancelled, throws
///    [RateLimitCancelled] so the runtime can abort cleanly.
/// 3. Once a slot opens, proceeds to the inner adapter.
///
/// `getAvailableModels` is also gated because some providers (e.g. NVIDIA NIM)
/// bill `/models` against the same window.
class RateLimitedLLMAdapter implements LLMAdapter {
  final LLMAdapter _inner;

  /// Provider adapter wrapped by this turn-scoped rate-limit/recovery layer.
  /// Background metadata calls may reuse the provider adapter, but must not
  /// retain this turn's cancellation token or runtime-notice callbacks.
  LLMAdapter get providerAdapter => _inner;

  final String providerInstanceId;
  final int requestsPerMinute;
  final ProviderRateLimiter limiter;

  /// Optional callback fired when the limiter makes the request wait.
  /// The runtime wires this to its notice broadcaster.
  final RuntimeNoticeEmitter? onRateLimited;

  /// Optional cancellation token (e.g. a Completer that completes on stop or
  /// provider change). When it fires during a wait, the wrapper throws
  /// [RateLimitCancelled] without invoking the inner adapter.
  final Future<void>? cancelToken;

  RateLimitedLLMAdapter(
    this._inner, {
    required this.providerInstanceId,
    required this.requestsPerMinute,
    required this.limiter,
    this.onRateLimited,
    this.cancelToken,
  });

  @override
  Future<int> getContextLimit([String? modelOverride]) =>
      _inner.getContextLimit(modelOverride);

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    await _acquire();
    return _inner.getAvailableModels();
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    await _acquire(options);
    return _inner.generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
      options: options,
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    await _acquire(options);
    yield* _inner.generateStream(
      history,
      tools: tools,
      modelOverride: modelOverride,
      options: options,
    );
  }

  Future<void> _acquire([LLMRequestOptions options = const LLMRequestOptions()]) async {
    final scope = options.cancellationScope;
    if (scope != null && !scope.isPublicationOpen) {
      throw ProviderRequestCancelledException(operation: 'rate_limit_wait');
    }
    if (!limiter.isLimited(providerInstanceId, requestsPerMinute)) {
      return;
    }
    // Fast path: if a slot is immediately available, take it without emitting.
    final probe = limiter.tryAcquire(providerInstanceId, requestsPerMinute);
    if (probe.granted) return;

    // Slow path: emit notice, then wait for a slot.
    if (onRateLimited != null) {
      await onRateLimited!(
        providerInstanceId: providerInstanceId,
        retryAfter: probe.retryAfter,
        limit: requestsPerMinute,
      );
    }
    final scopeCancel = scope?.whenCancelled;
    final mergedCancel = _mergeCancelTokens(cancelToken, scopeCancel);
    final permit = await limiter.waitForSlot(
      providerInstanceId,
      requestsPerMinute,
      cancelToken: mergedCancel,
    );
    if (permit.cancelled) {
      if (scope != null && !scope.isPublicationOpen) {
        throw ProviderRequestCancelledException(operation: 'rate_limit_wait');
      }
      throw RateLimitCancelled(providerInstanceId);
    }
  }

  static Future<void>? _mergeCancelTokens(
    Future<void>? first,
    Future<void>? second,
  ) {
    if (first == null) return second;
    if (second == null) return first;
    return Future.any([first, second]);
  }
}

/// Thrown when a rate-limit wait is cancelled (stop / provider change).
class RateLimitCancelled implements Exception {
  final String providerInstanceId;
  const RateLimitCancelled(this.providerInstanceId);

  @override
  String toString() =>
      'RateLimitCancelled: wait aborted for provider instance $providerInstanceId';
}
