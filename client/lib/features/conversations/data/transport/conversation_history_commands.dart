import 'package:logging/logging.dart';
import 'package:sanad_client/features/conversations/data/mappers/device_event_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/command_response_errors.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_request_id.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/pending_steer_record.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/stores/canonical_timeline_reconciler.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';

/// Owns conversation history hydration for `ConversationCommands`: the
/// initial and anchored snapshot, the older and newer page loads, the opaque
/// cursors each direction coalesces on, and the generation that rejects a
/// snapshot or page a newer hydration request already superseded.
///
/// The façade keeps the public methods, so the request identity, payload
/// shape, merge order, and rejection behavior every caller relies on are
/// unchanged.
class ConversationHistoryCommands {
  /// Keeps the façade's log category so the history diagnostics stream is
  /// identical before and after the owner split.
  static final _logger = Logger('ConversationCommands');

  final ConversationCommandGateway _gateway;
  final DeviceConversationStore _conversationStore;
  final DeviceEventMapper _mapper;
  int _historyHydrationGeneration = 0;
  Future<List<CanonicalEvent>>? _olderHistoryLoad;
  String? _olderHistoryCursor;
  Future<List<CanonicalEvent>>? _newerHistoryLoad;
  String? _newerHistoryCursor;

  ConversationHistoryCommands({
    required ConversationCommandGateway gateway,
    required DeviceConversationStore conversationStore,
    required DeviceEventMapper mapper,
  }) : _gateway = gateway,
       _conversationStore = conversationStore,
       _mapper = mapper;

  Future<List<CanonicalEvent>> loadSessionHistory(
    String sessionId, {
    String? anchorEventId,
  }) async {
    final generation = ++_historyHydrationGeneration;
    final restoredRetainedHistory = _conversationStore.activateSession(
      sessionId,
    );
    final retainedEvents = List<CanonicalEvent>.from(
      _conversationStore.currentMessages,
    );
    final retainedHistoryIsComplete =
        restoredRetainedHistory &&
        retainedEvents.isNotEmpty &&
        !_conversationStore.historyHasMore &&
        !_conversationStore.historyHasNewer;
    final baselineEventIds = retainedEvents.map((event) => event.id).toSet();

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'get_session_history',
      payload: {
        'request_id': requestId,
        'session_id': sessionId,
        'limit': 100,
        if (anchorEventId != null) 'anchor_event_id': anchorEventId,
      },
      requestId: requestId,
    );

