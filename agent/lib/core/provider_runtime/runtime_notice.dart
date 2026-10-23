import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';

/// Canonical runtime recovery state for a session (Plan 30 §5.1).
///
/// The agent is the single source of truth for every recovery state. The UI
/// only sends commands and waits for a fresh [RuntimeNotice] event before
/// changing its visual state. Instances of this class are emitted to all open
/// clients on the same session, so multiple windows share one source of truth.
class RuntimeNotice {
  /// Session this notice belongs to.
  final String sessionId;

  /// Request that triggered the recovery state (turn/request id).
  final String? requestId;

  /// Optional run/turn id.
  final String? runId;

  /// Lifecycle status of the recovery (Plan 30 §5.2).
  /// `waiting` = automatic resume at a known time.
  /// `blocked` = needs user action (retry / change provider / open settings).
  /// `resuming` = recovery cleared, execution restarting (transient).
  final RuntimeNoticeStatus status;

  /// Structured reason (Plan 30 §7.1).
  final RuntimeFailureReason reason;

  /// Severity for UI styling.
  final RuntimeNoticeSeverity severity;

  /// Short title shown as the banner headline.
  final String title;

  /// Longer message describing the situation + next step.
  final String message;

  /// Provider instance involved, if any.
  final String? providerInstanceId;
  final String? providerDisplayName;

  /// When to resume automatically. Only meaningful for `waiting` status.
  final DateTime? resumeAt;

  /// Convenience: milliseconds until [resumeAt], clamped to >= 0.
  int get retryAfterMs {
    final at = resumeAt;
    if (at == null) return 0;
    final ms = at.difference(DateTime.now()).inMilliseconds;
    return ms < 0 ? 0 : ms;
  }

  /// Active rate-limit value, when relevant.
  final int? limit;

  /// 1-based automatic-retry attempt this notice describes, when the runtime
  /// scheduled one. Null for a notice that describes no scheduled retry.
  final int? retryAttempt;

  /// Automatic-retry budget for this failure's reason. With [retryAttempt] it
  /// is what makes a notice self-describing: `retryAttempt < retryBudget` means
  /// the runtime will resume the request on its own, so no observer may report
  /// the turn as stopped.
  final int? retryBudget;

  /// UI actions allowed for this notice (Plan 30 §5.2 `actions[]`).
  final List<RuntimeNoticeAction> actions;

  final DateTime createdAt;
  final DateTime updatedAt;

  const RuntimeNotice({
    required this.sessionId,
    this.requestId,
    this.runId,
    required this.status,
    required this.reason,
    this.severity = RuntimeNoticeSeverity.warning,
    required this.title,
    required this.message,
    this.providerInstanceId,
    this.providerDisplayName,
    this.resumeAt,
    this.limit,
    this.retryAttempt,
    this.retryBudget,
    this.actions = const [],
    required this.createdAt,
    required this.updatedAt,
  });

  /// Whether the recovery state itself promises a resume: `waiting` waits on a
  /// resume timer and `resuming` is already restarting execution.
  bool get schedulesResume =>
      status == RuntimeNoticeStatus.waiting ||
      status == RuntimeNoticeStatus.resuming;

  /// Whether another automatic attempt is still inside the retry budget.
  bool get hasRetryBudgetLeft {
    final attempt = retryAttempt;
    final budget = retryBudget;
    return attempt != null && budget != null && budget > 0 && attempt < budget;
  }

  /// Whether the runtime will continue this turn without an operator: a
  /// scheduled resume, or a retryable failure with budget left.
  bool get isAutomaticRetryPending => schedulesResume || hasRetryBudgetLeft;

  /// Whether the turn is parked on an intervention with no scheduled resume.
  bool get awaitsIntervention =>
      !isAutomaticRetryPending &&
      (status == RuntimeNoticeStatus.blocked ||
          status == RuntimeNoticeStatus.fatal);

  /// Transport-safe payload for `session.runtime_notice`.
  Map<String, dynamic> toPayload() => {
    'session_id': sessionId,
    if (requestId != null) 'request_id': requestId,
    if (runId != null) 'run_id': runId,
    'status': _snakeCase(status.name),
    'reason': _snakeCase(reason.name),
    'severity': _snakeCase(severity.name),
    'title': title,
    'message': message,
    if (providerInstanceId != null) 'provider_instance_id': providerInstanceId,
    if (providerDisplayName != null)
      'provider_display_name': providerDisplayName,
    if (resumeAt != null) 'retry_after_ms': retryAfterMs,
    if (resumeAt != null) 'resume_at': resumeAt!.toUtc().toIso8601String(),
    if (limit != null) 'limit': {'requests_per_minute': limit},
    if (retryAttempt != null) 'retry_attempt': retryAttempt,
    if (retryBudget != null) 'retry_budget': retryBudget,
    'actions': actions.map((a) => _snakeCase(a.name)).toList(),
  };
}

/// Recovery lifecycle status (Plan 30 §5.2).
enum RuntimeNoticeStatus {
  /// Automatic resume at a known time.
  waiting,

  /// Needs user action.
  blocked,

  /// Recovery cleared, execution restarting (transient).
  resuming,

  /// Recovery resolved / dismissed.
  cleared,

  /// Not recoverable within the current session; shown as a final error.
  fatal,
}

/// Severity for UI styling.
enum RuntimeNoticeSeverity { info, warning, error }

/// UI actions the runtime advertises for a notice (Plan 30 §5.2).
enum RuntimeNoticeAction {
  stop,
  retry,
  changeProvider,
  continueWithProvider,
  openProviderSettings,
}

/// Converts a Dart enum name (camelCase) to the snake_case wire form used by
/// the canonical protocol (e.g. `rateLimit` → `rate_limit`,
/// `changeProvider` → `change_provider`).
String _snakeCase(String camel) {
  final out = StringBuffer();
  for (var i = 0; i < camel.length; i++) {
    final ch = camel[i];
    if (ch.toUpperCase() == ch && ch.toLowerCase() != ch && i > 0) {
      out.write('_');
    }
    out.write(ch.toLowerCase());
  }
  return out.toString();
}
