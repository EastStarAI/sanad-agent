import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_gateway_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/registry/toolsets.dart';
import 'package:sanad_agent/capabilities/skills/skill_load_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_server_config.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';
import 'package:sanad_agent/plugins/plugin_manager.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';

import 'support/local_gateway_test_support.dart';

class MockAuthManager extends AuthManager {
  @override
  bool get isAuthenticated => true;
  @override
  String get accessToken => 'mock_token';
}

class MockConfig extends Config {
  @override
  String get gatewayUrl => 'http://localhost:8000';
}

class TestLocalConfig extends MockConfig {
  TestLocalConfig(this._port);

  final int _port;

  @override
  int get localGatewayPort => _port;

  @override
  String get localGatewayUrl => 'http://127.0.0.1:$_port';
}

class BlockingRestartCoordinator extends DaemonRestartCoordinator {
  BlockingRestartCoordinator(this.preparation);

  final Completer<DaemonRestartPreparation> preparation;
  final started = Completer<void>();

  @override
  Future<DaemonRestartPreparation> prepareRestart({
    bool force = false,
    Duration timeout =
        SessionRunOrchestrator.controlledRestartCheckpointTimeout,
    String? requesterSessionId,
    String? requesterToolCallId,
  }) {
    if (!started.isCompleted) started.complete();
    return preparation.future;
  }
}

class FakeLlmAdapter implements LLMAdapter {
  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) {
    throw UnimplementedError();
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) {
    throw UnimplementedError();
  }

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    return [
      ModelOption(
        value: 'ollama/gemma:2b',
        label: 'Gemma 2B',
        provider: 'ollama',
        supportsReasoning: true,
      ),
    ];
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 8192;
}

class ReplayScenarioLlmAdapter implements LLMAdapter {
  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async => AgentResponse(
    message: Message(role: MessageRole.assistant, content: 'Replay complete.'),
    model: modelOverride ?? 'ollama/gemma:2b',
    provider: 'ollama',
  );

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(
      history,
      tools: tools,
      modelOverride: modelOverride,
      options: options,
    );
  }

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 8192;
}

class ResumeScenarioLlmAdapter implements LLMAdapter {
  static const _model = 'ollama/gemma:2b';
  static const _provider = 'ollama';
  static const _toolCallId = 'resume-tool-call-1';

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: 'Permission Resume Test',
      ),
      usage: const {'total_tokens': 8},
      model: _model,
      provider: _provider,
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    final hasToolResult = history.any(
      (message) =>
          message.role == MessageRole.tool &&
          message.toolCallId == _toolCallId &&
          (message.content?.isNotEmpty ?? false),
    );

    if (!hasToolResult) {
      yield AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(
              id: _toolCallId,
              name: 'shell_execute',
              arguments: {'command': 'echo "Terminal is working"'},
            ),
          ],
        ),
        isToolCall: true,
        usage: const {
          'prompt_tokens': 12,
          'total_tokens': 12,
          'prompt_tokens_details': {'cached_tokens': 8},
        },
        model: _model,
        provider: _provider,
      );
      return;
    }

    yield AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: 'Terminal command completed successfully.',
      ),
      usage: const {
        'prompt_tokens': 16,
        'total_tokens': 16,
        'prompt_tokens_details': {'cached_tokens': 10},
      },
      model: _model,
      provider: _provider,
    );
  }

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    return [
      ModelOption(
        value: _model,
        label: 'Gemma 2B',
        provider: _provider,
        supportsReasoning: true,
      ),
    ];
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 8192;
}

class NoopMcpRuntimeManager extends McpRuntimeManager {
  @override
  Future<List<McpServerConfig>> listServers({String? workspacePath}) async =>
      const [];

  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async =>
      const [];
}

class MinimalRuntimeContextBuilder extends RuntimeContextBuilder {
  const MinimalRuntimeContextBuilder()
    : super(skillRegistry: const SkillRegistry());

  @override
  Future<String?> build({
    required String workspacePath,
    String? workspaceName,
    ToolsRegistry? registry,
  }) async {
    return 'Workspace: ${workspaceName ?? workspacePath}';
  }
}

Future<Map<String, dynamic>> _nextFrame(StreamIterator<dynamic> frames) async {
  final hasFrame = await frames.moveNext().timeout(const Duration(seconds: 5));
  if (!hasFrame) {
    throw StateError('Expected websocket frame but stream ended.');
  }
  return jsonDecode(frames.current as String) as Map<String, dynamic>;
}