    if (result != null) {
      if (generation != _historyHydrationGeneration || _conversationStore.currentSessionId != sessionId) {
        return List<CanonicalEvent>.from(_conversationStore.currentMessages);
      }

      final payload = Map<String, dynamic>.from(
        result['payload'] as Map? ?? {},
      );
      _throwHistoryError(result);
      final messagesData = payload['messages'] as List? ?? [];
      final queuedMessagesData = payload['queued_messages'] as List? ?? [];
      final pendingSteersData = payload['pending_steers'] as List? ?? [];
      _conversationStore.hydrateSessionState(payload, sessionId: sessionId);
      for (final raw in messagesData.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final type = row['type']?.toString();
        if (type != 'session_route_transition' && type != 'session_preferences_updated') {
          continue;
        }
        final metadata = Map<String, dynamic>.from(
          row['metadata'] as Map? ?? const {},
        );
        _conversationStore.applyRoutePayload({
          ...metadata,
          ...row,
          'session_id': row['session_id'] ?? metadata['session_id'] ?? sessionId,
        }, expectedSessionId: sessionId);
      }
      final events = _mapper.mapHistory(messagesData);
      final queuedEvents = _mapper.mapHistory(queuedMessagesData);
      final inFlight = payload['in_flight'];
      final transientEvents = _conversationStore.currentMessages
          .where((event) => !baselineEventIds.contains(event.id))
          .toList(growable: false);

      if (inFlight is Map) {
        final snapshotEvent = _mapper.mapLiveEvent({
          'device_id': '',
          'event': inFlight['type'] ?? 'thought_stream',
          'payload': Map<String, dynamic>.from(
            inFlight.cast<String, dynamic>(),
          ),
        });
        if (snapshotEvent != null) {
          events.add(snapshotEvent);
        }
      }

      if (_conversationStore.currentSessionId != sessionId) {
        return events;
      }

      final hydratedEvents = retainedHistoryIsComplete
          ? _mergeRetainedHistoryWithHydration(retainedEvents, events)
          : events;
      _conversationStore.setHistory(
        hydratedEvents,
        hasMore: retainedHistoryIsComplete ? false : payload['has_more'] == true,
        nextCursor: retainedHistoryIsComplete ? null : payload['next_cursor']?.toString(),
        hasNewer: retainedHistoryIsComplete ? false : payload['has_newer'] == true,
        nextNewerCursor: retainedHistoryIsComplete ? null : payload['next_newer_cursor']?.toString(),
      );
      _conversationStore.setQueuedMessages(queuedEvents);
      final rawStopRecovery = payload['stop_draft_recovery'];
      if (rawStopRecovery is Map) {
        try {
          _conversationStore.applyStopRecovery(
            StopDraftRecovery.fromJson({
              ...Map<String, dynamic>.from(rawStopRecovery),
              'session_id': sessionId,
            }),
          );
        } on FormatException {
          // The durable payload remains available for a later hydration retry.
        }
      }
      for (final event in transientEvents) {
        if (_isAlreadyRepresentedInHistory(event, events)) {
          continue;
        }
        _conversationStore.apply(event);
      }
      _conversationStore.hydratePendingSteers(
        pendingSteersData.whereType<Map>().map(
          (row) => PendingSteerRecord.fromJson(Map<String, dynamic>.from(row)),
        ),
        sessionId: sessionId,
      );

      return List<CanonicalEvent>.from(_conversationStore.currentMessages);
    }

