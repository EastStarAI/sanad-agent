import 'dart:async';

import 'package:sanad_client/features/conversations/domain/models/device_processing_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/session_attention_state.dart';
import 'package:sanad_client/features/conversations/domain/models/session_execution_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/stores/session_execution_registry.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/pending_steer_record.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/stores/session_route_registry.dart';

import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_state.dart';

class DeviceConversationStoreSnapshot {
  final List<CanonicalEvent> messages;
  final String? currentSessionId;
  final bool isDraftSession;
  final bool isDraftProcessing;
  final String? pendingSessionRequestId;
  final Set<String> processingSessionIds;
  final DeviceSuspendedRequest? pendingSuspendedRequest;
  final RuntimeNotice? runtimeNotice;
  final Map<String, SessionExecutionSnapshot> executionSnapshots;
  final Map<String, DeviceSuspendedRequest> pendingSuspendedRequests;
  final Map<String, RuntimeNotice> runtimeNotices;
  final Map<String, SessionRouteSnapshot> routeSnapshots;
  final Map<String, Map<String, PendingSteerRecord>> pendingSteers;
  final bool historyHasMore;
  final String? historyNextCursor;

  const DeviceConversationStoreSnapshot({
    required this.messages,
    required this.currentSessionId,
    required this.isDraftSession,
    required this.isDraftProcessing,
    required this.pendingSessionRequestId,
    required this.processingSessionIds,
    required this.pendingSuspendedRequest,
    required this.runtimeNotice,
    this.executionSnapshots = const {},
    this.pendingSuspendedRequests = const {},
    this.runtimeNotices = const {},
    this.routeSnapshots = const {},
    this.pendingSteers = const {},
    this.historyHasMore = false,
    this.historyNextCursor,
  });
}

class DeviceConversationStore {
  final ConversationState _conversation;
  final StreamController<List<CanonicalEvent>> _messagesController = StreamController<List<CanonicalEvent>>.broadcast();
  final StreamController<List<CanonicalEvent>> _queuedMessagesController =
      StreamController<List<CanonicalEvent>>.broadcast();
  final StreamController<DeviceProcessingSnapshot> _processingController =
      StreamController<DeviceProcessingSnapshot>.broadcast();
  final StreamController<DeviceSuspendedRequest?> _pendingSuspendedController =
      StreamController<DeviceSuspendedRequest?>.broadcast();
  final StreamController<RuntimeNotice?> _runtimeNoticeController = StreamController<RuntimeNotice?>.broadcast();
  final StreamController<Map<String, SessionAttentionState>> _attentionController =
      StreamController<Map<String, SessionAttentionState>>.broadcast();
  final StreamController<Map<String, SessionRouteSnapshot>> _routeController =
      StreamController<Map<String, SessionRouteSnapshot>>.broadcast();
  final StreamController<StopDraftRecovery> _stopRecoveryController = StreamController<StopDraftRecovery>.broadcast();

  String? _currentSessionId;
  bool _isDraftSession = false;
  bool _isDraftProcessing = false;
  String? _pendingSessionRequestId;
  final Set<String> _processingSessionIds = {};
  final SessionExecutionRegistry _executionRegistry = SessionExecutionRegistry();
  final SessionRouteRegistry _routeRegistry = SessionRouteRegistry();
  final Map<String, DeviceSuspendedRequest> _pendingSuspendedRequestBySessionId = {};
  final Map<String, RuntimeNotice> _runtimeNoticeBySessionId = {};
  final List<CanonicalEvent> _queuedMessages = [];
  final Map<String, Map<String, PendingSteerRecord>> _pendingSteersBySessionId = {};
  final Set<(String, String)> _stopRecoveredPendingSteerKeys = {};
  bool _historyHasMore = false;
  String? _historyNextCursor;

