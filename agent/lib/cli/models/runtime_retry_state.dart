/// The daemon's own recovery classification for a failed turn, as a CLI
/// observer reads it.
///
/// The daemon is the single owner of recovery state: it decides whether a
/// failure is retried automatically, how many attempts the reason's budget
/// allows, and when it gives up. Observers must therefore classify on that
/// state — the runtime notice status, the reason's retryability, and the
/// remaining budget — and never on the first `blocked` text they see.
///
/// That distinction is what the 2026-10-23 defect was missing: a provider
/// timeout has a one-attempt automatic budget, so the daemon published a
/// retryable failure it *was* retrying, and both `sanad run` and the supervisor
/// reported a failed turn while the same turn resumed seconds later.
///
/// Two projections carry the same evidence, so both are read here:
///
/// * a `session.runtime_notice` payload (`status`, `reason`, `retry_attempt`,
///   `retry_budget`, `retry_after_ms`);
/// * a `session show` / session-history projection (`runtime_notice` plus the
///   durable `execution_snapshot.state`).
///
/// The durable snapshot outranks the notice. A notice lingers in the projection
/// after the turn it described has ended, so `execution_snapshot.state == idle`
/// is read as "the daemon stopped publishing this turn": nothing is retrying
/// and nothing is parked. A `fatal` notice is never a retry either, whatever
/// counters its reason happens to carry.
class RuntimeRetryState {
  /// Notice lifecycle status: `waiting`, `blocked`, `resuming`, `fatal`, or
  /// `cleared`. Null when the daemon published no notice.
  final String? noticeStatus;

  /// Structured failure reason (`timeout`, `rate_limit`, `auth`, …).
  final String? reason;

  /// Durable execution state (`running`, `waiting`, `blocked`, `resuming`, …).
  final String? executionState;

  /// 1-based automatic attempt the notice describes.
  final int? attempt;

  /// Automatic-retry budget for this failure's reason.
  final int? budget;

  /// Milliseconds until the scheduled resume, when the notice carries one.
  final int? retryAfterMs;

  /// Human-readable notice message (already redacted by the daemon).
  final String message;

  const RuntimeRetryState({
    this.noticeStatus,
    this.reason,
    this.executionState,
    this.attempt,
    this.budget,
    this.retryAfterMs,
    this.message = '',
  });

  /// Reads a `session.runtime_notice` payload.
  factory RuntimeRetryState.fromNotice(Object? notice) {
    final map = notice is Map ? notice : const <String, dynamic>{};
    return RuntimeRetryState(
      noticeStatus: _text(map['status']),
      reason: _text(map['reason'] ?? map['code']),
      attempt: _integer(map['retry_attempt'] ?? map['retryAttempt']),
      budget: _integer(map['retry_budget'] ?? map['retryBudget']),
      retryAfterMs: _integer(map['retry_after_ms'] ?? map['retryAfterMs']),
      message: _text(map['message']) ?? '',
    );
  }

  /// Reads a durable session projection, which carries the notice next to the
  /// execution snapshot.
  factory RuntimeRetryState.fromProjection(Map<String, dynamic> projection) {
    final notice = RuntimeRetryState.fromNotice(projection['runtime_notice']);
    final snapshot = projection['execution_snapshot'];
    final state = snapshot is Map ? _text(snapshot['state']) : null;
    return RuntimeRetryState(
      noticeStatus: notice.noticeStatus,
      reason: notice.reason,
      executionState: state,
      attempt: notice.attempt,
      budget: notice.budget,
      retryAfterMs: notice.retryAfterMs ??
          (snapshot is Map ? _integer(snapshot['retry_after_ms']) : null),
      message: notice.message,
    );
  }

  /// The durable state that means the daemon stopped publishing this turn.
  static const String _endedState = 'idle';

  /// Whether the recovery state itself promises a resume.
  bool get schedulesResume =>
      noticeStatus == 'waiting' || noticeStatus == 'resuming';

  /// Whether another automatic attempt is still inside the budget. A `fatal`
  /// notice is never retried, so its counters cannot promise an attempt.
  bool get hasRetryBudgetLeft {
    if (noticeStatus == 'fatal') return false;
    final attemptValue = attempt;
    final budgetValue = budget;
    return attemptValue != null &&
        budgetValue != null &&
        budgetValue > 0 &&
        attemptValue < budgetValue;
  }

  /// Whether the daemon will continue this turn without an operator: a
  /// scheduled resume, a retryable failure with budget left, or a durable
  /// `waiting` state whose notice was not projected.
  ///
  /// A durable `idle` snapshot ends the turn, so a notice left over from it
  /// never makes the turn look like it is still retrying.
  bool get isAutoRetrying {
    if (executionState == _endedState) return false;
    if (schedulesResume || hasRetryBudgetLeft) return true;
    return noticeStatus == null && executionState == 'waiting';
  }

  /// Whether the turn is parked with no scheduled resume, so only an operator
  /// (Retry, Change Provider, Stop) can move it.
  bool get isTrulyBlocked {
    if (executionState == _endedState) return false;
    if (isAutoRetrying) return false;
    return noticeStatus == 'blocked' ||
        noticeStatus == 'fatal' ||
        executionState == 'blocked';
  }

  /// `retrying (n/N)`, or plain `retrying` when the daemon published no
  /// counters. Only meaningful when [isAutoRetrying] is true.
  String get retryLabel {
    final attemptValue = attempt;
    final budgetValue = budget;
    if (attemptValue == null || budgetValue == null || budgetValue <= 0) {
      return 'retrying';
    }
    return 'retrying ($attemptValue/$budgetValue)';
  }

  static String? _text(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
  }

  static int? _integer(Object? value) {
    if (value is int) return value;
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }
}
