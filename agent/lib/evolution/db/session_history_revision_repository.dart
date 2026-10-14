import 'package:sqlite3/sqlite3.dart';

import 'agent_state_database.dart';
import '../models/compaction_operation_record.dart';

/// Reads and bumps monotonic `sessions.history_revision` for compaction CAS.
class SessionHistoryRevisionRepository {
  final AgentStateDatabase _state;

  SessionHistoryRevisionRepository(this._state);

  SessionHistoryRevision? read(String sessionId) {
    final rows = _state.db.select(
      'SELECT history_revision FROM sessions WHERE session_id = ?',
      [sessionId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return SessionHistoryRevision(rows.first['history_revision'] as int);
  }

  SessionHistoryRevision? readInTransaction(
    AgentStateTransaction transaction,
    String sessionId,
  ) {
    final rows = transaction.db.select(
      'SELECT history_revision FROM sessions WHERE session_id = ?',
      [sessionId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return SessionHistoryRevision(rows.first['history_revision'] as int);
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
    assert(by > 0, 'history revision bump must be positive');
    db.execute(
      '''
      UPDATE sessions
      SET history_revision = history_revision + ?, updated_at = ?
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
