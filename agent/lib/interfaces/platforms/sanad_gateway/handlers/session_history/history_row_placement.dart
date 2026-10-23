import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/evolution/compaction/model_context_projection.dart';
import 'package:sanad_agent/evolution/models/compaction_operation_record.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

/// Places the synthetic history rows — compaction lifecycle, fork marker, and
/// automatic-failover notices — on one `session_history` page.
///
/// `SessionQueryHandler` keeps envelope assembly and decides which synthetic
/// rows exist; this owner decides where each resolved row belongs and what the
/// row looks like, so placement and payload cannot diverge.
class HistoryPagePlacement {
  final List<PersistedMessage> _persistedMessages;
  final Map<int, int> _historyStartByMessageRowId;
  final int? _firstPageRowId;
  final int? _lastPageRowId;
  final Set<int> _pageRowIds;
  final List<Map<String, dynamic>> historyMessages;
  final bool isTailPage;
  final List<int> _compactionInsertionAnchors = <int>[];

  HistoryPagePlacement({
    required List<PersistedMessage> persistedMessages,
    required this.historyMessages,
    required Map<int, int> historyStartByMessageRowId,
    required this.isTailPage,
  }) : _persistedMessages = persistedMessages,
       _historyStartByMessageRowId = historyStartByMessageRowId,
       _firstPageRowId = persistedMessages.firstOrNull?.rowId,
       _lastPageRowId = persistedMessages.lastOrNull?.rowId,
       _pageRowIds = {for (final entry in persistedMessages) entry.rowId};

  void insertCompactionLifecycleRows(
    Iterable<CompactionOperationRecord> operations,
  ) {
    final firstPageRowId = _firstPageRowId;
    final lastPageRowId = _lastPageRowId;
    for (final operation in operations) {
      final tailEndRowId = _resolveCompactionHistoryAnchor(operation);
      if (firstPageRowId == null ||
          lastPageRowId == null ||
          tailEndRowId < firstPageRowId ||
          tailEndRowId > lastPageRowId) {
        continue;
      }
      final lifecycleRow = compactionLifecycleHistoryRow(operation);
      final firstPostBoundary = _persistedMessages
          .where((entry) => entry.rowId > tailEndRowId)
          .firstOrNull;
      final rawInsertionIndex = firstPostBoundary == null
          ? historyMessages.length - _compactionInsertionAnchors.length
          : _historyStartByMessageRowId[firstPostBoundary.rowId];
      late int insertionIndex;
      if (rawInsertionIndex != null) {
        insertionIndex =
            rawInsertionIndex +
            _compactionInsertionAnchors
                .where((anchor) => anchor <= rawInsertionIndex)
                .length;
        _compactionInsertionAnchors.add(rawInsertionIndex);
      } else {
        insertionIndex = historyMessages.indexWhere((row) {
          final createdAt = DateTime.tryParse(
            row['created_at']?.toString() ?? '',
          );
          return createdAt != null &&
              createdAt.isAfter(operation.startedAt.toUtc());
        });
        if (insertionIndex == -1) {
          insertionIndex = historyMessages.length;
        }
      }
      historyMessages.insert(insertionIndex, lifecycleRow);
    }
  }

  void insertForkMarker(
    SessionState session, {
    required int? copiedPrefixEndRowId,
  }) {
    final insertionIndex = _forkMarkerInsertionIndex(copiedPrefixEndRowId);
    if (insertionIndex == null) return;
    historyMessages.insert(insertionIndex, forkMarkerHistoryRow(session));
  }

  void insertRouteTransitionNotice(
    SessionRouteTransition transition, {
    required int? anchorRowId,
  }) {
    final insertionIndex = _routeTransitionInsertionIndex(
      transition,
      anchorRowId: anchorRowId,
    );
    if (insertionIndex == null) return;
    historyMessages.insert(
      insertionIndex,
      routeTransitionHistoryRow(transition),
    );
  }

  /// The fork marker follows the last row the fork copied, so it sits on the
  /// one page holding that row whatever came after it. A legacy child whose
  /// copied rows carry no `origin_message_id` keeps the old tail placement.
  int? _forkMarkerInsertionIndex(int? copiedPrefixEndRowId) {
    if (copiedPrefixEndRowId == null) {
      return isTailPage ? historyMessages.length : null;
    }
    if (!_pageRowIds.contains(copiedPrefixEndRowId)) return null;
    return _historyIndexAfterRow(copiedPrefixEndRowId);
  }

  /// Places an automatic-failover notice after its resolved anchor row, so the
  /// notice belongs to the one page that holds that row; an unresolvable notice
  /// stays tail-only.
  int? _routeTransitionInsertionIndex(
    SessionRouteTransition transition, {
    required int? anchorRowId,
  }) {
    if (anchorRowId != null) {
      if (!_pageRowIds.contains(anchorRowId)) return null;
      return _indexAfterEarlierSyntheticRows(
        _historyIndexAfterRow(anchorRowId),
        transition.createdAt,
      );
    }
    return isTailPage ? historyMessages.length : null;
  }

  /// Index just after every history row rendered from persisted rows up to
  /// [rowId], so a row that renders nothing still resolves to its position.
  int _historyIndexAfterRow(int rowId) {
    var index = 0;
    for (var i = 0; i < historyMessages.length; i++) {
      final sourceRowId = historyMessages[i]['source_message_row_id'];
      if (sourceRowId is int && sourceRowId <= rowId) index = i + 1;
    }
    return index;
  }

