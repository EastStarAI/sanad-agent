import 'dart:convert';

import 'package:meta/meta.dart';
import 'package:sqlite3/sqlite3.dart';
import '../persisted_runtime_state_repository.dart';
import '../agent_state_database.dart';

/// Work-item CRUD and FIFO/accessatomic transition graph for the
/// `session_work_items` table — the single durable source of truth for
/// queued and active runtime work (Gate C.1).
///
/// Shares the same `AgentStateDatabase` connection as
/// [`RuntimeStateRepository`] and other runtime repositories so that
/// cross-table cleanup operations stay atomic.
class SessionWorkItemRepository {
  final AgentStateDatabase _state;

  static const String _restorableStatesSql =
      "('queued', 'running', 'waiting', 'blocked', 'resuming')";

  Database get _db => _state.db;

  static const Map<SessionWorkState, Set<SessionWorkState>>
  _allowedTransitions = {
    SessionWorkState.queued: {
      SessionWorkState.queued,
      SessionWorkState.running,
      SessionWorkState.resuming,
      SessionWorkState.cancelled,
    },
    SessionWorkState.running: {
      SessionWorkState.queued,
      SessionWorkState.running,
      SessionWorkState.waiting,
      SessionWorkState.blocked,
      SessionWorkState.completed,
      SessionWorkState.cancelled,
    },
    SessionWorkState.waiting: {
      SessionWorkState.waiting,
      SessionWorkState.resuming,
      SessionWorkState.blocked,
      SessionWorkState.cancelled,
    },
    SessionWorkState.blocked: {
      SessionWorkState.blocked,
      SessionWorkState.resuming,
      SessionWorkState.cancelled,
    },
    SessionWorkState.resuming: {
      SessionWorkState.resuming,
      SessionWorkState.waiting,
      SessionWorkState.blocked,
      SessionWorkState.completed,
      SessionWorkState.cancelled,
    },
    SessionWorkState.completed: {SessionWorkState.completed},
    SessionWorkState.cancelled: {SessionWorkState.cancelled},
  };

  SessionWorkItemRepository(this._state);

  @visibleForTesting
  Database get db => _db;

  /// Inserts a new work item into the database.
  void insertWorkItem(
    SessionWorkItem item, {
    AgentStateTransaction? transaction,
  }) {
    final db = transaction?.db ?? _db;
    db.execute(
      '''
      INSERT INTO session_work_items (
        work_item_id, session_id, request_id, sequence,
        provider_instance_id, model_id, workspace_id,
        payload_json, attempt, state, continuation_metadata,
        created_at, updated_at
      ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
      ''',
      [
        item.workItemId,
        item.sessionId,
        item.requestId,
        item.sequence,
        item.providerInstanceId,
        item.modelId,
        item.workspaceId,
        jsonEncode(item.payload),
        item.attempt,
        item.state.name,
        jsonEncode(item.continuationMetadata),
        item.createdAt.toUtc().toIso8601String(),
        item.updatedAt.toUtc().toIso8601String(),
      ],
    );
  }

  /// Inserts a work item while assigning the next FIFO sequence atomically
  /// inside the same transaction.
  SessionWorkItem enqueueWorkItem({
    required String workItemId,
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
    String? workspaceId,
    Map<String, dynamic> payload = const {},
    int attempt = 0,
    SessionWorkState state = SessionWorkState.queued,
    Map<String, dynamic> continuationMetadata = const {},
    AgentStateTransaction? transaction,
  }) {
    SessionWorkItem enqueue(AgentStateTransaction tx) {
      final seq = _nextWorkItemSeqInTransaction(sessionId, tx: tx);
      final now = DateTime.now();
      final item = SessionWorkItem(
        workItemId: workItemId,
        sessionId: sessionId,
        requestId: requestId,
        sequence: seq,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        workspaceId: workspaceId,
        payload: payload,
        attempt: attempt,
        state: state,
        continuationMetadata: continuationMetadata,
        createdAt: now,
        updatedAt: now,
      );
      insertWorkItem(item, transaction: tx);
      return item;
    }

    return transaction == null
        ? _state.transaction(enqueue)
        : enqueue(transaction);
  }

  /// Finds a work item by ID.
  SessionWorkItem? findWorkItem(String workItemId) {
    final rows = _db.select(
      'SELECT * FROM session_work_items WHERE work_item_id = ?',
      [workItemId],
    );
    if (rows.isEmpty) return null;
    return SessionWorkItem.fromRow(rows.first);
  }

