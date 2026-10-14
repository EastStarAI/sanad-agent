import 'dart:convert';

import '../../models/pending_steer_record.dart';
import '../../models/stop_recovery_outcome.dart';
import '../agent_state_database.dart';

class PendingInputRepository {
  final AgentStateDatabase _state;

  PendingInputRepository(this._state);

  PendingSteerRecord insertPending({
    required String sessionId,
    required String requestId,
    required String runId,
    required int generation,
    required String text,
    required DateTime receivedAt,
    AgentStateTransaction? transaction,
  }) {
    PendingSteerRecord insert(AgentStateTransaction tx) {
      tx.db.execute(
        '''
        INSERT INTO session_pending_steers (
          session_id, request_id, run_id, generation, text, received_at,
          state, revision, updated_at
        ) VALUES (?, ?, ?, ?, ?, ?, 'pending', 1, ?)
        ON CONFLICT(session_id, request_id) DO NOTHING
        ''',
        [
          sessionId,
          requestId,
          runId,
          generation,
          text,
          receivedAt.toUtc().toIso8601String(),
          DateTime.now().toUtc().toIso8601String(),
        ],
      );
      return find(sessionId, requestId, transaction: tx)!;
    }

    return transaction == null
        ? _state.transaction(insert)
        : insert(transaction);
  }

  PendingSteerRecord? find(
    String sessionId,
    String requestId, {
    AgentStateTransaction? transaction,
  }) {
    final rows = (transaction?.db ?? _state.db).select(
      '''SELECT * FROM session_pending_steers
         WHERE session_id = ? AND request_id = ? LIMIT 1''',
      [sessionId, requestId],
    );
    return rows.isEmpty ? null : PendingSteerRecord.fromRow(rows.first);
  }

  List<PendingSteerRecord> findForSession(
    String sessionId, {
    bool includeTerminal = false,
    AgentStateTransaction? transaction,
  }) {
    final terminalFilter = includeTerminal
        ? ''
        : "AND state IN ('pending', 'delivering')";
    final rows = (transaction?.db ?? _state.db).select(
      '''SELECT * FROM session_pending_steers
         WHERE session_id = ? $terminalFilter
         ORDER BY received_at ASC, request_id ASC''',
      [sessionId],
    );
    return rows.map(PendingSteerRecord.fromRow).toList();
  }

  PendingSteerMutation<PendingSteerReserveOutcome> reserve({
    required String sessionId,
    required String requestId,
    required String runId,
    required int generation,
  }) {
    return _state.transaction((tx) {
      final current = find(sessionId, requestId, transaction: tx);
      if (current == null) {
        return const PendingSteerMutation(
          PendingSteerReserveOutcome.notFound,
          null,
        );
      }
      if (current.runId != runId || current.generation != generation) {
        return PendingSteerMutation(
          PendingSteerReserveOutcome.staleOwner,
          current,
        );
      }
      final outcome = switch (current.state) {
        PendingSteerState.pending => PendingSteerReserveOutcome.reserved,
        PendingSteerState.delivering =>
          PendingSteerReserveOutcome.alreadyReserved,
        PendingSteerState.delivered =>
          PendingSteerReserveOutcome.alreadyDelivered,
        PendingSteerState.cancelled ||
        PendingSteerState.recovered => PendingSteerReserveOutcome.cancelled,
      };
      if (outcome != PendingSteerReserveOutcome.reserved) {
        return PendingSteerMutation(outcome, current);
      }
      return PendingSteerMutation(
        outcome,
        _transition(current, PendingSteerState.delivering, tx),
      );
    });
  }

