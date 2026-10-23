import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_thinking/session_route_thinking_control.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_session_sync.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_errors.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/models/session_query.dart';
import 'package:sanad_agent/evolution/models/session_search.dart';
import 'package:sanad_agent/evolution/models/session_history_page.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/compaction/model_context_projection.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/evolution/models/compaction_operation_record.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

import '../sanad_protocol_bridge.dart';
import 'session_history/history_row_placement.dart';
import 'session_history/session_history_projector.dart';

/// Handles session-level queries and lightweight mutations from the Sanad
/// protocol: session history, session list, title updates, deletion, and
/// model preference updates.
///
/// Optional dependencies (`orchestrator`, `runtimeRecovery`) are passed
/// explicitly by the [SanadProtocolBridge] rather than resolved via the service
/// locator, so the handler stays decoupled from other runtime owners.
class SessionQueryHandler {
  final SessionManager _sessionManager;
  final SanadProtocolBridge _bridge;
  final SessionRunOrchestrator? _orchestrator;
  final RuntimeRecoveryService? _runtimeRecovery;
  final PersistedRuntimeStateRepository? _persistedState;
  final SessionRouteMutationCoordinator? _routeCoordinator;
  final SessionRouteTransitionRepository? _routeTransitions;
  final ThinkingSelectionResolver? _thinkingSelectionResolver;
  final ThinkingRoutePreferenceStore? _thinkingPreferenceStore;
  final ThinkingRouteSessionSync? _thinkingRouteSessionSync;
  final CompactionBoundaryRepository? _compactionBoundaries;
  final SessionHistoryProjector _historyProjector;

  SessionQueryHandler({
    required SessionManager sessionManager,
    required SanadProtocolBridge bridge,
    SessionRunOrchestrator? orchestrator,
    RuntimeRecoveryService? runtimeRecovery,
    PersistedRuntimeStateRepository? persistedState,
    SessionRouteMutationCoordinator? routeCoordinator,
    SessionRouteTransitionRepository? routeTransitions,
    ThinkingSelectionResolver? thinkingSelectionResolver,
    ThinkingRoutePreferenceStore? thinkingPreferenceStore,
    ThinkingRouteSessionSync? thinkingRouteSessionSync,
    CompactionBoundaryRepository? compactionBoundaries,
  }) : _sessionManager = sessionManager,
       _bridge = bridge,
       _orchestrator = orchestrator,
       _runtimeRecovery = runtimeRecovery,
       _persistedState = persistedState,
       _routeCoordinator = routeCoordinator,
       _routeTransitions = routeTransitions,
       _thinkingSelectionResolver = thinkingSelectionResolver,
       _thinkingPreferenceStore = thinkingPreferenceStore,
       _thinkingRouteSessionSync = thinkingRouteSessionSync,
       _compactionBoundaries = compactionBoundaries,
       _historyProjector = SessionHistoryProjector(
         toolCallOriginLookup: sessionManager.db.findOriginatingToolCall,
       );

  Map<String, dynamic> _sessionPayloadFor({
    required SessionState session,
    Map<String, dynamic>? sessionMetadata,
    Map<String, dynamic>? metadataOverrides,
  }) {
    final resolver = _thinkingSelectionResolver;
    final correction = _thinkingPreferenceStore
        ?.readCorrection(session.sessionId)
        ?.toMap();
    return buildSessionPayload(
      session: session,
      sessionMetadata: sessionMetadata,
      metadataOverrides: metadataOverrides,
      thinkingControl: resolver == null
          ? null
          : resolveSessionRouteThinkingControl(
              resolver: resolver,
              session: session,
            ),
      thinkingCorrection: correction,
    );
  }

  Map<String, dynamic> buildHistoryEnvelope(CanonicalEvent event) {
    try {
      return _buildHistoryEnvelope(event);
    } on SessionHistoryCursorFormatException catch (error) {
      return _buildHistoryErrorEnvelope(event, 'invalid_cursor', error.message);
    } on SessionHistoryCursorStaleException catch (error) {
      return _buildHistoryErrorEnvelope(event, 'stale_cursor', error.reason);
    } on SessionHistoryAnchorNotFoundException {
      return _buildHistoryErrorEnvelope(
        event,
        'anchor_not_found',
        'The requested history anchor is unavailable.',
      );
    } on RangeError catch (error) {
      return _buildHistoryErrorEnvelope(
        event,
        'invalid_limit',
        error.message.toString(),
      );
    } on FormatException catch (error) {
      return _buildHistoryErrorEnvelope(
        event,
        'invalid_request',
        error.message.toString(),
      );
    }
  }

