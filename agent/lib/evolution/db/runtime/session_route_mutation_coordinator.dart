import 'dart:async';

import 'package:uuid/uuid.dart';

import '../../../core/provider_runtime/provider_instance_repository.dart';
import '../../models/session_route_transition.dart';
import '../../models/session_execution_snapshot.dart';
import '../agent_state_database.dart';
import '../persisted_runtime_state_repository.dart';
import 'session_execution_state_coordinator.dart';
import 'session_execution_snapshot_repository.dart';
import 'session_route_transition_repository.dart';
import 'session_work_item_repository.dart';

/// Authoritative owner of a session provider/model route.
///
/// A real route change updates the session row, every non-terminal work item,
/// the independent route revision, and its durable transition under one
/// SQLite transaction. Callers may publish the committed result when the
/// mutation originated inside the runtime rather than a command response.
class SessionRouteMutationCoordinator {
  final AgentStateDatabase _state;
  final SessionWorkItemRepository _workItems;
  final SessionRouteTransitionRepository _transitions;
  final ProviderInstanceRepository _providerInstances;
  final SessionExecutionSnapshotRepository _snapshots;
  final SessionExecutionStateCoordinator? _executionState;
  final Uuid _uuid;
  final StreamController<SessionRouteMutationResult> _changes =
      StreamController<SessionRouteMutationResult>.broadcast(sync: true);

  SessionRouteMutationCoordinator({
    required AgentStateDatabase state,
    required SessionWorkItemRepository workItems,
    required SessionRouteTransitionRepository transitions,
    required ProviderInstanceRepository providerInstances,
    SessionExecutionSnapshotRepository? snapshots,
    SessionExecutionStateCoordinator? executionState,
    Uuid? uuid,
  }) : _state = state,
       _workItems = workItems,
       _transitions = transitions,
       _providerInstances = providerInstances,
       _snapshots = snapshots ?? SessionExecutionSnapshotRepository(state),
       _executionState = executionState,
       _uuid = uuid ?? const Uuid();

  Stream<SessionRouteMutationResult> get changes => _changes.stream;

  /// Resolves the current display name for a provider instance so transition
  /// rows snapshot a human-readable name at write time.
  String? _displayNameFor(String? instanceId) {
    if (instanceId == null || instanceId.isEmpty) return null;
    return _providerInstances.findById(instanceId)?.displayName;
  }