  SessionWorkItem? findByRequestId(
    String sessionId,
    String requestId, {
    AgentStateTransaction? transaction,
  }) {
    final rows = (transaction?.db ?? _db).select(
      '''SELECT * FROM session_work_items
         WHERE session_id = ? AND request_id = ? LIMIT 1''',
      [sessionId, requestId],
    );
    return rows.isEmpty ? null : SessionWorkItem.fromRow(rows.first);
  }

  /// Finds the single active (non-terminal) work item for a session, or null.
  SessionWorkItem? findActiveWorkItem(String sessionId) {
    final rows = _db.select(
      '''
      SELECT * FROM session_work_items
      WHERE session_id = ?
        AND state IN ('running', 'resuming', 'waiting', 'blocked')
      LIMIT 1
      ''',
      [sessionId],
    );
    if (rows.isEmpty) return null;
    return SessionWorkItem.fromRow(rows.first);
  }

  /// Finds all queued work items in FIFO order.
  List<SessionWorkItem> findQueuedWorkItems(String sessionId) {
    final rows = _db.select(
      '''
      SELECT * FROM session_work_items
      WHERE session_id = ?
        AND state = 'queued'
      ORDER BY sequence ASC
      ''',
      [sessionId],
    );
    return rows.map(SessionWorkItem.fromRow).toList();
  }

  /// Atomically claims the oldest queued work item for a session by moving it
  /// to [toState]. Returns the claimed item after transition, or null when no
  /// queued item exists.
  SessionWorkItem? claimNextQueuedWorkItem(
    String sessionId, {
    SessionWorkState toState = SessionWorkState.running,
    AgentStateTransaction? transaction,
  }) {
    final allowedTargets = {
      SessionWorkState.running,
      SessionWorkState.resuming,
      SessionWorkState.cancelled,
    };
    if (!allowedTargets.contains(toState)) {
      throw Exception(
        'claimNextQueuedWorkItem only supports queued -> running|resuming|cancelled',
      );
    }

    SessionWorkItem? claim(AgentStateTransaction tx) {
      final activeRows = tx.db.select(
        '''
        SELECT work_item_id FROM session_work_items
        WHERE session_id = ?
          AND state IN ('running', 'resuming', 'waiting', 'blocked')
        LIMIT 1
        ''',
        [sessionId],
      );
      if (activeRows.isNotEmpty) {
        return null;
      }

      final rows = tx.db.select(
        '''
        SELECT * FROM session_work_items
        WHERE session_id = ?
          AND state = 'queued'
        ORDER BY sequence ASC
        LIMIT 1
        ''',
        [sessionId],
      );
      if (rows.isEmpty) {
        return null;
      }

      final current = SessionWorkItem.fromRow(rows.first);
      tx.db.execute(
        '''
        UPDATE session_work_items
        SET state = ?,
            updated_at = ?
        WHERE work_item_id = ?
          AND state = 'queued'
        ''',
        [
          toState.name,
          DateTime.now().toUtc().toIso8601String(),
          current.workItemId,
        ],
      );
      final claimedRows = tx.db.select(
        'SELECT * FROM session_work_items WHERE work_item_id = ?',
        [current.workItemId],
      );
      final claimed = claimedRows.isEmpty
          ? null
          : SessionWorkItem.fromRow(claimedRows.first);
      return claimed;
    }

    return transaction == null ? _state.transaction(claim) : claim(transaction);
  }

  /// Rewrites the route for every non-terminal queued item atomically.
  void rewriteQueuedWorkItemRoute(
    String sessionId, {
    String? providerInstanceId,
    String? modelId,
    AgentStateTransaction? transaction,
  }) {
    void rewrite(AgentStateTransaction tx) {
      tx.db.execute(
        '''
        UPDATE session_work_items
        SET provider_instance_id = COALESCE(?, provider_instance_id),
            model_id = COALESCE(?, model_id),
            updated_at = ?
        WHERE session_id = ? AND state = 'queued'
        ''',
        [
          providerInstanceId,
          modelId,
          DateTime.now().toUtc().toIso8601String(),
          sessionId,
        ],
      );
    }

    transaction == null ? _state.transaction(rewrite) : rewrite(transaction);
  }

