import 'package:sqlite3/sqlite3.dart';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';

import '../models/compaction_operation_codec.dart';
import '../models/compaction_operation_record.dart';
import 'agent_state_database.dart';
import 'session_history_revision_repository.dart';
import 'session_projection_revision_repository.dart';

enum CompactionClaimOutcome { claimed, compactionInProgress, sessionNotFound }

class CompactionClaimResult {
  final CompactionClaimOutcome outcome;
  final CompactionOperationRecord? record;

  const CompactionClaimResult({required this.outcome, this.record});
}

enum CompactionTerminalOutcome {
  completed,
  failed,
  staleOperation,
  sourceRevisionStale,
  supersededByNewerBoundary,
  missingMessageRows,
}

class CompactionTerminalResult {
  final CompactionTerminalOutcome outcome;
  final CompactionOperationRecord? record;

  const CompactionTerminalResult({required this.outcome, this.record});
}

/// Sole SQL owner of `session_compaction_operations` (Plan 53b).
class CompactionBoundaryRepository {
  final AgentStateDatabase _state;
  final SessionHistoryRevisionRepository _historyRevisions;

  CompactionBoundaryRepository(this._state, this._historyRevisions);

  CompactionClaimResult tryClaim({
    required String compactionId,
    required String sessionId,
    required CompactionTrigger trigger,
    required CompactionMessageRange sourceRange,
    required CompactionMessageRange retainedTailRange,
    required RouteSignature routeSignature,
    required DateTime startedAt,
  }) {
    return _state.transaction((tx) {
      final revision = _historyRevisions.readInTransaction(tx, sessionId);
      if (revision == null) {
        return const CompactionClaimResult(
          outcome: CompactionClaimOutcome.sessionNotFound,
        );
      }
      final record = CompactionOperationRecord(
        compactionId: compactionId,
        sessionId: sessionId,
        trigger: trigger,
        status: CompactionStatus.started,
        sourceHistoryRevision: revision.toCompactionRevision(),
        sourceRange: sourceRange,
        retainedTailRange: retainedTailRange,
        routeSignature: routeSignature,
        startedAt: startedAt,
      );
      try {
        tx.db.execute('''
          INSERT INTO session_compaction_operations (
            compaction_id, session_id, trigger, status,
            source_history_revision,
            source_start_message_id, source_end_message_id,
            tail_start_message_id, tail_end_message_id,
            provider_instance_id, model_id, template_id, protocol,
            normalized_base_url, config_revision, credential_revision,
            started_at
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
          ''', CompactionOperationCodec.insertStartedParams(record: record));
      } on SqliteException catch (error) {
        if (_isStartedConflict(error)) {
          return const CompactionClaimResult(
            outcome: CompactionClaimOutcome.compactionInProgress,
          );
        }
        rethrow;
      }
      return CompactionClaimResult(
        outcome: CompactionClaimOutcome.claimed,
        record: record,
      );
    });
  }