  PendingSteerMutation<PendingSteerCancelOutcome> cancel({
    required String sessionId,
    required String requestId,
    required String runId,
    required int generation,
  }) {
    return _state.transaction((tx) {
      final current = find(sessionId, requestId, transaction: tx);
      if (current == null) {
        return const PendingSteerMutation(
          PendingSteerCancelOutcome.notFound,
          null,
        );
      }
      if (current.runId != runId || current.generation != generation) {
        return PendingSteerMutation(
          PendingSteerCancelOutcome.staleOwner,
          current,
        );
      }
      final outcome = switch (current.state) {
        PendingSteerState.pending => PendingSteerCancelOutcome.cancelled,
        PendingSteerState.delivering =>
          PendingSteerCancelOutcome.deliveryInProgress,
        PendingSteerState.delivered =>
          PendingSteerCancelOutcome.alreadyDelivered,
        PendingSteerState.cancelled || PendingSteerState.recovered =>
          PendingSteerCancelOutcome.alreadyCancelled,
      };
      if (outcome != PendingSteerCancelOutcome.cancelled) {
        return PendingSteerMutation(outcome, current);
      }
      return PendingSteerMutation(
        outcome,
        _transition(current, PendingSteerState.cancelled, tx),
      );
    });
  }

  PendingSteerRecord? markDelivered({
    required String sessionId,
    required String requestId,
    required String runId,
    required int generation,
    String? messageId,
    String? turnId,
    String? anchorMessageId,
    String? anchorToolCallId,
    int? historyRevision,
    AgentStateTransaction? transaction,
  }) {
    PendingSteerRecord? commit(AgentStateTransaction tx) {
      final current = find(sessionId, requestId, transaction: tx);
      if (current == null ||
          current.runId != runId ||
          current.generation != generation ||
          current.state != PendingSteerState.delivering) {
        return null;
      }
      final now = DateTime.now().toUtc().toIso8601String();
      tx.db.execute(
        '''UPDATE session_pending_steers
           SET state = 'delivered', revision = revision + 1, updated_at = ?,
               message_id = ?, turn_id = ?, anchor_message_id = ?,
               anchor_tool_call_id = ?, history_revision = ?
           WHERE session_id = ? AND request_id = ?''',
        [
          now,
          messageId,
          turnId,
          anchorMessageId,
          anchorToolCallId,
          historyRevision,
          sessionId,
          requestId,
        ],
      );
      return find(sessionId, requestId, transaction: tx);
    }

    return transaction == null
        ? _state.transaction(commit)
        : commit(transaction);
  }

  PendingSteerRecord? releaseDeliveryAfterFailure({
    required String sessionId,
    required String requestId,
    required String runId,
    required int generation,
  }) {
    return _state.transaction((tx) {
      final current = find(sessionId, requestId, transaction: tx);
      if (current == null ||
          current.runId != runId ||
          current.generation != generation ||
          current.state != PendingSteerState.delivering) {
        return null;
      }
      final snapshot = tx.db.select(
        'SELECT state FROM session_execution_snapshots WHERE session_id = ?',
        [sessionId],
      );
      final stopping =
          snapshot.isNotEmpty && snapshot.first['state'] == 'stopping';
      final released = _transition(
        current,
        stopping ? PendingSteerState.recovered : PendingSteerState.pending,
        tx,
      );
      if (stopping) {
        _appendRecoveredToLatestStopOutcome(released, tx);
      }
      return released;
    });
  }

  void _appendRecoveredToLatestStopOutcome(
    PendingSteerRecord record,
    AgentStateTransaction transaction,
  ) {
    final rows = transaction.db.select(
      '''SELECT stop_request_id, items_json
         FROM session_stop_recovery_outcomes
         WHERE session_id = ? AND acknowledged_at IS NULL
         ORDER BY created_at DESC LIMIT 1''',
      [record.sessionId],
    );
    if (rows.isEmpty) return;
    final row = rows.first;
    final items = (jsonDecode(row['items_json'] as String) as List)
        .map((item) => Map<String, dynamic>.from(item as Map))
        .toList();
    if (items.any((item) => item['request_id'] == record.requestId)) return;
    items.add(
      StopRecoveryItem(
        requestId: record.requestId,
        source: 'pending_steer',
        text: record.text,
        receivedAt: record.receivedAt,
      ).toJson(),
    );
    transaction.db.execute(
      '''UPDATE session_stop_recovery_outcomes SET items_json = ?
         WHERE stop_request_id = ?''',
      [jsonEncode(items), row['stop_request_id']],
    );
  }

