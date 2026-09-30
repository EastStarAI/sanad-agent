import 'dart:convert';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/ollama_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

const _route = RouteSignature(
  providerInstanceId: 'provider-1',
  templateId: 'openai-codex',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'gpt-test',
  configRevision: 1,
  credentialRevision: 1,
);

String _validJson({String goal = 'إنهاء المهمة الحالية'}) => jsonEncode({
  'schemaVersion': 1,
  'currentGoal': goal,
  'latestUserRequest': 'نفّذ التغيير ثم شغّل الاختبارات',
  'successCriteria': 'نجاح الاختبارات',
  'constraints': 'حافظ على المسار agent/lib/example.dart',
  'completedWork': 'اكتمل الاكتشاف',
  'activeState': 'التنفيذ جارٍ',
  'criticalContext': 'المعرّف 53i والمنفذ 58085',
  'decisions': 'استخدام JSON typed',
  'blockers': 'لا يوجد',
  'filesAndPaths': 'agent/lib/example.dart',
  'pendingAsks': 'إنهاء التنفيذ',
  'remainingWork': 'تشغيل analyzer والاختبارات',
});

List<IndexedConversationMessage> _timeline() => [
  IndexedConversationMessage(
    rowId: 1,
    message: Message(
      role: MessageRole.user,
      content: 'أريد إنهاء المهمة الحالية',
    ),
  ),
  for (var index = 2; index <= 35; index++)
    IndexedConversationMessage(
      rowId: index,
      message: Message(
        role: MessageRole.assistant,
        content: 'تفاصيل التنفيذ $index ${'س' * 160}',
      ),
    ),
];

CompactionEngineRequest _request(CompactionSummarizer summarizer) {
  final projection = [
    Message(role: MessageRole.system, content: 'stable system'),
    Message(role: MessageRole.user, content: 'أصلح ضغط السياق'),
    Message(role: MessageRole.assistant, content: 'أعمل على ذلك'),
    Message(role: MessageRole.user, content: 'نفّذ التغيير ثم شغّل الاختبارات'),
  ];
  return CompactionEngineRequest(
    compactionId: 'cmp-provider',
    sessionId: 'session-provider',
    trigger: CompactionTrigger.auto,
    sourceRevision: const CompactionHistoryRevision(1),
    routeSignature: _route,
    contextWindowTokens: 8_000,
    timeline: _timeline(),
    systemPrompt: 'stable system',
    runtimeContext: '',
    toolSchemas: const [
      {
        'name': 'read_file',
        'description': 'Read a file',
        'parameters': {'type': 'object'},
      },
    ],
    providerProjection: projection,
    providerTools: [
      ToolSchema(
        name: 'read_file',
        description: 'Read a file',
        parameters: const {'type': 'object'},
      ),
    ],
    providerRequestOptions: const LLMRequestOptions(
      sessionId: 'session-provider',
      requestId: 'compaction:cmp-provider',
    ),
    targetRequestTokens: 3_000,
    thresholdRatio: 0.10,
  );
}

class _RecordingProviderSummarizer
    implements CompactionSummarizer, ProviderProjectionCompactionSummarizer {
  final List<String> responses;
  final requests = <CompactionProviderRequest>[];

  _RecordingProviderSummarizer(this.responses);

  @override
  Future<String> summarize({required String prompt}) =>
      throw UnsupportedError('provider path expected');

  @override
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  ) async {
    requests.add(request);
    return CompactionProviderResult(
      content: responses[requests.length - 1],
      usage: const {
        'input_tokens': 1200,
        'input_tokens_details': {'cached_tokens': 900},
        'output_tokens': 200,
        'output_tokens_details': {'reasoning_tokens': 15},
      },
      duration: const Duration(milliseconds: 12),
    );
  }
}

class _OverflowThenProvider
    implements CompactionSummarizer, ProviderProjectionCompactionSummarizer {
  final requests = <CompactionProviderRequest>[];

  @override
  Future<String> summarize({required String prompt}) =>
      throw UnsupportedError('provider path expected');

  @override
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  ) async {
    requests.add(request);
    if (requests.length == 1) throw const CompactionProviderOverflow();
    return CompactionProviderResult(
      content: _validJson(),
      usage: const {'prompt_tokens': 100, 'completion_tokens': 20},
      duration: const Duration(milliseconds: 1),
    );
  }
}

