import 'package:equatable/equatable.dart';

enum SessionExecutionState {
  idle,
  queued,
  running,
  waiting,
  blocked,
  resuming,
  stopping
  ;

  static SessionExecutionState fromWireValue(Object? value) {
    final wireValue = value?.toString();
    return SessionExecutionState.values.where((state) => state.name == wireValue).firstOrNull ??
        (throw FormatException('Unknown session execution state: $wireValue'));
  }
}

class SessionExecutionSnapshot extends Equatable {
  final String sessionId;
  final SessionExecutionState state;
  final String? workItemId;
  final String? requestId;
  final int revision;
  final DateTime? updatedAt;
  final DateTime? turnStartedAt;
  final int? elapsedMs;
  final DateTime? baselineReceivedAt;

  const SessionExecutionSnapshot({
    required this.sessionId,
    required this.state,
    required this.workItemId,
    required this.requestId,
    required this.revision,
    required this.updatedAt,
    this.turnStartedAt,
    this.elapsedMs,
    this.baselineReceivedAt,
  });

  factory SessionExecutionSnapshot.virtualIdle(String sessionId) {
    final normalizedSessionId = sessionId.trim();
    if (normalizedSessionId.isEmpty) {
      throw const FormatException(
        'A virtual execution snapshot requires a session id.',
      );
    }
    return SessionExecutionSnapshot(
      sessionId: normalizedSessionId,
      state: SessionExecutionState.idle,
      workItemId: null,
      requestId: null,
      revision: 0,
      updatedAt: null,
      turnStartedAt: null,
      elapsedMs: null,
      baselineReceivedAt: null,
    );
  }

  factory SessionExecutionSnapshot.fromJson(
    Map<String, dynamic> json, {
    String? expectedSessionId,
    DateTime? receivedAt,
  }) {
    final sessionId = json['session_id']?.toString().trim() ?? '';
    if (sessionId.isEmpty) {
      throw const FormatException(
        'session_id is required for an execution snapshot.',
      );
    }
    if (expectedSessionId != null && sessionId != expectedSessionId) {
      throw FormatException(
        'Execution snapshot session_id $sessionId does not match $expectedSessionId.',
      );
    }

    final revisionValue = json['revision'];
    if (revisionValue is! num || revisionValue.toInt() != revisionValue || revisionValue.isNegative) {
      throw FormatException(
        'Execution snapshot revision must be a non-negative integer: $revisionValue',
      );
    }

    final updatedAtValue = json['updated_at'];
    final updatedAt = updatedAtValue == null ? null : DateTime.tryParse(updatedAtValue.toString());
    if (updatedAtValue != null && updatedAt == null) {
      throw FormatException(
        'Invalid execution snapshot updated_at: $updatedAtValue',
      );
    }

    final turnStartedAtValue = json['turn_started_at'];
    final turnStartedAt = turnStartedAtValue == null ? null : DateTime.tryParse(turnStartedAtValue.toString())?.toUtc();
    if (turnStartedAtValue != null && turnStartedAt == null) {
      throw FormatException(
        'Invalid execution snapshot turn_started_at: $turnStartedAtValue',
      );
    }
    final elapsedValue = json['elapsed_ms'];
    final elapsedMs = elapsedValue is num && elapsedValue.toInt() == elapsedValue && !elapsedValue.isNegative
        ? elapsedValue.toInt()
        : null;
    if (elapsedValue != null && elapsedMs == null) {
      throw FormatException(
        'Invalid execution snapshot elapsed_ms: $elapsedValue',
      );
    }
    if (elapsedMs != null && turnStartedAt == null) {
      throw const FormatException(
        'execution snapshot elapsed_ms requires turn_started_at.',
      );
    }

    return SessionExecutionSnapshot(
      sessionId: sessionId,
      state: SessionExecutionState.fromWireValue(json['state']),
      workItemId: _nullableString(json['work_item_id']),
      requestId: _nullableString(json['request_id']),
      revision: revisionValue.toInt(),
      updatedAt: updatedAt,
      turnStartedAt: turnStartedAt,
      elapsedMs: elapsedMs,
      baselineReceivedAt: elapsedMs == null ? null : (receivedAt ?? DateTime.now()).toUtc(),
    );
  }

  static SessionExecutionSnapshot fromNullablePayload(
    Map<String, dynamic>? payload, {
    required String sessionId,
  }) {
    return payload == null
        ? SessionExecutionSnapshot.virtualIdle(sessionId)
        : SessionExecutionSnapshot.fromJson(
            payload,
            expectedSessionId: sessionId,
          );
  }

  bool get isExecuting => state == SessionExecutionState.running || state == SessionExecutionState.resuming;
  bool get hasActiveWork => state != SessionExecutionState.idle;
  bool get canStop => switch (state) {
    SessionExecutionState.queued ||
    SessionExecutionState.running ||
    SessionExecutionState.waiting ||
    SessionExecutionState.blocked ||
    SessionExecutionState.resuming => true,
    SessionExecutionState.idle || SessionExecutionState.stopping => false,
  };
  bool get needsUserAction => state == SessionExecutionState.blocked;
  bool get isWaiting => state == SessionExecutionState.waiting;
  bool get isStopping => state == SessionExecutionState.stopping;

  Duration? elapsedAt(DateTime now) {
    final baseline = elapsedMs;
    final receivedAt = baselineReceivedAt;
    if (baseline == null || receivedAt == null) return null;
    final locallyElapsed = now.toUtc().difference(receivedAt).inMilliseconds;
    return Duration(
      milliseconds: baseline + (locallyElapsed < 0 ? 0 : locallyElapsed),
    );
  }

  bool hasSameAuthorityAs(SessionExecutionSnapshot other) =>
      sessionId == other.sessionId &&
      state == other.state &&
      workItemId == other.workItemId &&
      requestId == other.requestId &&
      revision == other.revision &&
      updatedAt == other.updatedAt &&
      turnStartedAt == other.turnStartedAt;

  static String? _nullableString(Object? value) {
    final normalized = value?.toString().trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  @override
  List<Object?> get props => [
    sessionId,
    state,
    workItemId,
    requestId,
    revision,
    updatedAt,
    turnStartedAt,
    elapsedMs,
  ];
}