  CompactionTerminalResult completeStarted({
    required CompactionCandidate candidate,
    required DateTime startedAt,
    required DateTime completedAt,
  }) {
    return _state.transaction((tx) {
      final startedRows = tx.db.select(
        '''
        SELECT * FROM session_compaction_operations
        WHERE compaction_id = ? AND status = ?
        ''',
        [candidate.compactionId, CompactionStatus.started.wireValue],
      );
      if (startedRows.isEmpty) {
        return const CompactionTerminalResult(
          outcome: CompactionTerminalOutcome.staleOperation,
        );
      }
      final started = CompactionOperationCodec.fromRow(startedRows);

      final newerCompleted = tx.db.select(
        '''
        SELECT 1 FROM session_compaction_operations
        WHERE session_id = ? AND status = ? AND compaction_id != ?
          AND completed_at > ?
        LIMIT 1
        ''',
        [
          candidate.sessionId,
          CompactionStatus.completed.wireValue,
          candidate.compactionId,
          started.startedAt.toUtc().toIso8601String(),
        ],
      );
      if (newerCompleted.isNotEmpty) {
        return const CompactionTerminalResult(
          outcome: CompactionTerminalOutcome.supersededByNewerBoundary,
        );
      }

      final liveRevision = _historyRevisions.readInTransaction(
        tx,
        candidate.sessionId,
      );
      if (liveRevision == null ||
          liveRevision.value != candidate.sourceRevision.value) {
        return const CompactionTerminalResult(
          outcome: CompactionTerminalOutcome.sourceRevisionStale,
        );
      }

      final rowIds = _messageRowIdsInTransaction(tx, candidate.sessionId);
      if (!_rangesResolve(candidate, rowIds)) {
        return const CompactionTerminalResult(
          outcome: CompactionTerminalOutcome.missingMessageRows,
        );
      }

      final completed = CompactionOperationRecord.fromCandidate(
        candidate: candidate,
        startedAt: startedAt,
        completedAt: completedAt,
      );
      final summaryJson = CompactionOperationCodec.encodeSummary(
        completed.internalSummary!,
      );
      final metrics = completed.metrics!;
      tx.db.execute(
        '''
        UPDATE session_compaction_operations
        SET status = ?, completed_at = ?, internal_summary_json = ?,
            context_window_tokens = ?, estimated_request_tokens_before = ?,
            estimated_request_tokens_after = ?, before_measurement_kind = ?,
            retained_tail_tokens = ?, duration_ms = ?
        WHERE compaction_id = ? AND status = ?
        ''',
        [
          CompactionStatus.completed.wireValue,
          completedAt.toUtc().toIso8601String(),
          summaryJson,
          metrics.contextWindowTokens,
          metrics.estimatedRequestTokensBefore,
          metrics.estimatedRequestTokensAfter,
          metrics.beforeMeasurementKind.wireValue,
          metrics.retainedTailTokens,
          metrics.duration?.inMilliseconds,
          candidate.compactionId,
          CompactionStatus.started.wireValue,
        ],
      );
      if (tx.db.updatedRows != 1) {
        return const CompactionTerminalResult(
          outcome: CompactionTerminalOutcome.staleOperation,
        );
      }
      SessionProjectionRevisionRepository.bumpDatabase(
        tx.db,
        candidate.sessionId,
      );
      return CompactionTerminalResult(
        outcome: CompactionTerminalOutcome.completed,
        record: completed,
      );
    });
  }

  /// Records the first provider-confirmed input usage after a completed
  /// compaction without changing its canonical boundary or estimate.
  CompactionOperationRecord? reconcileProviderUsage({
    required String compactionId,
    required int inputTokens,
  }) {
    if (inputTokens < 0) return null;
    return _state.transaction((tx) {
      final rows = tx.db.select(
        'SELECT * FROM session_compaction_operations WHERE compaction_id = ?',
        [compactionId],
      );
      if (rows.isEmpty) return null;
      final existing = CompactionOperationCodec.fromRow(rows);
      if (existing.status != CompactionStatus.completed ||
          existing.metrics == null) {
        return null;
      }
      final confirmed = existing.metrics!.providerConfirmedRequestTokensAfter;
      if (confirmed != null) {
        return confirmed == inputTokens ? existing : null;
      }
      tx.db.execute(
        '''
        UPDATE session_compaction_operations
        SET provider_confirmed_request_tokens_after = ?
        WHERE compaction_id = ?
          AND status = ?
          AND provider_confirmed_request_tokens_after IS NULL
        ''',
        [inputTokens, compactionId, CompactionStatus.completed.wireValue],
      );
      if (tx.db.updatedRows != 1) return null;
      final updated = tx.db.select(
        'SELECT * FROM session_compaction_operations WHERE compaction_id = ?',
        [compactionId],
      );
      return CompactionOperationCodec.fromRow(updated);
    });
  }

  CompactionTerminalResult failStarted({
    required String compactionId,
    required CompactionFailureReason failureReason,
    required DateTime completedAt,
    Map<String, dynamic>? failureDetail,
  }) {
    return _state.transaction((tx) {
      final rows = tx.db.select(
        'SELECT * FROM session_compaction_operations WHERE compaction_id = ?',
        [compactionId],
      );
      if (rows.isEmpty) {
        return const CompactionTerminalResult(
          outcome: CompactionTerminalOutcome.staleOperation,
        );
      }
      final started = CompactionOperationCodec.fromRow(rows);
      if (started.status != CompactionStatus.started) {
        return const CompactionTerminalResult(
          outcome: CompactionTerminalOutcome.staleOperation,
        );
      }
      final detailJson = CompactionOperationCodec.encodeFailureDetail(
        failureDetail,
      );
      tx.db.execute(
        '''
        UPDATE session_compaction_operations
        SET status = ?, failure_reason = ?, failure_detail_json = ?,
            completed_at = ?
        WHERE compaction_id = ? AND status = ?
        ''',
        [
          CompactionStatus.failed.wireValue,
          failureReason.wireValue,
          detailJson,
          completedAt.toUtc().toIso8601String(),
          compactionId,
          CompactionStatus.started.wireValue,
        ],
      );
      if (tx.db.updatedRows != 1) {
        return const CompactionTerminalResult(
          outcome: CompactionTerminalOutcome.staleOperation,
        );
      }
      return CompactionTerminalResult(
        outcome: CompactionTerminalOutcome.failed,
        record: started.copyWithTerminalFailure(
          failureReason: failureReason,
          completedAt: completedAt,
          failureDetailJson: detailJson,
        ),
      );
    });
  }