  /// Atomically claims the exact waiting owner and commits its failover route.
  /// A null result means the callback is stale or recovery no longer owns the
  /// expected work; callers must not continue on the alternate provider.
  SessionRouteMutationResult? claimAutoFailover({
    required String sessionId,
    required String? workItemId,
    required String? runId,
    required int? generation,
    required String expectedProviderInstanceId,
    required String providerInstanceId,
    required String model,
    required String reason,
    String? requestId,
    bool publish = false,
  }) {
    if (workItemId == null || runId == null || generation == null) return null;
    final normalizedProvider = providerInstanceId.trim();
    final normalizedModel = model.trim();
    if (normalizedProvider.isEmpty || normalizedModel.isEmpty) return null;

    SessionExecutionSnapshotChange? committedExecution;
    final result = _state.transaction<SessionRouteMutationResult?>((tx) {
      final active = _workItems.findActiveWorkItem(sessionId);
      if (active == null ||
          active.workItemId != workItemId ||
          active.state != SessionWorkState.waiting ||
          active.continuationMetadata['owner_run_id'] != runId ||
          active.continuationMetadata['owner_generation'] != generation ||
          (requestId != null && active.requestId != requestId)) {
        return null;
      }
      final notices = tx.db.select(
        'SELECT request_id, run_id, status FROM session_runtime_notices '
        'WHERE session_id = ?',
        [sessionId],
      );
      if (notices.isEmpty ||
          notices.first['status'] != 'waiting' ||
          notices.first['run_id'] != runId ||
          (requestId != null && notices.first['request_id'] != requestId)) {
        return null;
      }
      final sessions = tx.db.select(
        'SELECT provider_id, model, route_revision, route_updated_at '
        'FROM sessions WHERE session_id = ?',
        [sessionId],
      );
      if (sessions.isEmpty ||
          sessions.first['provider_id'] != expectedProviderInstanceId) {
        return null;
      }
      final row = sessions.first;
      final previousProvider = row['provider_id'] as String?;
      final previousDisplayName = _displayNameFor(previousProvider);
      final newDisplayName = _displayNameFor(normalizedProvider);
      final routeRevision = ((row['route_revision'] as int?) ?? 1) + 1;
      final updatedAt = DateTime.now().toUtc();
      final eventId = 'evt_${_uuid.v4()}';

      _workItems.transitionWorkItemState(
        workItemId: workItemId,
        fromState: SessionWorkState.waiting,
        toState: SessionWorkState.resuming,
        transaction: tx,
      );
      tx.db.execute(
        'UPDATE sessions SET provider_id = ?, model = ?, route_revision = ?, '
        'route_updated_at = ?, updated_at = ? WHERE session_id = ?',
        [
          normalizedProvider,
          normalizedModel,
          routeRevision,
          updatedAt.toIso8601String(),
          updatedAt.toIso8601String(),
          sessionId,
        ],
      );
      _workItems.rewriteAllNonTerminalWorkItemRoute(
        sessionId,
        providerInstanceId: normalizedProvider,
        modelId: normalizedModel,
        transaction: tx,
      );
      _transitions.insert(
        SessionRouteTransition(
          sessionId: sessionId,
          routeRevision: routeRevision,
          eventId: eventId,
          source: SessionRouteSource.autoFailover,
          previousProviderInstanceId: previousProvider,
          providerInstanceId: normalizedProvider,
          previousProviderDisplayName: previousDisplayName,
          providerDisplayName: newDisplayName,
          model: normalizedModel,
          reason: reason,
          requestId: requestId,
          createdAt: updatedAt,
        ),
        transaction: tx,
      );
      committedExecution = _snapshots.updateSnapshot(
        sessionId: sessionId,
        state: SessionExecutionState.resuming,
        workItemId: workItemId,
        requestId: active.requestId,
        transaction: tx,
        updatedAt: updatedAt,
        turnStartedAt: active.createdAt,
      );
      return SessionRouteMutationResult(
        sessionId: sessionId,
        source: SessionRouteSource.autoFailover,
        previousProviderInstanceId: previousProvider,
        providerInstanceId: normalizedProvider,
        previousProviderDisplayName: previousDisplayName,
        providerDisplayName: newDisplayName,
        model: normalizedModel,
        reason: reason,
        requestId: requestId,
        routeRevision: routeRevision,
        updatedAt: updatedAt,
        eventId: eventId,
        changed: true,
      );
    });
    final execution = committedExecution;
    if (execution != null) {
      _executionState?.publishCommittedChange(execution);
    }
    if (publish && result != null) _changes.add(result);
    return result;
  }

