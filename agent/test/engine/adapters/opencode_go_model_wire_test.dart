/// Task 120 — OpenCode Go per-model wire: Go-shaped Responses and Messages
/// wire fixtures, provider-state round-trips across a same-instance protocol
/// change, the frozen `RouteSignature.apiMode`, thinking resolution on the
/// model's own wire and durable compaction route identity. Synthetic only.
library;

import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_wire.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/models_dev_thinking_evidence.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_capability_assembler.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_control_cache_resolver.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_policy.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/engine/adapters/base_anthropic_adapter.dart';
import 'package:sanad_agent/engine/adapters/codex_responses_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/request_pressure_evaluator.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:test/test.dart';

import 'projection_fixtures.dart';

const _session = 'session-go';

ProviderProfile get _goTemplate =>
    ProviderRegistry.findByNameOrAlias('opencode-go')!;

ProviderInstance _goInstance() => ProviderInstance(
  id: goInstance,
  templateId: 'opencode-go',
  displayName: 'Go',
  protocol: ProviderProtocol.openaiCompatible,
  authMethod: ProviderAuthMethod.apiKey,
  defaultModel: deepseek,
  status: 'ready',
  createdAt: DateTime.utc(2026, 10, 21),
  updatedAt: DateTime.utc(2026, 10, 21),
);

class _Captured {
  final Uri url;
  final Map<String, String> headers;
  final Map<String, dynamic> body;
  _Captured(this.url, this.headers, this.body);
  String get wire => jsonEncode(body);
}

/// The Responses adapter exactly as `AgentRuntimeService._buildAdapter`
/// derives it from the frozen catalog wire.
CodexResponsesAdapter _responsesAdapter(
  ModelsDevService catalog,
  List<_Captured> seen,
) {
  final wire = ProviderModelWire.fromCatalog(
    template: _goTemplate,
    entry: catalog.modelEntrySync('opencode-go', goResponsesModel),
  )!;
  return CodexResponsesAdapter(
    FixedRouteConfig(wire.baseUrl),
    wire.applyTo(_goTemplate),
    providerInstanceId: goInstance,
    baseUrlOverride: wire.baseUrl,
    apiKeyOverride: 'fixture-key',
    defaultModelOverride: goResponsesModel,
    client: MockClient.streaming((request, _) async {
      final r = request as http.Request;
      seen.add(
        _Captured(
          r.url,
          r.headers,
          (jsonDecode(r.body) as Map).cast<String, dynamic>(),
        ),
      );
      final event = {
        'type': 'response.completed',
        'response': {
          'status': 'completed',
          'model': goResponsesModel,
          'output': [
            {
              'type': 'reasoning',
              'id': 'rs_go',
              'encrypted_content': 'sealed-go',
              'summary': [
                {'type': 'summary_text', 'text': 'luna plan'},
              ],
            },
            {
              'type': 'function_call',
              'id': 'fc_go',
              'call_id': 'call-go',
              'name': 'read_file',
              'arguments': '{"path":"go.txt"}',
            },
          ],
        },
      };
      return http.StreamedResponse(
        Stream.value(utf8.encode('data: ${jsonEncode(event)}\n\n')),
        200,
      );
    }),
  );
}

BaseAnthropicAdapter _messagesAdapter(
  ModelsDevService catalog,
  List<_Captured> seen,
) {
  final wire = ProviderModelWire.fromCatalog(
    template: _goTemplate,
    entry: catalog.modelEntrySync('opencode-go', goMessagesModel),
  )!;
  return BaseAnthropicAdapter(
    FixedRouteConfig(wire.baseUrl),
    wire.applyTo(_goTemplate),
    providerInstanceId: goInstance,
    baseUrlOverride: wire.baseUrl,
    apiKeyOverride: 'fixture-key',
    defaultModelOverride: goMessagesModel,
    client: MockClient((request) async {
      seen.add(
        _Captured(
          request.url,
          request.headers,
          (jsonDecode(request.body) as Map).cast<String, dynamic>(),
        ),
      );
      return http.Response(
        jsonEncode({
          'content': [
            {
              'type': 'thinking',
              'thinking': 'mini plan',
              'signature': 'sig-go',
            },
            {
              'type': 'tool_use',
              'id': 'tu-go',
              'name': 'read_file',
              'input': {'path': 'mini.txt'},
            },
          ],
          'stop_reason': 'tool_use',
          'usage': {'input_tokens': 1, 'output_tokens': 1},
        }),
        200,
      );
    }),
  );
}

