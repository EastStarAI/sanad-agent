import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';

import '../../helpers/fake_conversation_repository.dart';
import '../../helpers/fake_device_preferences_repository.dart';
import '../../helpers/fake_device_repository.dart';
import '../../helpers/fake_socket.dart';

/// F1 (Task 125 round 2): the first message of a New Conversation can be
/// refused before it starts. The daemon then never accepts the message, so no
/// canonical `user_message` ever matches the draft's `pendingRequestId`. The
/// client must release that draft when the turn reaches a terminal refusal so
/// the composer stays editable with the user's text, instead of waiting for an
/// acceptance that will never arrive.
void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late FakeConversationRepository conversationRepository;
  late ConversationCacheStore conversationCacheStore;
  late ConversationCacheRepository conversationCacheRepository;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit messagesCubit;
  late DeviceConfig agent;

  const text = 'Reply with exactly: G2-S1-MSG1';
  final session = Session(
    id: 'session-refused',
    title: text,
    deviceId: 'agent-1',
    createdAt: DateTime(2026, 1, 1),
    updatedAt: DateTime(2026, 1, 1),
  );

  setUp(() {
    socket = FakeSanadSocketService();
    socket.setConnected(true);
    socket.autoCapabilitiesPayload = const {
      'supports_workspaces': true,
      'workspace_required': true,
      'supports_workspace_selection': true,
      'local_tool_runtime_scope': 'workspace',
      'tool_protocol_version': 'tools.v2',
    };
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    conversationRepository = FakeConversationRepository();
    conversationCacheStore = ConversationCacheStore();
    conversationCacheRepository = ConversationCacheRepository(
      cache: conversationCacheStore,
      transport: conversationRepository,
    );
    agent = DeviceConfig(id: 'agent-1', name: 'Computer', isOnline: true);
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    conversationRepository.seedSessions(agent, [session]);
    conversationRepository.getWorkspacesHandler = (_) async => const [
      DeviceWorkspace(
        id: 'workspace-gone',
        name: 'g2-live-r1-ws',
        path: '/tmp/g2-live-r1-ws',
      ),
    ];
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: conversationCacheRepository,
    );
    messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      conversationCacheRepository: conversationCacheRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
  });

  tearDown(() async {
    await messagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    await conversationRepository.dispose();
    conversationCacheStore.dispose();
    socket.dispose();
  });

  Future<void> settle() async {
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Sends the first message of a New Conversation and returns the request id
  /// the client is now waiting to see accepted.
  Future<String> sendFirstMessage() async {
    conversationCacheRepository.setNewConversationDraft(
      agent.id,
      text: text,
      workspaceId: 'workspace-gone',
    );
    await settle();
    expect(await messagesCubit.sendMessage(text), isTrue);
    await settle();
    final draft = conversationCacheRepository.sessionDraft(
      agent.id,
      'session-1',
    );
    expect(
      draft?.pendingRequestId,
      'fake-request-1',
      reason: 'the send awaits canonical acceptance',
    );
    return draft!.pendingRequestId!;
  }

  test('a typed turn_failed refusal releases the awaiting draft and keeps the text', () async {
    final pendingRequestId = await sendFirstMessage();

    sessionCubit.handleGlobalSessionEventForTesting({
      'device_id': agent.id,
      'event': 'final_answer',
      'request_id': pendingRequestId,
      'payload': {
        'session_id': 'session-1',
        'request_id': pendingRequestId,
        'content': 'Error: Bad state: Workspace folder is unavailable.',
        'error_code': 'turn_failed',
      },
    });
    await settle();

    final released = conversationCacheRepository.sessionDraft(
      agent.id,
      'session-1',
    );
    expect(
      released?.pendingRequestId,
      isNull,
      reason: 'the daemon refused the turn, so no acceptance will ever arrive',
    );
    expect(
      released?.text,
      text,
      reason: 'the refused text stays editable instead of being discarded',
    );
  });

  test('a blocked runtime notice releases the awaiting draft and keeps the text', () async {
    final pendingRequestId = await sendFirstMessage();

    sessionCubit.handleGlobalSessionEventForTesting({
      'device_id': agent.id,
      'event': 'session.runtime_notice',
      'payload': {
        'session_id': 'session-1',
        'request_id': pendingRequestId,
        'status': 'blocked',
        'reason': 'network_error',
        'title': 'Connection failed',
        'message': 'The agent could not reach the runtime service.',
      },
    });
    await settle();

    final released = conversationCacheRepository.sessionDraft(
      agent.id,
      'session-1',
    );
    expect(released?.pendingRequestId, isNull);
    expect(released?.text, text);
  });

  test('a canonical acceptance still clears the draft', () async {
    final pendingRequestId = await sendFirstMessage();

    sessionCubit.handleGlobalSessionEventForTesting({
      'device_id': agent.id,
      'event': 'user_message',
      'payload': {
        'session_id': 'session-1',
        'request_id': pendingRequestId,
        'content': text,
        'message_id': 'message-1',
        'turn_id': 'turn-1',
        'input_kind': 'root_turn',
      },
    });
    await settle();

    expect(
      conversationCacheRepository.sessionDraft(agent.id, 'session-1'),
      isNull,
      reason: 'an accepted message is delivered, so its draft is gone',
    );
  });
}
