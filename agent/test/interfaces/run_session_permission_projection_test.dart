/// A `sanad run` session must keep its own targeting and permissions.
///
/// Two defects are covered here:
///
/// 1. The `session_created` projection of a first turn that only targets an
///    execution root carried no workspace and no permission mode, so the Client
///    could not offer the session's own permissions until an authoritative
///    `sessions_list` refresh replaced its copy.
/// 2. A later turn that did not restate its authority (any Client message) reset
///    the durable `allow_all_tools` to false and thereby stripped the run's
///    terminal and workspace permissions.
library;

import 'dart:async';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/runtime/llm_route_snapshot.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/title_service.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart'
    show ModelOption;
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/session_metadata_resolver.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/session_title_refresher.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/session_payload_builder.dart';
import 'package:test/test.dart';

import '../support/memory_agent_secret_store.dart';
import '../support/memory_workspace_policy_store.dart';

class _RecordingAdapter implements LLMAdapter {
  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async => AgentResponse(
    message: Message(role: MessageRole.assistant, content: 'ok'),
  );

  @override
  Stream<AgentResponse> generateStream(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    yield await generateResponse(history, options: options);
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];
}

class _NoopMcpRuntimeManager extends McpRuntimeManager {
  _NoopMcpRuntimeManager()
    : super(settingsStore: const SanadSettingsStore(homeDirectoryPath: '/tmp'));

  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async =>
      const [];
}

class _CountingBridge extends PlatformRuntimeBridge {
  int requestCount = 0;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    requestCount++;
    return const {'allowed': false, 'scope': 'once'};
  }
}

class _NoopCheckpoints extends SuspendedCheckpointStore {
  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async {}

  @override
  Future<SuspendedCheckpoint?> getByRequestId(String requestId) async =>
      null;

  @override
  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {}
}

