import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_event_handler.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/pending_steer_record.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  late FakeSanadSocketService socket;
  late SocketConversationCommandGateway gateway;
  late DeviceConversationStore store;
  late ConversationEventHandler handler;

  setUp(() {
    socket = FakeSanadSocketService()..setConnected(true);
    gateway = SocketConversationCommandGateway(
      config: DeviceConfig(id: 'agent-1', name: 'SanadAgent'),
      controller: socket,
    );
    store = DeviceConversationStore()..activateSession('session-1');
    handler = ConversationEventHandler(
      deviceId: 'agent-1',
      gateway: gateway,
      conversationStore: store,
      mapper: UnifiedDeviceMapper(),
    );
  });

  tearDown(() {
    handler.dispose();
    gateway.dispose();
    store.dispose();
    socket.dispose();
  });

  test('applies streaming events for the active session', () async {
    socket.eventRouter.routeEvent(
      _envelope('final_answer', {
        'content': 'answer',
        'session_id': 'session-1',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages.single.kind, EventKind.finalAnswer);
    expect(store.currentMessages.single.text, 'answer');
  });

  test('tracks background execution only from an authoritative snapshot', () async {
    socket.eventRouter.routeEvent(
      _envelope('thought_stream', {
        'content': 'background',
        'session_id': 'session-2',
      }),
    );
    socket.eventRouter.routeEvent(
      _executionEnvelope('session-2', state: 'running', revision: 1),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages, isEmpty);
    expect(store.isSessionProcessing('session-2'), isTrue);
  });

  test('compaction lifecycle updates only its active session timeline', () async {
    for (final status in ['started', 'completed', 'failed']) {
      socket.eventRouter.routeEvent(
        _envelope('context_compaction.$status', {
          'session_id': 'session-2',
          'compaction_id': 'background-compaction-$status',
          'trigger': 'manual',
          'status': status,
          'started_at': '2026-09-01T05:00:00.000Z',
          if (status != 'started') 'completed_at': '2026-09-01T05:00:01.000Z',
        }),
      );
    }
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages, isEmpty);

    socket.eventRouter.routeEvent(
      _envelope('context_compaction.completed', {
        'session_id': 'session-1',
        'compaction_id': 'active-compaction',
        'trigger': 'manual',
        'status': 'completed',
        'started_at': '2026-09-01T05:00:01.000Z',
        'completed_at': '2026-09-01T05:00:02.000Z',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages, hasLength(1));
    expect(
      store.currentMessages.single.metadata,
      containsPair('compaction_id', 'active-compaction'),
    );
  });

  test('stopped removes only the active model step and preserves completed thoughts', () async {
    socket.eventRouter.routeEvent(
      _envelope('thought_stream', {
        'content': 'completed first thought',
        'session_id': 'session-1',
        'run_id': 'run-1',
        'model_step_id': 'step-1',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('tool_use', {
        'tool': 'lookup',
        'input': '{}',
        'session_id': 'session-1',
        'run_id': 'run-1',
        'model_step_id': 'step-1',
        'tool_call_id': 'tool-1',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('thought_stream', {
        'content': 'unfinished second thought',
        'session_id': 'session-1',
        'run_id': 'run-1',
        'model_step_id': 'step-2',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('stopped', {
        'session_id': 'session-1',
        'run_id': 'run-1',
        'model_step_id': 'step-2',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    final thoughts = store.currentMessages.where((event) => event.kind == EventKind.thinking).toList();
    expect(thoughts, hasLength(1));
    expect(thoughts.single.modelStepId, 'step-1');
    expect(thoughts.single.status, EventStatus.done);
    expect(store.isCurrentConversationProcessing, isFalse);
  });

  test('stopped without partial content removes active streaming bubble', () async {
    socket.eventRouter.routeEvent(
      _envelope('thought_stream', {
        'content': 'partial that should disappear',
        'session_id': 'session-1',
        'run_id': 'run-1',
        'model_step_id': 'step-1',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('stopped', {
        'session_id': 'session-1',
        'run_id': 'run-1',
        'model_step_id': 'step-1',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages.any((event) => event.kind == EventKind.thinking), isFalse);
    expect(store.isCurrentConversationProcessing, isFalse);
  });

  test('recovery-only stopped event preserves completed conversation thoughts', () async {
    socket.eventRouter.routeEvent(
      _envelope('thought', {
        'content': 'persisted thought',
        'session_id': 'session-1',
        'run_id': 'run-1',
        'model_step_id': 'step-1',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('stopped', {'session_id': 'session-1'}),
    );
    await Future<void>.delayed(Duration.zero);

    final thoughts = store.currentMessages.where(
      (event) => event.kind == EventKind.thinking,
    );
    expect(thoughts.single.modelStepId, 'step-1');
    expect(thoughts.single.status, EventStatus.done);
  });

  test('stopped clears processing for a client-created session before session_created arrives', () async {
    store.activateSession('client-session-1');
    store.updateProcessingState('thought_stream', 'client-session-1');

    socket.eventRouter.routeEvent(
      _envelope('stopped', {
        'session_id': 'client-session-1',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.isCurrentConversationProcessing, isFalse);
  });

  test('preserves restart claim metadata on stop draft recovery', () async {
    final recoveryFuture = store.stopRecoveries.first;
    socket.eventRouter.routeEvent(
      _envelope('session.stop_draft_recovery', {
        'session_id': 'session-1',
        'stop_request_id': 'restart-stop-1',
        'recovery_reason': 'daemon_restart',
        'claim_required': false,
        'claimed_by': 'claim-1',
        'items': [
          {
            'request_id': 'message-1',
            'source': 'queued',
            'text': 'recover me',
            'received_at': '2026-07-15T10:30:00Z',
          },
        ],
      }),
    );

    final StopDraftRecovery recovery = await recoveryFuture;
    expect(recovery.recoveryReason, 'daemon_restart');
    expect(recovery.claimRequired, isFalse);
    expect(recovery.claimedBy, 'claim-1');
    expect(recovery.inputs.single.text, 'recover me');
  });

  test('stop draft recovery clears queued messages for the session', () async {
    // Seed a queued message in the store.
    store.apply(
      CanonicalEvent(
        id: 'queued-1',
        kind: EventKind.userMessage,
        text: 'queued message',
        sessionId: 'session-1',
        metadata: {'queued': true, 'request_id': 'message-1'},
        timestamp: DateTime.parse('2026-07-15T10:30:00Z'),
      ),
    );
    expect(store.currentQueuedMessages, hasLength(1));

    final recoveryFuture = store.stopRecoveries.first;
    socket.eventRouter.routeEvent(
      _envelope('session.stop_draft_recovery', {
        'session_id': 'session-1',
        'stop_request_id': 'stop-1',
        'items': [
          {
            'request_id': 'message-1',
            'source': 'queued',
            'text': 'queued message',
            'received_at': '2026-07-15T10:30:00Z',
          },
        ],
      }),
    );
    await recoveryFuture;

    expect(store.currentQueuedMessages, isEmpty);
  });

  test('stop draft recovery removes its pending steer bubble and blocks stale replay', () async {
    Map<String, dynamic> pendingSteerPayload({required int revision}) => {
      'session_id': 'session-1',
      'request_id': 'pending-1',
      'run_id': 'run-1',
      'generation': 1,
      'text': 'return me to the composer',
      'received_at': '2026-07-15T10:00:00Z',
      'state': 'pending',
      'revision': revision,
    };

    socket.eventRouter.routeEvent(
      _envelope(
        'session.pending_steer_changed',
        pendingSteerPayload(revision: 1),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(store.currentMessages.single.id, 'user_pending-1');

    final recoveryFuture = store.stopRecoveries.first;
    socket.eventRouter.routeEvent(
      _envelope('session.stop_draft_recovery', {
        'session_id': 'session-1',
        'stop_request_id': 'stop-1',
        'items': [
          {
            'request_id': 'pending-1',
            'source': 'pending_steer',
            'text': 'return me to the composer',
            'received_at': '2026-07-15T10:00:00Z',
          },
        ],
      }),
    );
    final recovery = await recoveryFuture;

    expect(recovery.inputs.single.requestId, 'pending-1');
    expect(store.currentMessages, isEmpty);

    socket.eventRouter.routeEvent(
      _envelope(
        'session.pending_steer_changed',
        pendingSteerPayload(revision: 2),
      ),
    );
    await Future<void>.delayed(Duration.zero);
    expect(store.currentMessages, isEmpty);
  });

  test('error removes the active streaming bubble when no partial snapshot is rendered', () async {
    socket.eventRouter.routeEvent(
      _envelope('thought_stream', {
        'content': 'partial',
        'session_id': 'session-1',
        'run_id': 'run-1',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('error', {
        'content': 'boom',
        'session_id': 'session-1',
        'run_id': 'run-1',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages.any((event) => event.kind == EventKind.thinking), isFalse);
    expect(store.currentMessages.single.kind, EventKind.error);
  });

  test('authoritative permission resolution clears the matching request', () async {
    socket.eventRouter.routeEvent(
      _envelope('tool_permission_request', {
        'session_id': 'session-1',
        'request_id': 'permission-1',
        'tool_name': 'system_ask_user',
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(store.currentPendingSuspendedRequest?.requestId, 'permission-1');

    socket.eventRouter.routeEvent(
      _envelope('tool_permission_resolved', {
        'session_id': 'session-1',
        'request_id': 'permission-1',
        'outcome': 'already_resolved',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentPendingSuspendedRequest, isNull);
  });

  test('runtime blocked notice does not change authoritative execution', () async {
    socket.eventRouter.routeEvent(
      _executionEnvelope('session-1', state: 'running', revision: 1),
    );

    socket.eventRouter.routeEvent(
      _envelope('session.runtime_notice', {
        'session_id': 'session-1',
        'status': 'blocked',
        'reason': 'network_error',
        'title': 'Connection failed',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.isCurrentConversationProcessing, isTrue);
    expect(store.isSessionProcessing('session-1'), isTrue);
    expect(store.currentRuntimeNotice?.title, 'Connection failed');
    expect(store.currentRuntimeNotice?.reason, 'network_error');
  });

  test('resuming snapshot restores processing independently of notices', () async {
    socket.eventRouter.routeEvent(
      _envelope('session.runtime_notice', {
        'session_id': 'session-1',
        'status': 'blocked',
        'reason': 'network_error',
      }),
    );
    socket.eventRouter.routeEvent(
      _executionEnvelope('session-1', state: 'resuming', revision: 1),
    );
    socket.eventRouter.routeEvent(
      _envelope('session.runtime_notice', {
        'session_id': 'session-1',
        'status': 'resuming',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.isCurrentConversationProcessing, isTrue);
    expect(store.isSessionProcessing('session-1'), isTrue);
    expect(store.currentRuntimeNotice?.status, 'resuming');
  });

  test('runtime notice cleared removes the active runtime banner state', () async {
    socket.eventRouter.routeEvent(
      _envelope('session.runtime_notice', {
        'session_id': 'session-1',
        'status': 'waiting',
        'reason': 'provider_rate_limit',
        'title': 'Rate limit reached',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('session.runtime_notice_cleared', {
        'session_id': 'session-1',
        'status': 'cleared',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentRuntimeNotice, isNull);
  });

  test('stopped clears the runtime notice fallback state for the session', () async {
    socket.eventRouter.routeEvent(
      _envelope('session.runtime_notice', {
        'session_id': 'session-1',
        'status': 'waiting',
        'reason': 'provider_rate_limit',
        'title': 'Rate limit reached',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('stopped', {
        'session_id': 'session-1',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentRuntimeNotice, isNull);
  });

  test('ignores events for a different agent id', () async {
    socket.eventRouter.routeEvent({
      'device_id': 'other-agent',
      'event': 'final_answer',
      'payload': {
        'content': 'not mine',
        'session_id': 'session-1',
      },
    });
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages, isEmpty);
  });

  test('same-revision live auto-failover enriches list route and renders once across transports', () async {
    store.hydrateSessionState({
      'session_id': 'session-1',
      'provider_instance_id': 'provider-new',
      'model': 'glm-5.2-exact',
      'route_revision': 4,
      'route_updated_at': '2026-07-15T10:00:00Z',
    }, sessionId: 'session-1');
    final confirmation = _envelope('session_preferences_updated', {
      'session_id': 'session-1',
      'source': 'auto_failover',
      'previous_provider_instance_id': 'provider-old',
      'provider_instance_id': 'provider-new',
      'model': 'glm-5.2-exact',
      'reason': 'provider_rate_limit',
      'route_revision': 4,
      'route_updated_at': '2026-07-15T10:00:00Z',
      'event_id': 'route-event-4',
    });

    socket.eventRouter.routeEvent(confirmation);
    socket.eventRouter.routeEvent(confirmation);
    await Future<void>.delayed(Duration.zero);

    expect(store.currentRouteSnapshots['session-1']?.source.name, 'autoFailover');
    expect(store.currentMessages, hasLength(1));
    expect(store.currentMessages.single.kind, EventKind.informational);
    expect(store.currentMessages.single.text, contains('provider-old'));
    expect(store.currentMessages.single.text, contains('provider-new'));
    expect(store.currentMessages.single.text, contains('provider rate limit'));
    expect(store.currentMessages.single.text, contains('glm-5.2-exact'));
  });

  test('history and live route transition share logical dedupe identity', () async {
    final mapper = UnifiedDeviceMapper();
    final history = mapper.mapHistory([
      {
        'id': 'persisted-route-id',
        'type': 'session_route_transition',
        'session_id': 'session-1',
        'source': 'auto_failover',
        'previous_provider_instance_id': 'provider-old',
        'provider_instance_id': 'provider-new',
        'model': 'glm-5.2-exact',
        'reason': 'provider_rate_limit',
        'route_revision': 5,
        'created_at': '2026-07-15T10:00:00Z',
      },
    ]);
    store.setHistory(history);
    final live = mapper.mapLiveEvent({
      'event': 'session_route_transition',
      'payload': {
        'event_id': 'cloud-copy-id',
        'session_id': 'session-1',
        'source': 'auto_failover',
        'previous_provider_instance_id': 'provider-old',
        'provider_instance_id': 'provider-new',
        'model': 'glm-5.2-exact',
        'reason': 'provider_rate_limit',
        'route_revision': 5,
        'created_at': '2026-07-15T10:00:00Z',
      },
    });
    store.apply(live!);

    expect(store.currentMessages, hasLength(1));
    expect(store.currentMessages.single.id, 'route_session-1_5');
  });

  test('pending steer lifecycle is revision ordered and reuses one user bubble', () async {
    socket.eventRouter.routeEvent(
      _envelope('session.pending_steer_changed', {
        'session_id': 'session-1',
        'request_id': 'raw-1',
        'run_id': 'run-1',
        'generation': 3,
        'text': 'follow up',
        'received_at': '2026-07-15T10:00:00Z',
        'state': 'pending',
        'revision': 2,
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('session.pending_steer_changed', {
        'session_id': 'session-1',
        'request_id': 'raw-1',
        'run_id': 'run-1',
        'generation': 3,
        'text': 'stale text',
        'received_at': '2026-07-15T10:00:00Z',
        'state': 'pending',
        'revision': 1,
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages, hasLength(1));
    expect(store.currentMessages.single.id, 'user_raw-1');
    expect(store.currentMessages.single.text, 'follow up');
    expect(store.currentMessages.single.metadata?['pending_steer_state'], 'pending');

    socket.eventRouter.routeEvent(
      _envelope('session.pending_steer_changed', {
        'session_id': 'session-1',
        'request_id': 'raw-1',
        'run_id': 'run-1',
        'generation': 3,
        'text': 'follow up',
        'received_at': '2026-07-15T10:00:00Z',
        'state': 'delivered',
        'revision': 3,
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages, hasLength(1));
    expect(store.currentMessages.single.metadata?['pending_steer_state'], 'delivered');
  });

  test('cancelled pending steer is removed only by authoritative lifecycle', () async {
    for (final state in ['pending', 'cancelled']) {
      socket.eventRouter.routeEvent(
        _envelope('session.pending_steer_changed', {
          'session_id': 'session-1',
          'request_id': 'raw-cancel',
          'run_id': 'run-1',
          'generation': 1,
          'text': 'remove me',
          'received_at': '2026-07-15T10:00:00Z',
          'state': state,
          'revision': state == 'pending' ? 1 : 2,
        }),
      );
      await Future<void>.delayed(Duration.zero);
      expect(store.currentMessages.isEmpty, state == 'cancelled');
    }
  });

  test('queued delete result consumes daemon outcome and removes the row', () async {
    store.setQueuedMessages([
      CanonicalEvent(
        id: 'user-queued-delete',
        kind: EventKind.userMessage,
        text: 'remove me',
        timestamp: DateTime.utc(2026, 9, 1),
        sessionId: 'session-1',
        metadata: const {
          'request_id': 'queued-delete-request',
          'queued': true,
        },
      ),
    ]);

    socket.eventRouter.routeEvent(
      _envelope('session.queued_message_delete_result', {
        'session_id': 'session-1',
        'target_request_id': 'queued-delete-request',
        'outcome': 'deleted',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentQueuedMessages, isEmpty);
  });

  test('background pending steer lifecycle never leaks into the active conversation', () async {
    socket.eventRouter.routeEvent(
      _envelope('session.pending_steer_changed', {
        'session_id': 'session-1',
        'request_id': 'background-steer',
        'run_id': 'run-1',
        'generation': 1,
        'text': 'belongs to the first session',
        'received_at': '2026-07-15T10:00:00Z',
        'state': 'pending',
        'revision': 1,
      }),
    );
    await Future<void>.delayed(Duration.zero);
    expect(store.currentMessages.single.id, 'user_background-steer');

    store.activateSession('session-2');
    socket.eventRouter.routeEvent(
      _envelope('session.pending_steer_changed', {
        'session_id': 'session-1',
        'request_id': 'background-steer',
        'run_id': 'run-1',
        'generation': 1,
        'text': 'belongs to the first session',
        'received_at': '2026-07-15T10:00:00Z',
        'state': 'delivered',
        'revision': 2,
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('session.pending_steer_cancel_result', {
        'session_id': 'session-1',
        'target_request_id': 'background-steer',
        'outcome': 'already_delivered',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages, isEmpty);
    expect(
      store.snapshot.pendingSteers['session-1']?['background-steer']?.state,
      PendingSteerState.delivered,
    );
  });

  test('tool_result cancelled closes running tool without spinner state', () async {
    socket.eventRouter.routeEvent(
      _envelope('tool_use', {
        'tool': 'shell_execute',
        'input': '{"command":"sleep 30"}',
        'session_id': 'session-1',
        'run_id': 'run-cancel',
        'model_step_id': 'step-1',
        'tool_call_id': 'tool-cancel-1',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('tool_result', {
        'tool': 'shell_execute',
        'output': 'Command cancelled by user.',
        'status': 'cancelled',
        'isError': true,
        'session_id': 'session-1',
        'run_id': 'run-cancel',
        'model_step_id': 'step-1',
        'tool_call_id': 'tool-cancel-1',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    final tool = store.currentMessages.singleWhere(
      (event) => event.kind == EventKind.toolCall,
    );
    expect(tool.status, EventStatus.cancelled);
    expect(tool.toolOutput, 'Command cancelled by user.');
  });

  test('stopped cancels running tools for the same run as defensive fallback', () async {
    socket.eventRouter.routeEvent(
      _envelope('tool_use', {
        'tool': 'shell_execute',
        'input': '{"command":"sleep 30"}',
        'session_id': 'session-1',
        'run_id': 'run-stop',
        'model_step_id': 'step-1',
        'tool_call_id': 'tool-stop-1',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('stopped', {
        'session_id': 'session-1',
        'run_id': 'run-stop',
        'model_step_id': 'step-1',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    final tool = store.currentMessages.singleWhere(
      (event) => event.kind == EventKind.toolCall,
    );
    expect(tool.status, EventStatus.cancelled);
    expect(tool.toolOutput, 'Command cancelled by user.');
  });

  test('stopped fallback leaves running tools from another run untouched', () async {
    for (final entry in [('run-stop', 'tool-stop'), ('run-other', 'tool-other')]) {
      socket.eventRouter.routeEvent(
        _envelope('tool_use', {
          'tool': 'shell_execute',
          'input': '{"command":"sleep 30"}',
          'session_id': 'session-1',
          'run_id': entry.$1,
          'model_step_id': 'step-${entry.$2}',
          'tool_call_id': entry.$2,
        }),
      );
    }
    socket.eventRouter.routeEvent(
      _envelope('stopped', {
        'session_id': 'session-1',
        'run_id': 'run-stop',
        'model_step_id': 'step-tool-stop',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      store.currentMessages.singleWhere((event) => event.toolCallId == 'tool-stop').status,
      EventStatus.cancelled,
    );
    expect(
      store.currentMessages.singleWhere((event) => event.toolCallId == 'tool-other').status,
      EventStatus.running,
    );
  });

  test('authoritative cancellation enriches fallback and blocks late timeout', () async {
    socket.eventRouter.routeEvent(
      _envelope('tool_use', {
        'tool': 'shell_execute',
        'input': '{"command":"sleep 30"}',
        'session_id': 'session-1',
        'run_id': 'run-stop',
        'model_step_id': 'step-1',
        'tool_call_id': 'tool-stop',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('stopped', {
        'session_id': 'session-1',
        'run_id': 'run-stop',
        'model_step_id': 'step-1',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('tool_result', {
        'tool': 'shell_execute',
        'output': 'Command cancelled by user.',
        'status': 'cancelled',
        'session_id': 'session-1',
        'run_id': 'run-stop',
        'model_step_id': 'step-1',
        'tool_call_id': 'tool-stop',
        'generation': 5,
        'revision': 50,
        'reason': 'user_stop',
        'terminal_at': '2026-08-29T00:00:01Z',
      }),
    );
    socket.eventRouter.routeEvent(
      _envelope('tool_result', {
        'tool': 'shell_execute',
        'output': 'Command timed out.',
        'status': 'error',
        'session_id': 'session-1',
        'run_id': 'run-stop',
        'model_step_id': 'step-1',
        'tool_call_id': 'tool-stop',
      }),
    );
    await Future<void>.delayed(Duration.zero);

    final tool = store.currentMessages.single;
    expect(tool.status, EventStatus.cancelled);
    expect(tool.toolOutput, 'Command cancelled by user.');
    expect(tool.generation, 5);
    expect(tool.revision, 50);
    expect(tool.metadata, containsPair('reason', 'user_stop'));
  });
}

Map<String, dynamic> _envelope(String event, Map<String, dynamic> payload) => {
  'device_id': 'agent-1',
  'event': event,
  'payload': payload,
};

Map<String, dynamic> _executionEnvelope(
  String sessionId, {
  required String state,
  required int revision,
}) => _envelope('session.execution_state_changed', {
  'session_id': sessionId,
  'state': state,
  'work_item_id': state == 'idle' ? null : 'work-$sessionId',
  'request_id': state == 'idle' ? null : 'request-$sessionId',
  'revision': revision,
  'updated_at': '2026-07-15T10:30:00Z',
});