Future<Map<String, dynamic>> _waitForEvent(
  StreamIterator<dynamic> frames,
  String eventName,
) async {
  final seen = <String>[];
  while (true) {
    final frame = await _nextFrame(frames);
    final type = frame['event']?.toString() ?? frame['type']?.toString() ?? '';
    if (type.isNotEmpty) {
      seen.add(type);
    }
    if (frame['event'] == eventName) {
      return frame;
    }
    if (seen.length > 20) {
      throw StateError(
        'Timed out waiting for event $eventName. Seen: ${seen.join(', ')}',
      );
    }
  }
}

Future<T> _waitForValue<T>(
  Future<T?> Function() readValue, {
  Duration timeout = const Duration(seconds: 5),
  Duration interval = const Duration(milliseconds: 100),
}) async {
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final value = await readValue();
    if (value != null) {
      return value;
    }
    await Future<void>.delayed(interval);
  }
  throw TimeoutException('Timed out waiting for value.', timeout);
}

Future<({GatewayManager gatewayManager, LocalDaemonServerPlatform platform})>
_startResumeRuntime({
  required int port,
  required String workspacePath,
  required LLMAdapter adapter,
}) async {
  await getIt.reset();
  // ignore: invalid_use_of_visible_for_testing_member
  SessionManager.resetForTesting();
  getIt.allowReassignment = true;

  getIt.registerSingleton<AuthManager>(MockAuthManager());
  getIt.registerSingleton<Config>(TestLocalConfig(port));
  getIt.registerSingleton<AgentStateDatabase>(AgentStateDatabase());
  getIt.registerSingleton<SessionManager>(SessionManager());
  getIt.registerSingleton<PersistedRuntimeStateRepository>(
    PersistedRuntimeStateRepository.fromState(getIt<AgentStateDatabase>()),
  );
  getIt.registerSingleton<LLMAdapter>(adapter);
  getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
  getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());
  getIt.registerSingleton<TitleService>(TitleService(adapter: adapter));
  getIt.registerSingleton<ToolsRegistry>(() {
    final registry = ToolsRegistry();
    registry.registerTools(Toolsets.coreTools);
    return registry;
  }());
  getIt.registerSingleton<SkillRegistry>(const SkillRegistry());
  getIt.registerSingleton<SkillLoadService>(
    SkillLoadService(registry: getIt<SkillRegistry>()),
  );
  getIt.registerSingleton<RuntimeContextBuilder>(
    const MinimalRuntimeContextBuilder(),
  );
  getIt.registerSingleton<WorkspacePolicyStore>(const WorkspacePolicyStore());
  getIt.registerSingleton<SuspendedCheckpointStore>(
    SuspendedCheckpointStore(sessionManager: getIt<SessionManager>()),
  );
  getIt.registerSingleton<PermissionManager>(
    PermissionManager(
      policyStore: getIt<WorkspacePolicyStore>(),
      platformRuntimeBridge: getIt<PlatformRuntimeBridge>(),
      checkpointStore: getIt<SuspendedCheckpointStore>(),
    ),
  );
  getIt.registerSingleton<LocalWorkspaceRuntimeService>(
    LocalWorkspaceRuntimeService(
      sanadHomePath: getSanadHome(),
      currentWorkingDirectory: workspacePath,
      skillRegistry: getIt<SkillRegistry>(),
      skillLoadService: getIt<SkillLoadService>(),
    ),
  );
  getIt.registerSingleton<LocalRuntimeCatalog>(
    LocalRuntimeCatalog(
      workspaceRuntimeService: getIt<LocalWorkspaceRuntimeService>(),
      mcpRuntimeManager: NoopMcpRuntimeManager(),
      permissionManager: getIt<PermissionManager>(),
      platformRuntimeBridge: getIt<PlatformRuntimeBridge>(),
    ),
  );
  getIt.registerSingleton<LocalRuntimeOrchestrator>(
    LocalRuntimeOrchestrator(
      getIt<LocalWorkspaceRuntimeService>(),
      getIt<LocalRuntimeCatalog>(),
      runtimeContextBuilder: getIt<RuntimeContextBuilder>(),
    ),
  );
  getIt.registerSingleton<SuspendedResumeService>(
    SuspendedResumeService(
      checkpointStore: getIt<SuspendedCheckpointStore>(),
      sessionManager: getIt<SessionManager>(),
      runtimeCatalog: getIt<LocalRuntimeCatalog>(),
      runtimeContextBuilder: getIt<RuntimeContextBuilder>(),
      workspaceRuntimeService: getIt<LocalWorkspaceRuntimeService>(),
      permissionManager: getIt<PermissionManager>(),
    ),
  );
  getIt.registerSingleton<PluginManager>(PluginManager());
  getIt.registerFactoryParam<AgentRunner, String?, void>(
    (sessionId, _) => AgentRunner(
      getIt<LLMAdapter>(),
      getIt<ToolsRegistry>().copy(),
      getIt<SessionManager>(),
      pluginManager: getIt<PluginManager>(),
      existingSessionId: sessionId,
    ),
  );
  getIt.registerSingleton<SessionRunOrchestrator>(SessionRunOrchestrator());
  getIt.registerSingleton<LocalDaemonServerPlatform>(
    LocalDaemonServerPlatform(),
  );

  final gatewayManager = GatewayManager();
  final platform = getIt<LocalDaemonServerPlatform>();
  gatewayManager.registerPlatform(platform);
  await gatewayManager.start();
  return (gatewayManager: gatewayManager, platform: platform);
}

