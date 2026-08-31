import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_session_sync.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'session_turn_request_helpers.dart';

class QueuedRun {
  final GatewayEvent event;
  final AgentTurnRequest request;
  final bool isResume;
  final String? workItemId;

  const QueuedRun({
    required this.event,
    required this.request,
    this.isResume = false,
    this.workItemId,
  });

  QueuedRun copyWith({
    GatewayEvent? event,
    AgentTurnRequest? request,
    bool? isResume,
    String? workItemId,
  }) {
    return QueuedRun(
      event: event ?? this.event,
      request: request ?? this.request,
      isResume: isResume ?? this.isResume,
      workItemId: workItemId ?? this.workItemId,
    );
  }
}

class SessionQueueCoordinator {
  static const _secretsRedactor = SecretsRedactor();

  final Map<String, List<QueuedRun>> _pendingEvents = {};
  final PersistedRuntimeStateRepository? Function() _getPersistedState;
  final String? Function(String providerInstanceId) _defaultModelForProvider;

  SessionQueueCoordinator({
    required PersistedRuntimeStateRepository? Function() getPersistedState,
    required String? Function(String providerInstanceId)
    defaultModelForProvider,
  }) : _getPersistedState = getPersistedState,
       _defaultModelForProvider = defaultModelForProvider;

  List<GatewayEvent> getQueuedEvents(String sessionId) {
    final queue = _pendingEvents[sessionId];
    if (queue == null) {
      return const [];
    }
    return queue.map((entry) => entry.event).toList(growable: false);
  }

  bool hasQueuedEvents(String sessionId) {
    final queue = _pendingEvents[sessionId];
    return queue != null && queue.isNotEmpty;
  }

  Iterable<String> get sessionIds => _pendingEvents.keys;

  SessionWorkItem? enqueue(
    String sessionId,
    GatewayEvent event,
    AgentTurnRequest request,
    SessionWorkState state,
  ) {
    final item = _insertDurableWorkItem(event, request, state);
    final admittedState = item?.state ?? state;
    if (admittedState == SessionWorkState.queued) {
      _pendingEvents
          .putIfAbsent(sessionId, () => [])
          .add(
            QueuedRun(
              event: event,
              request: request,
              workItemId: item?.workItemId,
            ),
          );
    }
    return item;
  }

  QueuedRun? claimNext(String sessionId) {
    final queue = _pendingEvents[sessionId];
    if (queue == null || queue.isEmpty) {
      return null;
    }
    final nextRun = queue.removeAt(0);
    if (queue.isEmpty) {
      _pendingEvents.remove(sessionId);
    }
    final claimed = _getPersistedState()?.claimNextQueuedWorkItem(
      sessionId,
      toState: nextRun.isResume
          ? SessionWorkState.resuming
          : SessionWorkState.running,
    );
    if (claimed != null &&
        nextRun.workItemId != null &&
        claimed.workItemId != nextRun.workItemId) {
      throw StateError(
        'FIFO claim mismatch: expected ${nextRun.workItemId}, got ${claimed.workItemId}',
      );
    }
    return nextRun.copyWith(workItemId: claimed?.workItemId);
  }

  void removePendingEvents(String sessionId) {
    _pendingEvents.remove(sessionId);
  }

  void removeQueuedRunByRequestId(String sessionId, String requestId) {
    final queue = _pendingEvents[sessionId];
    if (queue != null) {
      queue.removeWhere(
        (queuedRun) => requestIdForEvent(queuedRun.event) == requestId,
      );
      if (queue.isEmpty) {
        _pendingEvents.remove(sessionId);
      }
    }
  }

  void rewriteQueuedRoute(
    String sessionId, {
    String? providerInstanceId,
    String? modelId,
    bool allNonTerminal = false,
    bool persist = true,
  }) {
    final queue = _pendingEvents[sessionId];
    if (queue != null && queue.isNotEmpty) {
      _pendingEvents[sessionId] = queue
          .map((queuedRun) {
            var request = overrideTurnRoute(
              queuedRun.request,
              providerInstanceId: providerInstanceId,
              modelId: modelId,
              defaultModelForProvider: _defaultModelForProvider,
            );
            if (getIt.isRegistered<ThinkingRouteSessionSync>()) {
              request = getIt<ThinkingRouteSessionSync>().revalidateTurnRequest(
                request,
              );
            }
            return queuedRun.copyWith(request: request);
          })
          .toList();
    }
    if (!persist) return;
    final store = _getPersistedState();
    if (store == null) return;
    if (allNonTerminal) {
      store.rewriteAllNonTerminalWorkItemRoute(
        sessionId,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
      );
    } else {
      store.rewriteQueuedWorkItemRoute(
        sessionId,
        providerInstanceId: providerInstanceId,
        modelId: modelId,
      );
    }
  }

  void restoreQueue(String sessionId, List<QueuedRun> runs) {
    if (runs.isNotEmpty) {
      _pendingEvents[sessionId] = runs;
    }
  }

  SessionWorkItem? _insertDurableWorkItem(
    GatewayEvent event,
    AgentTurnRequest request,
    SessionWorkState state,
  ) {
    final repo = _getPersistedState();
    if (repo == null) return null;

    final arguments = (
      workItemId:
          'work_${DateTime.now().millisecondsSinceEpoch}_${javaRandInt()}',
      sessionId: event.sessionId,
      requestId:
          request.requestId ??
          event.runId ??
          'run_${DateTime.now().millisecondsSinceEpoch}',
      providerInstanceId: request.effectiveProviderInstanceId,
      modelId: request.model,
      workspaceId: request.workspaceId,
      payload: _secretsRedactor.redactMap({
        'message': event.message.content,
        'eventMetadata': event.metadata,
        'runId': event.runId,
        'thinkingMode': request.thinkingMode,
      }),
      attempt: 0,
    );
    if (state == SessionWorkState.running) {
      return repo.admitWorkItem(
        workItemId: arguments.workItemId,
        sessionId: arguments.sessionId,
        requestId: arguments.requestId,
        providerInstanceId: arguments.providerInstanceId,
        modelId: arguments.modelId,
        workspaceId: arguments.workspaceId,
        payload: arguments.payload,
        attempt: arguments.attempt,
      );
    }
    return repo.enqueueWorkItem(
      workItemId: arguments.workItemId,
      sessionId: arguments.sessionId,
      requestId: arguments.requestId,
      providerInstanceId: arguments.providerInstanceId,
      modelId: arguments.modelId,
      workspaceId: arguments.workspaceId,
      payload: arguments.payload,
      attempt: arguments.attempt,
      state: state,
    );
  }

  static int javaRandInt() {
    return (DateTime.now().microsecondsSinceEpoch % 1000000).abs();
  }
}