  /// Steps past derived rows (compaction lifecycle, earlier transitions, the
  /// fork marker) at the same anchor that happened no later than [at].
  int _indexAfterEarlierSyntheticRows(int index, DateTime at) {
    var cursor = index;
    while (cursor < historyMessages.length) {
      final row = historyMessages[cursor];
      if (row['source_message_row_id'] != null) break;
      final createdAt = DateTime.tryParse(row['created_at']?.toString() ?? '');
      if (createdAt == null || createdAt.isAfter(at)) break;
      cursor++;
    }
    return cursor;
  }

  int _resolveCompactionHistoryAnchor(CompactionOperationRecord operation) {
    final originalRowId = operation.retainedTailRange.end.rowId;
    if (_persistedMessages.any((entry) => entry.rowId == originalRowId)) {
      return originalRowId;
    }
    final fingerprint = operation.retainedTailEndFingerprint;
    final occurrence = operation.retainedTailEndOccurrence;
    if (fingerprint == null || occurrence == null) return originalRowId;

    var seen = 0;
    for (final entry in _persistedMessages) {
      if (CompactionMessageAnchor.fingerprint(entry.message) != fingerprint) {
        continue;
      }
      seen++;
      if (seen == occurrence) return entry.rowId;
    }
    return originalRowId;
  }
}

Map<String, dynamic> compactionLifecycleHistoryRow(
  CompactionOperationRecord operation,
) {
  final wireType = switch (operation.status) {
    CompactionStatus.started => CanonicalEventTypes.contextCompactionStarted,
    CompactionStatus.completed =>
      CanonicalEventTypes.contextCompactionCompleted,
    CompactionStatus.failed => CanonicalEventTypes.contextCompactionFailed,
  };
  final metrics = operation.metrics;
  final eventId = CompactionLifecycleEvent.eventIdFor(
    operation.compactionId,
    operation.status,
  );
  return {
    'id': eventId,
    'event_id': eventId,
    'sender': 'system',
    'type': wireType,
    'session_id': operation.sessionId,
    'compaction_id': operation.compactionId,
    'trigger': operation.trigger.wireValue,
    'status': operation.status.wireValue,
    'provider_instance_id': operation.routeSignature.providerInstanceId,
    'model_id': operation.routeSignature.modelId,
    'started_at': operation.startedAt.toUtc().toIso8601String(),
    if (operation.completedAt != null)
      'completed_at': operation.completedAt!.toUtc().toIso8601String(),
    if (metrics != null) ...{
      'context_window_tokens': metrics.contextWindowTokens,
      if (metrics.effectiveInputBudgetTokens != null)
        'effective_input_budget_tokens': metrics.effectiveInputBudgetTokens,
      if (metrics.autoThresholdTokens != null)
        'auto_threshold_tokens': metrics.autoThresholdTokens,
      'estimated_request_tokens_before': metrics.estimatedRequestTokensBefore,
      'estimated_request_tokens_after': metrics.estimatedRequestTokensAfter,
      'before_measurement_kind': metrics.beforeMeasurementKind.wireValue,
      if (metrics.providerConfirmedRequestTokensAfter != null)
        'provider_confirmed_request_tokens_after':
            metrics.providerConfirmedRequestTokensAfter,
      'retained_tail_tokens': metrics.retainedTailTokens,
      if (metrics.duration != null)
        'duration_ms': metrics.duration!.inMilliseconds,
    },
    if (operation.failureReason != null)
      'failure_reason': operation.failureReason!.wireValue,
    if (operation.failureStage != null)
      'failure_stage': operation.failureStage,
    if (operation.failureCause != null)
      'failure_cause': operation.failureCause,
    'created_at': (operation.completedAt ?? operation.startedAt)
        .toUtc()
        .toIso8601String(),
  };
}

Map<String, dynamic> forkMarkerHistoryRow(SessionState session) {
  final eventId = 'fork_${session.sessionId}';
  return {
    'id': eventId,
    'event_id': eventId,
    'sender': 'system',
    'type': CanonicalEventTypes.sessionForked,
    'content': 'Conversation forked',
    'session_id': session.sessionId,
    'created_at': session.createdAt.toUtc().toIso8601String(),
    'metadata': {
      'informational': true,
      'informational_kind': 'session_fork',
      'lineage_id': session.lineageId,
      'parent_session_id': session.parentSessionId,
      'forked_from_message_id': session.forkedFromMessageId,
      'forked_from_turn_id': session.forkedFromTurnId,
      'fork_sequence': session.forkSequence,
    },
  };
}

Map<String, dynamic> routeTransitionHistoryRow(
  SessionRouteTransition transition,
) {
  final previousProviderLabel =
      transition.previousProviderDisplayName ??
      transition.previousProviderInstanceId ??
      'the previous provider';
  final nextProviderLabel =
      transition.providerDisplayName ?? transition.providerInstanceId;
  final reasonText = transition.reason?.replaceAll('_', ' ');
  return {
    'id': transition.eventId,
    'event_id': transition.eventId,
    'sender': 'system',
    'type': 'session_route_transition',
    'content':
        'Switched automatically from '
        '$previousProviderLabel '
        'to $nextProviderLabel'
        '${reasonText == null ? '' : ' because $reasonText'}. '
        'Continuing with ${transition.model}.',
    ...transition.toPayload(),
    'created_at': transition.createdAt.toIso8601String(),
  };
}
