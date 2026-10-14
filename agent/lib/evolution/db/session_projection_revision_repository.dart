import 'package:sqlite3/sqlite3.dart';

import 'agent_state_database.dart';

/// Monotonic projection revision bumped only after successful compaction activation.
///
/// Interface layers (53d/53e) observe [SessionProjectionRevision] to reload model
/// projection without polling canonical message rows.
class SessionProjectionRevision {
  final int value;

  const SessionProjectionRevision(this.value)
      : assert(value >= 0, 'projection revision must be non-negative');

  SessionProjectionRevision next() => SessionProjectionRevision(value + 1);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is SessionProjectionRevision &&
          runtimeType == other.runtimeType &&
          value == other.value;

  @override
  int get hashCode => value.hashCode;
}

class SessionProjectionRevisionRepository {
  final AgentStateDatabase _state;

  SessionProjectionRevisionRepository(this._state);

  SessionProjectionRevision? read(String sessionId) {
    final rows = _state.db.select(
      'SELECT projection_revision FROM sessions WHERE session_id = ?',
      [sessionId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return SessionProjectionRevision(rows.first['projection_revision'] as int);
  }

  SessionProjectionRevision? readInTransaction(
    AgentStateTransaction transaction,
    String sessionId,
  ) {
    final rows = transaction.db.select(
      'SELECT projection_revision FROM sessions WHERE session_id = ?',
      [sessionId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return SessionProjectionRevision(rows.first['projection_revision'] as int);
  }

  void bumpInTransaction(
    AgentStateTransaction transaction,
    String sessionId, {
    int by = 1,
  }) {
    bumpDatabase(transaction.db, sessionId, by: by);
  }

  static void bumpDatabase(
    Database db,
    String sessionId, {
    int by = 1,
  }) {
    assert(by > 0, 'projection revision bump must be positive');
    db.execute(
      '''
      UPDATE sessions
      SET projection_revision = projection_revision + ?, updated_at = ?
      WHERE session_id = ?
      ''',
      [
        by,
        DateTime.now().toUtc().toIso8601String(),
        sessionId,
      ],
    );
  }
}
