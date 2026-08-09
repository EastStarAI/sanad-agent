import 'dart:convert';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/evolution/models/session_query.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/evolution/models/session_route_transition.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';

import '../sanad_protocol_bridge.dart';

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

  SessionQueryHandler({
    required SessionManager sessionManager,
    required SanadProtocolBridge bridge,
    SessionRunOrchestrator? orchestrator,
    RuntimeRecoveryService? runtimeRecovery,
    PersistedRuntimeStateRepository? persistedState,
    SessionRouteMutationCoordinator? routeCoordinator,
    SessionRouteTransitionRepository? routeTransitions,
  }) : _sessionManager = sessionManager,
       _bridge = bridge,
       _orchestrator = orchestrator,
       _runtimeRecovery = runtimeRecovery,
       _persistedState = persistedState,
       _routeCoordinator = routeCoordinator,
       _routeTransitions = routeTransitions;

  Map<String, dynamic> buildHistoryEnvelope(CanonicalEvent event) {
    final sessionId = event.sessionId ?? 'default';
    final session = _sessionManager.getSession(sessionId);
    final sessionMetadata = _sessionManager.getSessionMetadata(sessionId);
    final pendingPermissionRequest = _sessionManager
        .listSuspendedCheckpoints(status: 'awaiting_permission')
        .where((checkpoint) => checkpoint.sessionId == sessionId)
        .map((checkpoint) => checkpoint.permissionPayload)
        .firstOrNull;
    final messages = session?.messages ?? const <Message>[];
    final latestContextUsage = _latestContextUsage(sessionMetadata, messages);
    final requestId = event.payload['request_id'] as String?;

    final baseTime =
        session?.createdAt ??
        DateTime.now().subtract(Duration(seconds: messages.length));
    var index = 0;

    final historyMessages = <Map<String, dynamic>>[];
    Message? legacyFinalAssistant;
    for (final candidate in messages.reversed) {
      if (candidate.role == MessageRole.assistant &&
          candidate.metadata?['superseded_by_steer'] != true &&
          (candidate.toolCalls == null || candidate.toolCalls!.isEmpty)) {
        legacyFinalAssistant = candidate;
        break;
      }
    }
    for (final message in messages) {
      final msgId = ++index;
      final msgTime = baseTime.add(Duration(seconds: msgId)).toIso8601String();

      if (message.role == MessageRole.user) {
        final metadata = message.metadata;
        historyMessages.add({
          'id': msgId,
          'sender': 'user',
          'type': 'user_message',
          'content': message.content ?? '',
          'created_at': metadata?['received_at'] ?? msgTime,
          'session_id': sessionId,
          ...?metadata == null
              ? null
              : {
                  'metadata': metadata,
                  if (metadata['request_id'] != null)
                    'request_id': metadata['request_id'],
                },
        });
        continue;
      }

      if (message.role == MessageRole.assistant &&
          message.metadata?['superseded_by_steer'] == true) {
        final content = _nonEmpty(message.content);
        if (content != null) {
          final runId = message.metadata?['run_id'];
          final modelStepId = message.metadata?['model_step_id'];
          historyMessages.add({
            'id': msgId,
            'sender': 'ai',
            'type': 'thought',
            'content': content,
            'created_at': message.metadata?['received_at'] ?? msgTime,
            'session_id': sessionId,
            'run_id': ?runId,
            'model_step_id': ?modelStepId,
          });
        }
        continue;
      }

      if (message.role == MessageRole.assistant &&
          message.toolCalls != null &&
          message.toolCalls!.isNotEmpty) {
        final runId = message.metadata?['run_id'];
        final modelStepId = message.metadata?['model_step_id'];
        final reasoningContent = _nonEmpty(message.reasoning);
        final thoughtContent =
            _nonEmpty(message.thought) ?? _nonEmpty(message.content);

        if (reasoningContent != null) {
          historyMessages.add({
            'id': msgId,
            'sender': 'ai',
            'type': 'reasoning',
            'content': reasoningContent,
            'run_id': ?runId,
            'model_step_id': ?modelStepId,
            if (message.metadata?['context_usage'] != null)
              'context_usage': message.metadata!['context_usage'],
            'created_at': msgTime,
            'session_id': sessionId,
          });
          index++;
        }
        if (thoughtContent != null && thoughtContent != reasoningContent) {
          final thoughtId = reasoningContent == null ? msgId : index;
          historyMessages.add({
            'id': thoughtId,
            'sender': 'ai',
            'type': 'thought',
            'content': thoughtContent,
            'run_id': ?runId,
            'model_step_id': ?modelStepId,
            if (message.metadata?['context_usage'] != null)
              'context_usage': message.metadata!['context_usage'],
            'created_at': baseTime
                .add(Duration(seconds: thoughtId))
                .toIso8601String(),
            'session_id': sessionId,
          });
          index++;
        }

        for (final toolCall in message.toolCalls!) {
          historyMessages.add({
            'id': index,
            'sender': 'ai',
            'type': 'tool_use',
            'tool': toolCall.name,
            'input': jsonEncode(toolCall.arguments),
            'status': 'done',
            'run_id': ?runId,
            'model_step_id': ?modelStepId,
            'tool_call_id': toolCall.id,
            if (message.metadata?['context_usage'] != null)
              'context_usage': message.metadata!['context_usage'],
            'created_at': baseTime
                .add(Duration(seconds: index))
                .toIso8601String(),
            'session_id': sessionId,
          });
          index++;
        }
        continue;
      }

      if (message.role == MessageRole.tool) {
        final resolvedToolContext = _resolveToolContext(messages, message);
        final visibleContent =
            message.metadata?['steer_original_content']?.toString() ??
            message.content ??
            '';
        final isError =
            message.metadata?['is_error'] == true ||
            visibleContent.startsWith('Error:');

        historyMessages.add({
          'id': msgId,
          'sender': 'ai',
          'type': 'tool_result',
          'tool': resolvedToolContext.toolName ?? 'Unknown Tool',
          'output': visibleContent,
          'isError': isError,
          if (resolvedToolContext.runId != null)
            'run_id': resolvedToolContext.runId,
          if (resolvedToolContext.modelStepId != null)
            'model_step_id': resolvedToolContext.modelStepId,
          if (resolvedToolContext.toolCallId != null)
            'tool_call_id': resolvedToolContext.toolCallId,
          'created_at': msgTime,
          'session_id': sessionId,
        });
        final steerMessages = message.metadata?['steer_messages'];
        if (steerMessages is List) {
          for (final rawSteer in steerMessages) {
            if (rawSteer is! Map) continue;
            final steer = Map<String, dynamic>.from(rawSteer);
            final text = steer['text']?.toString().trim();
            if (text == null || text.isEmpty) continue;
            final steerId = ++index;
            final steerMetadata = <String, dynamic>{
              'steer': true,
              if (steer['request_id'] != null)
                'request_id': steer['request_id'],
              if (steer['received_at'] != null)
                'received_at': steer['received_at'],
            };
            historyMessages.add({
              'id': steerId,
              'sender': 'user',
              'type': 'user_message',
              'content': text,
              'created_at':
                  steer['received_at'] ??
                  baseTime.add(Duration(seconds: steerId)).toIso8601String(),
              'session_id': sessionId,
              'metadata': steerMetadata,
              if (steer['request_id'] != null)
                'request_id': steer['request_id'],
            });
          }
        }
        continue;
      }

      final meta = message.metadata;
      final reasoning = _nonEmpty(message.reasoning);
      final typedThought = _nonEmpty(message.thought);
      final isTerminalAssistant =
          meta?['terminal_work_item_id'] != null ||
          identical(message, legacyFinalAssistant);
      if (reasoning != null) {
        historyMessages.add({
          'id': msgId,
          'sender': 'ai',
          'type': 'reasoning',
          'content': reasoning,
          if (meta?['run_id'] != null) 'run_id': meta!['run_id'],
          if (meta?['model_step_id'] != null)
            'model_step_id': meta!['model_step_id'],
          if (meta?['context_usage'] != null)
            'context_usage': meta!['context_usage'],
          'created_at': msgTime,
          'session_id': sessionId,
        });
        index++;
      }
      if (typedThought != null && typedThought != reasoning) {
        final thoughtId = reasoning == null ? msgId : index;
        historyMessages.add({
          'id': thoughtId,
          'sender': 'ai',
          'type': 'thought',
          'content': typedThought,
          if (meta?['run_id'] != null) 'run_id': meta!['run_id'],
          if (meta?['model_step_id'] != null)
            'model_step_id': meta!['model_step_id'],
          if (meta?['context_usage'] != null)
            'context_usage': meta!['context_usage'],
          'created_at': baseTime
              .add(Duration(seconds: thoughtId))
              .toIso8601String(),
          'session_id': sessionId,
        });
        index++;
      }
      if (!isTerminalAssistant) {
        final thought = _nonEmpty(message.content);
        if (thought != null &&
            thought != reasoning &&
            thought != typedThought) {
          final thoughtId = reasoning == null && typedThought == null
              ? msgId
              : index;
          historyMessages.add({
            'id': thoughtId,
            'sender': 'ai',
            'type': 'thought',
            'content': thought,
            if (meta?['run_id'] != null) 'run_id': meta!['run_id'],
            if (meta?['model_step_id'] != null)
              'model_step_id': meta!['model_step_id'],
            if (meta?['context_usage'] != null)
              'context_usage': meta!['context_usage'],
            'created_at': baseTime
                .add(Duration(seconds: thoughtId))
                .toIso8601String(),
            'session_id': sessionId,
          });
        }
        continue;
      }
      final finalAnswerId = reasoning == null && typedThought == null
          ? msgId
          : index;
      historyMessages.add({
        'id': finalAnswerId,
        'sender': 'ai',
        'type': 'final_answer',
        'content': message.content ?? '',
        'created_at': baseTime
            .add(Duration(seconds: finalAnswerId))
            .toIso8601String(),
        'session_id': sessionId,
        if (meta != null) ...{
          if (meta['run_id'] != null) 'run_id': meta['run_id'],
          if (meta['model_step_id'] != null)
            'model_step_id': meta['model_step_id'],
          if (meta['model'] != null) 'model': meta['model'],
          if (meta['model_display'] != null)
            'model_display': meta['model_display'],
          if (meta['provider'] != null) 'provider': meta['provider'],
          if (meta['context_tokens'] != null)
            'context_tokens': meta['context_tokens'],
          if (meta['runtime_ms'] != null) 'runtime_ms': meta['runtime_ms'],
          if (meta['usage'] != null) 'usage': meta['usage'],
          if (meta['context_usage'] != null)
            'context_usage': meta['context_usage'],
        },
      });
    }

    if (latestContextUsage != null &&
        !historyMessages.any((row) => row['context_usage'] != null)) {
      for (final row in historyMessages.reversed) {
        final type = row['type'];
        if (type == 'final_answer' ||
            type == 'tool_use' ||
            type == 'thought' ||
            type == 'reasoning') {
          row['context_usage'] = latestContextUsage;
          break;
        }
      }
    }

    for (final transition
        in _routeTransitions?.findForSession(sessionId) ??
            const <SessionRouteTransition>[]) {
      if (transition.source != SessionRouteSource.autoFailover) continue;
      final previousProviderLabel =
          transition.previousProviderDisplayName ??
          transition.previousProviderInstanceId ??
          'the previous provider';
      final nextProviderLabel =
          transition.providerDisplayName ?? transition.providerInstanceId;
      final reasonText = transition.reason?.replaceAll('_', ' ');
      final transitionRow = <String, dynamic>{
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
      // History rows use synthetic timestamps (session creation + index), so
      // comparing them against the real transition time misplaces the notice.
      // Anchor on the durable request_id instead: the transition belongs to
      // the turn that carried that request, right before its next event.
      var insertionIndex = -1;
      final requestId = transition.requestId;
      if (requestId != null && requestId.isNotEmpty) {
        var lastMatch = -1;
        for (var i = 0; i < historyMessages.length; i++) {
          if (historyMessages[i]['request_id']?.toString() == requestId) {
            lastMatch = i;
          }
        }
        if (lastMatch != -1) {
          insertionIndex = lastMatch + 1;
        }
      }
      if (insertionIndex == -1) {
        // Fallback for legacy rows without a request_id: real-time ordering.
        insertionIndex = historyMessages.indexWhere((row) {
          final createdAt = DateTime.tryParse(
            row['created_at']?.toString() ?? '',
          );
          return createdAt != null && createdAt.isAfter(transition.createdAt);
        });
        if (insertionIndex == -1) {
          insertionIndex = historyMessages.length;
        }
      }
      historyMessages.insert(insertionIndex, transitionRow);
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
          'execution_snapshot': _executionSnapshot(sessionId).toPayload(),
          if (session != null)
            ...buildSessionPayload(
              session: session,
              sessionMetadata: sessionMetadata,
              metadataOverrides: {'context_usage': ?latestContextUsage},
            ),
          'context_usage': ?latestContextUsage,
          'messages': historyMessages,
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
          ...?runtimeNotice == null ? null : {'runtime_notice': runtimeNotice},
          'pending_permission_request': pendingPermissionRequest,
          'in_flight': inFlight,
        },
      ),
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
        final payload = buildSessionPayload(
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

  Map<String, dynamic>? buildSessionPreferencesEnvelope(CanonicalEvent event) {
    final sessionId = event.sessionId;
    final model = event.payload['model'] as String?;
    final requestedProvider = event.payload['provider_instance_id'] as String?;
    final requestId = event.payload['request_id'] as String?;

    if (sessionId == null || model == null) {
      return null;
    }

    final session = _sessionManager.getSession(sessionId);
    if (session == null) {
      return null;
    }

    final coordinator = _routeCoordinator;
    final provider = requestedProvider ?? session.providerId;
    if (coordinator != null && provider != null && provider.isNotEmpty) {
      final route = coordinator.mutate(
        sessionId: sessionId,
        providerInstanceId: provider,
        model: model,
        source: SessionRouteSource.user,
        reason: 'preferences_updated',
        requestId: requestId,
      );
      if (!route.changed || route.eventId == null) return null;
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.sessionPreferencesUpdated,
          sessionId: sessionId,
          payload: route.toPayload(),
          eventId: route.eventId!,
          delivery: const DeliveryPolicy.platformFamily(
            PlatformFamily.sanadClient,
          ),
        ),
      );
    }

    _sessionManager.updateSessionModel(sessionId, model);
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.sessionPreferencesUpdated,
        sessionId: sessionId,
        payload: {
          'request_id': requestId,
          'session_id': sessionId,
          'model': model,
        },
      ),
    );
  }

  _ResolvedToolContext _resolveToolContext(
    List<Message> messages,
    Message message,
  ) {
    var toolCallId = message.toolCallId;
    String? toolName;
    String? runId = message.metadata?['run_id']?.toString();
    String? modelStepId = message.metadata?['model_step_id']?.toString();

    if (toolCallId != null) {
      for (final previous in messages) {
        if (previous.role != MessageRole.assistant ||
            previous.toolCalls == null) {
          continue;
        }
        for (final toolCall in previous.toolCalls!) {
          if (toolCall.id == toolCallId) {
            toolName = toolCall.name;
            runId ??= previous.metadata?['run_id']?.toString();
            modelStepId ??= previous.metadata?['model_step_id']?.toString();
            break;
          }
        }
        if (toolName != null) {
          break;
        }
      }
    } else {
      final currentIndex = messages.indexOf(message);
      if (currentIndex != -1) {
        for (var idx = currentIndex - 1; idx >= 0; idx--) {
          final previous = messages[idx];
          if (previous.role == MessageRole.assistant &&
              previous.toolCalls != null &&
              previous.toolCalls!.isNotEmpty) {
            final toolCall = previous.toolCalls!.first;
            toolCallId = toolCall.id;
            toolName = toolCall.name;
            runId ??= previous.metadata?['run_id']?.toString();
            modelStepId ??= previous.metadata?['model_step_id']?.toString();
            break;
          }
        }
      }
    }

    return _ResolvedToolContext(
      toolCallId: toolCallId,
      toolName: toolName,
      runId: runId,
      modelStepId: modelStepId,
    );
  }

  static String? _nonEmpty(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
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

  static Map<String, dynamic>? _latestContextUsage(
    Map<String, dynamic>? sessionMetadata,
    List<Message> messages,
  ) {
    final projected = sessionMetadata?['context_usage'];
    if (projected is Map) {
      return Map<String, dynamic>.from(projected);
    }

    for (final message in messages.reversed) {
      if (message.role != MessageRole.assistant) continue;
      final metadata = message.metadata;
      final stored = metadata?['context_usage'];
      if (stored is Map) return Map<String, dynamic>.from(stored);
      final usage = metadata?['usage'];
      if (usage is! Map) continue;

      int? read(List<String> keys) {
        for (final key in keys) {
          final value = usage[key];
          if (value is num && value >= 0) return value.toInt();
        }
        return null;
      }

      final inputTokens = read(const [
        'input_tokens',
        'prompt_tokens',
        'input',
      ]);
      final outputTokens = read(const [
        'output_tokens',
        'completion_tokens',
        'output',
      ]);
      final totalTokens = read(const ['total_tokens', 'total']);
      final cachedTokens = read(const [
        'cached_tokens',
        'cache_read_input_tokens',
        'cache_read',
      ]);
      final reasoningTokens = read(const ['reasoning_tokens']);
      final snapshot = <String, dynamic>{
        'input_tokens': ?inputTokens,
        'output_tokens': ?outputTokens,
        'total_tokens': ?totalTokens,
        'cached_tokens': ?cachedTokens,
        'reasoning_tokens': ?reasoningTokens,
        if (metadata?['context_tokens'] is num)
          'context_window_tokens': (metadata!['context_tokens'] as num).toInt(),
        if (metadata?['model'] != null) 'model_id': metadata!['model'],
        if (metadata?['provider'] != null)
          'provider_instance_id': metadata!['provider'],
        if (metadata?['run_id'] != null) 'run_id': metadata!['run_id'],
        if (metadata?['model_step_id'] != null)
          'model_step_id': metadata!['model_step_id'],
      };
      if (snapshot.isNotEmpty) return snapshot;
    }
    return null;
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

class _ResolvedToolContext {
  final String? toolCallId;
  final String? toolName;
  final String? runId;
  final String? modelStepId;

  const _ResolvedToolContext({
    required this.toolCallId,
    required this.toolName,
    required this.runId,
    required this.modelStepId,
  });
}
