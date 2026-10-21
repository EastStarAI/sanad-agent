/// Task 116 — runner-level provider-compatible projection.
///
/// One persisted session runs OpenCode Go DeepSeek (Chat) -> Codex Responses
/// -> DeepSeek again, each turn through a fresh `AgentRunner` loading the
/// session from persistence (the restart boundary), real production adapters
/// and a MockClient HTTP carrier. A compaction-shaped continuation (summary
/// user turn plus the retained connected tail, written through the public
/// session API) then continues on DeepSeek. The D4 rejection is presented once
/// as a blocked local invalid request with no HTTP dispatch or history change.
///
/// Fixture boundary: this does not run the compaction engine or a live
/// provider; the post-compaction case proves projection of a compaction-shaped
/// canonical history, not compaction itself.
library;

import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_failure_reason.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_notice.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_exception.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/chat_reasoning_replay_policy.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';

import 'adapters/projection_fixtures.dart';

const _codexInstance = 'codex-1';
const _codexUrl = 'https://chatgpt.com/backend-api/codex';

final class _ReadFileTool extends BaseTool {
  @override
  ToolSchema get schema => ToolSchema(
    name: 'read_file',
    description: 'Read one synthetic file',
    parameters: const {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
      },
    },
  );

  @override
  Future<String> execute(Map<String, dynamic> args, {ToolContext? context}) async =>
      'contents of ${args['path'] ?? 'file'}';
}

String _chatToolCall(String id, {String? reasoning}) => sse([
  {
    'choices': [
      {
        'delta': {
          'reasoning_content': ?reasoning,
          'tool_calls': [
            {
              'index': 0,
              'id': id,
              'type': 'function',
              'function': {'name': 'read_file', 'arguments': '{"path":"$id"}'},
            },
          ],
        },
      },
    ],
  },
  {
    'choices': [
      {'delta': {}, 'finish_reason': 'tool_calls'},
    ],
  },
]);

String _chatFinal(String text) => sse([
  {
    'choices': [
      {
        'delta': {'reasoning_content': 'closing', 'content': text},
        'finish_reason': 'stop',
      },
    ],
  },
]);

String _codexEvent(List<Map<String, dynamic>> output) =>
    'data: ${jsonEncode({
      'type': 'response.completed',
      'response': {'status': 'completed', 'output': output},
    })}\n\n';

