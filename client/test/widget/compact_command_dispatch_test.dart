import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input_panel.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_conversation_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_device_repository.dart';
import '../helpers/fake_socket.dart';
import '../helpers/pump_app.dart';

void main() {
  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late DeviceCapabilitiesStore capabilities;
  late DeviceConnectionCoordinator resolver;
  late FakeConversationRepository conversationRepository;
  late SessionCubit sessionCubit;
  late _TestSessionMessagesCubit sessionMessagesCubit;
  late DeviceConfig agent;

  setUp(() async {
    await getIt.reset();
    ConversationInputPanel.debugOnValidationError = null;
    socket = FakeSanadSocketService();
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
    agent = DeviceConfig(id: 'agent-1', name: 'SanadAgent', isOnline: true);
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    conversationRepository.seedSessions(agent, [
      Session(
        id: 'session-compact',
        title: 'Compact test',
        deviceId: agent.id,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    ]);
    sessionMessagesCubit = _TestSessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
    sessionMessagesCubit.emitState(
      const SessionMessagesState(
        activeSessionId: 'session-compact',
      ),
    );
    sessionMessagesCubit.setNextMessagePreferences(
      providerId: 'provider-1',
      model: 'model-1',
    );
  });

  tearDown(() async {
    ConversationInputPanel.debugOnValidationError = null;
    await sessionMessagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    capabilities.dispose();
    resolver.dispose();
    await conversationRepository.dispose();
    socket.dispose();
    await getIt.reset();
  });

  testWidgets('exact /compact dispatches compact command without user message', (
    tester,
  ) async {
    var sendCalls = 0;
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {
          sendCalls += 1;
        },
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pumpAndSettle();

    expect(sendCalls, 0);
    expect(conversationRepository.compactSessionCalls, 1);
  });

  testWidgets('/compact with arguments shows validation and keeps draft', (
    tester,
  ) async {
    String? validationError;
    ConversationInputPanel.debugOnValidationError = (message) {
      validationError = message;
    };

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
      ),
    );

    await tester.enterText(
      find.byKey(const Key('chat_input')),
      '/compact force',
    );
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));

    expect(validationError, '/compact does not accept arguments.');
    expect(conversationRepository.compactSessionCalls, 0);
    expect(find.text('/compact force'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('session busy compact outcome shows validation feedback', (
    tester,
  ) async {
    conversationRepository.compactSessionResult = const SessionCompactResult(
      outcome: 'session_busy',
    );
    String? validationError;
    ConversationInputPanel.debugOnValidationError = (message) {
      validationError = message;
    };

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pumpAndSettle();

    expect(conversationRepository.compactSessionCalls, 1);
    expect(
      validationError,
      'Session is busy. Try /compact again when idle.',
    );
    expect(find.text('/compact'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('compaction in progress outcome shows validation feedback', (
    tester,
  ) async {
    conversationRepository.compactSessionResult = const SessionCompactResult(
      outcome: 'compaction_in_progress',
    );
    String? validationError;
    ConversationInputPanel.debugOnValidationError = (message) {
      validationError = message;
    };

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(
        sessionId: 'session-compact',
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), '/compact');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pumpAndSettle();

    expect(conversationRepository.compactSessionCalls, 1);
    expect(
      validationError,
      'Context compaction is already in progress.',
    );
    expect(find.text('/compact'), findsOneWidget);
    await tester.pump(const Duration(seconds: 3));
  });
}

class _TestSessionMessagesCubit extends SessionMessagesCubit {
  _TestSessionMessagesCubit({
    required super.agentCubit,
    required super.sessionCubit,
    required super.conversationRepository,
    required super.preferencesRepository,
  });

  void emitState(SessionMessagesState state) {
    emit(state);
  }
}