  DeviceConversationStore({
    ThinkingStreamMode thinkingStreamMode = ThinkingStreamMode.auto,
    DeviceConversationStoreSnapshot? initialSnapshot,
  }) : _conversation = ConversationState(
         thinkingStreamMode: thinkingStreamMode,
       ) {
    if (initialSnapshot != null) {
      _conversation.setHistory(initialSnapshot.messages);
      _currentSessionId = initialSnapshot.currentSessionId;
      _isDraftSession = initialSnapshot.isDraftSession;
      _isDraftProcessing = initialSnapshot.isDraftProcessing;
      _pendingSessionRequestId = initialSnapshot.pendingSessionRequestId;
      for (final snapshot in initialSnapshot.executionSnapshots.values) {
        _executionRegistry.apply(snapshot);
      }
      for (final snapshot in initialSnapshot.routeSnapshots.values) {
        _routeRegistry.apply(snapshot);
      }
      _pendingSuspendedRequestBySessionId.addAll(
        initialSnapshot.pendingSuspendedRequests,
      );
      _runtimeNoticeBySessionId.addAll(initialSnapshot.runtimeNotices);
      for (final entry in initialSnapshot.pendingSteers.entries) {
        _pendingSteersBySessionId[entry.key] = Map<String, PendingSteerRecord>.from(entry.value);
      }
      _historyHasMore = initialSnapshot.historyHasMore;
      _historyNextCursor = initialSnapshot.historyNextCursor;
      final pending = initialSnapshot.pendingSuspendedRequest;
      if (pending != null && pending.sessionId.isNotEmpty) {
        _pendingSuspendedRequestBySessionId[pending.sessionId] = pending;
      }
      final notice = initialSnapshot.runtimeNotice;
      if (notice != null && notice.sessionId.isNotEmpty) {
        _runtimeNoticeBySessionId[notice.sessionId] = notice;
      }
      _syncProcessingProjection();
    }
    _messagesController.add(_conversation.events);
    _emitProcessing();
    _pendingSuspendedController.add(currentPendingSuspendedRequest);
    _runtimeNoticeController.add(currentRuntimeNotice);
    _emitAttention();
    _emitQueuedMessages();
  }

  Stream<List<CanonicalEvent>> get messages => _messagesController.stream;
  Stream<List<CanonicalEvent>> get queuedMessages => _queuedMessagesController.stream;
  Stream<DeviceProcessingSnapshot> get processing => _processingController.stream;
  Stream<DeviceSuspendedRequest?> get pendingSuspendedRequest => _pendingSuspendedController.stream;
  Stream<RuntimeNotice?> get runtimeNotice => _runtimeNoticeController.stream;
  Stream<Map<String, SessionAttentionState>> get attentionStates => _attentionController.stream;
  Stream<Map<String, SessionRouteSnapshot>> get routeSnapshots => _routeController.stream;
  Stream<StopDraftRecovery> get stopRecoveries => _stopRecoveryController.stream;
  List<CanonicalEvent> get currentMessages => _conversation.events;
  List<CanonicalEvent> get currentQueuedMessages => List.unmodifiable(_queuedMessages);
  String? get currentSessionId => _currentSessionId;
  bool get historyHasMore => _historyHasMore;
  String? get historyNextCursor => _historyNextCursor;
  bool get isDraftSession => _isDraftSession;
  String? get pendingSessionRequestId => _pendingSessionRequestId;
  DeviceSuspendedRequest? get currentPendingSuspendedRequest =>
      _currentSessionId == null ? null : _pendingSuspendedRequestBySessionId[_currentSessionId!];
  RuntimeNotice? get currentRuntimeNotice =>
      _currentSessionId == null ? null : _runtimeNoticeBySessionId[_currentSessionId!];
  bool get isProcessing => processingSnapshot.isProcessing;
  bool get isCurrentConversationProcessing {
    if (_isDraftSession) return _isDraftProcessing;
    if (_currentSessionId != null) {
      return _processingSessionIds.contains(_currentSessionId);
    }
    return _isDraftSession && _isDraftProcessing;
  }

  DeviceProcessingSnapshot get processingSnapshot => DeviceProcessingSnapshot(
    isDraftProcessing: _isDraftProcessing,
    sessionIds: Set.unmodifiable(_processingSessionIds),
  );