    _logger.severe(
      'History hydration failed phase=request session_id=$sessionId request_id=$requestId',
    );
    throw StateError('Session history request failed');
  }

  List<CanonicalEvent> _mergeRetainedHistoryWithHydration(
    List<CanonicalEvent> retained,
    List<CanonicalEvent> hydrated,
  ) => CanonicalTimelineReconciler.mergeAuthoritativeSlice(
    retained,
    hydrated,
  );

  Future<List<CanonicalEvent>> loadAnchoredSessionHistory(
    String sessionId,
    String anchorEventId,
  ) {
    return loadSessionHistory(sessionId, anchorEventId: anchorEventId);
  }

  Future<List<CanonicalEvent>> loadOlderSessionHistory(String sessionId) {
    final cursor = _conversationStore.historyNextCursor;
    if (_conversationStore.currentSessionId != sessionId || !_conversationStore.historyHasMore || cursor == null) {
      return Future.value(
        List<CanonicalEvent>.from(_conversationStore.currentMessages),
      );
    }
    final existing = _olderHistoryLoad;
    if (existing != null && _olderHistoryCursor == cursor) return existing;

    final generation = _historyHydrationGeneration;
    final load = _loadOlderSessionHistory(
      sessionId: sessionId,
      cursor: cursor,
      generation: generation,
    );
    _olderHistoryCursor = cursor;
    _olderHistoryLoad = load;
    return load.whenComplete(() {
      if (identical(_olderHistoryLoad, load)) {
        _olderHistoryLoad = null;
        _olderHistoryCursor = null;
      }
    });
  }

  Future<List<CanonicalEvent>> _loadOlderSessionHistory({
    required String sessionId,
    required String cursor,
    required int generation,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'get_session_history',
      payload: {
        'request_id': requestId,
        'session_id': sessionId,
        'limit': 100,
        'cursor': cursor,
      },
      requestId: requestId,
    );
    if (result == null) {
      throw StateError('Older session history request failed');
    }
    if (generation != _historyHydrationGeneration || _conversationStore.currentSessionId != sessionId) {
      return List<CanonicalEvent>.from(_conversationStore.currentMessages);
    }
    _throwHistoryError(result);
    final payload = Map<String, dynamic>.from(result['payload'] as Map? ?? {});
    final events = _mapper.mapHistory(payload['messages'] as List? ?? const []);
    _conversationStore.prependHistory(
      events,
      hasMore: payload['has_more'] == true,
      nextCursor: payload['next_cursor']?.toString(),
      requestedCursor: cursor,
    );
    return List<CanonicalEvent>.from(_conversationStore.currentMessages);
  }

  Future<List<CanonicalEvent>> loadNewerSessionHistory(String sessionId) {
    final cursor = _conversationStore.historyNextNewerCursor;
    if (_conversationStore.currentSessionId != sessionId || !_conversationStore.historyHasNewer || cursor == null) {
      return Future.value(
        List<CanonicalEvent>.from(_conversationStore.currentMessages),
      );
    }
    final existing = _newerHistoryLoad;
    if (existing != null && _newerHistoryCursor == cursor) return existing;

    final generation = _historyHydrationGeneration;
    final load = _loadNewerSessionHistory(
      sessionId: sessionId,
      cursor: cursor,
      generation: generation,
    );
    _newerHistoryCursor = cursor;
    _newerHistoryLoad = load;
    return load.whenComplete(() {
      if (identical(_newerHistoryLoad, load)) {
        _newerHistoryLoad = null;
        _newerHistoryCursor = null;
      }
    });
  }

  Future<List<CanonicalEvent>> _loadNewerSessionHistory({
    required String sessionId,
    required String cursor,
    required int generation,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'get_session_history',
      payload: {
        'request_id': requestId,
        'session_id': sessionId,
        'limit': 100,
        'cursor': cursor,
      },
      requestId: requestId,
    );
    if (result == null) {
      throw StateError('Newer session history request failed');
    }
    if (generation != _historyHydrationGeneration || _conversationStore.currentSessionId != sessionId) {
      return List<CanonicalEvent>.from(_conversationStore.currentMessages);
    }
    _throwHistoryError(result);
    final payload = Map<String, dynamic>.from(result['payload'] as Map? ?? {});
    final events = _mapper.mapHistory(
      payload['messages'] as List? ?? const [],
    );
    _conversationStore.appendHistory(
      events,
      hasNewer: payload['has_newer'] == true,
      nextNewerCursor: payload['next_newer_cursor']?.toString(),
      requestedCursor: cursor,
    );
    return List<CanonicalEvent>.from(_conversationStore.currentMessages);
  }

  void _throwHistoryError(Map<String, dynamic> result) {
    final error = responseError(result);
    if (error == null) return;
    throw StateError('${error.code ?? 'history_failed'}: ${error.message ?? 'Session history request failed'}');
  }

  bool _isAlreadyRepresentedInHistory(
    CanonicalEvent transient,
    List<CanonicalEvent> history,
  ) {
    final matchingHistory = history.where(
      (persisted) => CanonicalTimelineReconciler.matches(
        persisted,
        transient,
        allowLegacyUserFallback: true,
      ),
    );
    final isRepresented = matchingHistory.isNotEmpty;

    // A live tool result can arrive while the history request is in flight.
    // The returned snapshot may still contain the matching tool as running, so
    // identity alone is not enough: reapply the terminal live event to merge
    // its output and advance the stale history row.
    if (transient.kind == EventKind.toolCall &&
        transient.status != EventStatus.running &&
        matchingHistory.any(
          (persisted) => persisted.status == EventStatus.running || isNewerToolTerminalEvent(persisted, transient),
        )) {
      return false;
    }

    // Running thinking chunks may be newer than the persisted in-flight
    // snapshot and must still merge into it.
    if (transient.kind == EventKind.thinking || transient.kind == EventKind.reasoning) {
      return false;
    }
    return isRepresented;
  }
}