class _WireAdapter implements LLMAdapter, WireInputUsageMeasurer {
  int toolCallsRemaining;
  final LLMFinishReason finishReason;
  List<Message>? generatedHistory;
  int measurementCalls = 0;
  int generateCalls = 0;
  final generatedTools = <List<ToolSchema>>[];
  final generatedOptions = <LLMRequestOptions>[];

  _WireAdapter({
    this.toolCallsRemaining = 0,
    this.finishReason = LLMFinishReason.unknown,
  });

  @override
  Future<WireInputMeasurement?> measureInput(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    measurementCalls++;
    return WireInputMeasurement(
      estimatedTokens: history.length * 10,
      stableMaterialFingerprint: 'stable',
      inputItemFingerprints: [
        for (var index = 0; index < history.length; index++) 'item-$index',
      ],
    );
  }

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    generateCalls++;
    generatedHistory = history;
    generatedTools.add(List.unmodifiable(tools ?? const []));
    generatedOptions.add(options);
    final toolCall = toolCallsRemaining > 0;
    if (toolCall) toolCallsRemaining--;
    return AgentResponse(
      message: Message(
        role: MessageRole.assistant,
        content: toolCall ? '' : _validJson(),
        toolCalls: toolCall
            ? [ToolCall(id: 'call-1', name: 'write', arguments: const {})]
            : null,
      ),
      isToolCall: toolCall,
      usage: const {'prompt_tokens': 10, 'completion_tokens': 2},
      finishReason: finishReason,
    );
  }

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 8_000;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) => throw UnsupportedError('not used');
}

class _Runtime extends AgentRuntimeService {
  final LLMAdapter resolvedAdapter;
  final RouteSignature resolvedRoute;
  _Runtime(
    super.config,
    super.repo,
    this.resolvedAdapter, {
    this.resolvedRoute = _route,
  });

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) =>
      resolvedRoute;

  @override
  LLMAdapter adapterFor(RouteSignature signature) => resolvedAdapter;
}

RouteSignature _adapterRoute({
  required String templateId,
  required String protocol,
  required String baseUrl,
}) => RouteSignature(
  providerInstanceId: 'provider-$templateId',
  templateId: templateId,
  protocol: protocol,
  normalizedBaseUrl: baseUrl,
  modelId: 'summary-model',
  configRevision: 1,
  credentialRevision: 1,
);

final List<ToolSchema> _adapterTools = [
  ToolSchema(
    name: 'read_file',
    description: 'Read a file',
    parameters: {'type': 'object'},
  ),
];

List<Message> _adapterBaseProjection() => [
  Message(role: MessageRole.system, content: 'stable system'),
  Message(role: MessageRole.user, content: 'earlier request'),
  Message(role: MessageRole.assistant, content: 'earlier answer'),
  Message(role: MessageRole.user, content: 'latest request'),
];

Future<CompactionProviderResult> _summarizeThroughAdapter({
  required AgentStateDatabase state,
  required LLMAdapter adapter,
  required RouteSignature route,
  required String instruction,
}) {
  final repo = ProviderInstanceRepository.fromDatabase(state.db);
  return ProviderBackedCompactionSummarizer(
    _Runtime(Config(), repo, adapter, resolvedRoute: route),
  ).summarizeProvider(
    CompactionProviderRequest(
      baseProjection: _adapterBaseProjection(),
      tools: _adapterTools,
      routeSignature: route,
      options: const LLMRequestOptions(
        sessionId: 'session-adapter-contract',
        requestId: 'compaction:adapter-contract',
      ),
      instruction: instruction,
    ),
  );
}

String _codexSse(Map<String, dynamic> response) =>
    'data: ${jsonEncode({'type': 'response.completed', 'response': response})}\n\n';

