import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_work_item_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/session_query_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

/// Task 78: an automatic failover after a tool step is anchored to the last
/// durable row the user saw live, and reloaded history renders it there.
void main() {
  late Directory tempDir;
  late AgentStateDatabase state;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sanad_route_anchor_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);
    state = AgentStateDatabase.inMemory();
    GetIt.I.registerSingleton<AgentStateDatabase>(state);
  });

  tearDown(() {
    GetIt.I.reset();
    SessionManager.resetForTesting();
    state.dispose();
    setSanadHomeOverride(null);
    try {
      tempDir.deleteSync(recursive: true);
    } catch (_) {}
  });

  test('failover after a tool step anchors on the persisted tool result and '
      'history replays the live order', () async {
    final sessionManager = SessionManager();
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    final now = DateTime.parse('2026-10-21T12:00:00Z');
    for (final id in ['provider-old', 'provider-new']) {
      repo.createInstance(
        ProviderInstance(
          id: id,
          templateId: 'openai',
          displayName: id == 'provider-old' ? 'Old' : 'New',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'model-a',
          status: InstanceStatus.ready,
          createdAt: now,
          updatedAt: now,
        ),
      );
    }
    final transitions = SessionRouteTransitionRepository(state);
    final coordinator = SessionRouteMutationCoordinator(
      state: state,
      workItems: SessionWorkItemRepository(state),
      transitions: transitions,
      providerInstances: repo,
    );
    final runtime = _SwitchingRuntime(
      repo,
      oldAdapter: _ToolThenRateLimitAdapter(),
      newAdapter: _AnswerAdapter(),
    );
    GetIt.I.registerSingleton<AgentRuntimeService>(runtime);
    GetIt.I.registerSingleton<ProviderInstanceRepository>(repo);
    GetIt.I.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(
        repo,
        ProviderRateLimiter(),
        autoFailoverEnabled: true,
      ),
    );
    GetIt.I.registerSingleton<SessionRouteMutationCoordinator>(coordinator);

    final session = sessionManager.createSession('model-a');
    final sessionId = session.sessionId;
    sessionManager.updateSessionProviderId(sessionId, 'provider-old');

    // What the live Client had rendered when the notice was published.
    List<String>? liveRolesAtPublish;
    final subscription = coordinator.changes.listen((_) {
      liveRolesAtPublish = [
        for (final m in sessionManager.getMessages(sessionId)) m.role.name,
      ];
    });
    addTearDown(subscription.cancel);

    final registry = ToolsRegistry()..registerTool(_EchoTool());
    final runner = AgentRunner(
      _AnswerAdapter(),
      registry,
      sessionManager,
      existingSessionId: sessionId,
    );
    final response = await runner.sendMessage('use the tool');
    expect(response.content, 'answer on new provider');

    expect(liveRolesAtPublish, ['user', 'assistant', 'tool']);
    final transition = transitions.findForSession(sessionId).single;
    final toolRow = sessionManager
        .getMessages(sessionId)
        .firstWhere((m) => m.role == MessageRole.tool);
    expect(transition.anchorMessageId, isNotNull);
    expect(transition.anchorMessageId, toolRow.metadata?['message_id']);

    final envelope =
        SessionQueryHandler(
          sessionManager: sessionManager,
          bridge: _EnvelopeBridge(),
          routeTransitions: transitions,
        ).buildHistoryEnvelope(
          CanonicalEvent(
            type: CanonicalEventTypes.getSessionHistory,
            sessionId: sessionId,
            payload: const {'request_id': 'reload'},
          ),
        );
    final types = [
      for (final row in (envelope['payload']['messages'] as List))
        (row as Map)['type'],
    ];
    expect(types, [
      'user_message',
      'tool_use',
      'tool_result',
      'session_route_transition',
      'final_answer',
    ]);
  });
}

class _EchoTool extends BaseTool {
  @override
  ToolSchema get schema =>
      ToolSchema(name: 'echo_tool', description: 'echo', parameters: {});

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => 'echoed';

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => ToolExecutionResult.text(await execute(args, context: context));
}

abstract class _StreamingAdapter implements LLMAdapter {
  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

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
}

/// First step calls a tool; the next step fails before streaming.
class _ToolThenRateLimitAdapter extends _StreamingAdapter {
  int calls = 0;

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    calls++;
    if (calls == 1) {
      return AgentResponse(
        message: Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(id: 'call-1', name: 'echo_tool', arguments: const {}),
          ],
        ),
        finishReason: LLMFinishReason.toolCalls,
      );
    }
    throw const LlmHttpException(
      statusCode: 429,
      body: '{"error":{"message":"rate limit"}}',
      headers: {},
      operation: 'chat.completions',
    );
  }
}

class _AnswerAdapter extends _StreamingAdapter {
  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async => AgentResponse(
    message: Message(
      role: MessageRole.assistant,
      content: 'answer on new provider',
    ),
    finishReason: LLMFinishReason.stop,
  );
}

class _SwitchingRuntime extends AgentRuntimeService {
  _SwitchingRuntime(
    this._repo, {
    required this.oldAdapter,
    required this.newAdapter,
  }) : super(
         Config(),
         _repo,
         rateLimiter: ProviderRateLimiter(),
         recoveryService: RuntimeRecoveryService(
           _repo,
           ProviderRateLimiter(),
           autoFailoverEnabled: true,
         ),
       );

  final ProviderInstanceRepository _repo;
  final LLMAdapter oldAdapter;
  final LLMAdapter newAdapter;

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    final instance = _repo.findById(providerId!)!;
    return RouteSignature(
      providerInstanceId: instance.id,
      templateId: instance.templateId,
      protocol: instance.protocol,
      normalizedBaseUrl: 'http://localhost:9000/v1',
      modelId: modelId ?? instance.defaultModel ?? 'model-a',
      configRevision: instance.configRevision,
      credentialRevision: instance.credentialRevision,
    );
  }

  @override
  LLMAdapter adapterForTurn(
    RouteSignature signature, {
    required String sessionId,
    String? requestId,
    String? runId,
  }) => signature.providerInstanceId == 'provider-old'
      ? oldAdapter
      : newAdapter;
}

class _EnvelopeBridge extends SanadProtocolBridge {
  @override
  Map<String, dynamic> buildAgentEventEnvelope(CanonicalEvent canonicalEvent) {
    return {
      'event': canonicalEvent.type,
      'payload': canonicalEvent.payload,
      'session_id': canonicalEvent.sessionId,
    };
  }
}