  /// Gate E.2: rewrites the provider/model route for every non-terminal work
  /// item (queued, running, waiting, blocked, resuming) atomically. Used
  /// when the user changes provider/model after a restart so all outstanding
  /// work adopts the new route instead of only queued items.
  void rewriteAllNonTerminalWorkItemRoute(
    String sessionId, {
    String? providerInstanceId,
    String? modelId,
    AgentStateTransaction? transaction,
  }) {
    void rewrite(AgentStateTransaction tx) {
      tx.db.execute(
        '''
        UPDATE session_work_items
        SET provider_instance_id = COALESCE(?, provider_instance_id),
            model_id = COALESCE(?, model_id),
            updated_at = ?
        WHERE session_id = ?
          AND state IN ('queued', 'running', 'waiting', 'blocked', 'resuming')
        ''',
        [
          providerInstanceId,
          modelId,
          DateTime.now().toUtc().toIso8601String(),
          sessionId,
        ],
      );
    }

    transaction == null ? _state.transaction(rewrite) : rewrite(transaction);
  }

  /// Finds all work items for a session.
  List<SessionWorkItem> findAllWorkItems(String sessionId) {
    final rows = _db.select(
      'SELECT * FROM session_work_items WHERE session_id = ? ORDER BY sequence ASC',
      [sessionId],
    );
    return rows.map(SessionWorkItem.fromRow).toList();
  }

  /// Finds only work that startup recovery can reconstruct or reclassify.
  /// Terminal history remains queryable through [findAllWorkItems] but is not
  /// decoded during daemon bootstrap.
  List<SessionWorkItem> findRestorableWorkItems(String sessionId) {
    final rows = _db.select(
      '''SELECT * FROM session_work_items
         WHERE session_id = ? AND state IN $_restorableStatesSql
         ORDER BY sequence ASC''',
      [sessionId],
    );
    return rows.map(SessionWorkItem.fromRow).toList();
  }

  /// Finds all distinct session IDs that have work items.
  List<String> findAllSessionIdsWithWorkItems() {
    final rows = _db.select(
      'SELECT DISTINCT session_id FROM session_work_items',
    );
    return rows.map((r) => r['session_id'] as String).toList();
  }

  /// Finds sessions that have queued or active work relevant to restart.
  List<String> findSessionIdsWithRestorableWorkItems() {
    final rows = _db.select(
      '''SELECT DISTINCT session_id FROM session_work_items
         WHERE state IN $_restorableStatesSql''',
    );
    return rows.map((row) => row['session_id'] as String).toList();
  }

  /// Performs an atomic state transition with validation.
  void transitionWorkItemState({
    required String workItemId,
    required SessionWorkState fromState,
    required SessionWorkState toState,
    int? attempt,
    Map<String, dynamic>? continuationMetadata,
    String? providerInstanceId,
    String? modelId,
    AgentStateTransaction? transaction,
  }) {
    void transition(AgentStateTransaction tx) {
      final rows = tx.db.select(
        'SELECT state, attempt, continuation_metadata, provider_instance_id, model_id FROM session_work_items WHERE work_item_id = ?',
        [workItemId],
      );
      if (rows.isEmpty) {
        throw Exception('Work item $workItemId not found');
      }
      final current = rows.first;
      final currentState = current['state'] as String;
      if (currentState != fromState.name) {
        throw Exception(
          'Invalid state transition for $workItemId: expected ${fromState.name}, got $currentState',
        );
      }
      final allowedTargets = _allowedTransitions[fromState] ?? const {};
      if (!allowedTargets.contains(toState)) {
        throw Exception(
          'Transition ${fromState.name} -> ${toState.name} is not allowed for $workItemId',
        );
      }

      final nextAttempt = attempt ?? current['attempt'] as int;
      final nextMeta = continuationMetadata != null
          ? jsonEncode(continuationMetadata)
          : current['continuation_metadata'] as String;
      final nextProvider =
          providerInstanceId ?? current['provider_instance_id'] as String?;
      final nextModel = modelId ?? current['model_id'] as String?;

      tx.db.execute(
        '''
        UPDATE session_work_items
        SET state = ?,
            attempt = ?,
            continuation_metadata = ?,
            provider_instance_id = ?,
            model_id = ?,
            updated_at = ?
        WHERE work_item_id = ?
        ''',
        [
          toState.name,
          nextAttempt,
          nextMeta,
          nextProvider,
          nextModel,
          DateTime.now().toUtc().toIso8601String(),
          workItemId,
        ],
      );
    }

    transaction == null
        ? _state.transaction(transition)
        : transition(transaction);
  }