  List<PendingSteerRecord> recoverPendingForStop(
    String sessionId, {
    required AgentStateTransaction transaction,
  }) {
    final records = findForSession(
      sessionId,
      transaction: transaction,
    ).where((record) => record.state == PendingSteerState.pending).toList();
    return records
        .map(
          (record) =>
              _transition(record, PendingSteerState.recovered, transaction),
        )
        .toList();
  }

  StopRecoveryOutcome saveStopOutcome({
    required String sessionId,
    required String stopRequestId,
    required List<StopRecoveryItem> items,
    String recoveryReason = 'user_stop',
    bool claimRequired = false,
    String? recoveryOwnerToken,
    AgentStateTransaction? transaction,
  }) {
    StopRecoveryOutcome save(AgentStateTransaction tx) {
      final createdAt = DateTime.now().toUtc();
      tx.db.execute(
        '''
        INSERT INTO session_stop_recovery_outcomes (
          stop_request_id, session_id, items_json, created_at, acknowledged_at,
          recovery_reason, claim_required, claimed_by
        ) VALUES (?, ?, ?, ?, NULL, ?, ?, ?)
        ON CONFLICT(stop_request_id) DO NOTHING
        ''',
        [
          stopRequestId,
          sessionId,
          jsonEncode(items.map((item) => item.toJson()).toList()),
          createdAt.toIso8601String(),
          recoveryReason,
          claimRequired ? 1 : 0,
          recoveryOwnerToken,
        ],
      );
      return findStopOutcome(stopRequestId, transaction: tx)!;
    }

    return transaction == null ? _state.transaction(save) : save(transaction);
  }

  StopRecoveryOutcome? findStopOutcome(
    String stopRequestId, {
    AgentStateTransaction? transaction,
  }) {
    final rows = (transaction?.db ?? _state.db).select(
      '''SELECT * FROM session_stop_recovery_outcomes
         WHERE stop_request_id = ? LIMIT 1''',
      [stopRequestId],
    );
    if (rows.isEmpty) return null;
    final row = rows.first;
    final decoded = jsonDecode(row['items_json'] as String) as List;
    return StopRecoveryOutcome(
      sessionId: row['session_id'] as String,
      stopRequestId: row['stop_request_id'] as String,
      items: decoded
          .map(
            (item) => StopRecoveryItem.fromJson(
              Map<String, dynamic>.from(item as Map),
            ),
          )
          .toList(),
      createdAt: DateTime.parse(row['created_at'] as String).toUtc(),
      acknowledgedAt: row['acknowledged_at'] == null
          ? null
          : DateTime.parse(row['acknowledged_at'] as String).toUtc(),
      recoveryReason: row['recovery_reason'] as String? ?? 'user_stop',
      claimRequired: (row['claim_required'] as int? ?? 0) == 1,
      claimedBy: row['claimed_by'] as String?,
    );
  }

  StopRecoveryOutcome? claimStopOutcome({
    required String sessionId,
    required String stopRequestId,
    required String claimantId,
  }) {
    return _state.transaction((tx) {
      tx.db.execute(
        '''UPDATE session_stop_recovery_outcomes
           SET claimed_by = ?
           WHERE session_id = ? AND stop_request_id = ?
             AND acknowledged_at IS NULL AND claim_required = 1
             AND (claimed_by IS NULL OR claimed_by = ?)''',
        [claimantId, sessionId, stopRequestId, claimantId],
      );
      final outcome = findStopOutcome(stopRequestId, transaction: tx);
      if (outcome == null || outcome.claimedBy != claimantId) return null;
      return StopRecoveryOutcome(
        sessionId: outcome.sessionId,
        stopRequestId: outcome.stopRequestId,
        items: outcome.items,
        createdAt: outcome.createdAt,
        acknowledgedAt: outcome.acknowledgedAt,
        recoveryReason: outcome.recoveryReason,
        claimRequired: false,
        claimedBy: claimantId,
      );
    });
  }

  StopRecoveryOutcome? findUnacknowledgedForSession(String sessionId) {
    final rows = _state.db.select(
      '''SELECT stop_request_id FROM session_stop_recovery_outcomes
         WHERE session_id = ? AND acknowledged_at IS NULL
         ORDER BY created_at DESC LIMIT 1''',
      [sessionId],
    );
    return rows.isEmpty
        ? null
        : findStopOutcome(rows.first['stop_request_id'] as String);
  }

