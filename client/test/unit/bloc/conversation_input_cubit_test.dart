import 'dart:io';

import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_route_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/runtime_notice.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_policy.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_runtime_service.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';
import 'package:sanad_client/infrastructure/mcp/mcp_service.dart';
import 'package:flutter_test/flutter_test.dart';

import '../../helpers/fake_device_repository.dart';
import '../../helpers/fake_conversation_repository.dart';
import '../../helpers/fake_socket.dart';
import '../../helpers/fake_device_preferences_repository.dart';

void main() {
  const workspace = DeviceWorkspace(id: 'workspace-1', name: 'desktop-agent', path: '/repo');

  late FakeSanadSocketService socket;
  late FakeDeviceRepository agentRepository;
  late FakeDeviceClientRegistry agentClientRegistry;
  late TestDeviceCubit agentCubit;
  late FakeConversationRepository conversationRepository;
  late ConversationCacheStore conversationCacheStore;
  late ConversationCacheRepository conversationCacheRepository;
  late FakeDevicePreferencesRepository preferencesRepository;
  late SessionCubit sessionCubit;
  late _TestSessionMessagesCubit messagesCubit;
  late ConversationInputCubit inputCubit;
  late DeviceConfig agent;
  late DeviceCapabilitiesStore capabilitiesStore;
  late DeviceConnectionCoordinator resolver;
  late _FakeLocalToolRuntimeService localToolRuntime;
  late WorkspaceToolRuntimeContext workspaceRuntimeContext;

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
    preferencesRepository = FakeDevicePreferencesRepository();
    resolver = createTestResolver(cloudSocket: socket, localSocket: socket);
    capabilitiesStore = DeviceCapabilitiesStore(resolver);
    localToolRuntime = _FakeLocalToolRuntimeService();
    workspaceRuntimeContext = WorkspaceToolRuntimeContext();
    agent = DeviceConfig(id: 'agent-1', name: 'Computer', isOnline: true);
    agentRepository.seedAgents([agent], activeAgentId: agent.id);
    conversationRepository.seedSessions(agent, [
      Session(
        id: 'session-1',
        title: 'Test Session',
        deviceId: agent.id,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    ]);
    agentCubit.emitState(DeviceActive(activeAgent: agent, agents: [agent]));
    sessionCubit = SessionCubit(
      agentCubit: agentCubit,
      socketService: socket,
      conversationRepository: conversationRepository,
    );
    messagesCubit = _TestSessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      conversationCacheRepository: conversationCacheRepository,
      preferencesRepository: preferencesRepository,
      capabilitiesStore: capabilitiesStore,
      localToolRuntime: localToolRuntime,
      workspaceRuntimeContext: workspaceRuntimeContext,
    );
    inputCubit = ConversationInputCubit(messagesCubit: messagesCubit);
  });

  tearDown(() async {
    await inputCubit.close();
    await messagesCubit.close();
    await sessionCubit.close();
    await agentCubit.close();
    await conversationRepository.dispose();
    conversationCacheStore.dispose();
    resolver.dispose();
    socket.dispose();
  });

  test('mirrors processing and active session state from SessionMessagesCubit', () async {
    messagesCubit.emitState(const SessionMessagesState(isProcessing: true, activeSessionId: 'session-1'));
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.isProcessing, isTrue);
    expect(inputCubit.state.activeSessionId, 'session-1');
  });

  test('new users default to balanced thinking mode', () async {
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageThinkingMode, SessionMessagesCubit.defaultThinkingMode);
    expect(
      preferencesRepository.getLastThinkingMode(agent.id),
      SessionMessagesCubit.defaultThinkingMode,
    );
  });

  test('model-scoped thinking leaves new users on provider default', () async {
    socket.autoCapabilitiesPayload = {
      'supports_workspaces': true,
      'workspace_required': true,
      'supports_workspace_selection': true,
      'local_tool_runtime_scope': 'workspace',
      'tool_protocol_version': 'tools.v2',
      'thinking_mode_source': 'model',
      'supports_thinking_mode_change': true,
      'thinking_modes_list': <String>[],
    };
    await capabilitiesStore.ensureFreshForAgent(agent, force: true);
    await preferencesRepository.clearPreferences(agent.id);
    await messagesCubit.close();
    messagesCubit = _TestSessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      conversationCacheRepository: conversationCacheRepository,
      preferencesRepository: preferencesRepository,
      capabilitiesStore: capabilitiesStore,
      localToolRuntime: localToolRuntime,
      workspaceRuntimeContext: workspaceRuntimeContext,
    );
    await inputCubit.close();
    inputCubit = ConversationInputCubit(messagesCubit: messagesCubit);
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageThinkingMode, isNull);
    expect(preferencesRepository.getLastThinkingMode(agent.id), isNull);
  });

  test('selectThinkingMode null clears model-scoped preference', () async {
    socket.autoCapabilitiesPayload = {
      'supports_workspaces': true,
      'workspace_required': true,
      'supports_workspace_selection': true,
      'local_tool_runtime_scope': 'workspace',
      'tool_protocol_version': 'tools.v2',
      'thinking_mode_source': 'model',
      'supports_thinking_mode_change': true,
    };
    await capabilitiesStore.ensureFreshForAgent(agent, force: true);
    messagesCubit.setNextMessagePreferences(thinkingMode: 'high');
    await Future<void>.delayed(Duration.zero);
    expect(inputCubit.state.nextMessageThinkingMode, 'high');

    await inputCubit.selectThinkingMode(
      scope: CapabilityValueScope.message,
      thinkingMode: null,
    );
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageThinkingMode, isNull);
    expect(preferencesRepository.getLastThinkingMode(agent.id), isNull);
  });

  test('cache workspace creation updates the composer picker immediately', () async {
    final created = await conversationCacheRepository.createWorkspace(
      agent,
      path: '/new-workspace',
      name: 'New Workspace',
    );
    await Future<void>.delayed(Duration.zero);

    expect(created, isNotNull);
    expect(
      inputCubit.state.availableWorkspaces,
      contains(
        const DeviceWorkspace(
          id: '/new-workspace',
          name: 'New Workspace',
          path: '/new-workspace',
        ),
      ),
    );
  });

  test('sendMessage trims drafts and delegates non-empty text', () async {
    messagesCubit.emitState(
      const SessionMessagesState(
        requiresWorkspace: true,
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-1',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await inputCubit.selectModel(
      scope: CapabilityValueScope.message,
      providerId: 'provider-1',
      model: 'model-1',
    );
    inputCubit.selectWorkspace(workspace);
    await Future<void>.delayed(Duration.zero);

    await inputCubit.sendMessage('  hello  ');
    await inputCubit.sendMessage('   ');

    expect(conversationRepository.sentMessages, ['hello']);
  });

  test('message-scoped model and thinking selections are sent with the next user message', () async {
    messagesCubit.emitState(const SessionMessagesState(requiresWorkspace: true));
    await Future<void>.delayed(Duration.zero);
    inputCubit.selectWorkspace(workspace);
    await Future<void>.delayed(Duration.zero);

    await inputCubit.selectModel(
      scope: CapabilityValueScope.message,
      providerId: 'provider-1',
      model: 'gpt-4o',
    );
    await inputCubit.selectThinkingMode(scope: CapabilityValueScope.message, thinkingMode: 'precise');
    await inputCubit.sendMessage('hello');

    expect(conversationRepository.sentMessageRequests.single, {
      'device_id': agent.id,
      'session_id': 'session-1',
      'workspace_id': 'workspace-1',
      'message': 'hello',
      'context': null,
      'model': 'gpt-4o',
      'thinking_mode': 'precise',
      'intent': 'auto',
    });
  });

  test('first message creates a session with workspace_id before think', () async {
    messagesCubit.emitState(
      const SessionMessagesState(
        requiresWorkspace: true,
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-1',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await inputCubit.selectModel(
      scope: CapabilityValueScope.message,
      providerId: 'provider-1',
      model: 'model-1',
    );
    inputCubit.selectWorkspace(workspace);
    await Future<void>.delayed(Duration.zero);

    await inputCubit.sendMessage('hello');

    expect(conversationRepository.createdSessionRequests.single, {
      'device_id': agent.id,
      'title': 'hello',
      'title_is_placeholder': true,
      'workspace_id': 'workspace-1',
      'provider_id': 'provider-1',
      'model': 'model-1',
      'thinking_mode': SessionMessagesCubit.defaultThinkingMode,
    });
    expect(conversationRepository.sentMessageRequests.single['session_id'], 'session-1');
    expect(
      conversationRepository.loadedHistorySessionIds,
      isEmpty,
      reason: 'Fresh sessions should not trigger immediate history hydration before the first turn persists.',
    );
  });

  test('session-scoped model changes update the active session immediately', () async {
    final selectedSession = Session(
      id: 'session-1',
      title: 'Test Session',
      deviceId: agent.id,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await sessionCubit.selectSession(selectedSession);
    await Future<void>.delayed(Duration.zero);

    await inputCubit.selectModel(scope: CapabilityValueScope.session, model: 'gpt-4o');

    expect(conversationRepository.updatedSessionPreferences.single, {
      'device_id': agent.id,
      'session_id': 'session-1',
      'provider_id': null,
      'model': 'gpt-4o',
      'thinking_mode': null,
    });
  });

  test('mirrors next message preferences from SessionMessagesCubit', () async {
    messagesCubit.setNextMessagePreferences(model: 'gpt-4o', thinkingMode: 'balanced');
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageModel, 'gpt-4o');
    expect(inputCubit.state.nextMessageThinkingMode, 'balanced');
  });

  test('mirrors runtime notice from SessionMessagesCubit', () async {
    const notice = RuntimeNotice(
      sessionId: 'session-1',
      requestId: 'req-1',
      status: 'waiting',
      reason: 'provider_rate_limit',
      title: 'NVIDIA NIM rate limit reached',
      retryAfterMs: 24000,
      requestsPerMinuteLimit: 38,
      actions: ['stop', 'continue_with_provider'],
    );

    final selectedSession = Session(
      id: 'session-1',
      title: 'Test Session',
      deviceId: agent.id,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await sessionCubit.selectSession(selectedSession);
    conversationRepository.setRuntimeNotice(agent, notice);
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.runtimeNotice, notice);
  });

  test('retryRuntimeNotice delegates to the repository', () async {
    const notice = RuntimeNotice(
      sessionId: 'session-1',
      requestId: 'req-1',
      status: 'blocked',
      reason: 'network_error',
      title: 'Connection failed',
      actions: ['retry'],
    );

    messagesCubit.emitState(const SessionMessagesState().copyWith(runtimeNotice: notice));
    await Future<void>.delayed(Duration.zero);

    await inputCubit.retryRuntimeNotice();

    expect(
      conversationRepository.retriedRuntimeNotices.single,
      {
        'device_id': agent.id,
        'session_id': 'session-1',
        'request_id': 'req-1',
        'provider_instance_id': null,
        'model_id': null,
      },
    );
  });

  test('retryRuntimeNotice uses the current UI provider/model route', () async {
    const notice = RuntimeNotice(
      sessionId: 'session-1',
      requestId: 'req-2',
      status: 'waiting',
      reason: 'provider_rate_limit',
      title: 'Rate limit reached',
      actions: ['retry'],
    );

    messagesCubit.emitState(
      const SessionMessagesState().copyWith(
        runtimeNotice: notice,
        nextMessageProviderId: 'provider-new',
        nextMessageModel: 'glm-5.2',
      ),
    );
    await Future<void>.delayed(Duration.zero);

    await inputCubit.retryRuntimeNotice();

    expect(
      conversationRepository.retriedRuntimeNotices.single,
      {
        'device_id': agent.id,
        'session_id': 'session-1',
        'request_id': 'req-2',
        'provider_instance_id': 'provider-new',
        'model_id': 'glm-5.2',
      },
    );
  });

  test('continueWithProvider delegates to the repository with an atomic provider/model route', () async {
    const notice = RuntimeNotice(
      sessionId: 'session-1',
      requestId: 'req-9',
      status: 'waiting',
      reason: 'provider_rate_limit',
      title: 'Rate limit reached',
      actions: ['continue_with_provider'],
    );

    messagesCubit.emitState(const SessionMessagesState().copyWith(runtimeNotice: notice));
    await Future<void>.delayed(Duration.zero);

    await inputCubit.continueWithProvider(
      providerInstanceId: 'provider-2',
      modelId: 'glm-5.2',
    );
    await Future<void>.delayed(Duration.zero);

    expect(
      conversationRepository.continuedRuntimeNotices.single,
      {
        'device_id': agent.id,
        'session_id': 'session-1',
        'provider_instance_id': 'provider-2',
        'request_id': 'req-9',
        'model_id': 'glm-5.2',
      },
    );
    expect(inputCubit.state.nextMessageProviderId, isNull);
    expect(inputCubit.state.nextMessageModel, isNull);
    expect(inputCubit.state.confirmedNextMessageProviderId, isNull);
    expect(inputCubit.state.confirmedNextMessageModel, isNull);
    expect(inputCubit.state.pendingNextMessageProviderId, 'provider-2');
    expect(inputCubit.state.pendingNextMessageModel, 'glm-5.2');
  });

  test('updates the visible route from the daemon-confirmed session_preferences_updated event', () async {
    final selectedSession = Session(
      id: 'session-1',
      title: 'Test Session',
      deviceId: agent.id,
      model: 'old-model',
      modelProvider: 'old-provider',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    conversationRepository.seedSessions(agent, [selectedSession]);
    await sessionCubit.selectSession(selectedSession);
    await Future<void>.delayed(Duration.zero);

    conversationRepository.setRouteSnapshots(agent, {
      'session-1': _route(
        provider: 'new-provider',
        model: 'new-model',
        revision: 2,
      ),
    });
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageProviderId, 'new-provider');
    expect(inputCubit.state.nextMessageModel, 'new-model');
    expect(inputCubit.state.confirmedNextMessageProviderId, 'new-provider');
    expect(inputCubit.state.confirmedNextMessageModel, 'new-model');
    expect(inputCubit.state.pendingNextMessageProviderId, isNull);
    expect(inputCubit.state.pendingNextMessageModel, isNull);
  });

  test(
    'repeated authoritative revision repairs a missing local provider route',
    () async {
      final selectedSession = Session(
        id: 'session-1',
        title: 'Test Session',
        deviceId: agent.id,
        model: 'model-1',
        modelProvider: 'provider-1',
        routeRevision: 2,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      conversationRepository.seedSessions(agent, [selectedSession]);
      await sessionCubit.selectSession(selectedSession);
      conversationRepository.setRouteSnapshots(agent, {
        'session-1': _route(
          provider: 'provider-1',
          model: 'model-1',
          revision: 2,
        ),
      });
      await Future<void>.delayed(Duration.zero);

      messagesCubit.replaceNextMessagePreferences(model: 'model-1');
      await Future<void>.delayed(Duration.zero);
      expect(inputCubit.state.nextMessageProviderId, isNull);

      conversationRepository.setRouteSnapshots(agent, {
        'session-1': _route(
          provider: 'provider-1',
          model: 'model-1',
          revision: 2,
        ),
      });
      await Future<void>.delayed(Duration.zero);
      await Future<void>.delayed(Duration.zero);

      expect(inputCubit.state.nextMessageProviderId, 'provider-1');
      expect(inputCubit.state.nextMessageModel, 'model-1');
    },
  );

  test('daemon rejection keeps the confirmed route instead of locking in the pending selection', () async {
    final selectedSession = Session(
      id: 'session-1',
      title: 'Test Session',
      deviceId: agent.id,
      model: 'old-model',
      modelProvider: 'old-provider',
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    conversationRepository.seedSessions(agent, [selectedSession]);
    await sessionCubit.selectSession(selectedSession);
    await Future<void>.delayed(Duration.zero);

    messagesCubit.emitState(
      messagesCubit.state.copyWith(
        activeSessionId: 'session-1',
        runtimeNotice: const RuntimeNotice(
          sessionId: 'session-1',
          requestId: 'req-reject',
          status: 'blocked',
          reason: 'provider_rate_limit',
          title: 'Waiting',
          actions: ['continue_with_provider'],
        ),
      ),
    );
    await Future<void>.delayed(Duration.zero);

    await inputCubit.continueWithProvider(
      providerInstanceId: 'candidate-provider',
      modelId: 'candidate-model',
    );
    await Future<void>.delayed(Duration.zero);
    expect(inputCubit.state.nextMessageProviderId, 'old-provider');
    expect(inputCubit.state.confirmedNextMessageProviderId, 'old-provider');
    expect(inputCubit.state.pendingNextMessageProviderId, 'candidate-provider');

    conversationRepository.setRouteSnapshots(agent, {
      'session-1': _route(
        provider: 'old-provider',
        model: 'old-model',
        revision: 2,
      ),
    });
    await Future<void>.delayed(Duration.zero);
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageProviderId, 'old-provider');
    expect(inputCubit.state.nextMessageModel, 'old-model');
    expect(inputCubit.state.pendingNextMessageProviderId, isNull);
    expect(inputCubit.state.pendingNextMessageModel, isNull);
  });

  test('blocks sending when a workspace is required but not selected', () async {
    messagesCubit.emitState(
      const SessionMessagesState(
        requiresWorkspace: true,
        nextMessageProviderId: 'provider-1',
        nextMessageModel: 'model-1',
      ),
    );
    await Future<void>.delayed(Duration.zero);
    await inputCubit.selectModel(
      scope: CapabilityValueScope.message,
      providerId: 'provider-1',
      model: 'model-1',
    );

    await inputCubit.sendMessage('hello');

    expect(conversationRepository.sentMessages, isEmpty);
    expect(inputCubit.state.error, contains('Select a workspace'));
  });

  test('blocks sending when provider or model selection is missing', () async {
    messagesCubit.emitState(const SessionMessagesState());
    await Future<void>.delayed(Duration.zero);

    await inputCubit.sendMessage('hello');

    expect(conversationRepository.createdSessionRequests, isEmpty);
    expect(conversationRepository.sentMessages, isEmpty);
    expect(
      inputCubit.state.error,
      ConversationInputCubit.missingProviderModelError,
    );
  });

  test('blocks sending while a permission request is pending', () async {
    final session = Session(
      id: 'session-1',
      title: 'Test Session',
      deviceId: agent.id,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await sessionCubit.selectSession(session);
    await Future<void>.delayed(Duration.zero);

    conversationRepository.setPendingSuspendedRequest(
      agent,
      const DeviceSuspendedRequest(
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
    );
    await Future<void>.delayed(Duration.zero);

    await inputCubit.sendMessage('hello');

    expect(conversationRepository.sentMessages, isEmpty);
    expect(inputCubit.state.error, contains('Resolve the pending clarifying question or permission request'));
  });

  test('approvePendingSuspendedRequest delegates to the repository', () async {
    final request = const DeviceSuspendedRequest(
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
    );

    await inputCubit.approvePendingSuspendedRequest(request: request, scope: 'session');

    expect(conversationRepository.permissionResponses.single, {
      'device_id': agent.id,
      'request_id': 'permission-1',
      'allow': 'true',
      'scope': 'session',
      'comment': null,
      'answer': null,
    });
  });

  test('mirrors workspace selection from SessionMessagesCubit', () async {
    messagesCubit.emitState(const SessionMessagesState(requiresWorkspace: true, availableWorkspaces: [workspace]));
    await Future<void>.delayed(Duration.zero);
    inputCubit.selectWorkspace(workspace);
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.requiresWorkspace, isTrue);
    expect(inputCubit.state.selectedWorkspace, workspace);
  });

  test('searchSlashCommands delegates to the active agent with the selected workspace id', () async {
    conversationRepository.slashCommandResults = const [
      SlashCommandEntry(sourceId: 'skill', command: 'review', insertText: 'review'),
    ];
    inputCubit.selectWorkspace(workspace);
    await Future<void>.delayed(Duration.zero);

    final results = await inputCubit.searchSlashCommands(query: 'rev');

    expect(results.map((entry) => entry.command), ['review']);
    expect(conversationRepository.slashCommandSearchRequests.single, {
      'device_id': agent.id,
      'query': 'rev',
      'workspace_id': workspace.id,
    });
  });

  test('browseWorkspaceTree delegates to the active agent runtime query', () async {
    conversationRepository.workspaceTreeSnapshot = const WorkspaceTreeSnapshot(
      workspaceId: '/repo',
      rootPath: '/repo',
      path: '/repo/apps',
      parentPath: '/repo',
      entries: [
        WorkspaceTreeEntry(
          name: 'sanad-client',
          path: '/repo/apps/sanad-client',
          relativePath: 'apps/sanad-client',
          isDirectory: true,
        ),
      ],
      truncated: false,
    );

    final snapshot = await inputCubit.browseWorkspaceTree(path: '/repo/apps');

    expect(snapshot.path, '/repo/apps');
    expect(snapshot.entries.single.name, 'sanad-client');
    expect(conversationRepository.browseWorkspaceTreeRequests.single, {
      'device_id': agent.id,
      'workspace_id': null,
      'path': '/repo/apps',
    });
  });

  test('selecting a workspace re-registers local tools for that workspace', () async {
    inputCubit.selectWorkspace(workspace);
    await Future<void>.delayed(Duration.zero);

    expect(localToolRuntime.broadcastRequests.single, {
      'workspace_id': 'workspace-1',
    });
  });

  test('selecting a workspace updates the local runtime workspace context', () async {
    inputCubit.selectWorkspace(workspace);
    await Future<void>.delayed(Duration.zero);

    expect(workspaceRuntimeContext.activeWorkspace, workspace);
  });

  test('setting workspace permission mode persists it locally and updates state', () async {
    final tempDir = await Directory.systemTemp.createTemp('workspace-permission-mode-');
    addTearDown(() => tempDir.delete(recursive: true));
    final tempWorkspace = DeviceWorkspace(id: 'workspace-temp', name: 'temp', path: tempDir.path);

    conversationRepository.seededWorkspacePolicies[tempDir.path] = const WorkspacePolicy(
      permissionMode: WorkspacePermissionMode.defaultMode,
    );

    // Wait for the agent to become active in agentCubit and propagate to messagesCubit
    if (agentCubit.state is! DeviceActive) {
      await agentCubit.stream.firstWhere((s) => s is DeviceActive);
    }
    for (int i = 0; i < 10; i++) {
      await Future<void>.delayed(Duration.zero);
    }

    inputCubit.selectWorkspace(tempWorkspace);

    // Wait for initial workspace policy load to complete
    if (messagesCubit.state.isLoadingPermissionMode) {
      await messagesCubit.stream.firstWhere((s) => !s.isLoadingPermissionMode);
    }
    // Yield microtasks to let any pending queue clear
    await Future<void>.delayed(Duration.zero);

    await inputCubit.setWorkspacePermissionMode(WorkspacePermissionMode.fullAccess);
    // Yield to let inputCubit process the stream event from messagesCubit
    await Future<void>.delayed(Duration.zero);

    expect(conversationRepository.setPermissionModeRequests.length, 1);
    expect(conversationRepository.setPermissionModeRequests.first['mode'], WorkspacePermissionMode.fullAccess);
    expect(inputCubit.state.permissionMode, WorkspacePermissionMode.fullAccess);
  });

  test('stop delegates to SessionMessagesCubit repository flow', () async {
    messagesCubit.emitState(const SessionMessagesState(activeSessionId: 'session-1'));
    await inputCubit.stop();

    expect(conversationRepository.stopCalls, 1);
    expect(conversationRepository.stoppedSessionIds, ['session-1']);
  });

  test('stop during waiting remains event-driven and does not clear the local notice optimistically', () async {
    final selectedSession = Session(
      id: 'session-1',
      title: 'Test Session',
      deviceId: agent.id,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    await sessionCubit.selectSession(selectedSession);
    conversationRepository.setRuntimeNotice(
      agent,
      const RuntimeNotice(
        sessionId: 'session-1',
        requestId: 'req-stop',
        status: 'waiting',
        reason: 'provider_rate_limit',
        title: 'Waiting',
        actions: ['stop'],
      ),
    );
    await Future<void>.delayed(Duration.zero);

    await inputCubit.stop();

    expect(conversationRepository.stopCalls, 1);
    expect(inputCubit.state.runtimeNotice?.status, 'waiting');
  });

  test('persists provider, model, and thinking mode when changed', () async {
    await inputCubit.selectModel(
      scope: CapabilityValueScope.message,
      providerId: 'provider-1',
      model: 'gpt-4o',
    );
    await inputCubit.selectThinkingMode(scope: CapabilityValueScope.message, thinkingMode: 'precise');

    expect(preferencesRepository.getLastProvider(agent.id), 'provider-1');
    expect(preferencesRepository.getLastModel(agent.id), 'gpt-4o');
    expect(preferencesRepository.getLastThinkingMode(agent.id), 'precise');
  });

  test('restores provider, model, and thinking mode from preferences on agent subscription', () async {
    // 1. Save some preferences first
    await preferencesRepository.setLastProvider(agent.id, 'provider-1');
    await preferencesRepository.setLastModel(agent.id, 'claude-3-opus');
      await preferencesRepository.setLastThinkingMode(agent.id, 'deep');

    // 2. Re-subscribe to agent by re-initializing the cubit (simulating fresh start)
    final newMessagesCubit = _TestSessionMessagesCubit(
      agentCubit: agentCubit,
      sessionCubit: sessionCubit,
      conversationRepository: conversationRepository,
      preferencesRepository: preferencesRepository,
      capabilitiesStore: capabilitiesStore,
      localToolRuntime: localToolRuntime,
      workspaceRuntimeContext: workspaceRuntimeContext,
    );
    final newInputCubit = ConversationInputCubit(messagesCubit: newMessagesCubit);

    // Wait for the async loading in initState of Cubit or subscriptions
    await Future<void>.delayed(Duration.zero);

    expect(newInputCubit.state.nextMessageProviderId, 'provider-1');
    expect(newInputCubit.state.nextMessageModel, 'claude-3-opus');
      expect(newInputCubit.state.nextMessageThinkingMode, 'deep');

    await newInputCubit.close();
    await newMessagesCubit.close();
  });

  test(
    'restored identity-only session keeps the persisted provider route',
    () async {
      final restoredSession = Session(
        id: 'session-restored',
        title: 'Loading...',
        deviceId: agent.id,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      );
      await sessionCubit.selectSession(restoredSession);
      await preferencesRepository.setLastProvider(agent.id, 'provider-1');
      await preferencesRepository.setLastModel(agent.id, 'claude-3-opus');

      final restartedMessagesCubit = _TestSessionMessagesCubit(
        agentCubit: agentCubit,
        sessionCubit: sessionCubit,
        conversationRepository: conversationRepository,
        preferencesRepository: preferencesRepository,
        capabilitiesStore: capabilitiesStore,
        localToolRuntime: localToolRuntime,
        workspaceRuntimeContext: workspaceRuntimeContext,
      );
      final restartedInputCubit = ConversationInputCubit(
        messagesCubit: restartedMessagesCubit,
      );
      await Future<void>.delayed(Duration.zero);

      expect(restartedInputCubit.state.nextMessageProviderId, 'provider-1');
      expect(restartedInputCubit.state.nextMessageModel, 'claude-3-opus');

      await restartedInputCubit.close();
      await restartedMessagesCubit.close();
    },
  );

  test('authoritative readiness repairs a provider-only route', () async {
    messagesCubit.setNextMessagePreferences(providerId: 'provider-partial');
    await Future<void>.delayed(Duration.zero);

    inputCubit.initializeProviderSelection(
      providerId: 'provider-default',
      model: 'model-default',
    );
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageProviderId, 'provider-default');
    expect(inputCubit.state.nextMessageModel, 'model-default');
  });

  test('initializes an empty provider route once from authoritative readiness', () async {
    inputCubit.initializeProviderSelection(
      providerId: 'provider-default',
      model: 'model-default',
    );
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageProviderId, 'provider-default');
    expect(inputCubit.state.nextMessageModel, 'model-default');
    expect(preferencesRepository.getLastProvider(agent.id), 'provider-default');
    expect(preferencesRepository.getLastModel(agent.id), 'model-default');

    inputCubit.initializeProviderSelection(
      providerId: 'provider-other',
      model: 'model-other',
    );
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageProviderId, 'provider-default');
    expect(inputCubit.state.nextMessageModel, 'model-default');

    inputCubit.initializeProviderSelection(
      providerId: 'provider-reconfigured',
      model: 'model-reconfigured',
      replaceExisting: true,
    );
    await Future<void>.delayed(Duration.zero);

    expect(inputCubit.state.nextMessageProviderId, 'provider-reconfigured');
    expect(inputCubit.state.nextMessageModel, 'model-reconfigured');
    expect(
      preferencesRepository.getLastProvider(agent.id),
      'provider-reconfigured',
    );
    expect(
      preferencesRepository.getLastModel(agent.id),
      'model-reconfigured',
    );
  });
}

SessionRouteSnapshot _route({
  required String provider,
  required String model,
  required int revision,
}) => SessionRouteSnapshot(
  sessionId: 'session-1',
  source: SessionRouteSource.recovery,
  previousProviderInstanceId: null,
  providerInstanceId: provider,
  model: model,
  reason: null,
  requestId: null,
  routeRevision: revision,
  updatedAt: DateTime(2026, 7, 15),
  eventId: null,
  previousProviderDisplayName: null,
  providerDisplayName: null,
);

class _TestSessionMessagesCubit extends SessionMessagesCubit {
  _TestSessionMessagesCubit({
    required super.agentCubit,
    required super.sessionCubit,
    required super.conversationRepository,
    super.conversationCacheRepository,
    required super.preferencesRepository,
    required super.capabilitiesStore,
    super.localToolRuntime,
    super.workspaceRuntimeContext,
  });

  void emitState(SessionMessagesState state) {
    emit(state);
  }
}

class _FakeLocalToolRuntimeService extends LocalToolRuntimeService {
  final List<Map<String, String?>> broadcastRequests = [];

  _FakeLocalToolRuntimeService()
    : super(
        mcpService: McpService(),
        conversationRepository: FakeConversationRepository(),
        deviceRepository: FakeDeviceRepository(),
      );

  @override
  Future<void> broadcastAvailableTools({String? agentType, String? workspaceId, String? workspacePath}) async {
    broadcastRequests.add({
      'workspace_id': workspaceId,
    });
  }
}
