import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';

/// Structured classification of an LLM/runtime failure (Plan 30 §7.1).
///
/// The runtime calls [classify] with whatever the adapter surfaces (HTTP
/// status, error body, Retry-After, provider context) and gets a single
/// decision object: how to surface it, whether to retry, whether to failover.
/// UI and adapters never re-interpret error text strings — this is the single
/// owner.
enum RuntimeFailureReason {
  auth,
  billing,
  rateLimit,
  upstreamRateLimit,
  overloaded,
  timeout,
  networkError,
  tlsCertificate,
  contextOverflow,
  payloadTooLarge,
  invalidRequest,
  modelNotFound,
  contentPolicyBlocked,
  toolRuntimeError,
  localRuntimeError,
  unknown;

  /// Decision for this reason (Plan 30 §7.1).
  FailureDecision decision() {
    switch (this) {
      case RuntimeFailureReason.auth:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.blocked,
          severity: RuntimeNoticeSeverity.error,
          retryable: false,
          allowAutoFailover: false,
          allowManualRetry: false,
          uiActions: [
            RuntimeNoticeAction.changeProvider,
            RuntimeNoticeAction.openProviderSettings,
          ],
        );
      case billing:
        // No retry on the same instance; failover allowed when a qualified
        // candidate exists.
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.blocked,
          severity: RuntimeNoticeSeverity.error,
          retryable: false,
          allowAutoFailover: true,
          allowManualRetry: false,
          uiActions: [
            RuntimeNoticeAction.changeProvider,
            RuntimeNoticeAction.openProviderSettings,
          ],
        );
      case rateLimit:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.waiting,
          severity: RuntimeNoticeSeverity.warning,
          retryable: true,
          allowAutoFailover: true,
          allowManualRetry: true,
          uiActions: [
            RuntimeNoticeAction.stop,
            RuntimeNoticeAction.changeProvider,
          ],
        );
      case upstreamRateLimit:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.waiting,
          severity: RuntimeNoticeSeverity.warning,
          retryable: true,
          // Aggregator limit: prefer failover, do not burn the current
          // credential as exhausted.
          allowAutoFailover: true,
          allowManualRetry: true,
          uiActions: [
            RuntimeNoticeAction.stop,
            RuntimeNoticeAction.changeProvider,
          ],
        );
      case overloaded:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.waiting,
          severity: RuntimeNoticeSeverity.warning,
          retryable: true,
          allowAutoFailover: false,
          allowManualRetry: true,
          uiActions: [RuntimeNoticeAction.stop, RuntimeNoticeAction.retry],
        );
      case timeout:
      case networkError:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.blocked,
          severity: RuntimeNoticeSeverity.error,
          retryable: true,
          allowAutoFailover: false,
          allowManualRetry: true,
          uiActions: [
            RuntimeNoticeAction.retry,
            RuntimeNoticeAction.changeProvider,
          ],
        );
      case tlsCertificate:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.blocked,
          severity: RuntimeNoticeSeverity.error,
          retryable: false,
          allowAutoFailover: false,
          allowManualRetry: true,
          uiActions: [
            RuntimeNoticeAction.retry,
            RuntimeNoticeAction.changeProvider,
          ],
        );
      case invalidRequest:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.blocked,
          severity: RuntimeNoticeSeverity.error,
          retryable: false,
          allowAutoFailover: false,
          allowManualRetry: false,
          uiActions: [RuntimeNoticeAction.changeProvider],
        );
      case contextOverflow:
      case payloadTooLarge:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.fatal,
          severity: RuntimeNoticeSeverity.error,
          retryable: false,
          allowAutoFailover: false,
          allowManualRetry: false,
          uiActions: [RuntimeNoticeAction.changeProvider],
        );
      case modelNotFound:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.blocked,
          severity: RuntimeNoticeSeverity.error,
          retryable: false,
          allowAutoFailover: true,
          allowManualRetry: false,
          uiActions: [RuntimeNoticeAction.changeProvider],
        );
      case contentPolicyBlocked:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.fatal,
          severity: RuntimeNoticeSeverity.error,
          retryable: false,
          allowAutoFailover: false,
          allowManualRetry: false,
          uiActions: [],
        );
      case toolRuntimeError:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.blocked,
          severity: RuntimeNoticeSeverity.error,
          retryable: true,
          allowAutoFailover: false,
          allowManualRetry: true,
          uiActions: [RuntimeNoticeAction.retry],
        );
      case localRuntimeError:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.blocked,
          severity: RuntimeNoticeSeverity.error,
          retryable: true,
          allowAutoFailover: false,
          allowManualRetry: true,
          uiActions: [RuntimeNoticeAction.retry],
        );
      case unknown:
        return const FailureDecision(
          noticeStatus: RuntimeNoticeStatus.blocked,
          severity: RuntimeNoticeSeverity.error,
          retryable: true,
          allowAutoFailover: false,
          allowManualRetry: true,
          uiActions: [
            RuntimeNoticeAction.retry,
            RuntimeNoticeAction.changeProvider,
          ],
        );
    }
  }

  /// Central classifier (Plan 30 §7.1). Returns a [RuntimeFailureReason]
  /// from HTTP status / error body / provider context.
  static RuntimeFailureReason classify({
    int? statusCode,
    String? body,
    String? errorCode,
    String? providerTemplateId,
    bool hasTrustedTemporaryReset = false,
  }) {
    final text = '${body ?? ''} ${errorCode ?? ''}'.toLowerCase();
    // Model-not-found patterns are checked early so a 400/404 carrying a
    // model message is never misclassified as a generic unknown/bad-request
    // (Plan 30 Phase H §5: "Unknown Model, please check the model code." and
    // similar provider strings must stay modelNotFound, not become unknown).
    final isModelNotFoundBody = _isModelNotFoundBody(text);
    final isContentPolicyBody =
        text.contains('content policy') ||
        text.contains('content_filter') ||
        text.contains('content filter');
    switch (statusCode) {
      case 400:
        // Some providers return 400 for an invalid/unknown model id.
        if (isModelNotFoundBody) return RuntimeFailureReason.modelNotFound;
        // Some providers return 400 for content-policy violations.
        if (isContentPolicyBody) {
          return RuntimeFailureReason.contentPolicyBlocked;
        }
        // OpenAI-compatible providers often return 400 for context overflow.
        if (text.contains('context length') || text.contains('maximum context')) {
          return RuntimeFailureReason.contextOverflow;
        }
        return RuntimeFailureReason.invalidRequest;
      case 401:
      case 403:
        return RuntimeFailureReason.auth;
      case 402:
        return RuntimeFailureReason.billing;
      case 404:
        // Some gateways 404 for a missing model.
        if (isModelNotFoundBody || text.contains('model')) {
          return RuntimeFailureReason.modelNotFound;
        }
        return RuntimeFailureReason.unknown;
      case 413:
        return RuntimeFailureReason.payloadTooLarge;
      case 429:
        return _classify429(
          text,
          providerTemplateId,
          hasTrustedTemporaryReset: hasTrustedTemporaryReset,
        );
      case 504:
        return RuntimeFailureReason.timeout;
      case 500:
      case 502:
      case 503:
        if (_isNetworkFailureBody(text)) {
          return RuntimeFailureReason.networkError;
        }
        if (text.contains('overload') ||
            text.contains('capacity') ||
            text.contains('busy')) {
          return RuntimeFailureReason.overloaded;
        }
        if (text.contains('gateway timeout')) {
          return RuntimeFailureReason.timeout;
        }
        if ((text.contains('upstream') || text.contains('gateway')) &&
            (text.contains('rate limit') ||
                text.contains('too many requests') ||
                text.contains('request limit') ||
                hasTrustedTemporaryReset)) {
          return RuntimeFailureReason.upstreamRateLimit;
        }
        if (text.contains('resourceexhausted') ||
            text.contains('resource_exhausted')) {
          if (text.contains('capacity') ||
              text.contains('worker unavailable') ||
              text.contains('unavailable')) {
            return RuntimeFailureReason.overloaded;
          }
          if (text.contains('quota') ||
              text.contains('insufficient quota') ||
              text.contains('quota exceeded')) {
            if (hasTrustedTemporaryReset) {
              return RuntimeFailureReason.rateLimit;
            }
            return RuntimeFailureReason.billing;
          }
          if (text.contains('request limit') ||
              text.contains('total request limit') ||
              text.contains('rate limit') ||
              hasTrustedTemporaryReset) {
            return RuntimeFailureReason.rateLimit;
          }
          return RuntimeFailureReason.unknown;
        }
        if (text.contains('request limit') ||
            text.contains('total request limit')) {
          return RuntimeFailureReason.rateLimit;
        }
        return RuntimeFailureReason.unknown;
      default:
        if (statusCode != null && statusCode >= 500) {
          return RuntimeFailureReason.unknown;
        }
        break;
    }
    // Pattern match for common error strings without a status code.
    if (isModelNotFoundBody) {
      return RuntimeFailureReason.modelNotFound;
    }
    if (_isTlsFailureBody(text)) {
      return RuntimeFailureReason.tlsCertificate;
    }
    if (text.contains('insufficient') && text.contains('credit') ||
        text.contains('billing') ||
        text.contains('payment required') ||
        text.contains('balance')) {
      return RuntimeFailureReason.billing;
    }
    if (_isPermanentQuotaBody(text)) {
      if (hasTrustedTemporaryReset) {
        return RuntimeFailureReason.rateLimit;
      }
      return RuntimeFailureReason.billing;
    }
    if (text.contains('overload') ||
        text.contains('capacity') ||
        text.contains('busy')) {
      return RuntimeFailureReason.overloaded;
    }
    if (text.contains('gateway timeout')) {
      return RuntimeFailureReason.timeout;
    }
    if (text.contains('usage limit') && text.contains('reset')) {
      return RuntimeFailureReason.rateLimit;
    }
    if (text.contains('quota') || text.contains('usage limit')) {
      return RuntimeFailureReason.rateLimit;
    }
    if (text.contains('resourceexhausted') ||
        text.contains('resource_exhausted')) {
      if (text.contains('capacity') ||
          text.contains('worker unavailable') ||
          text.contains('unavailable')) {
        return RuntimeFailureReason.overloaded;
      }
      if (text.contains('quota') ||
          text.contains('insufficient quota') ||
          text.contains('quota exceeded')) {
        if (hasTrustedTemporaryReset) {
          return RuntimeFailureReason.rateLimit;
        }
        return RuntimeFailureReason.billing;
      }
      if (text.contains('request limit') ||
          text.contains('total request limit') ||
          text.contains('rate limit') ||
          hasTrustedTemporaryReset) {
        return RuntimeFailureReason.rateLimit;
      }
      return RuntimeFailureReason.unknown;
    }
    if (text.contains('rate limit') || text.contains('too many requests')) {
      return RuntimeFailureReason.rateLimit;
    }
    if (text.contains('context length') || text.contains('maximum context')) {
      return RuntimeFailureReason.contextOverflow;
    }
    if (text.contains('content policy') || text.contains('content_filter')) {
      return RuntimeFailureReason.contentPolicyBlocked;
    }
    if (text.contains('timeout') || text.contains('timed out')) {
      return RuntimeFailureReason.timeout;
    }
    if (_isNetworkFailureBody(text)) {
      return RuntimeFailureReason.networkError;
    }
    if (text.contains('invalid request') ||
        text.contains('malformed') ||
        text.contains('unsupported parameter') ||
        text.contains('validation error') ||
        text.contains('unprocessable entity')) {
      return RuntimeFailureReason.invalidRequest;
    }
    return RuntimeFailureReason.unknown;
  }

  static bool _isNetworkFailureBody(String text) {
    return text.contains('upstream connect error') ||
        text.contains('disconnect/reset') ||
        text.contains('remote connection failure') ||
        text.contains('connection reset') ||
        text.contains('connection refused') ||
        text.contains('connection aborted') ||
        text.contains('connection closed') ||
        text.contains('server disconnected') ||
        text.contains('unexpected eof') ||
        text.contains('incomplete chunked read') ||
        text.contains('socket') ||
        text.contains('network');
  }

  /// Distinguishes the four flavors of 429 (Plan 30 §7.2).
  static RuntimeFailureReason _classify429(
    String text,
    String? providerTemplateId, {
    required bool hasTrustedTemporaryReset,
  }) {
    if (text.contains('upstream') || text.contains('aggregator')) {
      return RuntimeFailureReason.upstreamRateLimit;
    }
    if (text.contains('overload') || text.contains('capacity')) {
      return RuntimeFailureReason.overloaded;
    }
    if (hasTrustedTemporaryReset) {
      return RuntimeFailureReason.rateLimit;
    }
    if (_isPermanentQuotaBody(text)) {
      return RuntimeFailureReason.billing;
    }
    if (text.contains('usage limit') || text.contains('reset')) {
      // Daily/usage reset is retryable only when the HTTP layer resolved a
      // future reset hint. Without that hint it falls through to the generic
      // 429 minute cooldown handled by the runtime.
      return RuntimeFailureReason.rateLimit;
    }
    return RuntimeFailureReason.rateLimit;
  }

  /// Recognizes provider model-not-found bodies (Plan 30 Phase H §5).
  ///
  /// Covers the classic "model not found" plus the NVIDIA NIM / OpenAI
  /// compatible string `Unknown Model, please check the model code.` and the
  /// bare `unknown model` form. Always lowercase (caller lowercases).
  static bool _isModelNotFoundBody(String text) {
    if (text.contains('model') && text.contains('not found')) return true;
    if (text.contains('unknown model')) return true;
    if (text.contains('model') && text.contains('does not exist')) {
      return true;
    }
    if (text.contains('invalid model')) return true;
    return false;
  }

  static bool _isTlsFailureBody(String text) {
    return text.contains('certificate verify failed') ||
        text.contains('certificate verification failed') ||
        text.contains('unable to get local issuer certificate') ||
        text.contains('self signed certificate') ||
        text.contains('hostname mismatch') ||
        text.contains('x509:') ||
        text.contains('x509 certificate') ||
        text.contains('certificate has expired') ||
        text.contains('unknown ca');
  }

  static bool _isPermanentQuotaBody(String text) {
    return text.contains('insufficient_quota') ||
        text.contains('quota exceeded') ||
        text.contains('exceeded your current quota') ||
        text.contains('insufficient credits') ||
        text.contains('billing hard limit') ||
        text.contains('credit balance') ||
        text.contains('balance depleted');
  }
}

/// A single decision about how to handle a [RuntimeFailureReason] (Plan 30
/// §7.1).
class FailureDecision {
  final RuntimeNoticeStatus noticeStatus;
  final RuntimeNoticeSeverity severity;
  final bool retryable;
  final bool allowAutoFailover;
  final bool allowManualRetry;
  final List<RuntimeNoticeAction> uiActions;

  const FailureDecision({
    required this.noticeStatus,
    required this.severity,
    required this.retryable,
    required this.allowAutoFailover,
    required this.allowManualRetry,
    required this.uiActions,
  });

  /// Conservative default if nothing else matches.
  factory FailureDecision.unknown() => const FailureDecision(
    noticeStatus: RuntimeNoticeStatus.blocked,
    severity: RuntimeNoticeSeverity.error,
    retryable: true,
    allowAutoFailover: false,
    allowManualRetry: true,
    uiActions: [RuntimeNoticeAction.retry, RuntimeNoticeAction.changeProvider],
  );
}
