enum SessionExecutionState {
  idle,
  queued,
  running,
  waiting,
  blocked,
  resuming,
  stopping,
}

class SessionExecutionSnapshot {
  static final DateTime virtualIdleUpdatedAt =
      DateTime.fromMillisecondsSinceEpoch(0, isUtc: true);

  final String sessionId;
  final SessionExecutionState state;
  final String? workItemId;
  final String? requestId;
  final int revision;
  final DateTime updatedAt;
  final DateTime? turnStartedAt;

  const SessionExecutionSnapshot({
    required this.sessionId,
    required this.state,
    required this.workItemId,
    required this.requestId,
    required this.revision,
    required this.updatedAt,
    this.turnStartedAt,
  });

  factory SessionExecutionSnapshot.virtualIdle(String sessionId) {
    return SessionExecutionSnapshot(
      sessionId: sessionId,
      state: SessionExecutionState.idle,
      workItemId: null,
      requestId: null,
      revision: 0,
      updatedAt: virtualIdleUpdatedAt,
      turnStartedAt: null,
    );
  }

  factory SessionExecutionSnapshot.fromRow(Map<String, Object?> row) {
    return SessionExecutionSnapshot(
      sessionId: row['session_id']! as String,
      state: SessionExecutionState.values.byName(row['state']! as String),
      workItemId: row['work_item_id'] as String?,
      requestId: row['request_id'] as String?,
      revision: row['revision']! as int,
      updatedAt: DateTime.parse(row['updated_at']! as String).toUtc(),
      turnStartedAt: _parseOptionalDateTime(row['turn_started_at']),
    );
  }

  factory SessionExecutionSnapshot.fromPayload(Map<String, dynamic> payload) {
    final sessionId = payload['session_id'];
    final state = payload['state'];
    final revision = payload['revision'];
    final updatedAt = payload['updated_at'];
    if (sessionId is! String || sessionId.isEmpty) {
      throw const FormatException('execution snapshot requires session_id');
    }
    if (state is! String) {
      throw const FormatException('execution snapshot requires state');
    }
    final parsedState = SessionExecutionState.values
        .where((candidate) => candidate.name == state)
        .firstOrNull;
    if (parsedState == null) {
      throw FormatException('unknown execution state: $state');
    }
    if (revision is! int || revision < 0) {
      throw const FormatException(
        'execution snapshot requires a non-negative revision',
      );
    }
    if (updatedAt is! String) {
      throw const FormatException('execution snapshot requires updated_at');
    }
    final parsedUpdatedAt = DateTime.tryParse(updatedAt);
    if (parsedUpdatedAt == null) {
      throw const FormatException('execution snapshot updated_at is invalid');
    }
    final workItemId = payload['work_item_id'];
    final requestId = payload['request_id'];
    if (workItemId != null && workItemId is! String) {
      throw const FormatException('execution snapshot work_item_id is invalid');
    }
    if (requestId != null && requestId is! String) {
      throw const FormatException('execution snapshot request_id is invalid');
    }
    final turnStartedAt = _parseOptionalDateTime(payload['turn_started_at']);
    return SessionExecutionSnapshot(
      sessionId: sessionId,
      state: parsedState,
      workItemId: workItemId as String?,
      requestId: requestId as String?,
      revision: revision,
      updatedAt: parsedUpdatedAt.toUtc(),
      turnStartedAt: turnStartedAt,
    );
  }

  int? elapsedMsAt(DateTime observedAt) {
    final startedAt = turnStartedAt;
    if (startedAt == null) return null;
    final elapsed = observedAt.toUtc().difference(startedAt).inMilliseconds;
    return elapsed < 0 ? 0 : elapsed;
  }

  Map<String, dynamic> toPayload({DateTime? observedAt}) {
    final observation = (observedAt ?? DateTime.now()).toUtc();
    return {
      'session_id': sessionId,
      'state': state.name,
      'work_item_id': workItemId,
      'request_id': requestId,
      'revision': revision,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      if (turnStartedAt != null) ...{
        'turn_started_at': turnStartedAt!.toUtc().toIso8601String(),
        'elapsed_ms': elapsedMsAt(observation),
      },
    };
  }

  static DateTime? _parseOptionalDateTime(Object? value) {
    if (value == null) return null;
    final parsed = DateTime.tryParse(value.toString());
    if (parsed == null) {
      throw const FormatException(
        'execution snapshot turn_started_at is invalid',
      );
    }
    return parsed.toUtc();
  }
}

class SessionExecutionSnapshotChange {
  final SessionExecutionSnapshot snapshot;
  final bool changed;

  const SessionExecutionSnapshotChange({
    required this.snapshot,
    required this.changed,
  });
}