  DeviceConversationStoreSnapshot get snapshot => DeviceConversationStoreSnapshot(
    messages: List<CanonicalEvent>.unmodifiable(_conversation.events),
    currentSessionId: _currentSessionId,
    isDraftSession: _isDraftSession,
    isDraftProcessing: _isDraftProcessing,
    pendingSessionRequestId: _pendingSessionRequestId,
    processingSessionIds: Set<String>.unmodifiable(_processingSessionIds),
    pendingSuspendedRequest: currentPendingSuspendedRequest,
    runtimeNotice: currentRuntimeNotice,
    executionSnapshots: _executionRegistry.snapshotsBySessionId,
    pendingSuspendedRequests: Map.unmodifiable(
      _pendingSuspendedRequestBySessionId,
    ),
    runtimeNotices: Map.unmodifiable(_runtimeNoticeBySessionId),
    routeSnapshots: _routeRegistry.routesBySessionId,
    pendingSteers: Map<String, Map<String, PendingSteerRecord>>.unmodifiable({
      for (final entry in _pendingSteersBySessionId.entries)
        entry.key: Map<String, PendingSteerRecord>.unmodifiable(
          entry.value,
        ),
    }),
    historyHasMore: _historyHasMore,
    historyNextCursor: _historyNextCursor,
  );

  Map<String, SessionRouteSnapshot> get currentRouteSnapshots => _routeRegistry.routesBySessionId;

  SessionRouteSnapshot? routeSnapshotFor(String sessionId) => _routeRegistry.routeFor(sessionId);

  Map<String, SessionAttentionState> get currentAttentionStates {
    final sessionIds = <String>{
      if (_currentSessionId case final sessionId?) sessionId,
      ..._executionRegistry.snapshotsBySessionId.keys,
      ..._runtimeNoticeBySessionId.keys,
      ..._pendingSuspendedRequestBySessionId.keys,
    };
    return Map.unmodifiable({
      for (final sessionId in sessionIds) sessionId: attentionStateFor(sessionId),
    });
  }

  SessionAttentionState attentionStateFor(String sessionId) => SessionAttentionState(
    sessionId: sessionId,
    executionSnapshot: _executionRegistry.snapshotFor(sessionId),
    runtimeNotice: _runtimeNoticeBySessionId[sessionId],
    pendingSuspendedRequest: _pendingSuspendedRequestBySessionId[sessionId],
  );

  bool isSessionProcessing(String? sessionId) => processingSnapshot.isSessionProcessing(sessionId);
  bool canStopSession(String? sessionId) => sessionId != null && attentionStateFor(sessionId).executionSnapshot.canStop;

  void activateSession(String sessionId) {
    if (_currentSessionId == sessionId) return;
    _currentSessionId = sessionId;
    _isDraftSession = false;
    _pendingSessionRequestId = null;
    _conversation.clear();
    _queuedMessages.clear();
    _historyHasMore = false;
    _historyNextCursor = null;
    _emitMessages();
    _emitQueuedMessages();
    _emitPendingSuspended();
    _emitRuntimeNotice();
  }

  void beginNewSession() {
    _currentSessionId = null;
    _isDraftSession = true;
    _pendingSessionRequestId = null;
    _conversation.clear();
    _queuedMessages.clear();
    _historyHasMore = false;
    _historyNextCursor = null;
    _emitMessages();
    _emitQueuedMessages();
    _emitPendingSuspended();
    _emitRuntimeNotice();
  }

  void beginOutgoingRequest({
    required String requestId,
    String? sessionId,
    bool isDraftRequest = false,
  }) {
    final before = processingSnapshot;
    if (isDraftRequest || sessionId == null) {
      _isDraftProcessing = true;
    }

    _currentSessionId = sessionId;
    if (isDraftRequest || sessionId == null) {
      _isDraftSession = true;
      _pendingSessionRequestId = requestId;
    } else {
      _isDraftSession = false;
      _pendingSessionRequestId = null;
    }

    _emitProcessingIfChanged(before);
  }