void main() {
  late Directory scratch;
  late AgentStateDatabase db;
  late SessionManager sessionManager;
  late RuntimeRecoveryService recovery;
  late ToolsRegistry registry;

  setUp(() async {
    scratch = Directory.systemTemp.createTempSync('sanad-116-runner-');
    setSanadHomeOverride(scratch.path);
    db = AgentStateDatabase.inMemory();
    final store = AttachmentStore(db, stateHome: scratch.path);
    await store.initialize();
    final repo = ProviderInstanceRepository.fromDatabase(db.db);
    final now = DateTime.now();
    repo.createInstance(
      ProviderInstance(
        id: goInstance,
        templateId: 'opencode-go',
        displayName: 'OpenCode Go',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: goBaseUrl,
        createdAt: now,
        updatedAt: now,
      ).copyWith(configRevision: 1, credentialRevision: 1),
    );
    repo.createInstance(
      ProviderInstance(
        id: _codexInstance,
        templateId: 'openai-codex',
        displayName: 'ChatGPT Codex',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: _codexUrl,
        createdAt: now,
        updatedAt: now,
      ).copyWith(configRevision: 1, credentialRevision: 1),
    );
    final config = Config(environment: const {});
    recovery = RuntimeRecoveryService(repo, ProviderRateLimiter());

    await getIt.reset();
    getIt.registerSingleton<AgentStateDatabase>(db);
    getIt.registerSingleton<AttachmentStore>(store);
    getIt.registerSingleton<Config>(config);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    getIt.registerSingleton<RouteCapabilityResolver>(
      RouteCapabilityResolver(instances: repo, config: config),
    );
    getIt.registerSingleton<RuntimeRecoveryService>(recovery);

    SessionManager.resetForTesting();
    sessionManager = SessionManager();
    registry = ToolsRegistry()..registerTool(_ReadFileTool());
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    setSanadHomeOverride(null);
    try {
      scratch.deleteSync(recursive: true);
    } catch (_) {}
  });

  BaseOpenAIAdapter deepSeek(
    List<Map<String, dynamic>> bodies,
    List<String> responses, {
    ChatReasoningReplayPolicy policy = const ChatReasoningReplayPolicy(),
  }) {
    var index = 0;
    return BaseOpenAIAdapter(
      FixedRouteConfig(goBaseUrl),
      ProviderRegistry.findByNameOrAlias('opencode-go')!,
      providerInstanceId: goInstance,
      modelsDevService: fixtureModelsDev(),
      replayPolicy: policy,
      client: MockClient((request) async {
        bodies.add((jsonDecode(request.body) as Map).cast<String, dynamic>());
        return http.Response(
          responses[index++],
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      }),
    );
  }

  CodexResponsesAdapter codex(
    List<Map<String, dynamic>> bodies,
    List<String> responses,
  ) {
    var index = 0;
    return CodexResponsesAdapter(
      Config(
        environment: const {
          'ACTIVE_PROVIDER': 'openai-codex',
          'LLM_API_KEY': 'fixture-key',
          'LLM_MODEL': codexModel,
          'CHATGPT_MODEL': codexModel,
          'LLM_BASE_URL': _codexUrl,
        },
      ),
      const ProviderProfile(
        name: 'openai-codex',
        defaultBaseUrl: _codexUrl,
        fallbackModels: [codexModel],
        apiMode: 'codex_responses',
      ),
      providerInstanceId: _codexInstance,
      client: MockClient.streaming((request, _) async {
        bodies.add(
          (jsonDecode((request as http.Request).body) as Map)
              .cast<String, dynamic>(),
        );
        return http.StreamedResponse(
          Stream.value(utf8.encode(responses[index++])),
          200,
        );
      }),
    );
  }

  Future<String> send(
    LLMAdapter adapter,
    String sessionId,
    String text, {
    required String provider,
    required String model,
    required String requestId,
  }) async {
    final runner = AgentRunner(
      adapter,
      registry,
      sessionManager,
      existingSessionId: sessionId,
    );
    final chunks = await runner
        .streamMessage(
          text,
          requestId: requestId,
          providerId: provider,
          model: model,
        )
        .toList();
    return chunks.join();
  }

  List<Message> persisted(String sessionId) =>
      sessionManager.getMessages(sessionId);

  String stateFingerprint(List<Message> messages) => jsonEncode([
    for (final message in messages)
      if (message.role == MessageRole.assistant)
        [message.toolCalls?.map((c) => c.id).toList(), message.providerState],
  ]);

  test(
    'DeepSeek -> Codex -> DeepSeek across restarts and a compacted tail',
    () async {
      final session = sessionManager.createSession(deepseek, providerId: goInstance);

      // Turn 1 (X): DeepSeek with one reasoning and one zero-reasoning call.
      final deepBodies1 = <Map<String, dynamic>>[];
      await send(
        deepSeek(deepBodies1, [
          _chatToolCall('d1', reasoning: 'deep plan'),
          _chatToolCall('d2'),
          _chatFinal('deep done'),
        ]),
        session.sessionId,
        'first',
        provider: goInstance,
        model: deepseek,
        requestId: 'req-x1',
      );
      expect(deepBodies1, hasLength(3));
      final afterX = persisted(session.sessionId);
      final d2 = afterX.singleWhere(
        (m) => m.toolCalls?.any((c) => c.id == 'd2') ?? false,
      );
      expect(d2.providerState!.data['issuer_model'], deepseek);
      expect(d2.providerState!.data['reasoning_field'], 'absent');

      // Turn 2 (Y): restart onto Codex Responses in the same session.
      final codexBodies = <Map<String, dynamic>>[];
      await send(
        codex(codexBodies, [
          _codexEvent([
            {'id': 'rs_1', 'type': 'reasoning', 'encrypted_content': 'codex-sealed'},
            {
              'id': 'fc_1',
              'type': 'function_call',
              'call_id': 'x1',
              'name': 'read_file',
              'arguments': '{"path":"x1"}',
              'status': 'completed',
            },
          ]),
          _codexEvent([
            {
              'type': 'message',
              'role': 'assistant',
              'status': 'completed',
              'content': [
                {'type': 'output_text', 'text': 'codex done'},
              ],
            },
          ]),
        ]),
        session.sessionId,
        'second',
        provider: _codexInstance,
        model: codexModel,
        requestId: 'req-y1',
      );
      expect(codexBodies, hasLength(2));
      for (final body in codexBodies) {
        final input = jsonEncode(body['input']);
        expect(input, isNot(contains('deep plan')));
        expect(input, isNot(contains('reasoning_content')));
        expect(input, contains('"call_id":"d1"'));
      }

      // Turn 3 (X again): restart back onto DeepSeek.
      final canonicalBefore = stateFingerprint(persisted(session.sessionId));
      final deepBodies2 = <Map<String, dynamic>>[];
      await send(
        deepSeek(deepBodies2, [_chatFinal('back on deepseek')]),
        session.sessionId,
        'third',
        provider: goInstance,
        model: deepseek,
        requestId: 'req-x2',
      );
      final wire = deepBodies2.single['messages'] as List;
      Map turnFor(String id) => wire.cast<Map>().singleWhere(
        (m) =>
            m['role'] == 'assistant' &&
            ((m['tool_calls'] as List?)?.any((c) => c['id'] == id) ?? false),
      );
      expect(turnFor('d1')['reasoning_content'], 'deep plan');
      expect(turnFor('d2').containsKey('reasoning_content'), isFalse);
      expect(turnFor('x1').containsKey('reasoning_content'), isFalse);
      expect(jsonEncode(wire), isNot(contains('codex-sealed')));
      expect(
        stateFingerprint(persisted(session.sessionId)).startsWith(
          canonicalBefore.substring(0, canonicalBefore.length - 1),
        ),
        isTrue,
        reason: 'canonical provider state is never rewritten',
      );

      // Compaction-shaped continuation: summary turn plus the retained
      // connected tail (the Codex turn and the latest DeepSeek turn).
      final full = persisted(session.sessionId);
      final tailStart = full.indexWhere(
        (m) => m.role == MessageRole.user && m.content == 'second',
      );
      sessionManager.saveSessionHistory(session.sessionId, [
        Message(role: MessageRole.user, content: 'Summary of earlier work.'),
        Message(role: MessageRole.assistant, content: 'Understood.'),
        ...full.sublist(tailStart),
      ]);
      final deepBodies3 = <Map<String, dynamic>>[];
      await send(
        deepSeek(deepBodies3, [_chatFinal('after compaction')]),
        session.sessionId,
        'fourth',
        provider: goInstance,
        model: deepseek,
        requestId: 'req-x3',
      );
      final compacted = jsonEncode(deepBodies3.single['messages']);
      expect(compacted, isNot(contains('codex-sealed')));
      expect(compacted, contains('"id":"x1"'));
      expect(compacted, contains('"reasoning_content":"closing"'));
      expect(recovery.hasActiveNotice(session.sessionId), isFalse);
    },
  );

  test(
    'history rejection is one blocked local notice with no dispatch or change',
    () async {
      final session = sessionManager.createSession(deepseek, providerId: goInstance);
      sessionManager.saveSessionHistory(session.sessionId, [
        Message(role: MessageRole.user, content: 'earlier'),
        toolTurn('x1', state: codexState(), metadata: {'model': codexModel}),
        toolResult('x1'),
        Message(role: MessageRole.assistant, content: 'codex done'),
      ]);
      final before = jsonEncode(
        persisted(session.sessionId).map((m) => m.toJson()).toList(),
      );
      final bodies = <Map<String, dynamic>>[];
      final adapter = deepSeek(
        bodies,
        const [],
        policy: const ChatReasoningReplayPolicy(
          decisions: {ReplayCell.foreignEarlierTurn: ReplayDecision.reject},
        ),
      );
      final runner = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: session.sessionId,
      );

      await expectLater(
        runner
            .streamMessage(
              'continue',
              requestId: 'req-reject',
              providerId: goInstance,
              model: deepseek,
            )
            .toList(),
        throwsA(
          isA<RuntimeRecoveryRequired>().having(
            (e) => e.reason,
            'reason',
            RuntimeFailureReason.invalidRequest,
          ),
        ),
      );

      expect(bodies, isEmpty, reason: 'nothing dispatched');
      final notice = recovery.activeNotice(session.sessionId);
      expect(notice, isNotNull);
      expect(notice!.status, RuntimeNoticeStatus.blocked);
      expect(notice.reason, RuntimeFailureReason.invalidRequest);
      expect(notice.title, 'Conversation history not supported by this model');
      expect(notice.message, contains('$deepseek on OpenCode Go'));
      expect(notice.message, contains('1 step'));
      expect(notice.message.toLowerCase(), isNot(contains('compact')));
      expect(notice.message, isNot(contains('Provider response')));
      expect(notice.message, isNot(contains('codex-sealed')));
      expect(runner.activeProvider, goInstance, reason: 'no failover');
      expect(runner.activeModel, deepseek);

      final after = persisted(session.sessionId)
          .where((m) => !(m.role == MessageRole.user && m.content == 'continue'))
          .map((m) => m.toJson())
          .toList();
      expect(jsonEncode(after), before, reason: 'history unchanged');
    },
  );
}
