import 'dart:convert';

import 'package:sqlite3/sqlite3.dart';
import 'package:uuid/uuid.dart';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/llm_usage_snapshot.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/llm_request_dumper.dart';

import '../models/compaction_operation_codec.dart';
import '../models/compaction_operation_record.dart';
import 'agent_state_database.dart';
import 'message_history_identity.dart';
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
      final tailAnchor = _messageAnchorInTransaction(
        tx,
        sessionId,
        retainedTailRange.end.rowId,
      );
      final record = CompactionOperationRecord(
        compactionId: compactionId,
        sessionId: sessionId,
        trigger: trigger,
        status: CompactionStatus.started,
        sourceHistoryRevision: revision.toCompactionRevision(),
        sourceRange: sourceRange,
        retainedTailRange: retainedTailRange,
        retainedTailEndFingerprint: tailAnchor?.fingerprint,
        retainedTailEndOccurrence: tailAnchor?.occurrence,
        routeSignature: routeSignature,
        // Bound once at claim time so a later grown ordinary call can never
        // replace the pre-call measurement that preceded this boundary.
        diagnostics: CompactionDurableDiagnostics(
          lastPreCompactionCall: _preCallAttributionInTransaction(
            tx,
            sessionId: sessionId,
            routeSignature: routeSignature,
          ),
        ),
        startedAt: startedAt,
      );
      try {
        tx.db.execute('''
          INSERT INTO session_compaction_operations (
            compaction_id, session_id, trigger, status,
            source_history_revision,
            source_start_message_id, source_end_message_id,
            tail_start_message_id, tail_end_message_id,
            tail_end_anchor_fingerprint, tail_end_anchor_ordinal,
            provider_instance_id, model_id, template_id, protocol,
            normalized_base_url, config_revision, credential_revision,
            started_at, diagnostics_json
          ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
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
      final candidateDump = candidate.diagnostics?.relativeDumpPath ??
          LLMRequestDumper.getRelativeDumpPath(
            compactionId: candidate.compactionId,
          );
      final candidateDiagnostics = candidate.diagnostics != null
          ? (candidate.diagnostics!.relativeDumpPath == null && candidateDump != null
              ? candidate.diagnostics!.copyWith(relativeDumpPath: candidateDump)
              : candidate.diagnostics!)
          : CompactionDurableDiagnostics(
              relativeDumpPath: candidateDump,
              postBoundary: const CompactionPostBoundaryStatus(
                status: 'pending',
                targetOutcome: TargetOutcome.unknown,
              ),
            );
      // The claim-time pre-call binding is authoritative for the operation.
      final diagnostics = _withClaimedPreCall(
        candidateDiagnostics,
        started.diagnostics,
      );
      final diagnosticsJson = jsonEncode(diagnostics.toJson());
      tx.db.execute(
        '''
        UPDATE session_compaction_operations
        SET status = ?, completed_at = ?, internal_summary_json = ?,
            context_window_tokens = ?, effective_input_budget_tokens = ?,
            auto_threshold_tokens = ?, estimated_request_tokens_before = ?,
            estimated_request_tokens_after = ?, before_measurement_kind = ?,
            retained_tail_tokens = ?, duration_ms = ?,
            summarization_input_tokens = ?,
            summarization_cached_input_tokens = ?,
            summarization_cache_write_tokens = ?,
            summarization_output_tokens = ?,
            summarization_reasoning_tokens = ?,
            summarization_attempts = ?,
            diagnostics_json = ?
        WHERE compaction_id = ? AND status = ?
        ''',
        [
          CompactionStatus.completed.wireValue,
          completedAt.toUtc().toIso8601String(),
          summaryJson,
          metrics.contextWindowTokens,
          metrics.effectiveInputBudgetTokens,
          metrics.autoThresholdTokens,
          metrics.estimatedRequestTokensBefore,
          metrics.estimatedRequestTokensAfter,
          metrics.beforeMeasurementKind.wireValue,
          metrics.retainedTailTokens,
          metrics.duration?.inMilliseconds,
          metrics.summarizationInputTokens,
          metrics.summarizationCachedInputTokens,
          metrics.summarizationCacheWriteTokens,
          metrics.summarizationOutputTokens,
          metrics.summarizationReasoningTokens,
          metrics.summarizationAttempts,
          diagnosticsJson,
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
      final persisted = tx.db.select(
        'SELECT * FROM session_compaction_operations WHERE compaction_id = ?',
        [candidate.compactionId],
      );
      return CompactionTerminalResult(
        outcome: CompactionTerminalOutcome.completed,
        record: CompactionOperationCodec.fromRow(persisted),
      );
    });
  }

  /// Records the exact post-boundary provider confirmation, binding to the
  /// specific first request that used the compaction boundary and route.
  CompactionOperationRecord? reconcilePostBoundaryUsage({
    required String compactionId,
    required String requestId,
    required DateTime observedAt,
    required int inputTokens,
    int? cachedTokens,
    required RouteSignature routeSignature,
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
      // Route signature must match the exact boundary route
      if (existing.routeSignature != routeSignature) {
        return null;
      }
      // Immutability: first accepted confirmation cannot be overwritten by later growth
      final confirmed = existing.metrics!.providerConfirmedRequestTokensAfter;
      final postStatus = existing.diagnostics?.postBoundary;
      if (confirmed != null || postStatus?.status == 'confirmed') {
        final matchesRequest =
            postStatus == null || postStatus.requestId == requestId;
        if (matchesRequest && confirmed == inputTokens) {
          return existing;
        }
        return null;
      }

      // If already recorded as missing, later calls with usage cannot replace it
      if (postStatus?.status == 'missing') {
        return null;
      }

      // Require a reserved request identity before attaching a new exact first-call receipt.
      // Unsolicited unreserved replies and legacy rows without confirmation fail closed.
      if (existing.diagnostics == null ||
          postStatus == null ||
          postStatus.status != 'reserved' ||
          postStatus.requestId != requestId) {
        return null;
      }

      // In Stage 1, target outcome remains unknown; postInputRatio is truthfully recorded
      final w = existing.metrics!.contextWindowTokens;
      final double? postInputRatio = w > 0 ? inputTokens / w : null;
      const targetOutcome = TargetOutcome.unknown;

      final updatedPostStatus = CompactionPostBoundaryStatus(
        status: 'confirmed',
        requestId: requestId,
        observedAt: observedAt,
        inputTokens: inputTokens,
        cachedTokens: cachedTokens,
        targetOutcome: targetOutcome,
        postInputRatio: postInputRatio,
      );
      final updatedDiagnostics = existing.diagnostics!
          .copyWithPostBoundary(updatedPostStatus);
      final diagnosticsJson = jsonEncode(updatedDiagnostics.toJson());

      tx.db.execute(
        '''
        UPDATE session_compaction_operations
        SET provider_confirmed_request_tokens_after = ?,
            diagnostics_json = ?
        WHERE compaction_id = ?
          AND status = ?
          AND provider_confirmed_request_tokens_after IS NULL
        ''',
        [
          inputTokens,
          diagnosticsJson,
          compactionId,
          CompactionStatus.completed.wireValue,
        ],
      );
      final updated = tx.db.select(
        'SELECT * FROM session_compaction_operations WHERE compaction_id = ?',
        [compactionId],
      );
      return updated.isEmpty ? null : CompactionOperationCodec.fromRow(updated);
    });
  }

  /// Immutably reserves the exact first dispatched request/step for post-boundary reconciliation.
  CompactionOperationRecord? reservePostBoundaryDispatch({
    required String compactionId,
    required String requestId,
    required RouteSignature routeSignature,
    required DateTime dispatchedAt,
  }) {
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
      // Preserve historical confirmed scalars without mutating or synthesizing diagnostics
      final confirmed = existing.metrics!.providerConfirmedRequestTokensAfter;
      if (confirmed != null) {
        return existing;
      }

      // If diagnostics == null (legacy row from before upgrade), provenance is unknown.
      // Do not synthesize diagnostics; fail closed!
      if (existing.diagnostics == null) {
        return null;
      }
      final postStatus = existing.diagnostics?.postBoundary;
      // If already reserved, confirmed, or missing, do not overwrite the first dispatched reservation
      if (postStatus != null &&
          (postStatus.status == 'reserved' ||
              postStatus.status == 'confirmed' ||
              postStatus.status == 'missing')) {
        return existing;
      }
      // If post-boundary status is not pending, fail closed
      if (postStatus == null || postStatus.status != 'pending') {
        return null;
      }
      if (existing.routeSignature != routeSignature) {
        return null;
      }

      final updatedPostStatus = CompactionPostBoundaryStatus(
        status: 'reserved',
        requestId: requestId,
        observedAt: dispatchedAt,
        targetOutcome: TargetOutcome.unknown,
      );
      final updatedDiagnostics = existing.diagnostics!
          .copyWithPostBoundary(updatedPostStatus);
      final diagnosticsJson = jsonEncode(updatedDiagnostics.toJson());

      tx.db.execute(
        '''
        UPDATE session_compaction_operations
        SET diagnostics_json = ?
        WHERE compaction_id = ?
          AND status = ?
          AND provider_confirmed_request_tokens_after IS NULL
        ''',
        [
          diagnosticsJson,
          compactionId,
          CompactionStatus.completed.wireValue,
        ],
      );
      final updated = tx.db.select(
        'SELECT * FROM session_compaction_operations WHERE compaction_id = ?',
        [compactionId],
      );
      return updated.isEmpty ? null : CompactionOperationCodec.fromRow(updated);
    });
  }

  /// Explicitly records that provider usage was missing or absent on the post-boundary call.
  CompactionOperationRecord? recordPostBoundaryMissingUsage({
    required String compactionId,
    required String requestId,
    required DateTime observedAt,
    required String missingReason,
    required RouteSignature routeSignature,
  }) {
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
      final postStatus = existing.diagnostics?.postBoundary;
      if (confirmed != null || postStatus?.status == 'confirmed') {
        return existing;
      }
      if (postStatus?.status == 'missing') {
        return existing;
      }
      // Fail closed for legacy rows without diagnostics or unreserved requests
      if (existing.diagnostics == null ||
          postStatus == null ||
          postStatus.status != 'reserved' ||
          postStatus.requestId != requestId) {
        return null;
      }
      if (existing.routeSignature != routeSignature) {
        return null;
      }
      final updatedPostStatus = CompactionPostBoundaryStatus(
        status: 'missing',
        requestId: requestId,
        observedAt: observedAt,
        missingReason: missingReason,
        targetOutcome: TargetOutcome.unknown,
      );
      final updatedDiagnostics = existing.diagnostics!
          .copyWithPostBoundary(updatedPostStatus);
      final diagnosticsJson = jsonEncode(updatedDiagnostics.toJson());

      tx.db.execute(
        '''
        UPDATE session_compaction_operations
        SET diagnostics_json = ?
        WHERE compaction_id = ?
          AND status = ?
          AND provider_confirmed_request_tokens_after IS NULL
        ''',
        [
          diagnosticsJson,
          compactionId,
          CompactionStatus.completed.wireValue,
        ],
      );
      final updated = tx.db.select(
        'SELECT * FROM session_compaction_operations WHERE compaction_id = ?',
        [compactionId],
      );
      return updated.isEmpty ? null : CompactionOperationCodec.fromRow(updated);
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
      // Fail closed for legacy rows without diagnostics (provenance is unknown)
      if (existing.diagnostics == null) {
        return null;
      }
      // In Stage 1, target outcome remains unknown; postInputRatio is truthfully recorded
      final w = existing.metrics!.contextWindowTokens;
      final double? postInputRatio = w > 0 ? inputTokens / w : null;
      const targetOutcome = TargetOutcome.unknown;
      final updatedPostStatus = CompactionPostBoundaryStatus(
        status: 'confirmed',
        observedAt: DateTime.now().toUtc(),
        inputTokens: inputTokens,
        targetOutcome: targetOutcome,
        postInputRatio: postInputRatio,
      );
      final updatedDiagnostics = existing.diagnostics!
          .copyWithPostBoundary(updatedPostStatus);
      final diagnosticsJson = jsonEncode(updatedDiagnostics.toJson());

      tx.db.execute(
        '''
        UPDATE session_compaction_operations
        SET provider_confirmed_request_tokens_after = ?,
            diagnostics_json = ?
        WHERE compaction_id = ?
          AND status = ?
          AND provider_confirmed_request_tokens_after IS NULL
        ''',
        [
          inputTokens,
          diagnosticsJson,
          compactionId,
          CompactionStatus.completed.wireValue,
        ],
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
    CompactionDurableDiagnostics? diagnostics,
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
      final dumpPath = LLMRequestDumper.getRelativeDumpPath(
        compactionId: compactionId,
      );
      var effectiveDiagnostics = diagnostics;
      if (effectiveDiagnostics == null && dumpPath != null) {
        effectiveDiagnostics = CompactionDurableDiagnostics(
          relativeDumpPath: dumpPath,
        );
      } else if (effectiveDiagnostics != null &&
          effectiveDiagnostics.relativeDumpPath == null &&
          dumpPath != null) {
        effectiveDiagnostics = effectiveDiagnostics.copyWith(
          relativeDumpPath: dumpPath,
        );
      }
      final claimedPreCall = started.diagnostics?.lastPreCompactionCall;
      if (claimedPreCall != null) {
        effectiveDiagnostics = (effectiveDiagnostics ??
                const CompactionDurableDiagnostics())
            .copyWith(lastPreCompactionCall: claimedPreCall);
      }
      final diagnosticsJson = effectiveDiagnostics != null
          ? jsonEncode(effectiveDiagnostics.toJson())
          : null;
      tx.db.execute(
        '''
        UPDATE session_compaction_operations
        SET status = ?, failure_reason = ?, failure_detail_json = ?,
            diagnostics_json = COALESCE(?, diagnostics_json),
            completed_at = ?
        WHERE compaction_id = ? AND status = ?
        ''',
        [
          CompactionStatus.failed.wireValue,
          failureReason.wireValue,
          detailJson,
          diagnosticsJson,
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

  /// Reconciles orphaned `started` compaction operations left over from an
  /// interrupted daemon execution, transitioning them to terminal `failed`
  /// with reason `interrupted`.
  int reconcileOrphanedStartedOperations({DateTime? completedAt}) =>
      recoverInterruptedStartedOperations(completedAt: completedAt);

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

  /// Copies every terminal lifecycle event that occurs before the forked
  /// message prefix ends. Callers own the surrounding transaction.
  int cloneTerminalOperationsForFork({
    required String sourceSessionId,
    required String childSessionId,
    required Map<int, int> childRowIdBySourceRowId,
    required int sourcePrefixEndRowId,
    required int childHistoryRevision,
  }) {
    final rows = _state.db.select(
      '''
      SELECT * FROM session_compaction_operations
      WHERE session_id = ?
        AND status != ?
        AND tail_end_message_id < ?
      ORDER BY started_at ASC, compaction_id ASC
      ''',
      [
        sourceSessionId,
        CompactionStatus.started.wireValue,
        sourcePrefixEndRowId,
      ],
    );
    var copied = 0;
    for (final row in rows) {
      final sourceStart =
          childRowIdBySourceRowId[row['source_start_message_id'] as int];
      final sourceEnd =
          childRowIdBySourceRowId[row['source_end_message_id'] as int];
      final tailStart =
          childRowIdBySourceRowId[row['tail_start_message_id'] as int];
      final tailEnd =
          childRowIdBySourceRowId[row['tail_end_message_id'] as int];
      if (sourceStart == null ||
          sourceEnd == null ||
          tailStart == null ||
          tailEnd == null) {
        continue;
      }
      final childAnchor = _messageAnchor(_state.db, childSessionId, tailEnd);
      _state.db.execute(
        '''
        INSERT INTO session_compaction_operations (
          compaction_id, session_id, trigger, status,
          source_history_revision,
          source_start_message_id, source_end_message_id,
          tail_start_message_id, tail_end_message_id,
          tail_end_anchor_fingerprint, tail_end_anchor_ordinal,
          provider_instance_id, model_id, template_id, protocol,
          normalized_base_url, config_revision, credential_revision,
          context_window_tokens, effective_input_budget_tokens,
          auto_threshold_tokens, estimated_request_tokens_before,
          estimated_request_tokens_after, before_measurement_kind,
          provider_confirmed_request_tokens_after, retained_tail_tokens,
          duration_ms, summarization_input_tokens,
          summarization_cached_input_tokens, summarization_cache_write_tokens,
          summarization_output_tokens, summarization_reasoning_tokens,
          summarization_attempts,
          internal_summary_json, failure_reason,
          failure_detail_json, started_at, completed_at
        ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        ''',
        [
          const Uuid().v4(),
          childSessionId,
          row['trigger'],
          row['status'],
          childHistoryRevision,
          sourceStart,
          sourceEnd,
          tailStart,
          tailEnd,
          childAnchor?.fingerprint,
          childAnchor?.occurrence,
          row['provider_instance_id'],
          row['model_id'],
          row['template_id'],
          row['protocol'],
          row['normalized_base_url'],
          row['config_revision'],
          row['credential_revision'],
          row['context_window_tokens'],
          row['effective_input_budget_tokens'],
          row['auto_threshold_tokens'],
          row['estimated_request_tokens_before'],
          row['estimated_request_tokens_after'],
          row['before_measurement_kind'],
          row['provider_confirmed_request_tokens_after'],
          row['retained_tail_tokens'],
          row['duration_ms'],
          row['summarization_input_tokens'],
          row['summarization_cached_input_tokens'],
          row['summarization_cache_write_tokens'],
          row['summarization_output_tokens'],
          row['summarization_reasoning_tokens'],
          row['summarization_attempts'],
          row['internal_summary_json'],
          row['failure_reason'],
          row['failure_detail_json'],
          row['started_at'],
          row['completed_at'],
        ],
      );
      copied++;
    }
    return copied;
  }

  bool targetPrecedesCompletedCompaction({
    required String sessionId,
    required String messageId,
  }) {
    final rows = _state.db.select(
      '''
      SELECT 1
      FROM messages AS message
      JOIN session_compaction_operations AS compaction
        ON compaction.session_id = message.session_id
      WHERE message.session_id = ?
        AND message.message_id = ?
        AND compaction.status = ?
        AND message.id <= compaction.tail_end_message_id
      LIMIT 1
      ''',
      [sessionId, messageId, CompactionStatus.completed.wireValue],
    );
    return rows.isNotEmpty;
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

  /// Preserves the claim-time pre-call binding over later diagnostics writes.
  CompactionDurableDiagnostics _withClaimedPreCall(
    CompactionDurableDiagnostics diagnostics,
    CompactionDurableDiagnostics? startedDiagnostics,
  ) {
    final claimed = startedDiagnostics?.lastPreCompactionCall;
    if (claimed == null) return diagnostics;
    return diagnostics.copyWith(lastPreCompactionCall: claimed);
  }

  /// Reads the newest ordinary assistant row of the session at claim time.
  ///
  /// The row is the boundary's pre-call only if it carries provider-reported
  /// usage. Missing usage, identity, or material proof stays explicit instead
  /// of being replaced by an older call, a zero value, or an estimate.
  CompactionPreCallAttribution _preCallAttributionInTransaction(
    AgentStateTransaction tx, {
    required String sessionId,
    required RouteSignature routeSignature,
  }) {
    final rows = tx.db.select(
      '''
      SELECT id, message_id, request_id, run_id, data
      FROM messages
      WHERE session_id = ? AND history_status = ?
        AND json_extract(data, '\$.role') = ?
      ORDER BY id DESC
      LIMIT 1
      ''',
      [sessionId, MessageHistoryIdentity.active, MessageRole.assistant.name],
    );
    if (rows.isEmpty) {
      return const CompactionPreCallAttribution(
        status: CompactionPreCallStatus.absent,
        applicability: CompactionPreCallApplicability.unknown,
        reason: CompactionPreCallReason.noOrdinaryCall,
      );
    }

    final row = rows.first;
    final metadata = _metadataOf(row['data']);
    final contextUsage = _asMap(metadata?['context_usage']);
    final providerUsage = _asMap(metadata?['usage']);
    final usageSnapshot = providerUsage == null
        ? null
        : LlmUsageSnapshot.fromProviderUsage(providerUsage);
    final int? inputTokens;
    final int? cachedInputTokens;
    if (contextUsage != null) {
      inputTokens = CompactionPreCallAttribution.reportedInputTokens(
        contextUsage['input_tokens'],
      );
      cachedInputTokens =
          CompactionPreCallAttribution.reportedCachedInputTokens(
            contextUsage['cached_tokens'],
          );
    } else {
      inputTokens = CompactionPreCallAttribution.reportedInputTokens(
        usageSnapshot?.inputTokens,
      );
      cachedInputTokens =
          CompactionPreCallAttribution.reportedCachedInputTokens(
            usageSnapshot?.cachedTokens,
          );
    }
    final providerInstanceId =
        _safeText(contextUsage?['provider_instance_id']) ??
        _safeText(metadata?['provider_instance_id']) ??
        _safeText(metadata?['provider']);
    final modelId =
        _safeText(contextUsage?['model_id']) ?? _safeText(metadata?['model']);
    final runId =
        _safeText(contextUsage?['run_id']) ??
        _safeText(metadata?['run_id']) ??
        _safeText(row['run_id']);
    final modelStepId =
        _safeText(contextUsage?['model_step_id']) ??
        _safeText(metadata?['model_step_id']);
    final turnRequestId =
        _safeText(contextUsage?['request_id']) ??
        _safeText(row['request_id']) ??
        runId;
    final observedAt = DateTime.tryParse(
      _safeText(contextUsage?['observed_at']) ?? '',
    )?.toUtc();
    final requestId = turnRequestId != null && modelStepId != null
        ? '$turnRequestId:$modelStepId'
        : null;

    final String applicability;
    final String? reason;
    if (inputTokens == null) {
      applicability = CompactionPreCallApplicability.unknown;
      reason = CompactionPreCallReason.usageMissing;
    } else if (requestId == null ||
        observedAt == null ||
        providerInstanceId == null ||
        modelId == null) {
      applicability = CompactionPreCallApplicability.unknown;
      reason = CompactionPreCallReason.identityIncomplete;
    } else if (providerInstanceId != routeSignature.providerInstanceId ||
        modelId != routeSignature.modelId) {
      applicability = CompactionPreCallApplicability.notApplicable;
      reason = CompactionPreCallReason.routeChanged;
    } else if (_hasCompletedBoundaryAfter(tx, sessionId, observedAt)) {
      applicability = CompactionPreCallApplicability.notApplicable;
      reason = CompactionPreCallReason.materialChanged;
    } else {
      // Without current-material comparison (e.g. prospective prefix
      // remeasurement with active tool schemas), syntactic validity of
      // wire_proof alone cannot establish unchanged prompt/schema/options.
      // Applicability fails closed to unknown with material_unverified.
      applicability = CompactionPreCallApplicability.unknown;
      reason = CompactionPreCallReason.materialUnverified;
    }

    return CompactionPreCallAttribution(
      status: CompactionPreCallStatus.recorded,
      applicability: applicability,
      reason: reason,
      messageId:
          _safeText(row['message_id']) ?? _safeText(metadata?['message_id']),
      requestId: requestId,
      runId: runId,
      modelStepId: modelStepId,
      observedAt: observedAt,
      providerInstanceId: providerInstanceId,
      modelId: modelId,
      inputTokens: inputTokens,
      cachedInputTokens: cachedInputTokens,
    );
  }

  /// True when a completed boundary was activated after [observedAt], which
  /// means the measured pre-call material no longer matches the projection.
  bool _hasCompletedBoundaryAfter(
    AgentStateTransaction tx,
    String sessionId,
    DateTime observedAt,
  ) {
    final rows = tx.db.select(
      '''
      SELECT 1 FROM session_compaction_operations
      WHERE session_id = ? AND status = ? AND completed_at > ?
      LIMIT 1
      ''',
      [
        sessionId,
        CompactionStatus.completed.wireValue,
        observedAt.toUtc().toIso8601String(),
      ],
    );
    return rows.isNotEmpty;
  }

  static Map<String, dynamic>? _metadataOf(Object? data) {
    if (data is! String) return null;
    try {
      final decoded = jsonDecode(data);
      if (decoded is! Map) return null;
      return _asMap(decoded['metadata']);
    } catch (_) {
      return null;
    }
  }

  static Map<String, dynamic>? _asMap(Object? value) {
    if (value is! Map) return null;
    return Map<String, dynamic>.from(value);
  }

  static String? _safeText(Object? value) {
    final text = value?.toString().trim();
    return text == null || text.isEmpty ? null : text;
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

  ({String fingerprint, int occurrence})? _messageAnchorInTransaction(
    AgentStateTransaction tx,
    String sessionId,
    int targetRowId,
  ) => _messageAnchor(tx.db, sessionId, targetRowId);

  ({String fingerprint, int occurrence})? _messageAnchor(
    Database db,
    String sessionId,
    int targetRowId,
  ) {
    final rows = db.select(
      'SELECT id, data FROM messages WHERE session_id = ? AND id <= ? ORDER BY id ASC',
      [sessionId, targetRowId],
    );
    final targetRows = rows.where((row) => row['id'] == targetRowId);
    if (targetRows.isEmpty) return null;
    final targetMessage = Message.fromJson(
      jsonDecode(targetRows.first['data'] as String) as Map<String, dynamic>,
    );
    final targetFingerprint = CompactionMessageAnchor.fingerprint(
      targetMessage,
    );
    var occurrence = 0;
    for (final row in rows) {
      final message = Message.fromJson(
        jsonDecode(row['data'] as String) as Map<String, dynamic>,
      );
      final fingerprint = CompactionMessageAnchor.fingerprint(message);
      if (fingerprint == targetFingerprint) occurrence++;
    }
    if (occurrence == 0) return null;
    return (fingerprint: targetFingerprint, occurrence: occurrence);
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