  /// Directly updates other mutable fields of a work item.
  void updateWorkItem(
    SessionWorkItem item, {
    AgentStateTransaction? transaction,
  }) {
    final db = transaction?.db ?? _db;
    db.execute(
      '''
      UPDATE session_work_items
      SET provider_instance_id = ?,
          model_id = ?,
          workspace_id = ?,
          payload_json = ?,
          attempt = ?,
          state = ?,
          continuation_metadata = ?,
          updated_at = ?
      WHERE work_item_id = ?
      ''',
      [
        item.providerInstanceId,
        item.modelId,
        item.workspaceId,
        jsonEncode(item.payload),
        item.attempt,
        item.state.name,
        jsonEncode(item.continuationMetadata),
        DateTime.now().toUtc().toIso8601String(),
        item.workItemId,
      ],
    );
  }

  /// Deletes a specific work item.
  void deleteWorkItem(String workItemId) {
    _db.execute('DELETE FROM session_work_items WHERE work_item_id = ?', [
      workItemId,
    ]);
  }

  /// Deletes all work items for a session.
  void deleteAllWorkItemsForSession(String sessionId) {
    _db.execute('DELETE FROM session_work_items WHERE session_id = ?', [
      sessionId,
    ]);
  }

  /// Returns the next sequence number for a session.
  int nextWorkItemSeq(String sessionId) {
    return _nextWorkItemSeqInTransaction(sessionId);
  }

  /// Cancels all active and queued work items for a session.
  void cancelAllActiveAndQueuedWorkItems(
    String sessionId, {
    AgentStateTransaction? transaction,
  }) {
    void cancel(AgentStateTransaction tx) {
      tx.db.execute(
        '''
      UPDATE session_work_items
      SET state = 'cancelled',
          updated_at = ?
      WHERE session_id = ?
        AND state IN ('queued', 'running', 'waiting', 'blocked', 'resuming')
      ''',
        [DateTime.now().toUtc().toIso8601String(), sessionId],
      );
    }

    transaction == null ? _state.transaction(cancel) : cancel(transaction);
  }

  void cancelWorkItems(
    Iterable<String> workItemIds, {
    AgentStateTransaction? transaction,
  }) {
    final ids = workItemIds.toSet().toList(growable: false);
    if (ids.isEmpty) return;
    void cancel(AgentStateTransaction tx) {
      final placeholders = List.filled(ids.length, '?').join(', ');
      tx.db.execute(
        '''
        UPDATE session_work_items
        SET state = 'cancelled', updated_at = ?
        WHERE work_item_id IN ($placeholders)
          AND state IN ('queued', 'running', 'waiting', 'blocked', 'resuming')
        ''',
        [DateTime.now().toUtc().toIso8601String(), ...ids],
      );
    }

    transaction == null ? _state.transaction(cancel) : cancel(transaction);
  }

  bool cancelQueuedWorkItem(
    String sessionId,
    String requestId, {
    AgentStateTransaction? transaction,
  }) {
    final db = transaction?.db ?? _db;
    db.execute(
      '''UPDATE session_work_items
         SET state = 'cancelled', updated_at = ?
         WHERE session_id = ? AND request_id = ? AND state = 'queued' ''',
      [DateTime.now().toUtc().toIso8601String(), sessionId, requestId],
    );
    return db.updatedRows == 1;
  }

  /// Deletes rows whose `session_id` no longer exists in `sessions`.
  int cleanupOrphanedWorkItems() {
    _db.execute('BEGIN TRANSACTION');
    try {
      final before = _db.select('''
        SELECT COUNT(*) AS count
        FROM session_work_items wi
        WHERE NOT EXISTS (
          SELECT 1 FROM sessions s WHERE s.session_id = wi.session_id
        )
        ''');
      final count = before.first['count'] as int;
      if (count > 0) {
        _db.execute('''
          DELETE FROM session_work_items
          WHERE NOT EXISTS (
            SELECT 1 FROM sessions s WHERE s.session_id = session_work_items.session_id
          )
          ''');
      }
      _db.execute('COMMIT');
      return count;
    } catch (_) {
      _db.execute('ROLLBACK');
      rethrow;
    }
  }

  int _nextWorkItemSeqInTransaction(
    String sessionId, {
    AgentStateTransaction? tx,
  }) {
    final rows = (tx?.db ?? _db).select(
      'SELECT MAX(sequence) AS max_seq FROM session_work_items WHERE session_id = ?',
      [sessionId],
    );
    final maxSeq = rows.first['max_seq'];
    if (maxSeq == null) return 0;
    return (maxSeq as int) + 1;
  }
}