  Map<String, dynamic> _buildHistoryErrorEnvelope(
    CanonicalEvent event,
    String code,
    String message,
  ) {
    final sessionId =
        event.sessionId ?? event.payload['session_id']?.toString();
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.sessionHistory,
        sessionId: sessionId,
        payload: {
          'request_id': event.payload['request_id'],
          'session_id': ?sessionId,
          'error': {'code': code, 'message': message},
        },
      ),
    );
  }

  Map<String, dynamic> _buildHistoryEnvelope(CanonicalEvent event) {
    final sessionId = event.sessionId ?? 'default';
    final session = _sessionManager.getSession(sessionId);
    final sessionMetadata = _sessionManager.getSessionMetadata(sessionId);
    final pendingPermissionRequest = _sessionManager
        .listSuspendedCheckpoints(status: 'awaiting_permission')
        .where((checkpoint) => checkpoint.sessionId == sessionId)
        .map((checkpoint) => checkpoint.permissionPayload)
        .firstOrNull;
    final request = SessionHistoryRequest.fromPayload(event.payload);
    final cursor = request.cursor;
    final cursorDirection = cursor == null
        ? null
        : SessionHistoryCursor.decode(cursor).direction;
    final anchorRowId = request.anchorRowIdForSession(sessionId);
    final page = session == null
        ? const SessionHistoryPage(
            messages: <PersistedMessage>[],
            hasMore: false,
            nextCursor: null,
            historyRevision: 0,
          )
        : _sessionManager.getPersistedMessagePage(
            sessionId,
            limit: request.limit,
            cursor: cursor,
            anchorRowId: anchorRowId,
          );
    final persistedMessages = page.messages;
    final pageKind = anchorRowId != null
        ? 'anchor'
        : cursor == null
        ? 'tail'
        : cursorDirection == SessionHistoryCursorDirection.newer
        ? 'newer'
        : 'older';
    final includesRuntimeState = cursor == null;
    final isTailPage = pageKind == 'tail';
    final requestId = event.payload['request_id'] as String?;
    final baseTime =
        session?.createdAt ??
        DateTime.now().subtract(Duration(seconds: persistedMessages.length));

    final projection = _historyProjector.project(
      sessionId: sessionId,
      persistedMessages: persistedMessages,
      followingMessage: page.followingMessage,
      baseTime: baseTime,
      sessionMetadata: sessionMetadata,
      activeContinuation:
          _persistedState
              ?.findActiveWorkItem(sessionId)
              ?.continuationMetadata ??
          const {},
    );
    final historyMessages = projection.messages;
    final latestContextUsage = projection.latestContextUsage;

    final placement = HistoryPagePlacement(
      persistedMessages: persistedMessages,
      historyMessages: historyMessages,
      historyStartByMessageRowId: projection.historyStartByMessageRowId,
      isTailPage: isTailPage,
    );
    placement.insertCompactionLifecycleRows(
      _compactionBoundaries?.listLifecycleForSession(sessionId) ??
          const <CompactionOperationRecord>[],
    );

    if (session != null &&
        session.forkSequence > 0 &&
        session.forkedFromMessageId != null &&
        session.forkedFromTurnId != null) {
      placement.insertForkMarker(
        session,
        copiedPrefixEndRowId: _sessionManager.lastActiveForkCopiedRowId(
          sessionId,
        ),
      );
    }

    // Only automatic failover is rendered live (the Client turns
    // `session_preferences_updated` into a timeline tile for that source
    // alone), so history projects the same set for parity.
    for (final transition
        in _routeTransitions?.findForSession(sessionId) ??
            const <SessionRouteTransition>[]) {
      if (transition.source != SessionRouteSource.autoFailover) continue;
      placement.insertRouteTransitionNotice(
        transition,
        anchorRowId: _routeNoticeAnchorRowId(sessionId, transition),
      );
    }

    final inFlight = _sessionManager.getInFlightSnapshot(sessionId);
    final queuedEvents = _orchestrator?.getQueuedEvents(sessionId) ?? const [];
    final runtimeNotice =
        _runtimeRecovery?.activeNotice(sessionId)?.toPayload() ??
        _blockedPersistedNoticePayload(sessionId);
    final pendingSteers =
        _persistedState?.pendingInputs
            .findForSession(sessionId)
            .map((record) => record.toPayload())
            .toList() ??
        const <Map<String, dynamic>>[];
    final stopRecovery = _persistedState?.pendingInputs
        .findUnacknowledgedForSession(sessionId);

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.sessionHistory,
        sessionId: sessionId,
        payload: {
          'request_id': requestId,
          'session_id': sessionId,
          'page_kind': pageKind,
          'has_more': page.hasMore,
          if (page.nextCursor != null) 'next_cursor': page.nextCursor,
          'has_newer': page.hasNewer,
          if (page.nextNewerCursor != null)
            'next_newer_cursor': page.nextNewerCursor,
          'history_revision': page.historyRevision,
          'messages': historyMessages,
          if (includesRuntimeState) ...{
            'execution_snapshot': _executionSnapshot(sessionId).toPayload(),
            if (session != null)
              ..._sessionPayloadFor(
                session: session,
                sessionMetadata: sessionMetadata,
                metadataOverrides: {'context_usage': ?latestContextUsage},
              ),
            'context_usage': ?latestContextUsage,
            'queued_messages': queuedEvents
                .map(
                  (e) => {
                    'sender': 'user',
                    'type': 'user_message',
                    'content': e.message.content ?? '',
                    'session_id': sessionId,
                    'metadata': {
                      'queued': true,
                      'request_id': _queuedRequestIdFor(e),
                    },
                  },
                )
                .toList(),
            'pending_steers': pendingSteers,
            if (stopRecovery != null)
              'stop_draft_recovery': stopRecovery.toPayload(),
            ...?runtimeNotice == null
                ? null
                : {'runtime_notice': runtimeNotice},
            'pending_permission_request': pendingPermissionRequest,
            'in_flight': inFlight,
          },
        },
      ),
    );
  }

  /// Resolves the durable row an automatic-failover notice follows: its
  /// explicit `anchor_message_id`, else its request turn's newest tool result
  /// finished by then (else the turn's root user row).
  int? _routeNoticeAnchorRowId(
    String sessionId,
    SessionRouteTransition transition,
  ) {
    final anchorMessageId = transition.anchorMessageId;
    final anchorRowId = anchorMessageId == null
        ? null
        : _sessionManager.activeRowIdForMessageId(sessionId, anchorMessageId);
    if (anchorRowId != null) return anchorRowId;
    final requestId = transition.requestId;
    if (requestId == null || requestId.isEmpty) return null;
    return _sessionManager.legacyRouteNoticeAnchorRowId(
      sessionId,
      requestId,
      transition.createdAt,
    );
  }

  Map<String, dynamic> buildThreadsEnvelope(CanonicalEvent event) {
    final requestId = event.payload['request_id'];
    try {
      final query = SessionQueryRequest.fromMap(event.payload);
      final result = _sessionManager.getSessions(query);

      final pendingSessionIds = _sessionManager
          .listSuspendedCheckpoints(status: 'awaiting_permission')
          .map((checkpoint) => checkpoint.sessionId)
          .toSet();
      final executionSnapshots = _persistedState?.executionSnapshots
          .findSnapshots(result.sessions.map((session) => session.sessionId));

      final serializedSessions = result.sessions.map((session) {
        final runtimeNotice = _runtimeRecovery?.activeNotice(session.sessionId);
        final payload = _sessionPayloadFor(
          session: session,
          sessionMetadata: _sessionManager.getSessionMetadata(
            session.sessionId,
          ),
          metadataOverrides: {
            'has_pending_permission_request': pendingSessionIds.contains(
              session.sessionId,
            ),
            'has_runtime_recovery_notice': runtimeNotice != null,
            if (runtimeNotice != null)
              'runtime_recovery_status': runtimeNotice.status.name,
          },
        );
        payload['execution_snapshot'] =
            (executionSnapshots?[session.sessionId] ??
                    SessionExecutionSnapshot.virtualIdle(session.sessionId))
                .toPayload();
        return payload;
      }).toList();

      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.sessionsList,
          payload: {
            'request_id': requestId,
            'sessions': serializedSessions,
            'next_cursor': result.nextCursor,
            'has_more': result.hasMore,
          },
        ),
      );
    } on ArgumentError catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'Failed to query sessions: ${e.toString()}',
            'code': 'INVALID_QUERY_PARAMETERS',
          },
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'Failed to query sessions.',
            'code': 'SESSION_QUERY_FAILED',
          },
        ),
      );
    }
  }

  Map<String, dynamic> buildSearchEnvelope(CanonicalEvent event) {
    final requestId = event.payload['request_id'];
    try {
      final request = SessionSearchRequest.fromMap(event.payload);
      final result = _sessionManager.searchSessions(request);
      final hits = result.hits.map((hit) {
        return {
          'session': buildSessionPayload(
            session: hit.session,
            sessionMetadata: _sessionManager.getSessionMetadata(
              hit.session.sessionId,
            ),
          ),
          'match_kind': hit.matchKind.wireValue,
          'snippet': hit.snippet,
          'anchor_event_id': hit.anchorEventId,
        };
      }).toList();
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.sessionSearchResults,
          payload: {
            'request_id': requestId,
            'results': hits,
            'next_cursor': result.nextCursor,
            'has_more': result.hasMore,
          },
        ),
      );
    } on ArgumentError catch (error) {
      return _buildSearchErrorEnvelope(
        requestId,
        'invalid_search_request',
        error.message?.toString() ?? 'Invalid search request.',
      );
    } catch (_) {
      return _buildSearchErrorEnvelope(
        requestId,
        'session_search_failed',
        'Conversation search failed.',
      );
    }
  }

  Map<String, dynamic> _buildSearchErrorEnvelope(
    Object? requestId,
    String code,
    String message,
  ) {
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.sessionSearchResults,
        payload: {
          'request_id': requestId,
          'results': const <Object>[],
          'has_more': false,
          'error': {'code': code, 'message': message},
        },
      ),
    );
  }

  Map<String, dynamic>? buildUpdateSessionTitleEnvelope(CanonicalEvent event) {
    final sessionId = event.sessionId;
    final title = event.payload['title'] as String?;
    final requestId = event.payload['request_id'] as String?;

    if (sessionId == null || title == null) {
      return null;
    }

    _sessionManager.updateSessionTitle(sessionId, title);

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.sessionUpdated,
        sessionId: sessionId,
        payload: {
          'request_id': requestId,
          'session_id': sessionId,
          'title': title,
        },
      ),
    );
  }

  Map<String, dynamic>? buildDeleteSessionEnvelope(CanonicalEvent event) {
    final sessionId = event.sessionId;
    final requestId = event.payload['request_id'] as String?;

    if (sessionId == null) {
      return null;
    }

    _sessionManager.deleteSession(sessionId);

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.sessionDeleted,
        sessionId: sessionId,
        payload: {'request_id': requestId, 'session_id': sessionId},
      ),
    );
  }

  bool _routeOffersThinkingSelection({
    required String providerInstanceId,
    required String modelId,
    required String selectionId,
  }) {
    final resolver = _thinkingSelectionResolver;
    if (resolver == null) return false;
    try {
      resolver.resolve(
        providerInstanceId: providerInstanceId,
        modelId: modelId,
        selectionId: selectionId,
      );
      return true;
    } on ThinkingSelectionException {
      return false;
    }
  }

  Map<String, dynamic>? buildSessionPreferencesEnvelope(CanonicalEvent event) {
    final sessionId = event.sessionId;
    final model = event.payload['model'] as String?;
    final requestedProvider =
        (event.payload['provider_instance_id'] ?? event.payload['provider_id'])
            as String?;
    final thinkingMode = event.payload['thinking_mode'] as String?;
    final hasThinkingModeKey = event.payload.containsKey('thinking_mode');
    final requestId = event.payload['request_id'] as String?;

    if (sessionId == null) {
      return null;
    }
    if (model == null && !hasThinkingModeKey && requestedProvider == null) {
      return null;
    }

    final session = _sessionManager.getSession(sessionId);
    if (session == null) {
      return null;
    }

    String? effectiveThinkingMode;
    if (hasThinkingModeKey) {
      final normalizedThinking = thinkingMode?.trim();
      final clearThinking =
          normalizedThinking == null || normalizedThinking.isEmpty;
      effectiveThinkingMode = clearThinking ? null : normalizedThinking;
      // The choice applies to the route this request leaves the session on.
      final routeProvider = (requestedProvider ?? session.providerId)?.trim();
      final routeModel = (model ?? session.model).trim();
      final sync = _thinkingRouteSessionSync;
      final hasRoute =
          routeProvider != null &&
          routeProvider.isNotEmpty &&
          routeModel.isNotEmpty;
      if (sync != null &&
          hasRoute &&
          (clearThinking ||
              _routeOffersThinkingSelection(
                providerInstanceId: routeProvider,
                modelId: routeModel,
                selectionId: effectiveThinkingMode!,
              ))) {
        // Explicit client sets and clears are route-scoped: record them in the
        // route preference store so neither the next turn nor a later route
        // round trip restores an older stored choice for this route.
        effectiveThinkingMode = sync
            .revalidateAndApplySession(
              sessionId: sessionId,
              providerInstanceId: routeProvider,
              modelId: routeModel,
              selectionId: effectiveThinkingMode,
              restorePreserved: false,
            )
            .selectionId;
      } else {
        // No route-scoped sync, or an option the route does not offer: keep the
        // row-only write so turn admission validates and corrects it as before.
        _sessionManager.updateSessionModeling(
          sessionId,
          thinkingMode: effectiveThinkingMode,
          clearThinkingMode: clearThinking,
        );
      }
    }

    final coordinator = _routeCoordinator;
    final provider = requestedProvider ?? session.providerId;
    if (model != null &&
        coordinator != null &&
        provider != null &&
        provider.isNotEmpty) {
      final route = coordinator.mutate(
        sessionId: sessionId,
        providerInstanceId: provider,
        model: model,
        source: SessionRouteSource.user,
        reason: 'preferences_updated',
        requestId: requestId,
      );
      if (route.changed && route.eventId != null) {
        return _bridge.buildAgentEventEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.sessionPreferencesUpdated,
            sessionId: sessionId,
            payload: {
              ...route.toPayload(),
              if (hasThinkingModeKey) 'thinking_mode': effectiveThinkingMode,
            },
            eventId: route.eventId!,
            delivery: const DeliveryPolicy.platformFamily(
              PlatformFamily.sanadClient,
            ),
          ),
        );
      }
    } else {
      if (model != null) {
        _sessionManager.updateSessionModel(sessionId, model);
      }
      if (requestedProvider != null) {
        _sessionManager.updateSessionProviderId(sessionId, requestedProvider);
      }
    }

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.sessionUpdated,
        sessionId: sessionId,
        payload: {
          'request_id': requestId,
          'session_id': sessionId,
          'model': ?model,
          'provider_id': ?requestedProvider,
          'provider_instance_id': ?requestedProvider,
          if (hasThinkingModeKey) 'thinking_mode': effectiveThinkingMode,
        },
      ),
    );
  }

  String? _queuedRequestIdFor(GatewayEvent event) {
    final turnRequestId = event.turnRequest?.requestId;
    if (turnRequestId != null && turnRequestId.isNotEmpty) {
      return turnRequestId;
    }
    final payload = event.metadata['payload'];
    if (payload is Map) {
      final requestId = payload['request_id']?.toString();
      if (requestId != null && requestId.isNotEmpty) {
        return requestId;
      }
    }
    return event.runId;
  }

  Map<String, dynamic>? _blockedPersistedNoticePayload(String sessionId) {
    final persisted = _orchestrator?.persistedState?.findNotice(sessionId);
    if (persisted == null || persisted.status != 'blocked') {
      return null;
    }
    final payload = Map<String, dynamic>.from(persisted.toPayload());
    final actions = <String>{
      ...((payload['actions'] as List?) ?? const []).map((e) => e.toString()),
      'stop',
      'retry',
      'changeProvider',
    }.toList();
    payload['actions'] = actions;
    return payload;
  }

  SessionExecutionSnapshot _executionSnapshot(String sessionId) {
    return _persistedState?.executionSnapshots.getSnapshot(sessionId) ??
        SessionExecutionSnapshot.virtualIdle(sessionId);
  }
}