void main() {
  AgentTurnRequest clientShapedTurn(String sessionId, String requestId) =>
      AgentTurnRequest(
        sessionId: sessionId,
        message: 'a question from the Client',
        requestId: requestId,
        metadata: const {CommandAuthority.payloadKey: 'owner'},
      );

  group('turn targeting metadata', () {
    test('an execution-root-only turn seeds its own workspace identity', () {
      final metadata = buildTurnTargetingMetadata(
        AgentTurnRequest(
          sessionId: 's1',
          message: 'hi',
          metadata: const {
            'execution_root': ' /work/root ',
            'allow_all_tools': true,
          },
        ),
        hasRegisteredWorkspace: false,
      );

      expect(metadata['execution_root'], '/work/root');
      expect(metadata['workspace_id'], 'exec_root:/work/root');
      expect(metadata['allow_all_tools'], isTrue);
    });

    test('a registered workspace keeps ownership of the session', () {
      final metadata = buildTurnTargetingMetadata(
        AgentTurnRequest(
          sessionId: 's1',
          message: 'hi',
          metadata: const {'execution_root': '/work/root'},
        ),
        hasRegisteredWorkspace: true,
      );

      expect(metadata['execution_root'], '/work/root');
      expect(metadata.containsKey('workspace_id'), isFalse);
      expect(metadata.containsKey('allow_all_tools'), isFalse);
    });

    test('a turn that states no targeting contributes nothing', () {
      final metadata = buildTurnTargetingMetadata(
        AgentTurnRequest(sessionId: 's1', message: 'hi'),
        hasRegisteredWorkspace: false,
      );

      expect(metadata, isEmpty);
    });
  });

  group('durable turn metadata', () {
    late Directory tempDir;
    late Directory executionRoot;
    late SessionManager sessions;
    late LocalRuntimeOrchestrator orchestrator;

    setUp(() async {
      tempDir = Directory(
        (await Directory.systemTemp.createTemp('run-session-meta-')).path,
      );
      executionRoot =
          Directory(p.join(tempDir.path, 'isolated-worktree'))..createSync();
      tempDir = Directory(tempDir.resolveSymbolicLinksSync());
      executionRoot = Directory(p.join(tempDir.path, 'isolated-worktree'));
      setSanadHomeOverride(tempDir.path);
      await getIt.reset();
      SessionManager.resetForTesting();
      getIt.allowReassignment = true;
      sessions = SessionManager();
      getIt.registerSingleton<SessionManager>(sessions);
      final workspace = LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: tempDir.path,
      );
      getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspace);
      final catalog = LocalRuntimeCatalog(
        workspaceRuntimeService: workspace,
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      );
      orchestrator = LocalRuntimeOrchestrator(workspace, catalog);
    });

    tearDown(() async {
      await getIt.reset();
      SessionManager.resetForTesting();
      setSanadHomeOverride(null);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<void> seedRunSession(String sessionId) async {
      final now = DateTime.now();
      sessions.db.saveSession(
        SessionState(
          sessionId: sessionId,
          model: 'run-model',
          workspaceId: 'exec_root:${executionRoot.path}',
          createdAt: now,
          updatedAt: now,
        ),
      );
      sessions.saveSessionMetadata(sessionId, {
        'execution_root': executionRoot.path,
        'workspace_id': 'exec_root:${executionRoot.path}',
        'allow_all_tools': true,
        'permission_mode': 'full_access',
      });
    }

    test('a Client turn without authority keys inherits the run permissions',
        () async {
      const sessionId = 'oneshot-inherit';
      await seedRunSession(sessionId);

      final metadata = await orchestrator.buildSessionMetadata(
        clientShapedTurn(sessionId, 'req-client'),
      );

      expect(metadata['allow_all_tools'], isTrue);
      expect(metadata['permission_mode'], 'full_access');
      expect(metadata['execution_root'], executionRoot.path);
    });

    test('a Client turn that states a mode replaces the run permissions',
        () async {
      const sessionId = 'oneshot-downgrade';
      await seedRunSession(sessionId);

      final metadata = await orchestrator.buildSessionMetadata(
        AgentTurnRequest(
          sessionId: sessionId,
          message: 'downgrade me',
          requestId: 'req-downgrade',
          metadata: const {
            CommandAuthority.payloadKey: 'owner',
            'allow_all_tools': false,
          },
        ),
      );

      expect(metadata['allow_all_tools'], isFalse);
      expect(metadata['permission_mode'], 'default_mode');
    });

    test('inherited authority still executes terminal tools without a prompt',
        () async {
      const sessionId = 'oneshot-executes';
      await seedRunSession(sessionId);
      final metadata = await orchestrator.buildSessionMetadata(
        clientShapedTurn(sessionId, 'req-exec'),
      );

      final policyStore = MemoryWorkspacePolicyStore()
        ..bind(executionRoot.path, executionRoot.path);
      final bridge = _CountingBridge();
      final manager = PermissionManager(
        policyStore: policyStore,
        platformRuntimeBridge: bridge,
        checkpointStore: _NoopCheckpoints(),
      );

      await manager.ensureAuthorized(
        tool: const LocalToolSpec(
          name: 'shell_execute',
          displayName: 'Shell Execute',
          description: 'Run a shell command through the platform.',
          inputSchema: {
            'type': 'object',
            'properties': {
              'command': {'type': 'string'},
            },
            'required': ['command'],
          },
          source: {'type': 'platform', 'owner': 'platform', 'id': 'local-ui'},
          category: 'system',
          workspaceRequired: true,
          approval: {
            'mode': 'default',
            'sensitive': true,
            'scope': 'workspace',
            'permission_class': 'shell',
          },
          execution: {'target': 'platform'},
        ),
        arguments: const {'command': 'git status'},
        context: ToolContext(
          sessionId: sessionId,
          toolCallId: 'call-1',
          metadata: metadata,
        ),
      );

      expect(
        bridge.requestCount,
        0,
        reason: 'the run session keeps its permissions across a Client turn',
      );
    });
  });

  group('session created projection', () {
    const providerId = 'inst-run-projection';
    const modelId = 'run-model';

    late Directory tempDir;
    late Directory executionRoot;
    late SessionManager sessions;
    late SessionRunOrchestrator orchestrator;
    late List<GatewayResponse> responses;
    late StreamSubscription<GatewayResponse> responseSub;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('run-session-created-');
      executionRoot = Directory(p.join(tempDir.path, 'worktree'))
        ..createSync();
      tempDir = Directory(tempDir.resolveSymbolicLinksSync());
      executionRoot = Directory(p.join(tempDir.path, 'worktree'));
      setSanadHomeOverride(tempDir.path);
      await getIt.reset();
      SessionManager.resetForTesting();
      getIt.allowReassignment = true;

      final state = AgentStateDatabase.inMemory();
      getIt.registerSingleton<AgentStateDatabase>(state);
      final runtime = PersistedRuntimeStateRepository.fromState(state);
      getIt.registerSingleton<PersistedRuntimeStateRepository>(runtime);
      final providers = ProviderInstanceRepository.fromDatabase(state.db);
      getIt.registerSingleton<ProviderInstanceRepository>(providers);
      providers.createInstance(
        ProviderInstance(
          id: providerId,
          templateId: kCustomProviderTemplateId,
          displayName: 'Run provider',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: modelId,
          status: InstanceStatus.ready,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      sessions = SessionManager();
      getIt.registerSingleton<SessionManager>(sessions);
      getIt.registerSingleton<Config>(Config());
      getIt.registerSingleton<RuntimeRecoveryService>(
        RuntimeRecoveryService(providers, ProviderRateLimiter())
          ..attachPersistedState(runtime),
      );
      final workspace = LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: tempDir.path,
      );
      getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspace);
      final catalog = LocalRuntimeCatalog(
        workspaceRuntimeService: workspace,
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      );
      getIt.registerSingleton<LocalRuntimeCatalog>(catalog);
      getIt.registerSingleton<LocalRuntimeOrchestrator>(
        LocalRuntimeOrchestrator(workspace, catalog),
      );
      final adapter = _RecordingAdapter();
      getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
        (sessionId, _) => AgentRunner(
          adapter,
          ToolsRegistry(),
          sessions,
          existingSessionId: sessionId,
        ),
      );
      orchestrator = SessionRunOrchestrator();
      getIt.registerSingleton<SessionRunOrchestrator>(orchestrator);
      responses = [];
      responseSub = orchestrator.responses.listen(responses.add);
    });

    tearDown(() async {
      await responseSub.cancel();
      await getIt.reset();
      SessionManager.resetForTesting();
      setSanadHomeOverride(null);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Future<GatewayResponse> terminalFor(String runId) async {
      for (var i = 0; i < 400; i++) {
        final terminal = responses.where(
          (r) =>
              r.isComplete &&
              !r.isSessionCreated &&
              r.message.role == MessageRole.assistant &&
              r.runId == runId,
        );
        if (terminal.isNotEmpty) return terminal.last;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }
      fail(
        'no terminal response for $runId: '
        '${responses.map((r) => '${r.runId}:${r.isSessionCreated}:${r.message.content}').join('|')}',
      );
    }

    test('a run first turn creates the session with its full projection',
        () async {
      const sessionId = 'oneshot-created';
      await orchestrator.handleEvent(
        GatewayEvent(
          sessionId: sessionId,
          platformId: 'client',
          message: Message(role: MessageRole.user, content: 'start the work'),
          metadata: {
            'payload': {'request_id': 'req-run'},
          },
          runId: 'req-run',
          turnRequest: AgentTurnRequest(
            sessionId: sessionId,
            message: 'start the work',
            providerInstanceId: providerId,
            model: modelId,
            requestId: 'req-run',
            metadata: {
              CommandAuthority.payloadKey: CommandAuthority.owner.value,
              'execution_root': executionRoot.path,
              'allow_all_tools': true,
            },
          ),
        ),
      );
      await terminalFor('req-run');

      final created = responses.singleWhere((r) => r.isSessionCreated);
      final payload = created.sessionPayload;
      expect(payload, isNotNull);
      expect(payload!['workspace_id'], 'exec_root:${executionRoot.path}');
      expect(payload['workspace_path'], executionRoot.path);
      expect(payload['workspace_name'], 'worktree');
      expect(payload['permission_mode'], 'full_access');
      final metadata = Map<String, dynamic>.from(payload['metadata'] as Map);
      expect(metadata['execution_root'], executionRoot.path);
      expect(metadata['allow_all_tools'], isTrue);
      expect(metadata['permission_mode'], 'full_access');

      // The durable row agrees with the projection instead of staying empty.
      final row = sessions.getSession(sessionId);
      expect(row?.workspaceId, 'exec_root:${executionRoot.path}');
      expect(
        sessions.getSessionMetadata(sessionId)?['execution_root'],
        executionRoot.path,
      );
    });

    test('a Client-shaped first turn keeps the session without a run override',
        () async {
      const sessionId = 'client-created';
      await orchestrator.handleEvent(
        GatewayEvent(
          sessionId: sessionId,
          platformId: 'client',
          message: Message(role: MessageRole.user, content: 'hello'),
          metadata: {
            'payload': {'request_id': 'req-client'},
          },
          runId: 'req-client',
          turnRequest: AgentTurnRequest(
            sessionId: sessionId,
            message: 'hello',
            providerInstanceId: providerId,
            model: modelId,
            requestId: 'req-client',
            metadata: const {
              CommandAuthority.payloadKey: 'owner',
            },
          ),
        ),
      );
      await terminalFor('req-client');

      final payload = responses
          .singleWhere((r) => r.isSessionCreated)
          .sessionPayload!;
      expect(payload.containsKey('workspace_id'), isFalse);
      expect(payload['metadata'], isNull);
      expect(sessions.getSession(sessionId)?.workspaceId, isNull);
    });
  });

  group('session permission mode command', () {
    late Directory tempDir;
    late SessionManager sessions;
    late SessionQueryHandler handler;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('session-perm-mode-');
      setSanadHomeOverride(tempDir.path);
      await getIt.reset();
      SessionManager.resetForTesting();
      getIt.allowReassignment = true;
      sessions = SessionManager();
      getIt.registerSingleton<SessionManager>(sessions);
      getIt.registerSingleton<AuthManager>(
        AuthManager(secretStore: MemoryAgentSecretStore()),
      );
      handler = SessionQueryHandler(
        sessionManager: sessions,
        bridge: SanadProtocolBridge(),
      );
      final now = DateTime.now();
      sessions.db.saveSession(
        SessionState(
          sessionId: 'run-session',
          model: 'run-model',
          workspaceId: 'exec_root:/work/root',
          createdAt: now,
          updatedAt: now,
        ),
      );
      sessions.saveSessionMetadata('run-session', {
        'execution_root': '/work/root',
        'workspace_id': 'exec_root:/work/root',
        'workspace_name': 'root',
        'workspace_path': '/work/root',
        'allow_all_tools': true,
        'permission_mode': 'full_access',
      });
    });

    tearDown(() async {
      await getIt.reset();
      SessionManager.resetForTesting();
      setSanadHomeOverride(null);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    CanonicalEvent command(String mode) => CanonicalEvent(
      type: CanonicalEventTypes.setSessionPermissionMode,
      sessionId: 'run-session',
      payload: {
        'request_id': 'req-perm',
        'session_id': 'run-session',
        'permission_mode': mode,
        CommandAuthority.payloadKey: CommandAuthority.owner.value,
      },
    );

    test('a downgrade clears the run override and republishes the session', () {
      final envelope = handler.buildSetSessionPermissionModeEnvelope(
        command('default'),
      );

      expect(envelope, isNotNull);
      final event = envelope!['event'] ?? envelope['type'];
      expect(event, CanonicalEventTypes.sessionUpdated);
      final payload = Map<String, dynamic>.from(envelope['payload'] as Map);
      final projectedMetadata = Map<String, dynamic>.from(
        payload['metadata'] as Map,
      );
      expect(projectedMetadata['allow_all_tools'], isFalse);
      expect(payload['permission_mode'], 'default_mode');
      expect(payload['workspace_id'], 'exec_root:/work/root');

      final stored = sessions.getSessionMetadata('run-session')!;
      expect(stored['allow_all_tools'], isFalse);
      expect(stored['permission_mode'], 'default_mode');
      expect(
        stored['execution_root'],
        '/work/root',
        reason: 'a permission change never drops the session targeting',
      );    });

    test('full access is restored from the same command', () {
      sessions.saveSessionMetadata('run-session', {
        'execution_root': '/work/root',
        'allow_all_tools': false,
      });

      handler.buildSetSessionPermissionModeEnvelope(command('full_access'));

      final stored = sessions.getSessionMetadata('run-session')!;
      expect(stored['allow_all_tools'], isTrue);
      expect(stored['permission_mode'], 'full_access');
    });

    test('an unverified transport may not grant full access', () {
      sessions.saveSessionMetadata('run-session', const {
        'execution_root': '/work/root',
        'allow_all_tools': false,
      });

      final envelope = handler.buildSetSessionPermissionModeEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.setSessionPermissionMode,
          sessionId: 'run-session',
          payload: const {
            'request_id': 'req-perm',
            'session_id': 'run-session',
            'permission_mode': 'full_access',
          },
        ),
      );

      expect(envelope, isNotNull);
      final payload = Map<String, dynamic>.from(envelope!['payload'] as Map);
      expect(payload['code'], 'permission_denied');
      expect(sessions.getSessionMetadata('run-session')!['allow_all_tools'],
          isFalse);
    });
  });

  /// A stale session copy is worse than a missing one: the Client shows a mode
  /// the Agent does not enforce, so the very choice the owner makes looks like a
  /// no-op. Every `session_updated` therefore states the durable permission pair,
  /// not just the field the command changed.
  group('session update carries the durable permission state', () {
    late Directory tempDir;
    late SessionManager sessions;
    late SessionQueryHandler handler;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('session-perm-update-');
      setSanadHomeOverride(tempDir.path);
      await getIt.reset();
      SessionManager.resetForTesting();
      getIt.allowReassignment = true;
      sessions = SessionManager();
      getIt.registerSingleton<SessionManager>(sessions);
      getIt.registerSingleton<AuthManager>(
        AuthManager(secretStore: MemoryAgentSecretStore()),
      );
      handler = SessionQueryHandler(
        sessionManager: sessions,
        bridge: SanadProtocolBridge(),
      );
      final now = DateTime.now();
      sessions.db.saveSession(
        SessionState(
          sessionId: 'run-session',
          model: 'run-model',
          title: 'Run session',
          titleStatus: SessionTitleStatus.pending,
          workspaceId: 'exec_root:/work/root',
          createdAt: now,
          updatedAt: now,
        ),
      );
      sessions.saveSessionMetadata('run-session', {
        'execution_root': '/work/root',
        'workspace_id': 'exec_root:/work/root',
        'allow_all_tools': true,
        'permission_mode': 'full_access',
      });
    });

    tearDown(() async {
      await getIt.reset();
      SessionManager.resetForTesting();
      setSanadHomeOverride(null);
      if (tempDir.existsSync()) {
        tempDir.deleteSync(recursive: true);
      }
    });

    Map<String, dynamic> payloadOf(Map<String, dynamic> envelope) =>
        Map<String, dynamic>.from(envelope['payload'] as Map);

    void downgrade() {
      handler.buildSetSessionPermissionModeEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.setSessionPermissionMode,
          sessionId: 'run-session',
          payload: {
            'request_id': 'req-downgrade',
            'session_id': 'run-session',
            'permission_mode': 'default',
            CommandAuthority.payloadKey: CommandAuthority.owner.value,
          },
        ),
      );
    }

    test('a title refresh after a downgrade republishes default mode', () {
      downgrade();

      final payload = payloadOf(
        handler.buildUpdateSessionTitleEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.updateSessionTitle,
            sessionId: 'run-session',
            payload: const {
              'request_id': 'req-title',
              'session_id': 'run-session',
              'title': 'Renamed run session',
            },
          ),
        )!,
      );

      expect(payload['title'], 'Renamed run session');
      final metadata = Map<String, dynamic>.from(payload['metadata'] as Map);
      expect(metadata['allow_all_tools'], isFalse);
      expect(payload['permission_mode'], 'default_mode');
      expect(payload['workspace_id'], 'exec_root:/work/root');
    });

    test('a route preference change after a downgrade keeps default mode', () {
      downgrade();

      final payload = payloadOf(
        handler.buildSessionPreferencesEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.updateSessionPreferences,
            sessionId: 'run-session',
            payload: const {
              'request_id': 'req-route',
              'session_id': 'run-session',
              'model': 'next-model',
            },
          ),
        )!,
      );

      expect(payload['model'], 'next-model');
      final metadata = Map<String, dynamic>.from(payload['metadata'] as Map);
      expect(metadata['allow_all_tools'], isFalse);
      expect(payload['permission_mode'], 'default_mode');
    });

    test('a projection cannot describe an older authority than the stored one',
        () {
      downgrade();
      final stored = sessions.getSessionMetadata('run-session')!;

      final payload = buildSessionPayload(
        session: sessions.getSession('run-session')!,
        sessionMetadata: stored,
        // A caller-held snapshot from before the downgrade must never win.
        metadataOverrides: const {
          'allow_all_tools': true,
          'permission_mode': 'full_access',
        },
      );

      final metadata = Map<String, dynamic>.from(payload['metadata'] as Map);
      expect(metadata['allow_all_tools'], isFalse);
      expect(metadata['permission_mode'], 'default_mode');
      expect(payload['permission_mode'], 'default_mode');
    });

    test('the title refresher projects the durable mode after a downgrade', () async {
      downgrade();

      final emitted = <GatewayResponse>[];
      final refresher = SessionTitleRefresher(emitResponse: emitted.add);
      getIt.registerSingleton<TitleService>(_FixedTitleService('Fresh title'));

      await refresher.generateAndEmitIntelligentTitle(
        sessionId: 'run-session',
        platformId: 'local',
        expectedTitle: 'Run session',
        userMessage: 'list the files',
        assistantResponse: 'done',
        route: null,
      );

      expect(emitted, hasLength(1));
      final payload = emitted.single.sessionPayload!;
      final metadata = Map<String, dynamic>.from(payload['metadata'] as Map);
      expect(metadata['allow_all_tools'], isFalse);
      expect(payload['permission_mode'], 'default_mode');
    });
  });
}

/// A title service that returns a fixed title, so a refresh completes without
/// a provider call.
class _FixedTitleService implements TitleService {
  _FixedTitleService(this.title);

  final String title;

  @override
  Future<String> generateTitle({
    required String sessionId,
    required String userMessage,
    required String assistantResponse,
    String? modelOverride,
    LLMRouteSnapshot? route,
  }) async => title;

  @override
  Future<int> recoverPendingTitles() async => 0;
}