Future<int> _reserveFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  late Directory tempSanadHome;

  void originalSetUp() {
    tempSanadHome = Directory.systemTemp.createTempSync(
      'sanad-agent-gateway-test',
    );
    setSanadHomeOverride(tempSanadHome.path);
    getIt.registerSingleton<AuthManager>(MockAuthManager());
    getIt.registerSingleton<Config>(MockConfig());
    getIt.registerSingleton<SessionManager>(SessionManager());
    getIt.registerSingleton<LLMAdapter>(FakeLlmAdapter());
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
    getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());
  }

  setUp(() {
    originalSetUp();
  });

  tearDown(() async {
    // ignore: invalid_use_of_visible_for_testing_member
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    await getIt.reset();
    if (tempSanadHome.existsSync()) {
      await tempSanadHome.delete(recursive: true);
    }
  });

  test('SanadGatewayPlatform initialization', () async {
    final platform = SanadGatewayPlatform();

    // We can't easily test the socket connection without a real server or complex mocks,
    // but we can verify the platform identity and basic setup.
    expect(platform.platformId, equals('sanad_gateway'));
  });

  test(
    'LocalDaemonServerPlatform serves health and routes protocol commands',
    () async {
      final port = await _reserveFreePort();
      await getIt.reset();
      tempSanadHome = Directory.systemTemp.createTempSync(
        'sanad-agent-gateway-test',
      );
      setSanadHomeOverride(tempSanadHome.path);
      getIt.registerSingleton<AuthManager>(MockAuthManager());
      getIt.registerSingleton<Config>(TestLocalConfig(port));
      getIt.registerSingleton<SessionManager>(SessionManager());
      getIt.registerSingleton<LLMAdapter>(FakeLlmAdapter());
      getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
      getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());

      final sessionManager = getIt<SessionManager>();
      final session = sessionManager.createSession('ollama/gemma:2b');
      sessionManager.updateSessionTitle(session.sessionId, 'Local Session');

      final platform = LocalDaemonServerPlatform();
      await platform.initialize();

      final healthRequest = await HttpClient().getUrl(
        Uri.parse('http://127.0.0.1:$port/health'),
      );
      authorizeLocalGatewayTestRequest(healthRequest, tempSanadHome.path);
      final health = await (await healthRequest.close())
          .transform(utf8.decoder)
          .join();
      expect(jsonDecode(health)['status'], equals('ok'));

      final socket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: tempSanadHome.path,
      );
      final frames = StreamIterator(socket);
      await frames.moveNext();
      final firstFrame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      expect(firstFrame['type'], equals('register_success'));

      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'get_sessions',
          'payload': {'request_id': 'req-1'},
        }),
      );

      await frames.moveNext();
      final eventFrame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      expect(eventFrame['type'], equals('device_event'));
      expect(eventFrame['event'], equals('sessions_list'));
      final sessions = (eventFrame['payload']['sessions'] as List)
          .cast<Map<String, dynamic>>();
      expect(
        sessions.any((sessionItem) => sessionItem['id'] == session.sessionId),
        isTrue,
      );

      await frames.cancel();
      await socket.close();
      await platform.dispose();
    },
  );

  test('restart safety wait does not block health requests', () async {
    final port = await _reserveFreePort();
    await getIt.reset();
    tempSanadHome = Directory.systemTemp.createTempSync(
      'sanad-agent-gateway-test',
    );
    setSanadHomeOverride(tempSanadHome.path);
    getIt.registerSingleton<AuthManager>(AuthManager());
    getIt.registerSingleton<Config>(TestLocalConfig(port));
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
    getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());
    final pendingPreparation = Completer<DaemonRestartPreparation>();
    final restartCoordinator = BlockingRestartCoordinator(pendingPreparation);
    getIt.registerSingleton<DaemonRestartCoordinator>(restartCoordinator);

    final platform = LocalDaemonServerPlatform();
    await platform.initialize();
    final client = HttpClient();
    final restartRequest = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/restart?timeout_seconds=60'),
    );
    authorizeLocalGatewayTestRequest(restartRequest, tempSanadHome.path);
    final restartResponse = restartRequest.close();
    await restartCoordinator.started.future;

    final healthRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    authorizeLocalGatewayTestRequest(healthRequest, tempSanadHome.path);
    final healthResponse = await healthRequest.close().timeout(
      const Duration(seconds: 1),
    );
    expect(healthResponse.statusCode, HttpStatus.ok);
    await healthResponse.drain<void>();

    pendingPreparation.complete(
      const DaemonRestartPreparation(
        accepted: false,
        force: false,
        timeout: Duration(seconds: 60),
        outcome: 'timeout',
      ),
    );
    expect((await restartResponse).statusCode, HttpStatus.conflict);

    client.close(force: true);
    await platform.dispose();
  });

  test(
    'local daemon replays an edited latest turn across the idle boundary',
    () async {
      final port = await _reserveFreePort();
      final workspaceDir = Directory('${tempSanadHome.path}/replay-workspace')
        ..createSync(recursive: true);
      final runtime = await _startResumeRuntime(
        port: port,
        workspacePath: workspaceDir.path,
        adapter: ReplayScenarioLlmAdapter(),
      );
      final sessions = getIt<SessionManager>();
      final session = sessions.createSession('ollama/gemma:2b');
      sessions.saveSessionHistory(session.sessionId, [
        Message(
          role: MessageRole.user,
          content: 'Original request',
          metadata: const {'request_id': 'target-request'},
        ),
        Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(
              id: 'legacy-tool-call',
              name: 'file_edit',
              arguments: const {'path': 'example.txt'},
            ),
          ],
        ),
        Message(
          role: MessageRole.tool,
          toolCallId: 'legacy-tool-call',
          content: 'done',
        ),
        Message(role: MessageRole.assistant, content: 'Old answer'),
      ]);
      final target = sessions.getMessages(session.sessionId).first;
      final targetMessageId = target.metadata?['message_id']?.toString();
      final targetTurnId = target.metadata?['turn_id']?.toString();
      final historyRevision = sessions
          .getSession(session.sessionId)!
          .historyRevision;

      final socket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: tempSanadHome.path,
      );
      final frames = StreamIterator<dynamic>(socket);
      await _nextFrame(frames);
      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': CanonicalEventTypes.sessionTurnReplay,
          'device_id': 'local-device-1',
          'payload': {
            'session_id': session.sessionId,
            'request_id': 'preflight-request',
            'target_request_id': 'target-request',
            'target_message_id': targetMessageId,
            'target_turn_id': targetTurnId,
            'expected_history_revision': historyRevision,
            'action': 'edit',
            'message': 'Edited request',
          },
        }),
      );
      final confirmation = await _waitForEvent(
        frames,
        CanonicalEventTypes.sessionTurnReplayResult,
      );
      expect(
        confirmation['payload']['outcome'],
        equals('confirmation_required'),
      );
      expect(confirmation['payload']['replay_safety'], equals('unknown'));
      expect(sessions.getMessages(session.sessionId), hasLength(4));

      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': CanonicalEventTypes.sessionTurnReplay,
          'device_id': 'local-device-1',
          'payload': {
            'session_id': session.sessionId,
            'request_id': 'replacement-request',
            'target_request_id': 'target-request',
            'target_message_id': targetMessageId,
            'target_turn_id': targetTurnId,
            'expected_history_revision': historyRevision,
            'action': 'edit',
            'message': 'Edited request',
            'confirmed_replay_unsafe': true,
            'model_id': 'ollama/gemma:2b',
          },
        }),
      );

      final accepted = await _waitForEvent(
        frames,
        CanonicalEventTypes.sessionTurnReplayResult,
      );
      expect(accepted['payload']['outcome'], equals('accepted'));
      final liveUser = await _waitForEvent(frames, 'user_message');
      final liveAnswer = await _waitForEvent(
        frames,
        CanonicalEventTypes.finalAnswer,
      );
      expect(liveUser['payload']['message_id'], isNotEmpty);
      expect(liveUser['payload']['turn_id'], isNotEmpty);
      expect(liveUser['payload']['input_kind'], equals('root_turn'));
      expect(liveUser['payload']['replay_eligible'], isTrue);
      expect(liveAnswer['payload']['message_id'], isNotEmpty);
      expect(
        liveAnswer['payload']['turn_id'],
        equals(liveUser['payload']['turn_id']),
      );

      final messages = sessions.getMessages(session.sessionId);
      expect(
        messages.where((message) => message.role == MessageRole.user),
        hasLength(1),
      );
      expect(messages.first.content, equals('Edited request'));
      expect(
        messages.first.metadata?['request_id'],
        equals('replacement-request'),
      );
      expect(messages.last.content, equals('Replay complete.'));
      expect(
        sessions.getMessages(session.sessionId, includeSuperseded: true),
        hasLength(greaterThan(messages.length)),
      );
      expect(
        sessions
            .getMessages(session.sessionId, includeSuperseded: true)
            .any((message) => message.content == 'Original request'),
        isTrue,
      );

      await frames.cancel();
      await socket.close();
      await runtime.platform.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    },
  );

  test(
    'local daemon forks a middle final answer into an independent child',
    () async {
      final port = await _reserveFreePort();
      final workspaceDir = Directory('${tempSanadHome.path}/fork-workspace')
        ..createSync(recursive: true);
      final runtime = await _startResumeRuntime(
        port: port,
        workspacePath: workspaceDir.path,
        adapter: ReplayScenarioLlmAdapter(),
      );
      final sessions = getIt<SessionManager>();
      final session = sessions.createSession('ollama/gemma:2b');
      sessions.updateSessionTitle(session.sessionId, 'Refactor auth');
      sessions.saveSessionHistory(session.sessionId, [
        Message(
          role: MessageRole.user,
          content: 'one',
          metadata: const {
            'request_id': 'req-1',
            'message_id': 'm-u1',
            'turn_id': 'turn-1',
          },
        ),
        Message(
          role: MessageRole.assistant,
          content: 'first',
          finishReason: LLMFinishReason.stop,
          metadata: const {'message_id': 'm-a1', 'turn_id': 'turn-1'},
        ),
        Message(
          role: MessageRole.user,
          content: 'two',
          metadata: const {
            'request_id': 'req-2',
            'message_id': 'm-u2',
            'turn_id': 'turn-2',
          },
        ),
        Message(
          role: MessageRole.assistant,
          content: 'second final',
          finishReason: LLMFinishReason.stop,
          metadata: const {'message_id': 'm-a2', 'turn_id': 'turn-2'},
        ),
        Message(
          role: MessageRole.user,
          content: 'three',
          metadata: const {
            'request_id': 'req-3',
            'message_id': 'm-u3',
            'turn_id': 'turn-3',
          },
        ),
        Message(
          role: MessageRole.assistant,
          content: 'third',
          finishReason: LLMFinishReason.stop,
          metadata: const {'message_id': 'm-a3', 'turn_id': 'turn-3'},
        ),
      ]);

      final socket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: tempSanadHome.path,
      );
      final frames = StreamIterator<dynamic>(socket);
      await _nextFrame(frames);
      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': CanonicalEventTypes.sessionFork,
          'device_id': 'local-device-1',
          'payload': {
            'session_id': session.sessionId,
            'request_id': 'fork-e2e',
            'target_message_id': 'm-a2',
            'target_turn_id': 'turn-2',
          },
        }),
      );
      final accepted = await _waitForEvent(
        frames,
        CanonicalEventTypes.sessionForkResult,
      );
      expect(accepted['payload']['outcome'], equals('accepted'));
      expect(accepted['payload']['fork_sequence'], 1);
      final childId =
          (accepted['payload']['child'] as Map)['session_id'] as String;

      final parent = sessions.getSession(session.sessionId)!;
      final child = sessions.getSession(childId)!;
      expect(parent.messages, hasLength(6));
      expect(child.messages, hasLength(4));
      expect(child.title, '(1) Refactor auth');
      expect(child.messages.last.content, 'second final');
      expect(
        child.messages.map((message) => message.content),
        isNot(contains('three')),
      );

      sessions.saveSessionHistory(session.sessionId, [
        ...sessions.getMessages(session.sessionId),
        Message(
          role: MessageRole.user,
          content: 'parent only',
          metadata: const {'request_id': 'req-parent'},
        ),
      ]);
      sessions.saveSessionHistory(childId, [
        ...child.messages,
        Message(
          role: MessageRole.user,
          content: 'child only',
          metadata: const {'request_id': 'req-child'},
        ),
      ]);
      expect(
        sessions
            .getMessages(session.sessionId)
            .map((message) => message.content),
        containsAll(['three', 'parent only']),
      );
      expect(
        sessions
            .getMessages(session.sessionId)
            .map((message) => message.content),
        isNot(contains('child only')),
      );
      expect(
        sessions.getMessages(childId).map((message) => message.content),
        contains('child only'),
      );
      expect(
        sessions.getMessages(childId).map((message) => message.content),
        isNot(contains('parent only')),
      );
      expect(
        sessions.getMessages(childId).map((message) => message.content),
        isNot(contains('three')),
      );

      await frames.cancel();
      await socket.close();
      await runtime.platform.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 100));
    },
  );

  test('local family broadcast preserves session device_id', () async {
    final port = await _reserveFreePort();
    await getIt.reset();
    tempSanadHome = Directory.systemTemp.createTempSync(
      'sanad-agent-gateway-test',
    );
    setSanadHomeOverride(tempSanadHome.path);
    getIt.registerSingleton<AuthManager>(MockAuthManager());
    getIt.registerSingleton<Config>(TestLocalConfig(port));
    getIt.registerSingleton<SessionManager>(SessionManager());
    getIt.registerSingleton<LLMAdapter>(FakeLlmAdapter());
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
    getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());

    final platform = LocalDaemonServerPlatform();
    await platform.initialize();

    final socket = await connectAuthenticatedLocalGateway(
      port: port,
      sanadHomePath: tempSanadHome.path,
    );
    final frames = StreamIterator(socket);
    await frames.moveNext();
    expect(
      (jsonDecode(frames.current as String) as Map<String, dynamic>)['type'],
      equals('register_success'),
    );

    // The client identifies the logical device expected by its EventRouter
    // even before it has bound this cloud-origin session locally.
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'device_id': 'local-agent',
        'command': 'get_sessions',
        'payload': {'request_id': 'req-sessions'},
      }),
    );
    await frames.moveNext();
    expect(
      (jsonDecode(frames.current as String) as Map<String, dynamic>)['type'],
      equals('device_event'),
    );

    // Bind the conversation to the logical local alias, then issue an
    // unrelated hardware-scoped command on the same socket. The latter must
    // not overwrite the conversation's routing identity.
    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'device_id': 'local-agent',
        'command': 'get_session_history',
        'payload': {
          'session_id': 'cloud-origin-session',
          'request_id': 'req-history',
        },
      }),
    );
    await frames.moveNext();
    expect(
      (jsonDecode(frames.current as String) as Map<String, dynamic>)['type'],
      equals('device_event'),
    );

    socket.add(
      jsonEncode({
        'type': 'execute_command',
        'device_id': 'hardware-uuid',
        'command': 'get_sessions',
        'payload': {'request_id': 'req-hardware-sessions'},
      }),
    );
    await frames.moveNext();
    expect(
      (jsonDecode(frames.current as String) as Map<String, dynamic>)['type'],
      equals('device_event'),
    );

    await platform.sendResponse(
      GatewayResponse(
        sessionId: 'cloud-origin-session',
        platformId: 'sanad_gateway',
        message: Message(role: MessageRole.assistant, content: 'cloud answer'),
        eventId: 'evt-cloud-origin',
        delivery: const DeliveryPolicy.platformFamily(
          PlatformFamily.sanadClient,
        ),
      ),
    );

    await frames.moveNext();
    final eventFrame =
        jsonDecode(frames.current as String) as Map<String, dynamic>;
    expect(eventFrame['type'], equals('device_event'));
    expect(eventFrame['event_id'], equals('evt-cloud-origin'));
    expect(eventFrame['device_id'], equals('local-agent'));

    await frames.cancel();
    await socket.close();
    await platform.dispose();
  });

  test(
    'LocalDaemonServerPlatform fails clearly when the port is already in use',
    () async {
      final port = await _reserveFreePort();
      final blocker = await ServerSocket.bind(
        InternetAddress.loopbackIPv4,
        port,
      );

      await getIt.reset();
      tempSanadHome = Directory.systemTemp.createTempSync(
        'sanad-agent-gateway-test',
      );
      setSanadHomeOverride(tempSanadHome.path);
      getIt.registerSingleton<AuthManager>(MockAuthManager());
      getIt.registerSingleton<Config>(TestLocalConfig(port));
      getIt.registerSingleton<SessionManager>(SessionManager());
      getIt.registerSingleton<LLMAdapter>(FakeLlmAdapter());
      getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
      getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());

      final platform = LocalDaemonServerPlatform();

      await expectLater(platform.initialize(), throwsA(isA<SocketException>()));

      await blocker.close();
    },
  );

  test(
    'Local daemon bridge round-trips permission and platform tool responses',
    () async {
      final port = await _reserveFreePort();
      await getIt.reset();
      tempSanadHome = Directory.systemTemp.createTempSync(
        'sanad-agent-gateway-test',
      );
      setSanadHomeOverride(tempSanadHome.path);
      getIt.registerSingleton<AuthManager>(MockAuthManager());
      getIt.registerSingleton<Config>(TestLocalConfig(port));
      getIt.registerSingleton<SessionManager>(SessionManager());
      getIt.registerSingleton<LLMAdapter>(FakeLlmAdapter());
      getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
      getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());

      final platform = LocalDaemonServerPlatform();
      await platform.initialize();

      final socket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: tempSanadHome.path,
      );
      final frames = StreamIterator(socket);
      await frames.moveNext();
      jsonDecode(frames.current as String);

      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'get_session_history',
          'payload': {
            'session_id': 'session-permissions',
            'request_id': 'req-history',
          },
        }),
      );

      await frames.moveNext();
      jsonDecode(frames.current as String);

      final bridge = getIt<PlatformRuntimeBridge>();
      final permissionFuture = bridge.requestToolPermission(
        sessionId: 'session-permissions',
        payload: {'tool_name': 'shell_execute', 'permission_class': 'shell'},
      );

      await frames.moveNext();
      final permissionFrame =
          jsonDecode(frames.current as String) as Map<String, dynamic>;
      expect(
        permissionFrame['event'],
        equals(CanonicalEventTypes.toolPermissionRequest),
      );
      final permissionRequestId =
          permissionFrame['payload']['request_id'] as String;

      socket.add(
        jsonEncode({
          'type': 'protocol_event',
          'event': {
            'type': CanonicalEventTypes.toolPermissionResponse,
            'payload': {
              'request_id': permissionRequestId,
              'allowed': true,
              'scope': 'session',
            },
            'session_id': 'session-permissions',
          },
        }),
      );

      final permissionDecision = await permissionFuture;
      expect(permissionDecision['allowed'], isTrue);

      final toolFuture = bridge.executePlatformTool(
        sessionId: 'session-permissions',
        payload: {
          'tool_name': 'system_screenshot',
          'tool_input': {'monitor_number': 1},
        },
      );

      final toolFrame = await _waitForEvent(
        frames,
        CanonicalEventTypes.platformToolCall,
      );
      final toolRequestId = toolFrame['payload']['request_id'] as String;

      socket.add(
        jsonEncode({
          'type': 'protocol_event',
          'event': {
            'type': CanonicalEventTypes.platformToolResult,
            'payload': {
              'request_id': toolRequestId,
              'output': '{"ok":true}',
              'is_error': false,
            },
            'session_id': 'session-permissions',
          },
        }),
      );

      final toolResult = await toolFuture;
      expect(toolResult, equals('{"ok":true}'));

      await frames.cancel();
      await socket.close();
      await platform.dispose();
    },
  );

  test(
    'Local daemon resumes pending permission-gated tool call after runtime restart',
    () async {
      final port = await _reserveFreePort();
      final workspaceDir = Directory('${tempSanadHome.path}/workspace')
        ..createSync(recursive: true);
      final sessionId = 'session-resume-e2e';
      final adapter = ResumeScenarioLlmAdapter();

      final firstRuntime = await _startResumeRuntime(
        port: port,
        workspacePath: workspaceDir.path,
        adapter: adapter,
      );

      final firstSocket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: tempSanadHome.path,
      );
      final firstFrames = StreamIterator<dynamic>(firstSocket);
      await _nextFrame(firstFrames);

      firstSocket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'think',
          'device_id': 'local-device-1',
          'payload': {
            'session_id': sessionId,
            'request_id': 'req-think-1',
            'message': 'Run the terminal check.',
            'workspace_id': workspaceDir.path,
            'model': 'ollama/gemma:2b',
          },
        }),
      );

      await Future<void>.delayed(const Duration(milliseconds: 200));
      expect(getIt<SessionManager>().getSession(sessionId), isNotNull);
      final sessionWithAssistant = await _waitForValue(() async {
        final session = getIt<SessionManager>().getSession(sessionId);
        if (session == null || session.messages.length < 2) {
          return null;
        }
        return session;
      });
      expect(
        sessionWithAssistant.messages[1].toolCalls?.first.name,
        equals('shell_execute'),
      );
      expect(
        sessionWithAssistant.messages[1].metadata?['context_usage'],
        containsPair('input_tokens', 12),
      );
      expect(
        sessionWithAssistant.messages[1].metadata?['context_usage'],
        containsPair('cached_tokens', 8),
      );

      final pendingCheckpoint = await _waitForValue(() async {
        final checkpoints = getIt<SessionManager>().listSuspendedCheckpoints(
          status: 'awaiting_permission',
        );
        return checkpoints.isEmpty ? null : checkpoints.first;
      });
      expect(pendingCheckpoint.status, equals('awaiting_permission'));
      final permissionRequestId = pendingCheckpoint.requestId;

      await firstFrames.cancel();
      await firstSocket.close();
      await firstRuntime.platform.dispose();

      // ignore: invalid_use_of_visible_for_testing_member
      SessionManager.resetForTesting();

      final secondRuntime = await _startResumeRuntime(
        port: port,
        workspacePath: workspaceDir.path,
        adapter: adapter,
      );

      final secondSocket = await connectAuthenticatedLocalGateway(
        port: port,
        sanadHomePath: tempSanadHome.path,
      );
      final secondFrames = StreamIterator<dynamic>(secondSocket);
      await _nextFrame(secondFrames);

      secondSocket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'get_session_history',
          'device_id': 'local-device-1',
          'payload': {
            'session_id': sessionId,
            'request_id': 'req-history-after-restart',
          },
        }),
      );

      final historyFrame = await _waitForEvent(
        secondFrames,
        CanonicalEventTypes.sessionHistory,
      );
      expect(historyFrame['payload']['session_id'], equals(sessionId));
      expect(
        historyFrame['payload']['context_usage'],
        containsPair('input_tokens', 12),
      );
      expect(
        historyFrame['payload']['context_usage'],
        containsPair('cached_tokens', 8),
      );

      secondSocket.add(
        jsonEncode({
          'type': 'protocol_event',
          'event': {
            'type': CanonicalEventTypes.toolPermissionResponse,
            'payload': {
              'request_id': permissionRequestId,
              'allowed': true,
              'scope': 'workspace',
            },
            'session_id': sessionId,
          },
        }),
      );

      final toolResultFrame = await _waitForEvent(secondFrames, 'tool_result');
      expect(toolResultFrame['payload']['tool'], equals('shell_execute'));
      expect(
        (toolResultFrame['payload']['output'] as String),
        contains('Terminal is working'),
      );

      final finalAnswerFrame = await _waitForEvent(
        secondFrames,
        CanonicalEventTypes.finalAnswer,
      );
      expect(
        finalAnswerFrame['payload']['content'],
        equals('Terminal command completed successfully.'),
      );
      expect(
        finalAnswerFrame['payload']['context_usage'],
        containsPair('input_tokens', 16),
      );
      expect(
        finalAnswerFrame['payload']['context_usage'],
        containsPair('cached_tokens', 10),
      );

      final resumedCheckpoint = getIt<SessionManager>()
          .getSuspendedCheckpointByRequestId(permissionRequestId);
      expect(resumedCheckpoint, isNull);

      await secondFrames.cancel();
      await secondSocket.close();
      await secondRuntime.platform.dispose();
    },
  );
}
