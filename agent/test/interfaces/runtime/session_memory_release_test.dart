/// A finished turn must release its session runtime state, and a streamed
/// answer must not be re-copied per delta.
///
/// Drives the real `SessionRunOrchestrator`, `SessionTurnExecutor`,
/// `AgentRunner`, `SessionManager` and the SQLite-backed durable execution state
/// with a recording adapter. The assertions are on the daemon's own projections,
/// not on a mocked collaborator: after many finished sessions nothing keeps a
/// partial answer, the history cache stays inside its count and retained-text
/// bounds, and the committed answer is exactly the concatenation of the deltas
/// the provider streamed.
library;

import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/core/config.dart';
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
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

class _RecordingAdapter implements LLMAdapter {
  int calls = 0;

  /// Total characters the adapter streams for one turn.
  int answerChars = 0;

  /// Characters per streamed delta; the whole answer is one delta when zero.
  int deltaChars = 0;

  /// Blocks the stream after [gateAfterDeltas] deltas until released.
  Completer<void>? gate;
  int gateAfterDeltas = 0;
  int deltasEmitted = 0;

  String get expectedAnswer => 'A' * answerChars;

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async => AgentResponse(
    message: Message(role: MessageRole.assistant, content: expectedAnswer),
  );

  @override
  Stream<AgentResponse> generateStream(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    calls++;
    deltasEmitted = 0;
    final chunkChars = deltaChars <= 0 ? answerChars : deltaChars;
    final chunk = 'A' * chunkChars;
    var remaining = answerChars;
    while (remaining > 0) {
      final size = remaining < chunkChars ? remaining : chunkChars;
      remaining -= size;
      deltasEmitted++;
      yield AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          content: size == chunkChars ? chunk : 'A' * size,
        ),
      );
      if (gate != null && deltasEmitted == gateAfterDeltas) {
        await gate!.future;
      }
    }
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 1 << 20;

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

void main() {
  const providerId = 'inst-memory-release';
  const modelId = 'memory-release-model';

  late Directory tempDir;
  late AgentStateDatabase state;
  late PersistedRuntimeStateRepository runtime;
  late SessionManager sessions;
  late _RecordingAdapter adapter;
  late SessionRunOrchestrator orchestrator;
  late StreamSubscription<GatewayResponse> responseSub;

  setUp(() async {
    tempDir = Directory.systemTemp.createTempSync('memory_release_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);
    await getIt.reset();
    SessionManager.resetForTesting();
    getIt.allowReassignment = true;

    state = AgentStateDatabase.atPath(tempDir.path);
    getIt.registerSingleton<AgentStateDatabase>(state);
    runtime = PersistedRuntimeStateRepository.fromState(state);
    getIt.registerSingleton<PersistedRuntimeStateRepository>(runtime);
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    repo.createInstance(
      ProviderInstance(
        id: providerId,
        templateId: kCustomProviderTemplateId,
        displayName: 'Memory release provider',
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
      RuntimeRecoveryService(repo, ProviderRateLimiter())
        ..attachPersistedState(runtime),
    );

    final workspace = LocalWorkspaceRuntimeService(
      sanadHomePath: tempDir.path,
      currentWorkingDirectory: tempDir.path,
    );
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspace);
    getIt.registerSingleton<LocalRuntimeCatalog>(
      LocalRuntimeCatalog(
        workspaceRuntimeService: workspace,
        mcpRuntimeManager: _NoopMcpRuntimeManager(),
      ),
    );
    getIt.registerSingleton<LocalRuntimeOrchestrator>(
      LocalRuntimeOrchestrator(workspace, getIt<LocalRuntimeCatalog>()),
    );

    adapter = _RecordingAdapter();
    getIt.registerFactoryParam<AgentRunner, String?, dynamic>(
      (runnerSessionId, _) => AgentRunner(
        adapter,
        ToolsRegistry(),
        sessions,
        existingSessionId: runnerSessionId,
      ),
    );
    orchestrator = SessionRunOrchestrator();
    getIt.registerSingleton<SessionRunOrchestrator>(orchestrator);
    responseSub = orchestrator.responses.listen((_) {});
  });

  tearDown(() async {
    await responseSub.cancel();
    await getIt.reset();
    SessionManager.resetForTesting();
    state.dispose();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  Future<void> waitForIdle(String sessionId) async {
    final deadline = DateTime.now().add(const Duration(seconds: 20));
    while (orchestrator.isSessionBusy(sessionId) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    expect(
      orchestrator.isSessionBusy(sessionId),
      isFalse,
      reason: 'the turn must finish so its runtime state can be released',
    );
  }

  Future<void> runTurn(String sessionId, String requestId, String message) async {
    final now = DateTime.utc(2026, 11, 9);
    sessions.db.saveSession(
      SessionState(
        sessionId: sessionId,
        model: modelId,
        providerId: providerId,
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    await orchestrator.handleEvent(
      GatewayEvent(
        sessionId: sessionId,
        platformId: 'cli_client',
        type: 'message',
        message: Message(role: MessageRole.user, content: message),
        runId: requestId,
        turnRequest: AgentTurnRequest(
          sessionId: sessionId,
          message: message,
          providerInstanceId: providerId,
          model: modelId,
          requestId: requestId,
        ),
        metadata: {
          'command': 'message',
          'payload': {
            'session_id': sessionId,
            'request_id': requestId,
            'message': message,
          },
        },
      ),
    );
    await waitForIdle(sessionId);
  }

  test('many finished sessions keep no partial answer and a bounded cache',
      () async {
    adapter
      ..answerChars = 64 * 1024
      ..deltaChars = 512;
    const sessionsRun = 12;
    for (var i = 0; i < sessionsRun; i++) {
      final sessionId = 's-release-$i';
      await runTurn(sessionId, 'req-release-$i', 'question $i');
      expect(
        sessions.hasInFlightSnapshot(sessionId),
        isFalse,
        reason: 'a finished turn must release its in-flight projection',
      );
      final committed = sessions.getSession(sessionId)!;
      final assistant = committed.messages.last;
      expect(assistant.role, MessageRole.assistant);
      expect(
        assistant.content,
        adapter.expectedAnswer,
        reason: 'the buffered accumulator must commit the whole answer',
      );
    }
    expect(adapter.calls, sessionsRun);
    expect(sessions.historySnapshotCount, lessThanOrEqualTo(8));
    expect(sessions.historySnapshotChars, lessThanOrEqualTo(32 * 1024 * 1024));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('a reconnecting Client sees the whole partial answer mid-turn',
      () async {
    adapter
      ..answerChars = 8 * 1024
      ..deltaChars = 512;
    final gate = Completer<void>();
    adapter
      ..gate = gate
      ..gateAfterDeltas = 4;
    const sessionId = 's-mid-turn';
    unawaited(runTurn(sessionId, 'req-mid-turn', 'question'));

    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (!sessions.hasInFlightSnapshot(sessionId) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    final snapshot = sessions.getInFlightSnapshot(sessionId);
    expect(snapshot, isNotNull);
    expect(
      (snapshot!['content'] as String).length,
      4 * 512,
      reason: 'the live projection is every delta received so far',
    );

    gate.complete();
    await waitForIdle(sessionId);
    expect(sessions.hasInFlightSnapshot(sessionId), isFalse);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
