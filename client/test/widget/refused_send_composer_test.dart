import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input_panel.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';

import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_device_repository.dart';
import '../helpers/fake_socket.dart';
import '../helpers/pump_app.dart';

/// F1 (Task 125 round 2): while the composer waits for the daemon to accept a
/// send it shows an acceptance indicator and refuses a second send. A refused
/// turn never produces that acceptance, so the waiting state must end when the
/// daemon answers with a typed refusal, and the user's text must stay editable.
void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late DeviceCapabilitiesStore capabilities;
  late DeviceConnectionCoordinator resolver;
  late FakeConversationRepository conversationRepository;
  late SessionCubit sessionCubit;
  late SessionMessagesCubit messagesCubit;
  late DeviceConfig agent;
  late ConversationCacheStore cacheStore;
  late ConversationCacheRepository cacheRepository;

  const sessionId = 'session-refused';
  const requestId = 'request-refused-1';
  const text = 'Reply with exactly: G2-S1-MSG1';

  setUp(() async {
    await getIt.reset();
    socket = FakeSanadSocketService();
    socket.setConnected(true);
    socket.autoCapabilitiesPayload = const {
      'supports_workspaces': true,
      'supports_workspace_selection': true,
      'workspace_required': false,
    };
    agentRepository = FakeDeviceRepository();
    agentClientRegistry = FakeDeviceClientRegistry();
    agentCubit = TestDeviceCubit(
      socketService: socket,
      agentRepository: agentRepository,
      agentClientRegistry: agentClientRegistry,
    );
    resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    capabilities = DeviceCapabilitiesStore(resolver);
    conversationRepository = FakeConversationRepository();
    cacheStore = ConversationCacheStore();
    cacheRepository = ConversationCacheRepository(
      cache: cacheStore,
      transport: conversationRepository,
    );
    agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
    );
    messagesCubit = SessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      conversationCacheRepository: cacheRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
  });

  tearDown(() async {
    await messagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    capabilities.dispose();
    resolver.dispose();
    await conversationRepository.dispose();
    cacheStore.dispose();
    socket.dispose();
    await getIt.reset();
  });

  testWidgets('a refused send ends the acceptance wait and keeps the text', (tester) async {
    // The composer had sent this text and is now waiting for canonical
    // acceptance of [requestId], exactly like the live refused first send.
    cacheRepository.setSessionDraft(
      agent.id,
      sessionId,
      ConversationDraft(
        text: text,
        workspaceId: null,
        providerId: null,
        model: null,
        thinkingMode: null,
        permissionMode: null,
        pendingRequestId: requestId,
        updatedAt: DateTime.now().toUtc(),
      ),
    );

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: messagesCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      child: ConversationInputPanel(
        sessionId: sessionId,
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
      ),
    );
    await tester.pump();

    expect(
      find.byKey(const Key('send_message_acceptance_indicator')),
      findsOneWidget,
      reason: 'the composer is waiting for the daemon to accept the send',
    );

    // The daemon refused the turn before it started: nothing was accepted.
    cacheRepository.releaseRefusedDraft(agent.id, sessionId, requestId);
    await tester.pump();

    expect(
      find.byKey(const Key('send_message_acceptance_indicator')),
      findsNothing,
      reason: 'no acceptance will ever arrive, so the wait must end',
    );
    expect(
      find.text(text),
      findsOneWidget,
      reason: 'the user’s refused text stays in the composer for a retry',
    );
  });
}