const _options = LLMRequestOptions(
  providerInstanceId: goInstance,
  sessionId: _session,
);

void main() {
  late ModelsDevService catalog;

  setUp(() => catalog = goWireModelsDev());

  group('catalog wire resolution', () {
    test('maps AI SDK packages to wires and never guesses endpoints', () {
      ProviderModelWire? wireFor(String model) => ProviderModelWire.fromCatalog(
        template: _goTemplate,
        entry: catalog.modelEntrySync('opencode-go', model),
      );
      final responses = wireFor(goResponsesModel)!;
      expect(responses.apiMode, 'codex_responses');
      expect(responses.protocol, ProviderProtocol.openaiCompatible);
      expect(responses.baseUrl, goOpenAiApi);
      final messages = wireFor(goMessagesModel)!;
      expect(messages.apiMode, 'anthropic_messages');
      expect(messages.protocol, ProviderProtocol.anthropicCompatible);
      expect(messages.baseUrl, goAnthropicApi);
      expect(wireFor(deepseek), isNull, reason: 'Chat keeps configured wire');
      expect(wireFor('responses-without-api'), isNull);
      expect(wireFor('google-served'), isNull);
      expect(wireFor('absent-model'), isNull);
    });

    test('rejects non-https catalog endpoints', () {
      expect(
        ProviderModelWire.fromCatalog(
          template: _goTemplate,
          entry: {
            'provider': {'npm': '@ai-sdk/openai', 'api': 'http://x.invalid/v1'},
          },
        ),
        isNull,
      );
    });
  });

  group('Go-shaped Responses wire', () {
    test('posts to the catalog Responses endpoint with bearer auth', () async {
      final seen = <_Captured>[];
      final response = await _responsesAdapter(catalog, seen).generateResponse(
        [Message(role: MessageRole.user, content: 'go')],
        options: const LLMRequestOptions(
          providerInstanceId: goInstance,
          sessionId: _session,
          thinkingDirective: ResponsesReasoningDirective(effort: 'high'),
        ),
      );
      final request = seen.single;
      expect(request.url.toString(), '$goOpenAiApi/responses');
      expect(request.headers['Authorization'], 'Bearer fixture-key');
      expect(request.headers['x-opencode-session'], _session);
      expect(request.body['model'], goResponsesModel);
      expect(request.body['store'], false);
      expect(request.body['stream'], true);
      expect(request.body['reasoning'], containsPair('effort', 'high'));

      final state = response.message.providerState!;
      expect(state.namespace, 'codex_responses');
      expect(state.issuer, goResponsesIssuer);
      expect(response.message.toolCalls!.single.id, 'call-go');
    });

    test('declares native image tool results for the Responses route', () {
      expect(
        _responsesAdapter(catalog, []).toolResultMediaCapability,
        ToolResultMediaCapability.imageToolResults,
      );
    });
  });

  group('Go-shaped Messages wire', () {
    test('posts to the catalog Messages endpoint with x-api-key', () async {
      final seen = <_Captured>[];
      final response = await _messagesAdapter(catalog, seen).generateResponse([
        Message(role: MessageRole.user, content: 'go'),
      ], options: _options);
      final request = seen.single;
      expect(request.url.toString(), '$goAnthropicApi/messages');
      expect(request.headers['x-api-key'], 'fixture-key');
      expect(request.headers.containsKey('Authorization'), isFalse);
      expect(request.headers['anthropic-version'], isNotEmpty);
      expect(request.headers['x-opencode-session'], _session);
      expect(request.body['model'], goMessagesModel);

      final state = response.message.providerState!;
      expect(state.namespace, 'anthropic_messages');
      expect(state.issuer, goMessagesIssuer);
      expect(state.data['issuer_model'], goMessagesModel);
    });
  });

  test('Chat -> Responses -> Messages -> Chat on one instance replays only '
      'same-route state', () async {
    final history = <Message>[
      Message(role: MessageRole.user, content: 'start'),
      toolTurn('chat-1', state: chatState(reasoning: 'deepseek reasoning')),
      toolResult('chat-1'),
    ];

    // Chat -> Responses: Chat reasoning is foreign to the Responses issuer.
    final responsesSeen = <_Captured>[];
    final responses = _responsesAdapter(catalog, responsesSeen);
    final luna = await responses.generateResponse(history, options: _options);
    var input = jsonEncode(responsesSeen.last.body['input']);
    expect(input, isNot(contains('deepseek reasoning')));
    expect(input, isNot(contains('reasoning_content')));
    history
      ..add(luna.message)
      ..add(toolResult('call-go'));

    // Responses -> Messages: neither Chat nor Responses state reaches it.
    final messagesSeen = <_Captured>[];
    final messages = _messagesAdapter(catalog, messagesSeen);
    final mini = await messages.generateResponse(history, options: _options);
    var wire = messagesSeen.last.wire;
    for (final foreign in ['sealed-go', 'deepseek reasoning']) {
      expect(wire, isNot(contains(foreign)), reason: foreign);
    }
    final toolUses = (messagesSeen.last.body['messages'] as List)
        .expand((m) => m['content'] is List ? m['content'] as List : const [])
        .where((b) => b is Map && b['type'] == 'tool_use')
        .map((b) => (b as Map)['id']);
    expect(toolUses, ['chat-1', 'call-go']);
    history
      ..add(mini.message)
      ..add(toolResult('tu-go'));

    // Back to Responses: only its own encrypted reasoning replays.
    await responses.generateResponse(history, options: _options);
    input = jsonEncode(responsesSeen.last.body['input']);
    expect(input, contains('sealed-go'));
    expect(input, isNot(contains('sig-go')));
    expect(input, isNot(contains('mini plan')));
    expect(input, isNot(contains('deepseek reasoning')));

    // Back to Messages: only its own signed thinking replays.
    await messages.generateResponse(history, options: _options);
    wire = messagesSeen.last.wire;
    expect(wire, contains('sig-go'));
    expect(wire, isNot(contains('sealed-go')));
    expect(wire, isNot(contains('deepseek reasoning')));

    // Back to Chat: the unchanged Chat issuer still owns its reasoning.
    final recorder = WireRecorder();
    await goAdapter(
      recorder.client,
      modelsDev: catalog,
    ).generateResponse(history, modelOverride: deepseek, options: _options);
    final chatWire = jsonEncode(recorder.bodies.single);
    expect(chatWire, contains('deepseek reasoning'));
    for (final foreign in ['sealed-go', 'sig-go', 'mini plan', 'luna plan']) {
      expect(chatWire, isNot(contains(foreign)), reason: foreign);
    }
  });

  group('route signature and thinking authority', () {
    late Directory home;
    late AgentStateDatabase state;
    late ProviderInstanceRepository repo;
    late AgentRuntimeService runtime;
    late ThinkingCapabilityAssembler assembler;
    late ThinkingSelectionResolver resolver;

    setUp(() {
      home = Directory.systemTemp.createTempSync('sanad_120_thinking_');
      setSanadHomeOverride(home.path);
      state = AgentStateDatabase.inMemory();
      repo = ProviderInstanceRepository.fromDatabase(state.db);
      repo.createInstance(_goInstance());
      final config = Config(environment: {'SANAD_HOME': home.path});
      runtime = AgentRuntimeService(config, repo, modelsDevService: catalog);
      assembler = ThinkingCapabilityAssembler(
        buildProviderThinkingRegistry(),
        config,
        catalog.modelEntrySync,
      );
      resolver = ThinkingSelectionResolver(
        instances: repo,
        cacheResolver: ThinkingControlCacheResolver(repo),
        assembler: assembler,
        registry: buildProviderThinkingRegistry(),
        config: config,
      );
    });

    tearDown(() {
      state.dispose();
      setSanadHomeOverride(null);
      if (home.existsSync()) home.deleteSync(recursive: true);
    });

    test('freezes the resolved api mode into RouteSignature', () {
      RouteSignature sig(String model) =>
          runtime.resolveSignature(providerId: goInstance, modelId: model);
      expect(sig(goResponsesModel).apiMode, 'codex_responses');
      expect(sig(goMessagesModel).apiMode, 'anthropic_messages');
      expect(sig(deepseek).apiMode, isNull);
      expect(sig(goResponsesModel), equals(sig(goResponsesModel)));

      final base = sig(goResponsesModel);
      final withoutMode = RouteSignature(
        providerInstanceId: base.providerInstanceId,
        templateId: base.templateId,
        protocol: base.protocol,
        normalizedBaseUrl: base.normalizedBaseUrl,
        modelId: base.modelId,
        configRevision: base.configRevision,
        credentialRevision: base.credentialRevision,
      );
      expect(base, isNot(equals(withoutMode)));
    });

    test('wire proof stays byte-stable for routes without an api mode', () {
      final chat = runtime.resolveSignature(
        providerId: goInstance,
        modelId: deepseek,
      );
      final measurement = WireInputMeasurement(
        estimatedTokens: 1,
        stableMaterialFingerprint: 'stable',
        inputItemFingerprints: const ['a'],
      );
      final legacy = sha256
          .convert(
            utf8.encode(
              jsonEncode({
                'v': RequestPressureEvaluator.wireProofVersion,
                'provider_instance_id': chat.providerInstanceId,
                'model_id': chat.modelId,
                'protocol': chat.protocol,
                'base_url': chat.normalizedBaseUrl,
                'stable': 'stable',
                'items': ['a'],
              }),
            ),
          )
          .toString();
      expect(
        RequestPressureEvaluator.wireProof(
          wireMeasurement: measurement,
          routeSignature: chat,
        ),
        '${RequestPressureEvaluator.wireProofVersion}:$legacy',
      );
    });

    test('thinking policy and models.dev wire follow the model route', () {
      final instance = _goInstance();
      ProviderInstance routed(String model) =>
          assembler.routeInstance(instance, model);
      String apiMode(String model) => ThinkingRoutePolicy.apiModeFor(
        routed(model),
        ThinkingRoutePolicy.resolveTemplate(routed(model)),
      );
      expect(apiMode(goResponsesModel), 'codex_responses');
      expect(apiMode(goMessagesModel), 'anthropic_messages');
      expect(apiMode(deepseek), 'chat_completions');
      expect(
        ModelsDevThinkingWire.forRoute(routed(goResponsesModel)),
        ModelsDevThinkingWire.responses,
      );
      expect(
        ModelsDevThinkingWire.forRoute(routed(goMessagesModel)),
        ModelsDevThinkingWire.messages,
      );
      expect(
        ModelsDevThinkingWire.forRoute(routed(deepseek)),
        ModelsDevThinkingWire.chat,
      );
      expect(identical(routed(deepseek), instance), isTrue);
    });

    test('a thinking selection resolves to the dispatched wire directive', () {
      final luna = resolver.resolve(
        providerInstanceId: goInstance,
        modelId: goResponsesModel,
        selectionId: 'high',
      );
      expect(luna.directive, isA<ResponsesReasoningDirective>());
      expect((luna.directive as ResponsesReasoningDirective).effort, 'high');

      final haiku = resolver.resolve(
        providerInstanceId: goInstance,
        modelId: goMessagesEffortModel,
        selectionId: 'high',
      );
      expect(haiku.directive, isA<AnthropicAdaptiveDirective>());

      // A bare toggle has no Messages-wire representation: no control is
      // invented and the turn keeps the provider default.
      final mini = resolver.resolve(
        providerInstanceId: goInstance,
        modelId: goMessagesModel,
        selectionId: 'on',
      );
      expect(mini.directive, isA<UseProviderDefault>());

      final chat = resolver.resolve(
        providerInstanceId: goInstance,
        modelId: deepseek,
        selectionId: 'high',
      );
      // Unchanged Chat route: the native partner Chat dialect, as before.
      expect(chat.directive, isA<NativeThinkingEffortDirective>());
    });
  });

  test('compaction persists and restores the route api mode', () {
    final state = AgentStateDatabase.inMemory();
    final sessions = SessionDB.fromState(state);
    addTearDown(() {
      sessions.dispose();
      state.dispose();
    });
    final revisions = SessionHistoryRevisionRepository(state);
    final boundaries = CompactionBoundaryRepository(state, revisions);
    final now = DateTime.utc(2026, 10, 21);
    sessions.saveSession(
      SessionState(
        sessionId: _session,
        model: goResponsesModel,
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages(_session, [
      Message(role: MessageRole.user, content: 'one'),
      Message(role: MessageRole.user, content: 'two'),
      Message(role: MessageRole.assistant, content: 'three'),
      Message(role: MessageRole.user, content: 'four'),
    ]);
    const route = RouteSignature(
      providerInstanceId: goInstance,
      templateId: 'opencode-go',
      protocol: ProviderProtocol.openaiCompatible,
      normalizedBaseUrl: goOpenAiApi,
      modelId: goResponsesModel,
      configRevision: 1,
      credentialRevision: 1,
      apiMode: 'codex_responses',
    );
    final source = CompactionMessageRange(
      start: const CompactionMessageIdentity(1),
      end: const CompactionMessageIdentity(2),
    );
    final tail = CompactionMessageRange(
      start: const CompactionMessageIdentity(3),
      end: const CompactionMessageIdentity(4),
    );
    final claim = boundaries.tryClaim(
      compactionId: 'cmp-go',
      sessionId: _session,
      trigger: CompactionTrigger.auto,
      sourceRange: source,
      retainedTailRange: tail,
      routeSignature: route,
      startedAt: now,
    );
    expect(claim.outcome, CompactionClaimOutcome.claimed);
    const summary = CompactionInternalSummary(
      currentGoal: 'Goal',
      remainingWork: 'Work',
    );
    final result = boundaries.completeStarted(
      candidate: CompactionCandidate(
        compactionId: 'cmp-go',
        sessionId: _session,
        trigger: CompactionTrigger.auto,
        sourceRevision: claim.record!.sourceHistoryRevision,
        sourceRange: source,
        retainedTailRange: tail,
        internalSummary: summary,
        continuityResult: CompactionContinuityResult.fromSummary(summary),
        metrics: CompactionMetrics(
          contextWindowTokens: 400_000,
          estimatedRequestTokensBefore: 320_000,
          estimatedRequestTokensAfter: 40_000,
          retainedTailTokens: 10_000,
        ),
        routeSignature: route,
      ),
      startedAt: now,
      completedAt: now.add(const Duration(minutes: 1)),
    );
    expect(result.outcome, CompactionTerminalOutcome.completed);
    expect(
      boundaries.findLatestCompletedForSession(_session)?.routeSignature,
      route,
    );
  });
}
