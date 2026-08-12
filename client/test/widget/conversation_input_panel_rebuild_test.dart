import 'package:sanad_client/core/navigation/conversation_destination.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/core/di/injection.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_visual_state.dart';
import 'package:sanad_client/features/conversations/presentation/screens/brain_activity_view.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_bottom_actions.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input_panel.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/utils/workspace_picker_helper.dart';
import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import '../helpers/fake_device_repository.dart';
import '../helpers/fake_device_preferences_repository.dart';
import '../helpers/fake_conversation_repository.dart';
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
  late ConversationCacheStore cacheStore;
  late ConversationCacheRepository cacheRepository;

  setUp(() async {
    await getIt.reset();
    ConversationInputPanel.debugPickDirectoryPath = null;
    WorkspacePickerHelper.debugOnRemoteDisabled = null;
    socket = FakeSanadSocketService();
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
    );
    sessionMessagesCubit = _TestSessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: FakeDevicePreferencesRepository(),
    );
  });

  tearDown(() async {
    ConversationInputPanel.debugOnBottomActionsBuild = null;
    ConversationInputPanel.debugPickDirectoryPath = null;
    ConversationInputPanel.debugOnValidationError = null;
    WorkspacePickerHelper.debugOnRemoteDisabled = null;
    await sessionMessagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    capabilities.dispose();
    resolver.dispose();
    await conversationRepository.dispose();
    cacheStore.dispose();
    socket.dispose();
    await getIt.reset();
  });

  testWidgets('typing in the draft does not rebuild bottom actions', (tester) async {
    var bottomActionBuilds = 0;
    ConversationInputPanel.debugOnBottomActionsBuild = () => bottomActionBuilds += 1;

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    final buildsAfterInitialPump = bottomActionBuilds;

    await tester.enterText(find.byType(TextField), 'hello from the draft');
    await tester.pump();

    expect(bottomActionBuilds, buildsAfterInitialPump);
  });

  testWidgets('streaming message updates do not rebuild bottom actions', (tester) async {
    var bottomActionBuilds = 0;
    ConversationInputPanel.debugOnBottomActionsBuild = () => bottomActionBuilds += 1;

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    final buildsAfterInitialPump = bottomActionBuilds;
    conversationRepository.setMessages(agent, [
      CanonicalEvent(
        id: 'stream-1',
        kind: EventKind.thinking,
        status: EventStatus.running,
        text: 'streaming...',
        timestamp: DateTime(2026, 1, 1),
      ),
    ]);
    await tester.pump();

    expect(bottomActionBuilds, buildsAfterInitialPump);
  });

  testWidgets('mounting the composer does not prefetch slash commands', (tester) async {
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    await tester.pump();

    expect(
      conversationRepository.slashCommandSearchRequests,
      isEmpty,
      reason: 'Slash command queries should be driven by explicit composer intent, not widget mount.',
    );
  });

  testWidgets('unrelated cache snapshots do not erase text before debounce', (tester) async {
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), 'keep this draft');
    cacheRepository.recordLastDestination(
      ConversationDestination.session(
        deviceId: agent.id,
        sessionId: 'another-session',
      ),
    );
    await tester.pump();

    expect(find.text('keep this draft'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 500));
    expect(cacheRepository.newConversationDraft(agent.id).text, 'keep this draft');
  });

  testWidgets('loading an existing session never shows the New Conversation draft', (tester) async {
    cacheRepository.setNewConversationDraft(
      agent.id,
      text: 'new conversation only',
    );

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      child: BrainActivityView(
        sessionId: null,
        composerSessionId: 'session-1',
        visualState: ConversationVisualState.loadingTransition,
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {},
      ),
    );

    expect(find.byKey(const Key('chat_input')), findsOneWidget);
    expect(find.text('new conversation only'), findsNothing);
    expect(
      cacheRepository.newConversationDraft(agent.id).text,
      'new conversation only',
    );
  });

  testWidgets('send before debounce saves text and canonical acceptance clears it', (tester) async {
    String? sentText;
    sessionMessagesCubit.setNextMessagePreferences(
      providerId: 'provider-1',
      model: 'model-1',
    );
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      child: ConversationInputPanel(
        onSendMessage: (text, {intent = MessageDeliveryIntent.auto}) => sentText = text,
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), 'send immediately');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pump();

    expect(sentText, 'send immediately');
    expect(cacheRepository.newConversationDraft(agent.id).text, 'send immediately');

    cacheRepository.markNewConversationDraftAwaitingAcceptance(agent.id, 'request-1');
    await tester.pump();
    expect(find.byKey(const Key('send_message_acceptance_indicator')), findsOneWidget);
    expect(find.byKey(const Key('send_message_btn')), findsNothing);

    cacheRepository.applyUserMessageAccepted(
      agent.id,
      'session-1',
      requestId: 'request-1',
    );
    await tester.pump();

    expect(find.text('send immediately'), findsNothing);
  });

  testWidgets('acceptance for an older request preserves a newer edit', (
    tester,
  ) async {
    sessionMessagesCubit.setNextMessagePreferences(
      providerId: 'provider-1',
      model: 'model-1',
    );
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), 'first message');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    cacheRepository.markNewConversationDraftAwaitingAcceptance(
      agent.id,
      'request-old',
    );
    await tester.pump();
    expect(find.byKey(const Key('send_message_acceptance_indicator')), findsOneWidget);

    await tester.enterText(find.byKey(const Key('chat_input')), 'newer draft');
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byKey(const Key('send_message_acceptance_indicator')), findsNothing);
    cacheRepository.applyUserMessageAccepted(
      agent.id,
      'session-1',
      requestId: 'request-old',
    );
    await tester.pump();

    expect(find.text('newer draft'), findsOneWidget);
    expect(cacheRepository.newConversationDraft(agent.id).text, 'newer draft');
  });

  testWidgets('send is blocked when provider and model are unselected', (
    tester,
  ) async {
    var sendCalls = 0;
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
        onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {
          sendCalls += 1;
        },
      ),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), 'hello');
    await tester.pump();
    await tester.tap(find.byKey(const Key('send_message_btn')));
    await tester.pump();

    expect(sendCalls, 0);
    expect(
      validationError,
      ConversationInputCubit.missingProviderModelError,
    );
    await tester.pump(const Duration(seconds: 3));
  });

  testWidgets('switching devices loads the target device draft', (tester) async {
    final secondAgent = DeviceConfig(id: 'agent-2', name: 'Sanad Two', isOnline: true);
    cacheRepository.setNewConversationDraft(agent.id, text: 'first device');
    cacheRepository.setNewConversationDraft(secondAgent.id, text: 'second device');

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );
    expect(find.text('first device'), findsOneWidget);

    agentCubit.emitState(
      DeviceActive(activeAgent: secondAgent, agents: [agent, secondAgent]),
    );
    await tester.pump();

    expect(find.text('second device'), findsOneWidget);
    expect(cacheRepository.newConversationDraft(agent.id).text, 'first device');
  });

  testWidgets('disposing before debounce flushes the latest draft', (tester) async {
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    await tester.enterText(find.byKey(const Key('chat_input')), 'flush on dispose');
    await tester.pumpWidget(const MaterialApp(home: SizedBox.shrink()));

    expect(cacheRepository.newConversationDraft(agent.id).text, 'flush on dispose');
  });

  testWidgets('new conversation route metadata is persisted without inheriting permission mode', (tester) async {
    final inputCubit = _TestConversationInputCubit(messagesCubit: sessionMessagesCubit);
    const workspace = DeviceWorkspace(id: 'workspace-1', name: 'Project', path: '/project');
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      conversationInputCubit: inputCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    inputCubit.emitSessionMessagesState(
      const SessionMessagesState(
        selectedWorkspace: workspace,
        availableWorkspaces: [workspace],
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-1',
        nextMessageThinkingMode: 'high',
        permissionMode: WorkspacePermissionMode.fullAccess,
      ),
    );
    await tester.pump(const Duration(milliseconds: 500));

    final draft = cacheRepository.newConversationDraft(agent.id);
    expect(draft.workspaceId, workspace.id);
    expect(draft.providerId, 'provider-1');
    expect(draft.model, 'model-1');
    expect(draft.thinkingMode, 'high');
    expect(draft.permissionMode, isNull);
    expect(conversationRepository.setPermissionModeRequests, isEmpty);
  });

  testWidgets('empty draft snapshots do not clear an initialized provider route', (tester) async {
    final inputCubit = _TestConversationInputCubit(messagesCubit: sessionMessagesCubit);
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      conversationInputCubit: inputCubit,
      capabilities: capabilities,
      conversationCacheRepository: cacheRepository,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    inputCubit.emitSessionMessagesState(
      const SessionMessagesState(
        nextMessageProviderId: 'provider-default',
        nextMessageModel: 'model-default',
      ),
    );
    await tester.pump();

    cacheRepository.setNewConversationDraft(
      agent.id,
      clearProvider: true,
      clearModel: true,
    );
    await tester.pump();

    expect(inputCubit.state.nextMessageProviderId, 'provider-default');
    expect(inputCubit.state.nextMessageModel, 'model-default');
  });

  testWidgets('model chip provider lookup does not repeat after unmatched snapshot result', (tester) async {
    final providerClient = _FakeProviderLookupClient();
    getIt.registerSingleton<ProviderSetupClient>(providerClient);
    await sessionCubit.selectSession(
      Session(
        id: 'session-1',
        title: 'Chat',
        deviceId: agent.id,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        model: 'glm-5.2',
        modelProvider: 'legacy-provider-id',
      ),
    );

    await pumpTestApp(
      tester,
      sessionCubit: sessionCubit,
      child: ConversationBottomActions(
        activeAgent: agent,
        inputSlice: const ConversationInputSlice(
          isProcessing: false,
          nextMessageModel: null,
          nextMessageProviderId: null,
          nextMessageThinkingMode: null,
          availableWorkspaces: [],
          selectedWorkspace: null,
          isLoadingWorkspaces: false,
          requiresWorkspace: false,
          permissionMode: WorkspacePermissionMode.defaultMode,
          isLoadingPermissionMode: false,
          pendingSuspendedRequest: null,
          runtimeNotice: null,
          queuedMessages: [],
        ),
        capabilities: const Capability(supportsModelChange: true),
        dimTextColor: Colors.black,
        chipBgColor: Colors.white,
        borderColor: Colors.black12,
        onConfirmFullAccess: () async => true,
      ),
    );
    await tester.pump();
    await tester.pump();
    await tester.pump();

    expect(providerClient.modelSnapshotCalls, 1);
  });

  testWidgets('model chip ignores pending route and shows exact authoritative confirmation', (
    tester,
  ) async {
    getIt.registerSingleton<ProviderSetupClient>(_FakeProviderLookupClient());
    await sessionCubit.selectSession(
      Session(
        id: 'session-1',
        title: 'Chat',
        deviceId: agent.id,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        model: 'old-model',
        modelProvider: 'provider-old',
        routeRevision: 1,
        metadata: const {'provider_display_name': 'NVIDIA NIM'},
      ),
    );

    Widget actions(ConversationInputSlice slice) => ConversationBottomActions(
      activeAgent: agent,
      inputSlice: slice,
      capabilities: const Capability(supportsModelChange: true),
      dimTextColor: Colors.black,
      chipBgColor: Colors.white,
      borderColor: Colors.black12,
      onConfirmFullAccess: () async => true,
    );

    const base = ConversationInputSlice(
      isProcessing: false,
      nextMessageModel: 'old-model',
      nextMessageProviderId: 'provider-old',
      nextMessageThinkingMode: null,
      availableWorkspaces: [],
      selectedWorkspace: null,
      isLoadingWorkspaces: false,
      requiresWorkspace: false,
      permissionMode: WorkspacePermissionMode.defaultMode,
      isLoadingPermissionMode: false,
      pendingSuspendedRequest: null,
      runtimeNotice: null,
      queuedMessages: [],
    );
    await pumpTestApp(
      tester,
      sessionCubit: sessionCubit,
      child: actions(base),
    );
    await tester.pump();

    expect(find.text('NVIDIA NIM | old-model'), findsOneWidget);
    expect(find.textContaining('glm-5.2-exact'), findsNothing);

    await sessionCubit.selectSession(
      Session(
        id: 'session-1',
        title: 'Chat',
        deviceId: agent.id,
        createdAt: DateTime(2026, 1, 1),
        updatedAt: DateTime(2026, 1, 1),
        model: 'glm-5.2-exact',
        modelProvider: 'provider-new',
        routeRevision: 2,
        metadata: const {'provider_display_name': 'Z.ai'},
      ),
    );
    await pumpTestApp(
      tester,
      sessionCubit: sessionCubit,
      child: actions(
        const ConversationInputSlice(
          isProcessing: false,
          nextMessageModel: 'glm-5.2-exact',
          nextMessageProviderId: 'provider-new',
          nextMessageThinkingMode: null,
          availableWorkspaces: [],
          selectedWorkspace: null,
          isLoadingWorkspaces: false,
          requiresWorkspace: false,
          permissionMode: WorkspacePermissionMode.defaultMode,
          isLoadingPermissionMode: false,
          pendingSuspendedRequest: null,
          runtimeNotice: null,
          queuedMessages: [],
        ),
      ),
    );
    await tester.pump();

    expect(find.text('Z.ai | glm-5.2-exact'), findsOneWidget);
  });

  testWidgets('shows inline permission request card and hides the draft composer', (tester) async {
    final inputCubit = _TestConversationInputCubit(messagesCubit: sessionMessagesCubit);
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      conversationInputCubit: inputCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    inputCubit.emitSessionMessagesState(
      const SessionMessagesState(
        pendingSuspendedRequest: DeviceSuspendedRequest(
          requestId: 'permission-1',
          sessionId: 'session-1',
          toolName: 'shell_execute',
          permissionClass: 'shell_execution',
          scope: 'workspace',
          workspaceId: 'workspace-1',
          workspaceName: 'desktop-agent',
          workspacePath: '/repo',
          toolInput: {'command': 'echo hello'},
          tool: {'name': 'shell_execute'},
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 50));

    expect(find.text('Allow Sanad to run this command?'), findsOneWidget);
    expect(find.textContaining('Command: '), findsNothing);
    expect(find.textContaining('echo hello'), findsOneWidget);
    expect(find.byKey(const Key('chat_input')), findsNothing);
  });

  testWidgets('pressing Stop on a runtime notice keeps the banner visible until daemon events clear it', (
    tester,
  ) async {
    final inputCubit = _TestConversationInputCubit(messagesCubit: sessionMessagesCubit);
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      conversationInputCubit: inputCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    sessionMessagesCubit.emitState(
      const SessionMessagesState(
        activeSessionId: 'session-1',
        runtimeNotice: RuntimeNotice(
          sessionId: 'session-1',
          requestId: 'req-stop',
          status: 'waiting',
          reason: 'provider_rate_limit',
          title: 'NVIDIA NIM rate limit reached',
          retryAfterMs: 24000,
          actions: ['stop'],
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('NVIDIA NIM rate limit reached'), findsOneWidget);
    await tester.tap(find.text('Stop'));
    await tester.pump();

    expect(conversationRepository.stopCalls, 1);
    expect(find.text('NVIDIA NIM rate limit reached'), findsOneWidget);
  });

  testWidgets('Change Provider reuses the model picker and sends provider + model atomically', (
    tester,
  ) async {
    final providerClient = _FakeRecoveryProviderClient();
    getIt.registerSingleton<ProviderSetupClient>(providerClient);
    final usageCubit = ProviderUsageCubit(client: providerClient);
    getIt.registerSingleton<ProviderUsageCubit>(usageCubit);
    addTearDown(usageCubit.close);

    final inputCubit = _TestConversationInputCubit(messagesCubit: sessionMessagesCubit);

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      conversationInputCubit: inputCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    sessionMessagesCubit.emitState(
      const SessionMessagesState(
        activeSessionId: 'session-1',
        nextMessageProviderId: 'provider-old',
        nextMessageModel: 'old-model',
        runtimeNotice: RuntimeNotice(
          sessionId: 'session-1',
          requestId: 'req-route',
          status: 'waiting',
          reason: 'provider_rate_limit',
          title: 'Waiting for provider',
          actions: ['continue_with_provider'],
        ),
      ),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.text('Change Provider'));
    await tester.pumpAndSettle();

    expect(find.text('Select Model'), findsOneWidget);
    await tester.tap(find.text('glm-5.2'));
    await tester.pumpAndSettle();

    expect(
      conversationRepository.continuedRuntimeNotices.single,
      {
        'device_id': agent.id,
        'session_id': 'session-1',
        'provider_instance_id': 'provider-new',
        'request_id': 'req-route',
        'model_id': 'glm-5.2',
      },
    );
  });

  testWidgets('clarifying question wizard resets when pending request id changes', (tester) async {
    final inputCubit = _TestConversationInputCubit(messagesCubit: sessionMessagesCubit);
    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      conversationInputCubit: inputCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );

    inputCubit.emitSessionMessagesState(
      SessionMessagesState(
        pendingSuspendedRequest: DeviceSuspendedRequest(
          requestId: 'question-1',
          sessionId: 'session-1',
          toolName: 'system_ask_user',
          permissionClass: 'clarification',
          scope: 'session',
          workspaceId: 'workspace-1',
          workspaceName: 'desktop-agent',
          workspacePath: '/repo',
          toolInput: const {
            'questions': [
              {
                'question': 'Pick a mode',
                'options': ['Fast', 'Safe'],
              },
              {
                'question': 'Pick a format',
                'options': ['JSON', 'Markdown'],
              },
            ],
          },
          tool: const {'name': 'system_ask_user'},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clarifying Question (1 of 2)'), findsOneWidget);
    await tester.tap(find.byKey(const Key('predefined_option_1')));
    await tester.pumpAndSettle();
    expect(find.text('Clarifying Question (2 of 2)'), findsOneWidget);

    inputCubit.emitSessionMessagesState(
      SessionMessagesState(
        pendingSuspendedRequest: DeviceSuspendedRequest(
          requestId: 'question-2',
          sessionId: 'session-1',
          toolName: 'system_ask_user',
          permissionClass: 'clarification',
          scope: 'session',
          workspaceId: 'workspace-1',
          workspaceName: 'desktop-agent',
          workspacePath: '/repo',
          toolInput: const {
            'questions': [
              {
                'question': 'Start again',
                'options': ['Option A', 'Option B'],
              },
            ],
          },
          tool: const {'name': 'system_ask_user'},
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(find.text('Clarifying Question (1 of 1)'), findsOneWidget);
    expect(find.text('1  Option A'), findsOneWidget);
    expect(find.text('Back to previous question'), findsNothing);
  });

  testWidgets('uses native folder picker for local agents when adding a workspace', (tester) async {
    socket.setConnected(true);
    agent = DeviceConfig(
      id: 'agent-1',
      name: 'SanadAgent',
      isOnline: true,
      metadata: const {'is_local_reachable': true},
    );
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    ConversationInputPanel.debugPickDirectoryPath = () async => '/picked/local-workspace';

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add New Workspace'));
    await tester.pumpAndSettle();

    expect(conversationRepository.browseWorkspaceTreeRequests, isEmpty);
    expect(conversationRepository.createdWorkspaces.single, containsPair('path', '/picked/local-workspace'));
  });

  testWidgets('blocks remote workspace creation with a security notice', (tester) async {
    socket.setConnected(true);
    var pickerCalled = false;
    String? disabledMessage;
    ConversationInputPanel.debugPickDirectoryPath = () async {
      pickerCalled = true;
      return '/remote/workspace';
    };
    WorkspacePickerHelper.debugOnRemoteDisabled = (message) {
      disabledMessage = message;
    };

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );
    await tester.pumpAndSettle();

    await tester.tap(find.byKey(const Key('workspace_selector_btn')));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Add New Workspace'));
    await tester.pumpAndSettle();

    expect(find.text('Choose Workspace'), findsNothing);
    expect(disabledMessage, WorkspacePickerHelper.remoteDisabledMessage);
    expect(pickerCalled, isFalse);
    expect(conversationRepository.browseWorkspaceTreeRequests, isEmpty);
    expect(conversationRepository.createdWorkspaces, isEmpty);
  });

  testWidgets('appends dropped file paths to input field when files are dragged and dropped', (tester) async {
    socket.setConnected(true);
    agent = DeviceConfig(
      id: 'agent-1',
      name: 'SanadAgent',
      isOnline: true,
      metadata: const {'is_local_reachable': true},
    );
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));

    await pumpTestApp(
      tester,
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      sessionMessagesCubit: sessionMessagesCubit,
      capabilities: capabilities,
      child: ConversationInputPanel(onSendMessage: (_, {intent = MessageDeliveryIntent.auto}) {}),
    );
    await tester.pumpAndSettle();

    final dropTargetFinder = find.byType(DropTarget);
    expect(dropTargetFinder, findsOneWidget);
    final DropTarget dropTarget = tester.widget(dropTargetFinder);

    // 1. Drop a single file on an empty input
    dropTarget.onDragDone?.call(
      DropDoneDetails(
        files: [
          DropItemFile('/path/to/first_file.txt'),
        ],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pump();

    // Verify input text is updated to the file path
    final textFieldFinder = find.byKey(const Key('chat_input'));
    expect(textFieldFinder, findsOneWidget);
    final TextField textField1 = tester.widget(textFieldFinder);
    expect(textField1.controller?.text, '/path/to/first_file.txt ');

    // 2. Drop multiple files on a non-empty input
    dropTarget.onDragDone?.call(
      DropDoneDetails(
        files: [
          DropItemFile('/path/to/second_file.jpg'),
          DropItemFile('/path/to/third_file.png'),
        ],
        localPosition: Offset.zero,
        globalPosition: Offset.zero,
      ),
    );
    await tester.pump();

    final TextField textField2 = tester.widget(textFieldFinder);
    expect(textField2.controller?.text, '/path/to/first_file.txt /path/to/second_file.jpg /path/to/third_file.png ');
  });
}

class _TestConversationInputCubit extends ConversationInputCubit {
  _TestConversationInputCubit({required super.messagesCubit});

  void emitSessionMessagesState(SessionMessagesState state) {
    emit(
      ConversationInputState(
        isProcessing: state.isProcessing,
        activeSessionId: state.activeSessionId,
        nextMessageProviderId: state.nextMessageProviderId,
        nextMessageModel: state.nextMessageModel,
        confirmedNextMessageProviderId: state.confirmedNextMessageProviderId,
        confirmedNextMessageModel: state.confirmedNextMessageModel,
        pendingNextMessageProviderId: state.pendingNextMessageProviderId,
        pendingNextMessageModel: state.pendingNextMessageModel,
        nextMessageThinkingMode: state.nextMessageThinkingMode,
        availableWorkspaces: state.availableWorkspaces,
        selectedWorkspace: state.selectedWorkspace,
        isLoadingWorkspaces: state.isLoadingWorkspaces,
        requiresWorkspace: state.requiresWorkspace,
        permissionMode: state.permissionMode,
        isLoadingPermissionMode: state.isLoadingPermissionMode,
        pendingSuspendedRequest: state.pendingSuspendedRequest,
        runtimeNotice: state.runtimeNotice,
        queuedMessages: state.queuedMessages,
        error: state.error,
      ),
    );
  }
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

class _FakeProviderLookupClient extends ProviderSetupClient {
  var modelSnapshotCalls = 0;

  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    modelSnapshotCalls += 1;
    return const ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'instance-1',
          displayName: 'Z.AI Coding Plan',
          defaultModel: 'glm-5.2',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'ready',
          models: [ModelCacheModelDto(id: 'glm-5.2')],
        ),
      ],
      recent: [],
    );
  }

  @override
  Future<List<ProviderInstanceDto>> listInstances({DeviceConfig? agent}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeRecoveryProviderClient extends ProviderSetupClient {
  @override
  Future<ModelCacheSnapshotDto> modelSnapshot({DeviceConfig? agent}) async {
    return const ModelCacheSnapshotDto(
      instances: [
        ModelCacheInstanceDto(
          id: 'provider-new',
          displayName: 'Z.AI Coding Plan',
          defaultModel: 'glm-5.2',
          status: 'ready',
          isDefault: true,
          cacheStatus: 'ready',
          models: [
            ModelCacheModelDto(id: 'glm-5.2'),
          ],
        ),
      ],
      recent: [],
    );
  }

  @override
  Future<List<ProviderInstanceDto>> listInstances({DeviceConfig? agent}) async => const [];

  @override
  Future<void> modelRefresh({
    required String providerInstanceId,
    bool manual = false,
    DeviceConfig? agent,
  }) async {}

  @override
  Future<List<RecentModelDto>> modelRecentList({DeviceConfig? agent}) async => const [];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