void main() {
  test(
    'provider engine appends one instruction to immutable current projection',
    () async {
      final summarizer = _RecordingProviderSummarizer([_validJson()]);
      final candidate = await ContextCompactionEngine(
        summarizer: summarizer,
      ).buildCandidate(_request(summarizer));

      expect(candidate, isNotNull);
      final request = summarizer.requests.single;
      expect(
        request.baseProjection.last.content,
        'نفّذ التغيير ثم شغّل الاختبارات',
      );
      expect(
        request.appendedProjection.length,
        request.baseProjection.length + 1,
      );
      for (var index = 0; index < request.baseProjection.length; index++) {
        expect(
          identical(
            request.appendedProjection[index],
            request.baseProjection[index],
          ),
          isTrue,
        );
      }
      expect(candidate!.internalSummary.currentGoal, 'إنهاء المهمة الحالية');
      expect(candidate.metrics.summarizationCachedInputTokens, 900);
      expect(candidate.metrics.summarizationReasoningTokens, 15);
      expect(candidate.metrics.summarizationAttempts, 1);
    },
  );

  test(
    'corrective attempt reuses immutable base and excludes failed output',
    () async {
      final summarizer = _RecordingProviderSummarizer([
        '{"schemaVersion":1,"currentGoal":"incomplete"}',
        _validJson(),
      ]);
      final candidate = await ContextCompactionEngine(
        summarizer: summarizer,
      ).buildCandidate(_request(summarizer));

      expect(candidate, isNotNull);
      expect(summarizer.requests, hasLength(2));
      for (
        var index = 0;
        index < summarizer.requests[0].baseProjection.length;
        index++
      ) {
        expect(
          identical(
            summarizer.requests[1].baseProjection[index],
            summarizer.requests[0].baseProjection[index],
          ),
          isTrue,
        );
      }
      expect(
        summarizer.requests[1].baseProjection.any(
          (message) => message.content?.contains('incomplete') ?? false,
        ),
        isFalse,
      );
      expect(candidate!.metrics.summarizationAttempts, 2);
    },
  );

  test('strict parser rejects unknown and duplicate keys', () {
    expect(
      () => CompactionSummaryParser.parse(
        _validJson().replaceFirst('"remainingWork"', '"unknown"'),
      ),
      throwsFormatException,
    );
    expect(
      () => CompactionSummaryParser.parse(
        _validJson().replaceFirst('{', '{"currentGoal":"duplicate",'),
      ),
      throwsFormatException,
    );
  });

  test(
    'strict parser accepts a valid summary without compaction-only caps',
    () {
      final largeGoal = '${'س' * 20_000} {"currentGoal":"quoted data"}';
      expect(
        CompactionSummaryParser.parse(_validJson(goal: largeGoal)).currentGoal,
        largeGoal,
      );
    },
  );

  test('provider overflow uses bounded typed recovery', () async {
    final summarizer = _OverflowThenProvider();
    final candidate = await ContextCompactionEngine(
      summarizer: summarizer,
    ).buildCandidate(_request(summarizer));

    expect(candidate, isNotNull);
    expect(summarizer.requests.length, inInclusiveRange(3, 6));
    expect(
      candidate!.metrics.summarizationAttempts,
      summarizer.requests.length - 1,
    );
  });

  group('registered adapter wire contract', () {
    late AgentStateDatabase state;
    late Config config;
    late String instruction;

    setUp(() {
      state = AgentStateDatabase.inMemory();
      config = Config(
        environment: const {
          'LLM_API_KEY': 'test-key',
          'LLM_MODEL': 'summary-model',
          'LLM_BASE_URL': 'https://unused.example/v1',
        },
      );
      instruction = CompactionSummaryPrompt.buildJsonInstruction();
    });
    tearDown(() => state.dispose());

    test(
      'Codex Responses keeps the final instruction and ordinary tools',
      () async {
        late Map<String, dynamic> body;
        const baseUrl = 'https://chatgpt.com/backend-api/codex';
        final route = _adapterRoute(
          templateId: 'openai-codex',
          protocol: 'openai_compatible',
          baseUrl: baseUrl,
        );
        final adapter = CodexResponsesAdapter(
          config,
          ProviderRegistry.findByNameOrAlias('openai-codex')!,
          baseUrlOverride: baseUrl,
          apiKeyOverride: 'test-key',
          defaultModelOverride: route.modelId,
          client: MockClient.streaming((request, _) async {
            body = (jsonDecode((request as http.Request).body) as Map)
                .cast<String, dynamic>();
            return http.StreamedResponse(
              Stream.value(
                utf8.encode(
                  _codexSse({
                    'status': 'completed',
                    'model': route.modelId,
                    'output': [
                      {
                        'type': 'message',
                        'role': 'assistant',
                        'status': 'completed',
                        'phase': 'final_answer',
                        'content': [
                          {'type': 'output_text', 'text': _validJson()},
                        ],
                      },
                    ],
                    'usage': {
                      'input_tokens': 120,
                      'input_tokens_details': {'cached_tokens': 90},
                      'output_tokens': 20,
                    },
                  }),
                ),
              ),
              200,
            );
          }),
        );

        final result = await _summarizeThroughAdapter(
          state: state,
          adapter: adapter,
          route: route,
          instruction: instruction,
        );

        expect(result.content, _validJson());
        expect(body['model'], route.modelId);
        expect(body['stream'], isTrue);
        expect(body['tools'][0]['name'], 'read_file');
        final input = body['input'] as List;
        expect(input.last['role'], 'user');
        expect(input.last['content'][0]['text'], instruction);
      },
    );

    test(
      'OpenAI-compatible keeps the final instruction and ordinary tools',
      () async {
        late Map<String, dynamic> body;
        const baseUrl = 'https://openai.example/v1';
        final route = _adapterRoute(
          templateId: 'openai',
          protocol: 'openai_compatible',
          baseUrl: baseUrl,
        );
        final adapter = BaseOpenAIAdapter(
          config,
          ProviderRegistry.findByNameOrAlias('openai')!,
          baseUrlOverride: baseUrl,
          apiKeyOverride: 'test-key',
          defaultModelOverride: route.modelId,
          client: MockClient((request) async {
            body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
            return http.Response(
              jsonEncode({
                'choices': [
                  {
                    'message': {'role': 'assistant', 'content': _validJson()},
                    'finish_reason': 'stop',
                  },
                ],
                'usage': {'prompt_tokens': 120, 'completion_tokens': 20},
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );

        final result = await _summarizeThroughAdapter(
          state: state,
          adapter: adapter,
          route: route,
          instruction: instruction,
        );

        expect(result.content, _validJson());
        expect(body['model'], route.modelId);
        expect(body['tools'][0]['function']['name'], 'read_file');
        expect(body['messages'].last['role'], 'user');
        expect(body['messages'].last['content'], instruction);
      },
    );

    test(
      'Anthropic-compatible keeps the final instruction and ordinary tools',
      () async {
        late Map<String, dynamic> body;
        const baseUrl = 'https://anthropic.example';
        final route = _adapterRoute(
          templateId: 'anthropic',
          protocol: 'anthropic_compatible',
          baseUrl: baseUrl,
        );
        final adapter = BaseAnthropicAdapter(
          config,
          ProviderRegistry.findByNameOrAlias('anthropic')!,
          baseUrlOverride: baseUrl,
          apiKeyOverride: 'test-key',
          defaultModelOverride: route.modelId,
          client: MockClient((request) async {
            body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
            return http.Response(
              jsonEncode({
                'content': [
                  {'type': 'text', 'text': _validJson()},
                ],
                'stop_reason': 'end_turn',
                'usage': {
                  'input_tokens': 120,
                  'cache_read_input_tokens': 90,
                  'output_tokens': 20,
                },
              }),
              200,
              headers: {'content-type': 'application/json; charset=utf-8'},
            );
          }),
        );

        final result = await _summarizeThroughAdapter(
          state: state,
          adapter: adapter,
          route: route,
          instruction: instruction,
        );

        expect(result.content, _validJson());
        expect(body['model'], route.modelId);
        expect(body['tools'][0]['name'], 'read_file');
        final lastMessage = body['messages'].last as Map;
        expect(lastMessage['role'], 'user');
        final content = lastMessage['content'] as List;
        expect(content.last['type'], 'text');
        expect(content.last['text'], instruction);
      },
    );

    test('Ollama keeps the final instruction and ordinary tools', () async {
      late Map<String, dynamic> body;
      const baseUrl = 'http://ollama.example:11434';
      final route = _adapterRoute(
        templateId: 'ollama',
        protocol: 'openai_compatible',
        baseUrl: baseUrl,
      );
      final adapter = OllamaAdapter(
        config,
        ProviderRegistry.findByNameOrAlias('ollama')!,
        baseUrlOverride: baseUrl,
        client: MockClient((request) async {
          body = (jsonDecode(request.body) as Map).cast<String, dynamic>();
          return http.Response(
            jsonEncode({
              'message': {'role': 'assistant', 'content': _validJson()},
              'done': true,
              'prompt_eval_count': 120,
              'eval_count': 20,
            }),
            200,
            headers: {'content-type': 'application/json; charset=utf-8'},
          );
        }),
      );

      final result = await _summarizeThroughAdapter(
        state: state,
        adapter: adapter,
        route: route,
        instruction: instruction,
      );

      expect(result.content, _validJson());
      expect(body['model'], route.modelId);
      expect(body['tools'][0]['function']['name'], 'read_file');
      expect(body['messages'].last['role'], 'user');
      expect(body['messages'].last['content'], instruction);
    });
  });

  group('ProviderBackedCompactionSummarizer', () {
    late AgentStateDatabase state;
    late ProviderInstanceRepository repo;
    setUp(() {
      state = AgentStateDatabase.inMemory();
      repo = ProviderInstanceRepository.fromDatabase(state.db);
    });
    tearDown(() => state.dispose());

    test(
      'invokes adapter without compaction-specific wire measurement',
      () async {
        final adapter = _WireAdapter();
        final summarizer = ProviderBackedCompactionSummarizer(
          _Runtime(Config(), repo, adapter),
        );
        final base = [Message(role: MessageRole.user, content: 'طلب حالي')];
        const ordinaryOptions = LLMRequestOptions(
          sessionId: 'session-provider',
          maxOutputTokens: 7_777,
          timeout: Duration(seconds: 37),
        );
        final result = await summarizer.summarizeProvider(
          CompactionProviderRequest(
            baseProjection: base,
            tools: const [],
            routeSignature: _route,
            options: ordinaryOptions,
            instruction: CompactionSummaryPrompt.buildJsonInstruction(),
          ),
        );

        expect(adapter.measurementCalls, 0);
        expect(adapter.generatedHistory, hasLength(2));
        expect(identical(adapter.generatedHistory!.first, base.first), isTrue);
        expect(
          identical(adapter.generatedOptions.single, ordinaryOptions),
          isTrue,
        );
        expect(result.content, _validJson());
      },
    );

    test(
      'tool call is never executed and receives one corrective retry',
      () async {
        final adapter = _WireAdapter(toolCallsRemaining: 1);
        final summarizer = ProviderBackedCompactionSummarizer(
          _Runtime(Config(), repo, adapter),
        );
        final candidate = await ContextCompactionEngine(
          summarizer: summarizer,
        ).buildCandidate(_request(summarizer));

        expect(candidate, isNotNull);
        expect(adapter.generateCalls, 2);
        expect(
          adapter.generatedTools.every(
            (tools) => tools.single.name == 'read_file',
          ),
          isTrue,
        );
        expect(
          adapter.generatedOptions.map((options) => options.maxOutputTokens),
          everyElement(isNull),
        );
        expect(candidate!.metrics.summarizationAttempts, 2);
        expect(candidate.metrics.summarizationInputTokens, 20);
        expect(
          adapter.generatedHistory!.last.content,
          endsWith('return only the final JSON object.'),
        );
      },
    );

    test('second tool call fails safely without executing a tool', () async {
      final adapter = _WireAdapter(toolCallsRemaining: 2);
      final summarizer = ProviderBackedCompactionSummarizer(
        _Runtime(Config(), repo, adapter),
      );

      await expectLater(
        ContextCompactionEngine(
          summarizer: summarizer,
        ).buildCandidate(_request(summarizer)),
        throwsA(
          isA<CompactionEngineFailure>().having(
            (error) => error.reason,
            'reason',
            CompactionFailureReason.summarizationFailed,
          ),
        ),
      );
      expect(adapter.generateCalls, 2);
      expect(adapter.toolCallsRemaining, 0);
      expect(
        adapter.generatedTools.every(
          (tools) => tools.single.name == 'read_file',
        ),
        isTrue,
      );
    });

    test(
      'non-terminal provider response fails safely after correction',
      () async {
        final adapter = _WireAdapter(finishReason: LLMFinishReason.incomplete);
        final summarizer = ProviderBackedCompactionSummarizer(
          _Runtime(Config(), repo, adapter),
        );

        await expectLater(
          ContextCompactionEngine(
            summarizer: summarizer,
          ).buildCandidate(_request(summarizer)),
          throwsA(
            isA<CompactionEngineFailure>().having(
              (error) => error.reason,
              'reason',
              CompactionFailureReason.summarizationFailed,
            ),
          ),
        );
        expect(adapter.generateCalls, 2);
      },
    );
  });
}