  SessionRouteMutationResult mutate({
    required String sessionId,
    required String providerInstanceId,
    required String model,
    required SessionRouteSource source,
    String? reason,
    String? requestId,
    bool publish = false,
  }) {
    final normalizedProvider = providerInstanceId.trim();
    final normalizedModel = model.trim();
    if (normalizedProvider.isEmpty || normalizedModel.isEmpty) {
      throw ArgumentError('Session route requires a provider and model.');
    }
    final newDisplayName = _displayNameFor(normalizedProvider);

    final result = _state.transaction((tx) {
      final rows = tx.db.select(
        'SELECT provider_id, model, route_revision, route_updated_at '
        'FROM sessions WHERE session_id = ?',
        [sessionId],
      );
      if (rows.isEmpty) {
        throw StateError('Session $sessionId not found');
      }
      final row = rows.first;
      final previousProvider = row['provider_id'] as String?;
      final previousDisplayName = _displayNameFor(previousProvider);
      final previousModel = row['model']! as String;
      final currentRevision = (row['route_revision'] as int?) ?? 1;
      final currentUpdatedAt = DateTime.parse(
        (row['route_updated_at'] as String?) ??
            DateTime.fromMillisecondsSinceEpoch(
              0,
              isUtc: true,
            ).toIso8601String(),
      ).toUtc();

      if (previousProvider == normalizedProvider &&
          previousModel == normalizedModel) {
        return SessionRouteMutationResult(
          sessionId: sessionId,
          source: source,
          previousProviderInstanceId: previousProvider,
          providerInstanceId: normalizedProvider,
          model: normalizedModel,
          reason: reason,
          requestId: requestId,
          routeRevision: currentRevision,
          updatedAt: currentUpdatedAt,
          eventId: null,
          changed: false,
        );
      }

      final routeRevision = currentRevision + 1;
      final updatedAt = DateTime.now().toUtc();
      final eventId = 'evt_${_uuid.v4()}';
      tx.db.execute(
        '''
        UPDATE sessions
        SET provider_id = ?, model = ?, route_revision = ?,
            route_updated_at = ?, updated_at = ?
        WHERE session_id = ?
        ''',
        [
          normalizedProvider,
          normalizedModel,
          routeRevision,
          updatedAt.toIso8601String(),
          updatedAt.toIso8601String(),
          sessionId,
        ],
      );
      _workItems.rewriteAllNonTerminalWorkItemRoute(
        sessionId,
        providerInstanceId: normalizedProvider,
        modelId: normalizedModel,
        transaction: tx,
      );
      _transitions.insert(
        SessionRouteTransition(
          sessionId: sessionId,
          routeRevision: routeRevision,
          eventId: eventId,
          source: source,
          previousProviderInstanceId: previousProvider,
          providerInstanceId: normalizedProvider,
          previousProviderDisplayName: previousDisplayName,
          providerDisplayName: newDisplayName,
          model: normalizedModel,
          reason: reason,
          requestId: requestId,
          createdAt: updatedAt,
        ),
        transaction: tx,
      );
      return SessionRouteMutationResult(
        sessionId: sessionId,
        source: source,
        previousProviderInstanceId: previousProvider,
        providerInstanceId: normalizedProvider,
        previousProviderDisplayName: previousDisplayName,
        providerDisplayName: newDisplayName,
        model: normalizedModel,
        reason: reason,
        requestId: requestId,
        routeRevision: routeRevision,
        updatedAt: updatedAt,
        eventId: eventId,
        changed: true,
      );
    });
    if (publish && result.changed) {
      _changes.add(result);
    }
    return result;
  }
}

class SessionRouteMutationResult {
  final String sessionId;
  final SessionRouteSource source;
  final String? previousProviderInstanceId;
  final String providerInstanceId;
  final String? previousProviderDisplayName;
  final String? providerDisplayName;
  final String model;
  final String? reason;
  final String? requestId;
  final int routeRevision;
  final DateTime updatedAt;
  final String? eventId;
  final bool changed;

  const SessionRouteMutationResult({
    required this.sessionId,
    required this.source,
    required this.previousProviderInstanceId,
    required this.providerInstanceId,
    this.previousProviderDisplayName,
    this.providerDisplayName,
    required this.model,
    required this.reason,
    required this.requestId,
    required this.routeRevision,
    required this.updatedAt,
    required this.eventId,
    required this.changed,
  });

  Map<String, dynamic> toPayload() => {
    'session_id': sessionId,
    'source': source.storageValue,
    'previous_provider_instance_id': previousProviderInstanceId,
    'provider_instance_id': providerInstanceId,
    if (previousProviderDisplayName != null)
      'previous_provider_display_name': previousProviderDisplayName,
    if (providerDisplayName != null)
      'provider_display_name': providerDisplayName,
    'model': model,
    'reason': reason,
    'request_id': requestId,
    'route_revision': routeRevision,
    'updated_at': updatedAt.toUtc().toIso8601String(),
  };
}