  int recoverInterruptedStartedOperations({DateTime? completedAt}) {
    final terminalAt = (completedAt ?? DateTime.now())
        .toUtc()
        .toIso8601String();
    _state.db.execute(
      '''
      UPDATE session_compaction_operations
      SET status = ?, failure_reason = ?, completed_at = ?
      WHERE status = ?
      ''',
      [
        CompactionStatus.failed.wireValue,
        CompactionFailureReason.interrupted.wireValue,
        terminalAt,
        CompactionStatus.started.wireValue,
      ],
    );
    return _state.db.updatedRows;
  }

  CompactionOperationRecord? findById(String compactionId) {
    final rows = _state.db.select(
      'SELECT * FROM session_compaction_operations WHERE compaction_id = ?',
      [compactionId],
    );
    if (rows.isEmpty) {
      return null;
    }
    return CompactionOperationCodec.fromRow(rows);
  }

  CompactionOperationRecord? findStartedForSession(String sessionId) {
    final rows = _state.db.select(
      '''
      SELECT * FROM session_compaction_operations
      WHERE session_id = ? AND status = ?
      ORDER BY started_at DESC
      LIMIT 1
      ''',
      [sessionId, CompactionStatus.started.wireValue],
    );
    if (rows.isEmpty) {
      return null;
    }
    return CompactionOperationCodec.fromRow(rows);
  }

  CompactionOperationRecord? findLatestCompletedForSession(String sessionId) {
    final rows = _state.db.select(
      '''
      SELECT * FROM session_compaction_operations
      WHERE session_id = ? AND status = ?
      ORDER BY completed_at DESC, compaction_id DESC
      LIMIT 1
      ''',
      [sessionId, CompactionStatus.completed.wireValue],
    );
    if (rows.isEmpty) {
      return null;
    }
    return CompactionOperationCodec.fromRow(rows);
  }

  List<CompactionOperationRecord> listCompletedForSession(String sessionId) {
    final rows = _state.db.select(
      '''
      SELECT * FROM session_compaction_operations
      WHERE session_id = ? AND status = ?
      ORDER BY completed_at DESC, compaction_id DESC
      ''',
      [sessionId, CompactionStatus.completed.wireValue],
    );
    return rows
        .map(CompactionOperationCodec.fromSingleRow)
        .toList(growable: false);
  }

  /// All compaction lifecycle rows for history hydration (Plan 53d D6 / 53f F4).
  List<CompactionOperationRecord> listLifecycleForSession(String sessionId) {
    final rows = _state.db.select(
      '''
      SELECT * FROM session_compaction_operations
      WHERE session_id = ?
      ORDER BY started_at ASC, compaction_id ASC
      ''',
      [sessionId],
    );
    return rows
        .map(CompactionOperationCodec.fromSingleRow)
        .toList(growable: false);
  }

  SessionHistoryRevision? historyRevisionForSession(String sessionId) {
    return SessionHistoryRevisionRepository(_state).read(sessionId);
  }

  Set<int> messageRowIdsForSession(String sessionId) {
    final rows = _state.db.select(
      'SELECT id FROM messages WHERE session_id = ?',
      [sessionId],
    );
    return rows.map((row) => row['id'] as int).toSet();
  }

  bool _isStartedConflict(SqliteException error) {
    final message = error.message.toLowerCase();
    return message.contains('unique') ||
        message.contains('constraint') ||
        message.contains('idx_session_compaction_one_started');
  }

  Set<int> _messageRowIdsInTransaction(
    AgentStateTransaction tx,
    String sessionId,
  ) {
    final rows = tx.db.select('SELECT id FROM messages WHERE session_id = ?', [
      sessionId,
    ]);
    return rows.map((row) => row['id'] as int).toSet();
  }

  bool _rangesResolve(CompactionCandidate candidate, Set<int> rowIds) {
    for (final range in [candidate.sourceRange, candidate.retainedTailRange]) {
      if (!rowIds.contains(range.start.rowId) ||
          !rowIds.contains(range.end.rowId)) {
        return false;
      }
    }
    return true;
  }
}
