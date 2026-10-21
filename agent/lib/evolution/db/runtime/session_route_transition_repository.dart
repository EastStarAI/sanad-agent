import '../../models/session_route_transition.dart';
import '../agent_state_database.dart';

/// Sole SQL owner of `session_route_transitions`.
class SessionRouteTransitionRepository {
  final AgentStateDatabase _state;

  SessionRouteTransitionRepository(this._state);

  void insert(
    SessionRouteTransition transition, {
    AgentStateTransaction? transaction,
  }) {
    if (transaction != null) {
      _insertInTransaction(transaction, transition);
      return;
    }
    _state.transaction((tx) => _insertInTransaction(tx, transition));
  }

  void _insertInTransaction(
    AgentStateTransaction transaction,
    SessionRouteTransition transition,
  ) {
    transaction.db.execute(
      '''
      INSERT INTO session_route_transitions (
        session_id, route_revision, event_id, source,
        previous_provider_instance_id, provider_instance_id,
        previous_provider_display_name, provider_display_name,
        model, reason, request_id, anchor_message_id, created_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        transition.sessionId,
        transition.routeRevision,
        transition.eventId,
        transition.source.storageValue,
        transition.previousProviderInstanceId,
        transition.providerInstanceId,
        transition.previousProviderDisplayName,
        transition.providerDisplayName,
        transition.model,
        transition.reason,
        transition.requestId,
        transition.anchorMessageId,
        transition.createdAt.toUtc().toIso8601String(),
      ],
    );
  }

  SessionRouteTransition? findByRevision(String sessionId, int routeRevision) {
    final rows = _state.db.select(
      'SELECT * FROM session_route_transitions '
      'WHERE session_id = ? AND route_revision = ?',
      [sessionId, routeRevision],
    );
    if (rows.isEmpty) return null;
    return SessionRouteTransition.fromRow(rows.first);
  }

  SessionRouteTransition? findByEventId(String eventId) {
    final rows = _state.db.select(
      'SELECT * FROM session_route_transitions WHERE event_id = ?',
      [eventId],
    );
    if (rows.isEmpty) return null;
    return SessionRouteTransition.fromRow(rows.first);
  }

  List<SessionRouteTransition> findForSession(String sessionId) {
    final rows = _state.db.select(
      'SELECT * FROM session_route_transitions '
      'WHERE session_id = ? ORDER BY route_revision ASC',
      [sessionId],
    );
    return rows.map(SessionRouteTransition.fromRow).toList(growable: false);
  }
}
