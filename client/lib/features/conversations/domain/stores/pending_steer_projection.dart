import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/pending_steer_record.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_state.dart';

/// Owns the pending-steer lifecycle projection of a device conversation.
///
/// Pending steers are daemon lifecycle rows, not durable history: this owner
/// keeps their per-session map, the request ids a stop already recovered, and
/// the transient timeline projection they contribute at the live activity tail.
/// The host store injects the canonical [ConversationState], its selected
/// session id, and the message-emit callback, so every projection mutation
/// still publishes the timeline exactly where it did before this owner existed.
class PendingSteerProjection {
  final ConversationState _conversation;

  /// The host store's selected session id; only that session projects into the
  /// visible timeline.
  final String? Function() getCurrentSessionId;

  /// Publishes the host store's message stream after a projection mutation.
  final void Function() emitMessages;

  final Map<String, Map<String, PendingSteerRecord>> _pendingSteersBySessionId = {};
  final Set<(String, String)> _stopRecoveredPendingSteerKeys = {};

  PendingSteerProjection({
    required ConversationState conversation,
    required this.getCurrentSessionId,
    required this.emitMessages,
  }) : _conversation = conversation;

  /// Restores the lifecycle map carried by a `DeviceConversationStoreSnapshot`.
  void restore(Map<String, Map<String, PendingSteerRecord>> pendingSteers) {
    for (final entry in pendingSteers.entries) {
      _pendingSteersBySessionId[entry.key] = Map<String, PendingSteerRecord>.from(entry.value);
    }
  }

  Map<String, Map<String, PendingSteerRecord>> get pendingSteersBySessionId =>
      Map<String, Map<String, PendingSteerRecord>>.unmodifiable({
        for (final entry in _pendingSteersBySessionId.entries)
          entry.key: Map<String, PendingSteerRecord>.unmodifiable(
            entry.value,
          ),
      });

  void applyPendingSteer(PendingSteerRecord record) {
    final key = (record.sessionId, record.requestId);
    if (_stopRecoveredPendingSteerKeys.contains(key) &&
        (record.state == PendingSteerState.pending || record.state == PendingSteerState.delivering)) {
      return;
    }
    final byRequest = _pendingSteersBySessionId.putIfAbsent(
      record.sessionId,
      () => {},
    );
    final current = byRequest[record.requestId];
    if (current != null && record.revision <= current.revision) return;
    byRequest[record.requestId] = record;
    if (record.sessionId != getCurrentSessionId()) return;

    _reconcilePendingSteerProjection(record);
    emitMessages();
  }

  void _reconcilePendingSteerProjection(
    PendingSteerRecord record, {
    Map<String, dynamic> metadataOverrides = const {},
  }) {
    final transientEventId = 'user_${record.requestId}';
    if (record.state == PendingSteerState.cancelled || record.state == PendingSteerState.recovered) {
      _conversation.removeById(transientEventId);
      return;
    }

    final durableEvent = _conversation.events
        .where(
          (event) =>
              event.id != transientEventId &&
              event.kind == EventKind.userMessage &&
              event.sessionId == record.sessionId &&
              event.requestId == record.requestId,
        )
        .firstOrNull;
    final hasTransientProjection = _conversation.events.any(
      (event) => event.id == transientEventId,
    );
    if (durableEvent != null) {
      _conversation.removeById(transientEventId);
    } else if (record.state == PendingSteerState.delivered && !hasTransientProjection) {
      // A delivered lifecycle row is metadata for a durable history message,
      // not authority to synthesize that message outside the loaded slice.
      return;
    }
    final base = durableEvent;
    _conversation.apply(
      CanonicalEvent(
        id: base?.id ?? transientEventId,
        kind: EventKind.userMessage,
        text: base?.text ?? record.text,
        timestamp: base?.timestamp ?? record.receivedAt,
        sessionId: base?.sessionId ?? record.sessionId,
        runId: base?.runId ?? record.runId,
        eventId: base?.eventId,
        metadata: {
          ...?base?.metadata,
          'request_id': record.requestId,
          'pending_steer_state': record.state.name,
          'pending_steer_revision': record.revision,
          'generation': record.generation,
          if (record.messageId != null) 'message_id': record.messageId,
          if (record.turnId != null) 'turn_id': record.turnId,
          if (record.anchorMessageId != null) 'anchor_message_id': record.anchorMessageId,
          if (record.anchorToolCallId != null) 'anchor_tool_call_id': record.anchorToolCallId,
          if (record.historyRevision != null) 'history_revision': record.historyRevision,
          'input_kind': 'steer',
          'replay_eligible': false,
          ...metadataOverrides,
        },
      ),
    );
    if (record.state == PendingSteerState.delivered &&
        (record.anchorMessageId != null || record.anchorToolCallId != null)) {
      _conversation.moveAfterAnchor(
        base?.id ?? transientEventId,
        anchorMessageId: record.anchorMessageId,
        anchorToolCallId: record.anchorToolCallId,
      );
    } else if (record.state != PendingSteerState.delivered) {
      _conversation.moveToEnd(base?.id ?? transientEventId);
    }
  }