  void stopCurrentSession({String? sessionId}) {
    final before = processingSnapshot;
    final targetSessionId = sessionId ?? _currentSessionId;
    if (targetSessionId == null) {
      _isDraftProcessing = false;
    }
    _emitProcessingIfChanged(before);
  }

  bool adoptCreatedSession({
    required String createdSessionId,
    required String? requestId,
  }) {
    final isExpectedDraftSession =
        _isDraftSession && _pendingSessionRequestId != null && requestId == _pendingSessionRequestId;
    if (_isDraftSession && !isExpectedDraftSession) {
      return false;
    }
    if (_currentSessionId != null && createdSessionId != _currentSessionId) {
      return false;
    }

    final before = processingSnapshot;
    _currentSessionId = createdSessionId;
    _isDraftSession = false;
    if (_isDraftProcessing) {
      _isDraftProcessing = false;
    }
    _pendingSessionRequestId = null;
    _emitProcessingIfChanged(before);
    return true;
  }

  bool shouldAcceptStreamingEvent(String? sessionId) {
    return _currentSessionId != null && sessionId != null && sessionId == _currentSessionId;
  }

  void setThinkingStreamMode(ThinkingStreamMode mode) {
    _conversation.updateThinkingStreamMode(mode);
  }

  void apply(CanonicalEvent event) {
    final isQueued = event.metadata?['queued'] == true;
    if (isQueued) {
      final reqId = event.metadata?['request_id'];
      final existingIndex = _queuedMessages.indexWhere(
        (e) => e.metadata?['request_id'] == reqId,
      );
      if (existingIndex != -1) {
        _queuedMessages[existingIndex] = event;
      } else {
        _queuedMessages.add(event);
      }
      _emitQueuedMessages();
    } else {
      final reqId = event.metadata?['request_id'];
      if (reqId != null) {
        _queuedMessages.removeWhere((e) => e.metadata?['request_id'] == reqId);
        _emitQueuedMessages();
      }
      _conversation.apply(event);
      _emitMessages();
    }
  }

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
    if (record.sessionId != _currentSessionId) return;