  bool acknowledgeStopOutcome(
    String sessionId,
    String stopRequestId, {
    String? claimantId,
    String? recoveryOwnerToken,
  }) {
    return _state.transaction((tx) {
      final current = findStopOutcome(stopRequestId, transaction: tx);
      if (current == null || current.sessionId != sessionId) return false;
      final presentedOwner = current.recoveryReason == 'user_stop'
          ? recoveryOwnerToken
          : claimantId;
      if (current.claimedBy == null || current.claimedBy != presentedOwner) {
        return false;
      }
      if (current.isAcknowledged) return true;
      tx.db.execute(
        '''UPDATE session_stop_recovery_outcomes
           SET acknowledged_at = ?, items_json = '[]'
           WHERE session_id = ? AND stop_request_id = ? AND acknowledged_at IS NULL''',
        [DateTime.now().toUtc().toIso8601String(), sessionId, stopRequestId],
      );
      return tx.db.updatedRows == 1;
    });
  }

  List<StopRecoveryOutcome> reconcileAfterRestart() {
    final sessionRows = _state.db.select(
      '''SELECT DISTINCT session_id FROM session_pending_steers
         WHERE state IN ('pending', 'delivering')''',
    );
    final outcomes = <StopRecoveryOutcome>[];
    for (final sessionRow in sessionRows) {
      final sessionId = sessionRow['session_id'] as String;
      final outcome = _state.transaction((tx) {
        final active = findForSession(sessionId, transaction: tx);
        final recovered = <PendingSteerRecord>[];
        for (final record in active) {
          if (record.state == PendingSteerState.delivering &&
              _historyContainsRequestId(
                sessionId,
                record.requestId,
                transaction: tx,
              )) {
            _transition(record, PendingSteerState.delivered, tx);
          } else {
            recovered.add(_transition(record, PendingSteerState.recovered, tx));
          }
        }
        if (recovered.isEmpty) return null;
        final stopRequestId =
            'restart_recovery_${sessionId}_${recovered.first.requestId}';
        return saveStopOutcome(
          sessionId: sessionId,
          stopRequestId: stopRequestId,
          items: recovered
              .map(
                (record) => StopRecoveryItem(
                  requestId: record.requestId,
                  source: 'pending_steer',
                  text: record.text,
                  receivedAt: record.receivedAt,
                ),
              )
              .toList(),
          recoveryReason: 'daemon_restart',
          claimRequired: true,
          transaction: tx,
        );
      });
      if (outcome != null) outcomes.add(outcome);
    }
    return outcomes;
  }

  bool _historyContainsRequestId(
    String sessionId,
    String requestId, {
    required AgentStateTransaction transaction,
  }) {
    final rows = transaction.db.select(
      'SELECT data FROM messages WHERE session_id = ?',
      [sessionId],
    );
    for (final row in rows) {
      final decoded = jsonDecode(row['data'] as String);
      if (_containsRequestId(decoded, requestId)) return true;
    }
    return false;
  }

  bool _containsRequestId(Object? value, String requestId) {
    if (value is Map) {
      if (value['request_id']?.toString() == requestId) return true;
      return value.values.any((entry) => _containsRequestId(entry, requestId));
    }
    if (value is List) {
      return value.any((entry) => _containsRequestId(entry, requestId));
    }
    return false;
  }

  PendingSteerRecord _transition(
    PendingSteerRecord current,
    PendingSteerState next,
    AgentStateTransaction tx,
  ) {
    final now = DateTime.now().toUtc();
    tx.db.execute(
      '''UPDATE session_pending_steers
         SET state = ?, revision = revision + 1, updated_at = ?
         WHERE session_id = ? AND request_id = ? AND state = ? AND revision = ?''',
      [
        next.name,
        now.toIso8601String(),
        current.sessionId,
        current.requestId,
        current.state.name,
        current.revision,
      ],
    );
    if (tx.db.updatedRows != 1) {
      throw StateError('Pending steer changed concurrently');
    }
    return find(current.sessionId, current.requestId, transaction: tx)!;
  }
}