  void moveCurrentPendingSteersToTail() {
    final sessionId = getCurrentSessionId();
    if (sessionId == null) return;
    final records = _pendingSteersBySessionId[sessionId];
    if (records == null) return;
    for (final record in records.values) {
      if (record.state == PendingSteerState.pending || record.state == PendingSteerState.delivering) {
        final projection = _conversation.events
            .where(
              (event) =>
                  event.kind == EventKind.userMessage &&
                  event.sessionId == sessionId &&
                  event.requestId == record.requestId,
            )
            .firstOrNull;
        _conversation.moveToEnd(projection?.id ?? 'user_${record.requestId}');
      }
    }
  }

  void reconcileCurrentPendingSteerProjections() {
    final sessionId = getCurrentSessionId();
    if (sessionId == null) return;
    final records = _pendingSteersBySessionId[sessionId];
    if (records == null) return;
    for (final record in records.values) {
      _reconcilePendingSteerProjection(record);
    }
  }

  void hydratePendingSteers(
    Iterable<PendingSteerRecord> records, {
    required String sessionId,
  }) {
    final incomingIds = records
        .where((record) => record.sessionId == sessionId)
        .map((record) => record.requestId)
        .toSet();
    final existing = _pendingSteersBySessionId[sessionId] ?? const <String, PendingSteerRecord>{};
    for (final record in existing.values) {
      if (!incomingIds.contains(record.requestId) && record.state == PendingSteerState.pending) {
        _conversation.removeById('user_${record.requestId}');
      }
    }
    for (final record in records) {
      if (record.sessionId == sessionId) applyPendingSteer(record);
    }
    emitMessages();
  }

  /// Drops the pending steers a stop recovered, so their transient projections
  /// can never be resurrected by a late lifecycle replay.
  void recoverStoppedInputs(StopDraftRecovery recovery) {
    final recoveredPendingSteerIds = recovery.inputs
        .where(
          (input) => input.source == 'pending_steer' && input.requestId.isNotEmpty,
        )
        .map((input) => input.requestId)
        .toSet();
    if (recoveredPendingSteerIds.isNotEmpty) {
      final byRequest = _pendingSteersBySessionId[recovery.sessionId];
      for (final requestId in recoveredPendingSteerIds) {
        _stopRecoveredPendingSteerKeys.add((recovery.sessionId, requestId));
        byRequest?.remove(requestId);
        if (getCurrentSessionId() == recovery.sessionId) {
          _conversation.removeById('user_$requestId');
        }
      }
      if (byRequest?.isEmpty ?? false) {
        _pendingSteersBySessionId.remove(recovery.sessionId);
      }
      if (getCurrentSessionId() == recovery.sessionId) {
        emitMessages();
      }
    }
  }

  void applyPendingSteerCancelOutcome(String requestId, String outcome) {
    final record = _pendingSteersBySessionId.values
        .map((records) => records[requestId])
        .whereType<PendingSteerRecord>()
        .firstOrNull;
    if (record == null || record.sessionId != getCurrentSessionId()) return;
    _reconcilePendingSteerProjection(
      record,
      metadataOverrides: {'pending_cancel_outcome': outcome},
    );
    emitMessages();
  }
}