    final eventId = 'user_${record.requestId}';
    if (record.state == PendingSteerState.cancelled || record.state == PendingSteerState.recovered) {
      _conversation.removeById(eventId);
      _emitMessages();
      return;
    }
    _conversation.apply(
      CanonicalEvent(
        id: eventId,
        kind: EventKind.userMessage,
        text: record.text,
        timestamp: record.receivedAt,
        sessionId: record.sessionId,
        runId: record.runId,
        metadata: {
          'request_id': record.requestId,
          'pending_steer_state': record.state.name,
          'pending_steer_revision': record.revision,
          'generation': record.generation,
        },
      ),
    );
    _emitMessages();
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
    _emitMessages();
  }

  void applyStopRecovery(StopDraftRecovery recovery) {
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
        if (_currentSessionId == recovery.sessionId) {
          _conversation.removeById('user_$requestId');
        }
      }
      if (byRequest?.isEmpty ?? false) {
        _pendingSteersBySessionId.remove(recovery.sessionId);
      }
      if (_currentSessionId == recovery.sessionId) {
        _emitMessages();
      }
    }
    // The daemon clears the queue atomically during stop; mirror that in the
    // client projection so queued messages disappear with the recovery event.
    removeQueuedMessagesForSession(recovery.sessionId);
    if (!_stopRecoveryController.isClosed) {
      _stopRecoveryController.add(recovery);
    }
  }

  void applyPendingSteerCancelOutcome(String requestId, String outcome) {
    final record = _pendingSteersBySessionId.values
        .map((records) => records[requestId])
        .whereType<PendingSteerRecord>()
        .firstOrNull;
    if (record == null || record.sessionId != _currentSessionId) return;
    _conversation.apply(
      CanonicalEvent(
        id: 'user_$requestId',
        kind: EventKind.userMessage,
        text: record.text,
        timestamp: record.receivedAt,
        sessionId: record.sessionId,
        runId: record.runId,
        metadata: {
          'request_id': requestId,
          'pending_steer_state': record.state.name,
          'pending_steer_revision': record.revision,
          'pending_cancel_outcome': outcome,
        },
      ),
    );
    _emitMessages();
  }

  void applyQueueMutationOutcome(String requestId, String outcome) {
    final index = _queuedMessages.indexWhere(
      (event) => event.requestId == requestId,
    );
    if (index == -1) return;
    _queuedMessages[index] = _queuedMessages[index].copyWith(
      metadata: {
        ...?_queuedMessages[index].metadata,
        'queue_mutation_outcome': outcome,
      },
    );
    _emitQueuedMessages();
  }

  void setHistory(
    List<CanonicalEvent> events, {
    bool hasMore = false,
    String? nextCursor,
  }) {
    _conversation.setHistory(events);
    _historyHasMore = hasMore && nextCursor != null;
    _historyNextCursor = _historyHasMore ? nextCursor : null;
    _emitMessages();
  }

  bool prependHistory(
    List<CanonicalEvent> events, {
    required bool hasMore,
    required String? nextCursor,
    required String requestedCursor,
  }) {
    if (_historyNextCursor != requestedCursor) return false;
    final existingIds = _conversation.events.map((event) => event.id).toSet();
    final older = events.where((event) => existingIds.add(event.id)).toList(growable: false);
    _conversation.setHistory([...older, ..._conversation.events]);
    final advanced = nextCursor != null && nextCursor != requestedCursor;
    _historyHasMore = hasMore && advanced;
    _historyNextCursor = _historyHasMore ? nextCursor : null;
    _emitMessages();
    return older.isNotEmpty || !_historyHasMore;
  }

  void applyTurnReplayAccepted({
    required String sessionId,
    required String targetRequestId,
    String? targetTurnId,
    String? targetMessageId,
  }) {
    if (_currentSessionId != sessionId) return;
    final hidden = _conversation.hideSupersededIdentities(
      turnId: targetTurnId,
      messageId: targetMessageId,
    );
    if (hidden) {
      _emitMessages();
    }
  }

  void setQueuedMessages(List<CanonicalEvent> events) {
    _queuedMessages.clear();
    _queuedMessages.addAll(events);
    _emitQueuedMessages();
  }

  void removeQueuedMessagesForSession(String? sessionId) {
    if (sessionId == null) return;
    _queuedMessages.removeWhere((event) => event.sessionId == sessionId);
    _emitQueuedMessages();
  }

  void removeQueuedMessage(String requestId) {
    final before = _queuedMessages.length;
    _queuedMessages.removeWhere((event) => event.requestId == requestId);
    if (_queuedMessages.length != before) {
      _emitQueuedMessages();
    }
  }

  void setPendingSuspendedRequest(DeviceSuspendedRequest? request) {
    if (request == null) {
      final sessionId = _currentSessionId;
      if (sessionId != null) {
        _pendingSuspendedRequestBySessionId.remove(sessionId);
      }
    } else if (request.sessionId.isNotEmpty) {
      _pendingSuspendedRequestBySessionId[request.sessionId] = request;
    }
    _emitPendingSuspended();
    _emitAttention();
  }

  void setRuntimeNotice(RuntimeNotice? notice) {
    if (notice == null || notice.sessionId.isEmpty) {
      return;
    }
    final executionRevision = notice.executionRevision;
    if (executionRevision != null && executionRevision < _executionRegistry.snapshotFor(notice.sessionId).revision) {
      return;
    }
    _runtimeNoticeBySessionId[notice.sessionId] = notice;
    _emitRuntimeNotice();
    _emitAttention();
  }

  void clearRuntimeNotice({
    String? sessionId,
    String? requestId,
    int? executionRevision,
  }) {
    final targetSessionId = sessionId ?? _currentSessionId;
    if (targetSessionId == null || targetSessionId.isEmpty) {
      return;
    }
    final current = _runtimeNoticeBySessionId[targetSessionId];
    if (current == null || (requestId != null && current.requestId != requestId)) {
      return;
    }
    if (executionRevision != null &&
        current.executionRevision != null &&
        executionRevision < current.executionRevision!) {
      return;
    }
    if (_runtimeNoticeBySessionId.remove(targetSessionId) != null) {
      _emitRuntimeNotice();
      _emitAttention();
    }
  }

  void clearPendingSuspendedRequest({String? requestId}) {
    final sessionId = _currentSessionId;
    if (sessionId == null) return;
    final current = _pendingSuspendedRequestBySessionId[sessionId];
    if (requestId != null && current?.requestId != requestId) {
      return;
    }
    if (current == null) {
      return;
    }
    _pendingSuspendedRequestBySessionId.remove(sessionId);
    _emitPendingSuspended();
    _emitAttention();
  }

  void clearPendingSuspendedRequestForSession(
    String sessionId, {
    String? requestId,
  }) {
    final current = _pendingSuspendedRequestBySessionId[sessionId];
    if (current == null || (requestId != null && current.requestId != requestId)) {
      return;
    }
    _pendingSuspendedRequestBySessionId.remove(sessionId);
    _emitPendingSuspended();
    _emitAttention();
  }

  SessionExecutionApplyResult applyExecutionSnapshot(
    SessionExecutionSnapshot snapshot,
  ) {
    final result = _executionRegistry.apply(snapshot);
    if (result.changed) {
      final notice = _runtimeNoticeBySessionId[snapshot.sessionId];
      if (notice?.executionRevision != null && notice!.executionRevision! < result.current.revision) {
        _runtimeNoticeBySessionId.remove(snapshot.sessionId);
        _emitRuntimeNotice();
      }
      final before = processingSnapshot;
      _syncProcessingProjection();
      _emitProcessingIfChanged(before);
      _emitAttention();
    }
    return result;
  }

  SessionExecutionApplyResult applyExecutionPayload(
    Map<String, dynamic> payload, {
    String? expectedSessionId,
  }) => applyExecutionSnapshot(
    SessionExecutionSnapshot.fromJson(
      payload,
      expectedSessionId: expectedSessionId,
    ),
  );

  SessionExecutionApplyResult hydrateExecutionSnapshot(
    Map<String, dynamic>? payload, {
    required String sessionId,
  }) => applyExecutionSnapshot(
    SessionExecutionSnapshot.fromNullablePayload(payload, sessionId: sessionId),
  );

  void hydrateSessionState(
    Map<String, dynamic> payload, {
    required String sessionId,
  }) {
    final executionPayload = payload['execution_snapshot'];
    hydrateExecutionSnapshot(
      executionPayload is Map ? Map<String, dynamic>.from(executionPayload) : null,
      sessionId: sessionId,
    );

    final rawRoute = payload['route_snapshot'];
    final routePayload = rawRoute is Map
        ? Map<String, dynamic>.from(rawRoute)
        : payload.containsKey('route_revision')
        ? Map<String, dynamic>.from(payload)
        : null;
    if (routePayload != null) {
      routePayload['session_id'] ??= sessionId;
      applyRoutePayload(routePayload, expectedSessionId: sessionId);
    }

    final rawAttention = payload['attention_state'];
    final attention = rawAttention is Map ? Map<String, dynamic>.from(rawAttention) : const <String, dynamic>{};
    if (payload.containsKey('pending_permission_request') || attention.containsKey('pending_permission_request')) {
      final rawPermission = payload['pending_permission_request'] ?? attention['pending_permission_request'];
      if (rawPermission is Map) {
        setPendingSuspendedRequest(
          DeviceSuspendedRequest.fromJson({
            ...Map<String, dynamic>.from(rawPermission),
            'session_id': sessionId,
          }),
        );
      } else {
        clearPendingSuspendedRequestForSession(sessionId);
      }
    }

    if (payload.containsKey('runtime_notice') || attention.containsKey('runtime_notice')) {
      final rawNotice = payload['runtime_notice'] ?? attention['runtime_notice'];
      if (rawNotice is Map) {
        final noticePayload = Map<String, dynamic>.from(rawNotice);
        noticePayload['execution_revision'] ??= _executionRegistry.snapshotFor(sessionId).revision;
        setRuntimeNotice(
          RuntimeNotice.fromJson({...noticePayload, 'session_id': sessionId}),
        );
      } else {
        clearRuntimeNotice(sessionId: sessionId);
      }
    }
  }

  SessionRouteApplyResult applyRoutePayload(
    Map<String, dynamic> payload, {
    String? expectedSessionId,
  }) {
    final result = _routeRegistry.applyPayload(
      payload,
      expectedSessionId: expectedSessionId,
    );
    if (result.changed) _emitRoutes();
    return result;
  }

  void removeThinkingByRunId(String? runId) {
    if (runId == null || runId.isEmpty) return;
    _conversation.removeThinkingByRunId(runId);
    _emitMessages();
  }

  void removeRunningThinkingForSession(String? sessionId) {
    if (sessionId == null || sessionId.isEmpty) return;
    _conversation.removeRunningThinkingForSession(sessionId);
    _emitMessages();
  }

  void removeRunningThinkingStep({
    required String? modelStepId,
    String? runId,
    String? sessionId,
  }) {
    if (modelStepId == null || modelStepId.isEmpty) return;
    final changed = _conversation.removeRunningThinkingStep(
      modelStepId: modelStepId,
      runId: runId,
      sessionId: sessionId,
    );
    if (changed) _emitMessages();
  }

  void cancelRunningToolsForRun({
    required String runId,
    String? sessionId,
    String message = 'Command cancelled by user.',
  }) {
    final hadRunningTools = _conversation.events.any(
      (event) =>
          event.kind == EventKind.toolCall &&
          event.status == EventStatus.running &&
          event.runId == runId &&
          (sessionId == null || event.sessionId == sessionId),
    );
    if (!hadRunningTools) return;
    _conversation.cancelRunningToolsForRun(
      runId: runId,
      sessionId: sessionId,
      message: message,
    );
    _emitMessages();
  }

  void updateProcessingState(String? type, String? sessionId) {
    // Compatibility no-op. Session processing is projected exclusively from
    // authoritative execution snapshots.
  }

  void _emitProcessingIfChanged(DeviceProcessingSnapshot before) {
    final after = processingSnapshot;
    if (before.isDraftProcessing == after.isDraftProcessing &&
        before.sessionIds.length == after.sessionIds.length &&
        before.sessionIds.containsAll(after.sessionIds)) {
      return;
    }
    _emitProcessing();
  }

  void _emitProcessing() {
    if (!_processingController.isClosed) {
      _processingController.add(processingSnapshot);
    }
  }

  void dispose() {
    unawaited(_messagesController.close());
    unawaited(_queuedMessagesController.close());
    unawaited(_processingController.close());
    unawaited(_pendingSuspendedController.close());
    unawaited(_runtimeNoticeController.close());
    unawaited(_attentionController.close());
    unawaited(_routeController.close());
    unawaited(_stopRecoveryController.close());
  }

  void _emitMessages() {
    if (!_messagesController.isClosed) {
      _messagesController.add(_conversation.events);
    }
  }

  void _emitQueuedMessages() {
    if (!_queuedMessagesController.isClosed) {
      _queuedMessagesController.add(List.unmodifiable(_queuedMessages));
    }
  }

  void _emitPendingSuspended() {
    if (!_pendingSuspendedController.isClosed) {
      _pendingSuspendedController.add(currentPendingSuspendedRequest);
    }
  }

  void _emitRuntimeNotice() {
    if (!_runtimeNoticeController.isClosed) {
      _runtimeNoticeController.add(currentRuntimeNotice);
    }
  }

  void _syncProcessingProjection() {
    _processingSessionIds
      ..clear()
      ..addAll(
        _executionRegistry.snapshotsBySessionId.values
            .where((snapshot) => snapshot.isExecuting)
            .map((snapshot) => snapshot.sessionId),
      );
  }

  void _emitAttention() {
    if (!_attentionController.isClosed) {
      _attentionController.add(currentAttentionStates);
    }
  }

  void _emitRoutes() {
    if (!_routeController.isClosed) {
      _routeController.add(currentRouteSnapshots);
    }
  }
}
