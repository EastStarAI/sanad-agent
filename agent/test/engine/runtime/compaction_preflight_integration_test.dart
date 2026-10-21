import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/provider_profile.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/evolution/compaction/compaction_activation_service.dart';
import 'package:sanad_agent/evolution/compaction/compaction_summary_projection.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

class _PreflightAdapter implements LLMAdapter, WireInputUsageMeasurer {
  final int contextLimit;
  final WireInputMeasurement? wireMeasurement;
  final WireInputMeasurement? Function(List<Message>)? wireMeasurementFor;

  _PreflightAdapter({
    this.contextLimit = 3_000,
    this.wireMeasurement,
    this.wireMeasurementFor,
  });

  @override
  Future<WireInputMeasurement?> measureInput(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async => wireMeasurementFor?.call(history) ?? wireMeasurement;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => contextLimit;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    throw UnsupportedError('not used');
  }

  @override
  Stream<AgentResponse> generateStream(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async* {
    throw UnsupportedError('not used');
  }
}

class _FakeRuntimeService extends AgentRuntimeService {
  _FakeRuntimeService(super.config, super.repo);

  LLMAdapter? turnAdapter;
  RouteSignature signature = const RouteSignature(
    providerInstanceId: 'provider-1',
    templateId: 'openai',
    protocol: 'openai_compatible',
    normalizedBaseUrl: 'https://api.example.com/v1',
    modelId: 'gpt-4o',
    configRevision: 1,
    credentialRevision: 1,
  );

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    return signature;
  }

  @override
  LLMAdapter adapterForTurn(
    RouteSignature signature, {
    required String sessionId,
    String? requestId,
    String? runId,
  }) =>
      turnAdapter ??
      super.adapterForTurn(
        signature,
        sessionId: sessionId,
        requestId: requestId,
        runId: runId,
      );
}

/// Minimal adapter without wire measurement: it deliberately implements only
/// [LLMAdapter] to stand in for routes whose adapter exposes no measurement
/// interface. Production `BaseOpenAIAdapter` does implement
/// `WireInputUsageMeasurer`/`WireInputTokenEstimator` since G11 R4, so these
/// fixtures exist to prove the no-measurer fail-closed path, not production
/// shape.
class _GenericOpenAiCompatibleAdapter implements LLMAdapter {
  _GenericOpenAiCompatibleAdapter({
    this.contextLimit = 358_000,
    this.responses = const [],
  });

  final int contextLimit;
  final List<AgentResponse> responses;
  int _calls = 0;

  @override
  Future<int> getContextLimit([String? modelOverride]) async => contextLimit;

  @override
  Future<List<ModelOption>> getAvailableModels() async => const [];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    if (_calls < responses.length) return responses[_calls++];
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'ok'),
    );
  }

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

/// Capability resolver that returns a fixed wire-visible thinking directive,
/// so a request-option change can be exercised against the wire proof without
/// a live provider route.
class _DirectiveDriftResolver extends RouteCapabilityResolver {
  _DirectiveDriftResolver();

  NativeThinkingDirective? directive;

  @override
  RouteCapabilityProfile resolveSync({
    required String providerInstanceId,
    required String modelId,
    String? thinkingMode,
    String? baseUrl,
  }) => RouteCapabilityProfile(
    providerInstanceId: providerInstanceId,
    modelId: modelId,
    imageSupport: RouteImageSupport.unknown,
    thinkingSelectionId: 'drift-selection',
    thinkingDirective: directive,
    evidenceSource: 'test',
  );
}

/// Minimal schema-bearing tool used to prove that a tool-schema change after
/// a restore invalidates the restored provider-usage baseline.
class _SchemaDriftProbeTool extends BaseTool {
  @override
  ToolSchema get schema => ToolSchema(
    name: 'schema_drift_probe',
    description: 'schema drift probe',
    parameters: const {'type': 'object', 'properties': <String, dynamic>{}},
  );

  @override
  Future<String> execute(Map<String, dynamic> args, {ToolContext? context}) async {
    return 'probe';
  }
}

class _FailingSummarizer implements CompactionSummarizer {
  @override
  Future<String> summarize({required String prompt}) {
    throw StateError('synthetic summarizer failure');
  }
}

class _CapturingProviderSummarizer
    implements CompactionSummarizer, ProviderProjectionCompactionSummarizer {
  CompactionProviderRequest? request;

  @override
  Future<String> summarize({required String prompt}) =>
      throw UnsupportedError('provider projection expected');

  @override
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  ) async {
    this.request = request;
    return const CompactionProviderResult(
      content:
          '{"schemaVersion":1,"currentGoal":"تشغيل الضغط","latestUserRequest":"الطلب الجاري الواجب تنفيذه","successCriteria":"success","constraints":"none","completedWork":"none","activeState":"working","criticalContext":"الطلب الجاري الواجب تنفيذه","decisions":"none","blockers":"none","filesAndPaths":"none","pendingAsks":"الطلب الجاري الواجب تنفيذه","remainingWork":"continue"}',
      usage: {'prompt_tokens': 1000, 'completion_tokens': 100},
      duration: Duration(milliseconds: 1),
    );
  }
}

void main() {
  late AgentStateDatabase state;
  late SessionManager sessionManager;
  late SessionDB sessions;
  late CompactionBoundaryRepository boundaries;
  late CompactionCoordinator coordinator;
  late AgentRunner runner;
  late Directory sanadHome;

  setUp(() async {
    sanadHome = Directory.systemTemp.createTempSync('compaction_preflight_');
    setSanadHomeOverride(sanadHome.path);
    await SanadHomeBootstrap.identity().prepare();
    getIt.allowReassignment = true;
    state = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(state);
    SessionManager.resetForTesting();
    sessionManager = SessionManager();
    sessions = sessionManager.db;
    boundaries = CompactionBoundaryRepository(
      state,
      SessionHistoryRevisionRepository(state),
    );
    final activation = CompactionActivationService(
      boundaries: boundaries,
      projectionRevisions: SessionProjectionRevisionRepository(state),
    );
    coordinator = CompactionCoordinator(
      engine: ContextCompactionEngine(
        summarizer: StructuredCompactionSummarizer(),
      ),
      boundaries: boundaries,
      activation: activation,
      projectionBuilder: ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ),
    );
    getIt.registerSingleton<CompactionCoordinator>(coordinator);
    getIt.registerSingleton<ModelProjectionBuilder>(
      ModelProjectionBuilder(sessions: sessions, boundaries: boundaries),
    );
    getIt.registerSingleton<SessionHistoryRevisionRepository>(
      SessionHistoryRevisionRepository(state),
    );
    getIt.registerSingleton<SessionProjectionRevisionRepository>(
      SessionProjectionRevisionRepository(state),
    );
    getIt.registerSingleton<ContextCompactionEngine>(
      ContextCompactionEngine(summarizer: StructuredCompactionSummarizer()),
    );
    final repo = ProviderInstanceRepository.fromDatabase(state.db);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    getIt.registerSingleton<ProviderRateLimiter>(ProviderRateLimiter());
    getIt.registerSingleton<RuntimeRecoveryService>(
      RuntimeRecoveryService(repo, getIt<ProviderRateLimiter>()),
    );
    getIt.registerSingleton<Config>(Config());
    getIt.registerSingleton<AgentRuntimeService>(
      _FakeRuntimeService(Config(), repo),
    );

    final now = DateTime.utc(2026, 8, 29);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-preflight',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages('session-preflight', [
      Message(
        role: MessageRole.user,
        content: 'goal: run preflight compaction',
      ),
      for (var i = 0; i < 60; i++)
        Message(role: MessageRole.user, content: 'filler $i ${'x' * 500}'),
    ]);

    runner = AgentRunner(
      _PreflightAdapter(),
      ToolsRegistry(),
      sessionManager,
      existingSessionId: 'session-preflight',
    );
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    await getIt.reset();
    state.dispose();
    setSanadHomeOverride(null);
    sanadHome.deleteSync(recursive: true);
  });

  test('preflight rebuilds provider history from activated projection', () async {
    final canonicalLength = runner.history.length;
    final revision = getIt<SessionHistoryRevisionRepository>().read(
      'session-preflight',
    )!;
    final timeline = getIt<ModelProjectionBuilder>().loadCanonicalTimeline(
      'session-preflight',
    );
    final outcome = await coordinator.runCompaction(
      request: CompactionEngineRequest(
        compactionId: 'cmp-preflight',
        sessionId: 'session-preflight',
        trigger: CompactionTrigger.auto,
        sourceRevision: revision.toCompactionRevision(),
        routeSignature: getIt<AgentRuntimeService>().resolveSignature(
          providerId: 'provider-1',
          modelId: 'gpt-4o',
        ),
        contextWindowTokens: 3_000,
        timeline: [
          for (final entry in timeline.messages)
            IndexedConversationMessage(
              rowId: entry.rowId,
              message: entry.message,
            ),
        ],
        systemPrompt: 'system',
        runtimeContext: '',
        toolSchemas: const [],
        targetRequestTokens: 2_000,
      ),
      force: true,
    );
    expect(outcome?.status, CompactionStatus.completed);
    expect(
      boundaries.findLatestCompletedForSession('session-preflight'),
      isNotNull,
    );

    final persistedAfterCompaction = sessions.getMessages('session-preflight');
    sessions.replaceMessages('session-preflight', [
      persistedAfterCompaction.first.copyWith(
        metadata: {
          ...?persistedAfterCompaction.first.metadata,
          'delivery_state': 'confirmed',
        },
      ),
      ...persistedAfterCompaction.skip(1),
      Message(
        role: MessageRole.user,
        content: 'small follow-up after compaction',
      ),
    ]);
    final history = await runner.debugPrepareProviderHistory();
    expect(
      boundaries.listCompletedForSession('session-preflight'),
      hasLength(1),
      reason:
          'an active compacted projection below the trigger must not compact again',
    );
    expect(history.where((m) => m.role == MessageRole.system), isNotEmpty);
    expect(history.length, lessThan(canonicalLength + 2));
    expect(
      history.any(
        (message) =>
            message.metadata?[CompactionSummaryProjection
                .projectionMetadataKey] ==
            true,
      ),
      isTrue,
    );
    expect(runner.history.length, canonicalLength);
  });

  test(
    'auto compaction seed includes the currently admitted user request',
    () async {
      sessions.replaceMessages('session-preflight', [
        Message(role: MessageRole.user, content: 'طلب سابق'),
        for (var index = 0; index < 500; index++) ...[
          Message(role: MessageRole.user, content: 'تفصيل $index'),
          Message(
            role: MessageRole.assistant,
            content: 'سياق كبير $index ${'x' * 1_000}',
          ),
        ],
        Message(role: MessageRole.user, content: 'الطلب الجاري الواجب تنفيذه'),
      ]);
      // Task 106 G7: the user's admitted thinking selection exists for the
      // auto path and must reach the compaction request unchanged.
      sessions.saveSession(
        SessionState(
          sessionId: 'session-preflight',
          model: 'gpt-4o',
          thinkingMode: 'high',
          createdAt: DateTime.utc(2026, 8, 29),
          updatedAt: DateTime.utc(2026, 8, 29),
          lastUserMessageAt: DateTime.utc(2026, 8, 29),
        ),
      );
      runner = AgentRunner(
        _PreflightAdapter(contextLimit: 3_000),
        ToolsRegistry(),
        sessionManager,
        existingSessionId: 'session-preflight',
      );
      final summarizer = _CapturingProviderSummarizer();
      getIt.registerSingleton<CompactionCoordinator>(
        CompactionCoordinator(
          engine: ContextCompactionEngine(summarizer: summarizer),
          boundaries: boundaries,
          activation: CompactionActivationService(
            boundaries: boundaries,
            projectionRevisions: getIt<SessionProjectionRevisionRepository>(),
          ),
          projectionBuilder: getIt<ModelProjectionBuilder>(),
        ),
      );

      await runner.debugPrepareProviderHistory();

      expect(
        summarizer.request,
        isNotNull,
        reason: boundaries
            .listLifecycleForSession('session-preflight')
            .map(
              (operation) => '${operation.status}:${operation.failureReason}',
            )
            .join(', '),
      );
      expect(
        summarizer.request!.baseProjection.last.content,
        'الطلب الجاري الواجب تنفيذه',
      );
      expect(
        summarizer.request!.appendedProjection.last.content,
        endsWith('return only the final JSON object.'),
      );
      // Task 106 G7: the auto path forwards canonical request options with the
      // exact user thinking selection, resolved route context, and correlation
      // id without any downgrade or substitution.
      final options = summarizer.request!.options;
      expect(options.sessionId, 'session-preflight');
      expect(options.providerInstanceId, 'provider-1');
      expect(options.requestId, startsWith('compaction:auto:'));
      expect(options.thinkingMode, 'high');
      expect(options.routeCapabilityProfile, isNotNull);
      expect(
        sessions.getSessionRecord('session-preflight')?.thinkingMode,
        'high',
      );
    },
  );

  test(
    'Task 118b D1: the manual seed carries the same instructions and tools as the ordinary request',
    () async {
      runner.registry.registerTools([_SchemaDriftProbeTool()]);
      const runtimeContext = 'workspace runtime context for the next request';
      final ordinary = await runner.debugPrepareProviderHistory(
        runtimeSystemPrompt: runtimeContext,
      );
      final seed = await runner.prepareCompactionProviderSeed(
        runtimeSystemPrompt: runtimeContext,
      );

      String instructions(List<Message> projection) => [
        for (final message in projection.takeWhile(
          (message) => message.role == MessageRole.system,
        ))
          message.content ?? '',
      ].join('\n');
      expect(instructions(seed.projection), instructions(ordinary));
      expect(instructions(seed.projection), contains(runtimeContext));
      expect(
        [for (final tool in seed.tools) tool.name],
        [for (final tool in runner.registry.allTools) tool.schema.name],
      );
    },
  );

  test('one failed auto compaction opens the per-run breaker', () async {
    sessions.replaceMessages('session-preflight', [
      Message(role: MessageRole.user, content: 'goal: exercise breaker'),
      for (var index = 0; index < 500; index++)
        Message(
          role: MessageRole.user,
          content: 'large request $index ${'x' * 1_000}',
        ),
    ]);
    // Task 106 G7: a rejected/failed auto compaction must never rewrite the
    // stored user thinking choice as error recovery.
    sessions.saveSession(
      SessionState(
        sessionId: 'session-preflight',
        model: 'gpt-4o',
        thinkingMode: 'high',
        createdAt: DateTime.utc(2026, 8, 29),
        updatedAt: DateTime.utc(2026, 8, 29),
        lastUserMessageAt: DateTime.utc(2026, 8, 29),
      ),
    );
    var startedEvents = 0;
    getIt.registerSingleton<CompactionCoordinator>(
      CompactionCoordinator(
        engine: ContextCompactionEngine(summarizer: _FailingSummarizer()),
        boundaries: boundaries,
        activation: CompactionActivationService(
          boundaries: boundaries,
          projectionRevisions: SessionProjectionRevisionRepository(state),
        ),
        projectionBuilder: getIt<ModelProjectionBuilder>(),
        onLifecycleEvent: (event) {
          if (event.status == CompactionStatus.started) startedEvents++;
        },
      ),
    );

    await runner.debugPrepareProviderHistory();
    expect(runner.debugLastPreflightPressure?.exceedsThreshold, isTrue);
    await runner.debugPrepareProviderHistory();

    expect(startedEvents, 1);
    expect(
      boundaries
          .listLifecycleForSession('session-preflight')
          .where((record) => record.status == CompactionStatus.failed),
      hasLength(1),
    );
    expect(
      sessions.getSessionRecord('session-preflight')?.thinkingMode,
      'high',
      reason: 'provider failure must not lower or clear the user choice',
    );
  });

  group('Task 118 item 2: overflow path respects the per-run breaker', () {
    const overflowError = LlmHttpException(
      statusCode: 400,
      body: 'maximum context length exceeded',
      headers: {},
      operation: 'chat.completions',
    );

    late int startedEvents;
    late List<CompactionTrigger> startedTriggers;

    void installFailingCoordinator() {
      startedEvents = 0;
      startedTriggers = [];
      getIt.registerSingleton<CompactionCoordinator>(
        CompactionCoordinator(
          engine: ContextCompactionEngine(summarizer: _FailingSummarizer()),
          boundaries: boundaries,
          activation: CompactionActivationService(
            boundaries: boundaries,
            projectionRevisions: SessionProjectionRevisionRepository(state),
          ),
          projectionBuilder: getIt<ModelProjectionBuilder>(),
          onLifecycleEvent: (event) {
            if (event.status == CompactionStatus.started) {
              startedEvents++;
              startedTriggers.add(event.trigger);
            }
          },
        ),
      );
    }

    setUp(() {
      sessions.replaceMessages('session-preflight', [
        Message(role: MessageRole.user, content: 'goal: exercise breaker'),
        for (var index = 0; index < 500; index++)
          Message(
            role: MessageRole.user,
            content: 'large request $index ${'x' * 1_000}',
          ),
      ]);
      runner = AgentRunner(
        _PreflightAdapter(),
        ToolsRegistry(),
        sessionManager,
        existingSessionId: 'session-preflight',
      );
      runner.beginAuthoritativeRun('run-breaker');
      installFailingCoordinator();
    });

    test(
      'a failed automatic compaction blocks overflow compaction in the same run',
      () async {
        await runner.debugPrepareProviderHistory();
        expect(startedTriggers, [CompactionTrigger.auto]);

        final recovered = await runner.debugTryOverflowCompactionRecovery(
          error: overflowError,
          providerInstanceId: 'provider-1',
          modelId: 'gpt-4o',
        );

        expect(recovered, isFalse);
        expect(
          startedTriggers,
          [CompactionTrigger.auto],
          reason: 'the open breaker must stop the overflow compaction attempt',
        );
        expect(
          boundaries
              .listLifecycleForSession('session-preflight')
              .where((record) => record.status == CompactionStatus.failed),
          hasLength(1),
        );
      },
    );

    test(
      'a failed overflow compaction opens the breaker for later auto steps',
      () async {
        final recovered = await runner.debugTryOverflowCompactionRecovery(
          error: overflowError,
          providerInstanceId: 'provider-1',
          modelId: 'gpt-4o',
        );
        expect(recovered, isFalse);
        expect(startedTriggers, [CompactionTrigger.overflow]);

        await runner.debugPrepareProviderHistory();

        expect(
          startedTriggers,
          [CompactionTrigger.overflow],
          reason: 'a later model step in the same run must not retry',
        );
      },
    );

    test('a new run closes the breaker again', () async {
      await runner.debugPrepareProviderHistory();
      expect(startedEvents, 1);

      runner.beginAuthoritativeRun('run-breaker-next');
      await runner.debugPrepareProviderHistory();

      expect(startedEvents, 2);
    });
  });

  test(
    'next preflight uses provider input baseline instead of full estimate',
    () async {
      final now = DateTime.utc(2026, 8, 31);
      sessions.saveSession(
        SessionState(
          sessionId: 'session-provider-baseline',
          providerId: 'provider-1',
          model: 'gpt-4o',
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      sessions.replaceMessages('session-provider-baseline', [
        Message(
          role: MessageRole.user,
          content: 'goal: preserve provider usage',
        ),
        for (var index = 0; index < 30; index++)
          Message(
            role: MessageRole.user,
            content: 'short estimated history $index ${'x' * 200}',
          ),
      ]);
      final usageRegistry = ToolsRegistry();
      // The route's adapter exposes no wire measurement, so the in-memory
      // provider-confirmed baseline is consumed through the legacy comparison.
      (getIt<AgentRuntimeService>() as _FakeRuntimeService).turnAdapter =
          _GenericOpenAiCompatibleAdapter(contextLimit: 128_000);
      final usageRunner = AgentRunner(
        _PreflightAdapter(contextLimit: 10_000),
        usageRegistry,
        sessionManager,
        existingSessionId: 'session-provider-baseline',
      );

      await usageRunner.debugPrepareProviderHistory();
      expect(
        boundaries.listCompletedForSession('session-provider-baseline'),
        isEmpty,
      );
      usageRunner.debugSetConfirmedInputUsageBaseline(
        ConfirmedInputUsageBaseline(
          routeSignature: getIt<AgentRuntimeService>().resolveSignature(
            providerId: 'provider-1',
            modelId: 'gpt-4o',
          ),
          inputTokens: 7_500,
          conversationMessages: const [],
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: usageRegistry.allTools
              .map((tool) => tool.schema.toJson())
              .toList(),
        ),
      );

      sessions.replaceMessages('session-provider-baseline', [
        ...sessions.getMessages('session-provider-baseline'),
        Message(role: MessageRole.user, content: 'small suffix'),
      ]);
      await usageRunner.debugPrepareProviderHistory();

      expect(
        usageRunner.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.mixed,
      );
      expect(
        usageRunner.debugLastPreflightPressure?.estimatedRequestTokens,
        greaterThan(7_000),
        reason:
            '7,500 provider-confirmed input tokens must drive admission even when the chars/4 estimate is small',
      );
    },
  );

  test(
    '65 percent provider usage plus a small wire suffix does not auto compact',
    () async {
      final now = DateTime.utc(2026, 8, 31);
      sessions.saveSession(
        SessionState(
          sessionId: 'session-provider-priority',
          providerId: 'provider-1',
          model: 'gpt-4o',
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      sessions.replaceMessages('session-provider-priority', [
        Message(role: MessageRole.user, content: 'large canonical history'),
        Message(role: MessageRole.tool, content: 'small new result'),
      ]);
      final nextWire = WireInputMeasurement(
        estimatedTokens: 99_000,
        stableMaterialFingerprint: 'stable-wire-material',
        inputItemFingerprints: ['measured-prefix', 'small-tool-suffix'],
      );
      final usageRegistry = ToolsRegistry();
      // The turn adapter must be the measurer that owns [nextWire]; otherwise
      // the preflight remeasures different wire material than the baseline
      // extension this fixture asserts.
      final preflightAdapter = _PreflightAdapter(
        contextLimit: 400_000,
        wireMeasurement: nextWire,
      );
      (getIt<AgentRuntimeService>() as _FakeRuntimeService).turnAdapter =
          preflightAdapter;
      final usageRunner = AgentRunner(
        preflightAdapter,
        usageRegistry,
        sessionManager,
        existingSessionId: 'session-provider-priority',
      );
      usageRunner.debugSetConfirmedInputUsageBaseline(
        ConfirmedInputUsageBaseline(
          routeSignature: getIt<AgentRuntimeService>().resolveSignature(
            providerId: 'provider-1',
            modelId: 'gpt-4o',
          ),
          inputTokens: 83_200,
          conversationMessages: const [],
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: usageRegistry.allTools
              .map((tool) => tool.schema.toJson())
              .toList(),
          wireMeasurement: WireInputMeasurement(
            estimatedTokens: 98_500,
            stableMaterialFingerprint: 'stable-wire-material',
            inputItemFingerprints: ['measured-prefix'],
          ),
        ),
      );

      await usageRunner.debugPrepareProviderHistory();
      expect(usageRunner.debugConfirmedInputUsageBaseline?.inputTokens, 83_200);
      expect(
        usageRunner.debugLastPreflightPressure?.estimatedRequestTokens,
        lessThan(98_304),
      );
      expect(
        usageRunner.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.mixed,
      );
      expect(
        boundaries.listCompletedForSession('session-provider-priority'),
        isEmpty,
      );
    },
  );

  test(
    'restores provider usage from persisted assistant metadata after restart',
    () async {
      final now = DateTime.utc(2026, 8, 31);
      sessions.saveSession(
        SessionState(
          sessionId: 'session-restored-provider-priority',
          providerId: 'provider-1',
          model: 'gpt-4o',
          createdAt: now,
          updatedAt: now,
          lastUserMessageAt: now,
        ),
      );
      final prefixMeasurement = WireInputMeasurement(
        estimatedTokens: 98_500,
        stableMaterialFingerprint: 'stable-wire-material',
        inputItemFingerprints: ['measured-prefix'],
      );
      final signature = RouteSignature(
        providerInstanceId: 'provider-1',
        templateId: 'openai',
        protocol: 'openai_compatible',
        normalizedBaseUrl: 'https://api.example.com/v1',
        modelId: 'gpt-4o',
        configRevision: 1,
        credentialRevision: 1,
      );
      final wireProof = RequestPressureEvaluator.wireProof(
        wireMeasurement: prefixMeasurement,
        routeSignature: signature,
      );
      sessions.replaceMessages('session-restored-provider-priority', [
        Message(role: MessageRole.user, content: 'measured prefix'),
        Message(
          role: MessageRole.assistant,
          content: 'provider-confirmed response',
          metadata: {
            'model': 'gpt-4o',
            'provider': 'openai',
            'usage': {'input_tokens': 83_200},
            'context_usage': {
              'input_tokens': 83_200,
              'provider_instance_id': 'provider-1',
              'model_id': 'gpt-4o',
              'wire_proof': wireProof,
            },
          },
        ),
        Message(role: MessageRole.user, content: 'small resumed suffix'),
      ]);
      final usageRegistry = ToolsRegistry();
      final preflightAdapter = _PreflightAdapter(
        contextLimit: 400_000,
        wireMeasurementFor: (history) {
          final includesConfirmedResponse = history.any(
            (message) => message.content == 'provider-confirmed response',
          );
          return WireInputMeasurement(
            estimatedTokens: includesConfirmedResponse ? 99_000 : 98_500,
            stableMaterialFingerprint: 'stable-wire-material',
            inputItemFingerprints: includesConfirmedResponse
                ? const ['measured-prefix', 'small-resumed-suffix']
                : const ['measured-prefix'],
          );
        },
      );
      (getIt<AgentRuntimeService>() as _FakeRuntimeService).turnAdapter =
          preflightAdapter;
      final usageRunner = AgentRunner(
        preflightAdapter,
        usageRegistry,
        sessionManager,
        existingSessionId: 'session-restored-provider-priority',
      );

      final prepared = await usageRunner.debugPrepareProviderHistory();

      expect(
        prepared.any(
          (message) => message.content == 'provider-confirmed response',
        ),
        isTrue,
      );
      expect(usageRunner.debugConfirmedInputUsageBaseline?.inputTokens, 83_200);
      expect(
        usageRunner.debugLastPreflightPressure?.estimatedRequestTokens,
        83_700,
      );
      expect(
        usageRunner.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.mixed,
      );
      expect(
        boundaries.listCompletedForSession(
          'session-restored-provider-priority',
        ),
        isEmpty,
      );
    },
  );

  test('does not restore persisted usage from a different route', () async {
    final now = DateTime.utc(2026, 8, 31);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-stale-provider-usage',
        providerId: 'provider-1',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages('session-stale-provider-usage', [
      Message(role: MessageRole.user, content: 'old route prefix'),
      Message(
        role: MessageRole.assistant,
        content: 'old route response',
        metadata: {
          'model': 'gpt-4o',
          'provider': 'different-provider',
          'usage': {'input_tokens': 83_200},
        },
      ),
      Message(role: MessageRole.user, content: 'new route suffix'),
    ]);
    final preflightAdapter = _PreflightAdapter(
      contextLimit: 400_000,
      wireMeasurement: WireInputMeasurement(
        estimatedTokens: 90_000,
        stableMaterialFingerprint: 'new-route-material',
        inputItemFingerprints: const ['new-route-request'],
      ),
    );
    (getIt<AgentRuntimeService>() as _FakeRuntimeService).turnAdapter =
        preflightAdapter;
    final usageRunner = AgentRunner(
      preflightAdapter,
      ToolsRegistry(),
      sessionManager,
      existingSessionId: 'session-stale-provider-usage',
    );

    await usageRunner.debugPrepareProviderHistory();

    expect(usageRunner.debugConfirmedInputUsageBaseline, isNull);
    expect(
      usageRunner.debugLastPreflightPressure?.measurementKind,
      CompactionMeasurementKind.estimated,
    );
  });

  group('Generic OpenAI-compatible route (G11 R2 receipts)', () {
    const routeProvider = 'opencode-go';
    const routeModel = 'deepseek-v4.1-flash';

    /// Canonical aggregate from the reviewer-session receipt:
    /// 219 assistant rows / 9698 visible characters / 492742 reasoning
    /// characters, 234 tool rows / 673218 characters, 3 user rows / 3125
    /// characters. The reasoning metadata must never be priced, which is why
    /// the character estimate stays far below the confirmed `371839` input.
    List<Message> receiptHistory({Map<String, dynamic>? confirmedMetadata}) {
      final messages = <Message>[
        Message(role: MessageRole.user, content: 'goal ${'u' * 995}'),
        Message(role: MessageRole.user, content: 'v' * 1000),
        Message(role: MessageRole.user, content: 'w' * 1125),
      ];
      for (var index = 0; index < 234; index++) {
        final callId = 'call_step_$index';
        messages.add(
          Message(
            role: MessageRole.assistant,
            content: 'assistant step $index ${'a' * 20}',
            toolCalls: [
              ToolCall(
                id: callId,
                name: 'read_file',
                arguments: const {'path': 'fixture.txt'},
              ),
            ],
            metadata: {'reasoning': 'z' * 2095},
          ),
        );
        messages.add(
          Message(
            role: MessageRole.tool,
            content: 'r' * 2877,
            toolCallId: callId,
          ),
        );
      }
      messages.add(
        Message(
          role: MessageRole.assistant,
          content: 'latest assistant step',
          metadata: confirmedMetadata,
        ),
      );
      return messages;
    }

    Map<String, dynamic> confirmedMetadata({
      required int contextUsageInput,
      int? genericUsageInput,
    }) => {
      'provider': routeProvider,
      'model': routeModel,
      if (genericUsageInput != null) 'usage': {'input_tokens': genericUsageInput},
      'context_usage': {
        'input_tokens': contextUsageInput,
        'output_tokens': 282,
        'total_tokens': contextUsageInput + 282,
        'context_window_tokens': 358000,
        'provider_instance_id': routeProvider,
        'model_id': routeModel,
      },
    };

    AgentRunner openAiRunner({
      required String sessionId,
      http.Client? client,
      int contextLimit = 358_000,
      String model = routeModel,
      String providerId = routeProvider,
    }) {
      final adapter = BaseOpenAIAdapter(
        getIt<Config>(),
        const ProviderProfile(
          name: 'openai',
          displayName: 'OpenAI',
          defaultBaseUrl: 'https://opencode.invalid/v1',
        ),
        client: client ??
            MockClient(
              (_) async => http.Response(
                'data: {"choices":[{"delta":{"content":"ok"}}]}\n\ndata: [DONE]\n\n',
                200,
                headers: {'content-type': 'text/event-stream'},
              ),
            ),
        baseUrlOverride: 'https://opencode.invalid/v1',
        apiKeyOverride: 'test-key',
        defaultModelOverride: model,
        providerInstanceId: providerId,
        modelContextLimitLookup: (_) => contextLimit,
      );
      (getIt<AgentRuntimeService>() as _FakeRuntimeService)
        ..turnAdapter = adapter
        ..signature = RouteSignature(
          providerInstanceId: providerId,
          templateId: 'openai',
          protocol: 'openai_compatible',
          normalizedBaseUrl: 'https://opencode.invalid/v1',
          modelId: model,
          configRevision: 1,
          credentialRevision: 1,
        );
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          providerId: providerId,
          model: model,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      return AgentRunner(
        adapter,
        ToolsRegistry(),
        sessionManager,
        existingSessionId: sessionId,
      );
    }

    AgentRunner genericRunner({
      required String sessionId,
      required List<AgentResponse> responses,
      String providerId = routeProvider,
      String model = routeModel,
    }) {
      final adapter = _GenericOpenAiCompatibleAdapter(
        contextLimit: 358_000,
        responses: responses,
      );
      (getIt<AgentRuntimeService>() as _FakeRuntimeService)
        ..turnAdapter = adapter
        ..signature = RouteSignature(
          providerInstanceId: providerId,
          templateId: 'openai',
          protocol: 'openai_compatible',
          normalizedBaseUrl: 'https://opencode.invalid/v1',
          modelId: model,
          configRevision: 1,
          credentialRevision: 1,
        );
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          providerId: providerId,
          model: model,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      return AgentRunner(
        adapter,
        ToolsRegistry(),
        sessionManager,
        existingSessionId: sessionId,
      );
    }

    /// Binds the newest assistant row to a versioned wire proof in
    /// `context_usage`, mirroring what the live producer persists.
    List<Message> bindNewestAssistantRowWithProof({
      required List<Message> history,
      required String wireProof,
    }) {
      final bound = history.toList();
      final index = bound.lastIndexWhere(
        (message) => message.role == MessageRole.assistant,
      );
      final message = bound[index];
      final metadata = Map<String, dynamic>.from(message.metadata ?? const {});
      final contextUsage = Map<String, dynamic>.from(
        metadata['context_usage'] as Map? ?? const {},
      );
      contextUsage['wire_proof'] = wireProof;
      metadata['context_usage'] = contextUsage;
      bound[index] = message.copyWith(metadata: metadata);
      return bound;
    }

    /// Prepares history and computes the expected wire proof for the historical
    /// prefix preceding the newest assistant row.
    Future<String> wireProofForAssistantRow(
      AgentRunner runner, {
      String? runtimeSystemPrompt,
    }) async {
      final material = await runner.debugPrepareProviderHistory(
        runtimeSystemPrompt: runtimeSystemPrompt,
      );
      final assistantIndex = material.lastIndexWhere(
        (m) => m.role == MessageRole.assistant,
      );
      final measured = assistantIndex >= 0
          ? material.sublist(0, assistantIndex)
          : material;
      final measurer = runner.adapter as WireInputUsageMeasurer;
      final routing = (getIt<AgentRuntimeService>() as _FakeRuntimeService)
          .resolveSignature(providerId: routeProvider, modelId: routeModel);
      final measurement = await measurer.measureInput(
        measured,
        tools: runner.registry.allTools.map((t) => t.schema).toList(),
        modelOverride: routeModel,
        options: runner.debugRequestOptionsForTurn(routeProvider),
      );
      return RequestPressureEvaluator.wireProof(
        wireMeasurement: measurement!,
        routeSignature: routing,
      );
    }

    test('BaseOpenAIAdapter implements WireInputUsageMeasurer and WireInputTokenEstimator', () async {
      final adapter = BaseOpenAIAdapter(
        getIt<Config>(),
        const ProviderProfile(
          name: 'openai',
          displayName: 'OpenAI',
          defaultBaseUrl: 'https://opencode.invalid/v1',
        ),
        baseUrlOverride: 'https://opencode.invalid/v1',
        apiKeyOverride: 'test-key',
        defaultModelOverride: routeModel,
        providerInstanceId: routeProvider,
        modelContextLimitLookup: (_) => 358_000,
      );

      expect(adapter, isA<WireInputUsageMeasurer>());
      expect(adapter, isA<WireInputTokenEstimator>());

      final messages = [
        Message(role: MessageRole.system, content: 'You are an agent'),
        Message(role: MessageRole.user, content: 'List files'),
      ];
      final tools = [
        ToolSchema(
          name: 'list_files',
          description: 'lists files',
          parameters: const {'type': 'object'},
        ),
      ];

      final measurement = await adapter.measureInput(
        messages,
        tools: tools,
        modelOverride: routeModel,
      );
      expect(measurement, isNotNull);
      expect(measurement!.estimatedTokens, greaterThan(0));
      expect(measurement.inputItemFingerprints.length, messages.length);
      expect(measurement.stableMaterialFingerprint, isNotEmpty);

      final tokens = await adapter.estimateInputTokens(
        messages,
        tools: tools,
        modelOverride: routeModel,
      );
      expect(tokens, measurement.estimatedTokens);

      // Verify opaque state excluded from wire estimation
      final opaquePayload = {
        'model': routeModel,
        'messages': [
          {'role': 'user', 'content': 'hello'},
        ],
        'encrypted_content': 'x' * 100000,
      };
      final estimatedWithOpaque = CompactionTokenEstimator.estimateWirePayload(
        opaquePayload,
        opaqueKeys: const {'encrypted_content'},
      );
      final estimatedWithoutOpaque = CompactionTokenEstimator.estimateWirePayload(
        {
          'model': routeModel,
          'messages': [
            {'role': 'user', 'content': 'hello'},
          ],
        },
      );
      expect(estimatedWithOpaque, estimatedWithoutOpaque);
    });

    test('wire proof binds complete ordered wire items, stable material and route signature', () {
      final measurementA = WireInputMeasurement(
        estimatedTokens: 100,
        stableMaterialFingerprint: 'stable-mat-1',
        inputItemFingerprints: ['item-1', 'item-2'],
      );
      final measurementB = WireInputMeasurement(
        estimatedTokens: 100,
        stableMaterialFingerprint: 'stable-mat-1',
        inputItemFingerprints: ['item-2', 'item-1'], // order changed
      );
      final measurementC = WireInputMeasurement(
        estimatedTokens: 100,
        stableMaterialFingerprint: 'stable-mat-2', // material changed
        inputItemFingerprints: ['item-1', 'item-2'],
      );
      final routeA = RouteSignature(
        providerInstanceId: 'provider-1',
        templateId: 'openai',
        protocol: 'openai_compatible',
        normalizedBaseUrl: 'https://api.example.com/v1',
        modelId: 'gpt-4o',
        configRevision: 1,
        credentialRevision: 1,
      );
      final routeB = RouteSignature(
        providerInstanceId: 'provider-1',
        templateId: 'openai',
        protocol: 'openai_compatible',
        normalizedBaseUrl: 'https://api.example.com/v1',
        modelId: 'gpt-4o-mini', // model changed
        configRevision: 1,
        credentialRevision: 1,
      );

      final proofA = RequestPressureEvaluator.wireProof(
        wireMeasurement: measurementA,
        routeSignature: routeA,
      );
      expect(proofA, startsWith('v1:'));
      expect(RequestPressureEvaluator.isValidWireProof(proofA), isTrue);
      expect(RequestPressureEvaluator.isValidWireProof('invalid'), isFalse);
      expect(RequestPressureEvaluator.isValidWireProof('v2:${'a' * 64}'), isFalse);
      expect(RequestPressureEvaluator.isValidWireProof('v1:short'), isFalse);

      final proofB = RequestPressureEvaluator.wireProof(
        wireMeasurement: measurementB,
        routeSignature: routeA,
      );
      expect(proofB, isNot(proofA), reason: 'item order affects wire proof');

      final proofC = RequestPressureEvaluator.wireProof(
        wireMeasurement: measurementC,
        routeSignature: routeA,
      );
      expect(proofC, isNot(proofA), reason: 'stable material affects wire proof');

      final proofRouteB = RequestPressureEvaluator.wireProof(
        wireMeasurement: measurementA,
        routeSignature: routeB,
      );
      expect(proofRouteB, isNot(proofA), reason: 'route changes affect wire proof');
    });

    test(
      'a legacy row without a persisted wire_proof never becomes a floor',
      () async {
        const sessionId = 'session-generic-legacy-unbound';
        sessions.saveSession(
          SessionState(
            sessionId: sessionId,
            providerId: routeProvider,
            model: routeModel,
            thinkingMode: 'max',
            createdAt: DateTime.utc(2026, 10, 18),
            updatedAt: DateTime.utc(2026, 10, 18),
            lastUserMessageAt: DateTime.utc(2026, 10, 18),
          ),
        );
        sessions.replaceMessages(
          sessionId,
          [
            ...receiptHistory(
              confirmedMetadata: confirmedMetadata(
                contextUsageInput: 371_839,
                genericUsageInput: 92_337,
              ),
            ),
            Message(role: MessageRole.tool, content: 'trailing tool output'),
            Message(role: MessageRole.user, content: 'continue the review'),
          ],
        );
        final runner = openAiRunner(sessionId: sessionId);

        await runner.debugPrepareProviderHistory();

        expect(
          runner.debugConfirmedInputUsageBaseline,
          isNull,
          reason:
              'usage recorded without a wire_proof is unproven and '
              'must never be reused as a baseline',
        );
        expect(
          runner.debugLastPreflightPressure?.measurementKind,
          CompactionMeasurementKind.estimated,
        );
        expect(
          runner.debugLastPreflightPressure?.confirmedInputTokens,
          isNull,
        );
        expect(
          runner.debugLastPreflightPressure?.exceedsThreshold,
          isFalse,
          reason:
              'the unproven legacy row must not trigger automatic compaction',
        );
      },
    );

    test(
      'an adapter lacking WireInputUsageMeasurer fails closed even if wire_proof is present',
      () async {
        const sessionId = 'session-generic-no-measurer';
        sessions.saveSession(
          SessionState(
            sessionId: sessionId,
            providerId: routeProvider,
            model: routeModel,
            thinkingMode: 'max',
            createdAt: DateTime.utc(2026, 10, 18),
            updatedAt: DateTime.utc(2026, 10, 18),
            lastUserMessageAt: DateTime.utc(2026, 10, 18),
          ),
        );
        sessions.replaceMessages(sessionId, [
          ...receiptHistory(
            confirmedMetadata: {
              'provider': routeProvider,
              'model': routeModel,
              'context_usage': {
                'input_tokens': 371_839,
                'provider_instance_id': routeProvider,
                'model_id': routeModel,
                'wire_proof': 'v1:${'a' * 64}',
              },
            },
          ),
          Message(role: MessageRole.tool, content: 'trailing tool output'),
          Message(role: MessageRole.user, content: 'continue the review'),
        ]);
        final runner = genericRunner(
          sessionId: sessionId,
          responses: const [],
        );

        await runner.debugPrepareProviderHistory();

        expect(
          runner.debugConfirmedInputUsageBaseline,
          isNull,
          reason: 'adapters without WireInputUsageMeasurer must fail closed',
        );
        expect(
          runner.debugLastPreflightPressure?.measurementKind,
          CompactionMeasurementKind.estimated,
        );
        expect(
          runner.debugLastPreflightPressure?.confirmedInputTokens,
          isNull,
        );
      },
    );

    test(
      'producer, persistence and restore preserve a bound confirmed baseline (cached input remains input)',
      () async {
        const sessionId = 'session-generic-producer-chain';
        final summarizer = _CapturingProviderSummarizer();
        getIt.registerSingleton<CompactionCoordinator>(
          CompactionCoordinator(
            engine: ContextCompactionEngine(summarizer: summarizer),
            boundaries: boundaries,
            activation: CompactionActivationService(
              boundaries: boundaries,
              projectionRevisions: getIt<SessionProjectionRevisionRepository>(),
            ),
            projectionBuilder: getIt<ModelProjectionBuilder>(),
          ),
        );
        final client = MockClient((request) async {
          final sseData = [
            'data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":"acknowledged"},"finish_reason":null}]}',
            '',
            'data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":371839,"completion_tokens":20,"total_tokens":371859,"prompt_tokens_details":{"cached_tokens":370816}}}',
            '',
            'data: [DONE]',
            '',
          ].join('\n\n');
          return http.Response(
            sseData,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        });
        final producer = openAiRunner(
          sessionId: sessionId,
          client: client,
        );

        await producer
            .streamMessage(
              'continue the review',
              providerId: routeProvider,
              model: routeModel,
            )
            .toList();

        final snapshot = await producer.getContextUsageSnapshot();
        expect(
          snapshot,
          isNotNull,
          reason: 'the producer must project a context-usage snapshot',
        );
        expect(snapshot!['input_tokens'], 371_839);
        expect(
          snapshot['cached_tokens'],
          370_816,
          reason: 'the snapshot must carry the cached share, not a discount',
        );
        expect(
          snapshot['wire_proof'],
          isNotNull,
          reason:
              'the actual producer must bind its confirmed usage to the '
              'request wire material it measured',
        );
        expect(
          RequestPressureEvaluator.isValidWireProof(
            snapshot['wire_proof']?.toString(),
          ),
          isTrue,
        );

        // Commit snapshot to the assistant row as SessionTurnExecutor does
        producer.attachMetadataToLastAssistantMessage({
          'provider': routeProvider,
          'model': routeModel,
          'context_usage': snapshot,
        });

        final restarted = openAiRunner(
          sessionId: sessionId,
          client: client,
        );

        await restarted.debugPrepareProviderHistory();

        expect(
          restarted.debugConfirmedInputUsageBaseline?.inputTokens,
          371_839,
          reason:
              'the bound persisted usage must restore as a confirmed baseline',
        );
        expect(
          restarted.debugLastPreflightPressure?.confirmedInputTokens,
          371_839,
        );
        expect(
          restarted.debugLastPreflightPressure?.estimatedRequestTokens,
          greaterThanOrEqualTo(371_839),
          reason:
              'the full confirmed input decides admission, including the '
              '370816 cached tokens',
        );
        expect(
          restarted.debugLastPreflightPressure?.exceedsThreshold,
          isTrue,
        );
        expect(
          summarizer.request,
          isNotNull,
          reason: boundaries
              .listLifecycleForSession(sessionId)
              .map((operation) => '${operation.status}:${operation.failureReason}')
              .join(', '),
        );
        expect(
          boundaries.listLifecycleForSession(sessionId),
          isNotEmpty,
          reason: 'a durable automatic compaction attempt must be recorded',
        );
        expect(
          sessions.getSessionRecord(sessionId)?.thinkingMode,
          'max',
          reason: 'automatic compaction must not change the stored choice',
        );
      },
    );

    test(
      'Task 118 Stage3B: after a completed compaction and a restart the pre-boundary receipt is not restored and does not repeat compaction',
      () async {
        const sessionId = 'session-generic-post-boundary-restart';
        final summarizer = _CapturingProviderSummarizer();
        getIt.registerSingleton<CompactionCoordinator>(
          CompactionCoordinator(
            engine: ContextCompactionEngine(summarizer: summarizer),
            boundaries: boundaries,
            activation: CompactionActivationService(
              boundaries: boundaries,
              projectionRevisions: getIt<SessionProjectionRevisionRepository>(),
            ),
            projectionBuilder: getIt<ModelProjectionBuilder>(),
          ),
        );
        final client = MockClient((request) async {
          final sseData = [
            'data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":"acknowledged"},"finish_reason":null}]}',
            '',
            'data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":371839,"completion_tokens":20,"total_tokens":371859,"prompt_tokens_details":{"cached_tokens":370816}}}',
            '',
            'data: [DONE]',
            '',
          ].join('\n\n');
          return http.Response(
            sseData,
            200,
            headers: {'content-type': 'text/event-stream'},
          );
        });
        // A multi-turn conversation, so the compaction has a head to replace.
        openAiRunner(sessionId: sessionId, client: client);
        sessions.replaceMessages(sessionId, [
          for (var turn = 0; turn < 6; turn++) ...[
            Message(role: MessageRole.user, content: 'earlier ask $turn ${'q' * 400}'),
            Message(role: MessageRole.assistant, content: 'earlier answer $turn ${'a' * 400}'),
          ],
        ]);
        final producer = openAiRunner(sessionId: sessionId, client: client);
        await producer
            .streamMessage(
              'continue the review',
              providerId: routeProvider,
              model: routeModel,
            )
            .toList();
        producer.attachMetadataToLastAssistantMessage({
          'provider': routeProvider,
          'model': routeModel,
          'context_usage': (await producer.getContextUsageSnapshot())!,
        });

        // Restart 1: the proven 371839 receipt is genuine pressure and
        // compacts once.
        final first = openAiRunner(sessionId: sessionId, client: client);
        await first.debugPrepareProviderHistory();
        final afterFirst = boundaries.listLifecycleForSession(sessionId);
        expect(afterFirst, hasLength(1));
        expect(afterFirst.single.status, CompactionStatus.completed);

        // Restart 2, before any post-boundary turn: the newest retained row
        // still carries the receipt measured on the pre-compaction request.
        // Its wire proof cannot match the summary projection, so it is not
        // restored and the small projection does not compact again.
        final second = openAiRunner(sessionId: sessionId, client: client);
        await second.debugPrepareProviderHistory();
        expect(second.debugConfirmedInputUsageBaseline, isNull);
        expect(
          second.debugLastPreflightPressure?.measurementKind,
          CompactionMeasurementKind.estimated,
        );
        expect(second.debugLastPreflightPressure?.exceedsThreshold, isFalse);
        expect(boundaries.listLifecycleForSession(sessionId), hasLength(1));
      },
    );

    test('warm live confirmed input is used for generic-route admission', () async {
      const sessionId = 'session-generic-warm';
      final client = MockClient((request) async {
        final sseData = [
          'data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{"role":"assistant","content":"acknowledged"},"finish_reason":null}]}',
          '',
          'data: {"id":"chatcmpl-1","choices":[{"index":0,"delta":{},"finish_reason":"stop"}],"usage":{"prompt_tokens":371839,"completion_tokens":20,"total_tokens":371859,"prompt_tokens_details":{"cached_tokens":370816}}}',
          '',
          'data: [DONE]',
          '',
        ].join('\n\n');
        return http.Response(
          sseData,
          200,
          headers: {'content-type': 'text/event-stream'},
        );
      });
      final runner = openAiRunner(
        sessionId: sessionId,
        client: client,
      );

      await runner
          .streamMessage(
            'continue the review',
            providerId: routeProvider,
            model: routeModel,
          )
          .toList();

      expect(
        runner.debugConfirmedInputUsageBaseline?.inputTokens,
        371_839,
        reason: 'the live provider-confirmed input must become the baseline',
      );
      await runner.debugPrepareProviderHistory();
      expect(
        runner.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.mixed,
      );
      expect(
        runner.debugLastPreflightPressure?.estimatedRequestTokens,
        greaterThanOrEqualTo(371_839),
      );
      expect(
        runner.debugLastPreflightPressure?.exceedsThreshold,
        isTrue,
      );
    });


    test(
      'an unbound legacy receipt is not restored after an active boundary',
      () async {
        const sessionId = 'session-generic-pre-boundary';
        getIt.registerSingleton<CompactionCoordinator>(
          CompactionCoordinator(
            engine: ContextCompactionEngine(
              summarizer: StructuredCompactionSummarizer(),
            ),
            boundaries: boundaries,
            activation: CompactionActivationService(
              boundaries: boundaries,
              projectionRevisions: getIt<SessionProjectionRevisionRepository>(),
            ),
            projectionBuilder: getIt<ModelProjectionBuilder>(),
          ),
        );
        genericRunner(sessionId: sessionId, responses: const []);
        sessions.replaceMessages(sessionId, [
          ...receiptHistory(),
          Message(
            role: MessageRole.user,
            content: 'الطلب الجاري الواجب تنفيذه',
          ),
        ]);
        final revision = getIt<SessionHistoryRevisionRepository>().read(
          sessionId,
        )!;
        final timeline = getIt<ModelProjectionBuilder>().loadCanonicalTimeline(
          sessionId,
        );
        final outcome = await getIt<CompactionCoordinator>().runCompaction(
          request: CompactionEngineRequest(
            compactionId: 'cmp-pre-boundary',
            sessionId: sessionId,
            trigger: CompactionTrigger.auto,
            sourceRevision: revision.toCompactionRevision(),
            routeSignature: getIt<AgentRuntimeService>().resolveSignature(
              providerId: routeProvider,
              modelId: routeModel,
            ),
            contextWindowTokens: 358_000,
            timeline: [
              for (final entry in timeline.messages)
                IndexedConversationMessage(
                  rowId: entry.rowId,
                  message: entry.message,
                ),
            ],
            systemPrompt: 'system',
            runtimeContext: '',
            toolSchemas: const [],
            targetRequestTokens: 35_288,
          ),
          force: true,
        );
        expect(
          outcome?.status,
          CompactionStatus.completed,
          reason: boundaries
              .listLifecycleForSession(sessionId)
              .map(
                (operation) =>
                    '${operation.status}:${operation.failureReason}:${operation.failureStage}',
              )
              .join(', '),
        );
        expect(boundaries.findLatestCompletedForSession(sessionId), isNotNull);
        expect(
          getIt<ModelProjectionBuilder>().buildForSession(sessionId).activeBoundary,
          isNotNull,
          reason: 'a completed compaction must activate the projection boundary',
        );

        // A provider-confirmed row recorded before the boundary was activated
        // measures the pre-compaction request base, so it must not become the
        // prospective baseline for the projected request. Under the wire-proof
        // gate that stale material is discarded by proof mismatch; this fixture
        // exercises the no-proof/no-measurer half of the fail-closed rule.
        sessions.replaceMessages(sessionId, [
          ...sessions.getMessages(sessionId),
          ...receiptHistory(
            confirmedMetadata: {
              'provider': routeProvider,
              'model': routeModel,
              'context_usage': {
                'input_tokens': 371_839,
                'context_window_tokens': 358_000,
                'provider_instance_id': routeProvider,
                'model_id': routeModel,
                'observed_at': DateTime.utc(2020).toIso8601String(),
              },
            },
          ),
          Message(role: MessageRole.tool, content: 'trailing tool output'),
          Message(role: MessageRole.user, content: 'continue the review'),
        ]);
        final runner = genericRunner(sessionId: sessionId, responses: const []);

        await runner.debugPrepareProviderHistory();

        expect(
          getIt<ModelProjectionBuilder>()
              .buildForSession(sessionId)
              .activeBoundary,
          isNotNull,
          reason: 'the fixture must keep an active compaction boundary',
        );
        expect(runner.debugConfirmedInputUsageBaseline, isNull);
        expect(
          runner.debugLastPreflightPressure?.measurementKind,
          CompactionMeasurementKind.estimated,
        );
      },
    );

    test(
      'a foreign-route confirmed input is never carried onto the generic route',
      () async {
        const sessionId = 'session-generic-foreign';
        sessions.saveSession(
          SessionState(
            sessionId: sessionId,
            providerId: routeProvider,
            model: routeModel,
            thinkingMode: 'max',
            createdAt: DateTime.utc(2026, 10, 18),
            updatedAt: DateTime.utc(2026, 10, 18),
            lastUserMessageAt: DateTime.utc(2026, 10, 18),
          ),
        );
        sessions.replaceMessages(
          sessionId,
          receiptHistory(
            confirmedMetadata: {
              'provider': 'ChatGPT',
              'model': 'gpt-6.1-sol',
              'usage': {'input_tokens': 207_084},
              'context_usage': {
                'input_tokens': 207_084,
                'model_id': 'gpt-6.1-sol',
                'provider_instance_id': 'openai-codex',
              },
            },
          ),
        );
        final runner = genericRunner(sessionId: sessionId, responses: const []);

        await runner.debugPrepareProviderHistory();

        expect(runner.debugConfirmedInputUsageBaseline, isNull);
        expect(
          runner.debugLastPreflightPressure?.measurementKind,
          CompactionMeasurementKind.estimated,
        );
      },
    );

    test(
      'a mismatched authoritative context_usage provider is not overridden by a matching legacy provider',
      () async {
        const sessionId = 'session-generic-authoritative-provider';
        sessions.saveSession(
          SessionState(
            sessionId: sessionId,
            providerId: routeProvider,
            model: routeModel,
            thinkingMode: 'max',
            createdAt: DateTime.utc(2026, 10, 18),
            updatedAt: DateTime.utc(2026, 10, 18),
            lastUserMessageAt: DateTime.utc(2026, 10, 18),
          ),
        );
        sessions.replaceMessages(sessionId, [
          ...receiptHistory(
            confirmedMetadata: {
              // The mutable legacy identity matches the route, but the
              // authoritative snapshot says a foreign provider measured this
              // input, so the usage must not be restored.
              'provider': routeProvider,
              'model': routeModel,
              'context_usage': {
                'input_tokens': 371_839,
                'provider_instance_id': 'openai-codex',
                'model_id': routeModel,
              },
            },
          ),
          Message(role: MessageRole.tool, content: 'trailing tool output'),
          Message(role: MessageRole.user, content: 'continue the review'),
        ]);
        final runner = genericRunner(sessionId: sessionId, responses: const []);

        await runner.debugPrepareProviderHistory();

        expect(
          runner.debugConfirmedInputUsageBaseline,
          isNull,
          reason:
              'a present authoritative context_usage identity must never be '
              'overridden by a matching mutable legacy provider',
        );
        expect(
          runner.debugLastPreflightPressure?.measurementKind,
          CompactionMeasurementKind.estimated,
        );
        expect(runner.debugLastPreflightPressure?.confirmedInputTokens, isNull);
      },
    );

    test('a matching authoritative context_usage identity wins over a mismatched legacy identity', () async {
      const sessionId = 'session-generic-authoritative-match';
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          providerId: routeProvider,
          model: routeModel,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      sessions.replaceMessages(sessionId, [
        ...receiptHistory(
          confirmedMetadata: {
            // The mutable legacy identity is foreign, but the authoritative
            // snapshot measured this same route, so the usage is restored.
            'provider': 'ChatGPT',
            'model': 'gpt-6.1-sol',
            'context_usage': {
              'input_tokens': 40_000,
              'provider_instance_id': routeProvider,
              'model_id': routeModel,
            },
          },
        ),
        Message(role: MessageRole.tool, content: 'trailing tool output'),
        Message(role: MessageRole.user, content: 'continue the review'),
      ]);
      final runner = openAiRunner(sessionId: sessionId);
      final proof = await wireProofForAssistantRow(runner);
      sessions.replaceMessages(
        sessionId,
        bindNewestAssistantRowWithProof(
          history: sessions.getMessages(sessionId),
          wireProof: proof,
        ),
      );

      await runner.debugPrepareProviderHistory();

      expect(runner.debugConfirmedInputUsageBaseline?.inputTokens, 40_000);
      expect(runner.debugLastPreflightPressure?.confirmedInputTokens, 40_000);
    });

    test('a row without any provider identity fails closed on the generic route', () async {
      const sessionId = 'session-generic-absent-provider';
      // No provider is set on the session, so the resolved turn routing has a
      // null provider id and the candidate alias set must never contain it.
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          model: routeModel,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      sessions.replaceMessages(sessionId, [
        ...receiptHistory(
          confirmedMetadata: {
            'model': routeModel,
            'context_usage': {'input_tokens': 371_839, 'model_id': routeModel},
          },
        ),
        Message(role: MessageRole.tool, content: 'trailing tool output'),
        Message(role: MessageRole.user, content: 'continue the review'),
      ]);
      final adapter = _GenericOpenAiCompatibleAdapter(contextLimit: 358_000);
      (getIt<AgentRuntimeService>() as _FakeRuntimeService)
        ..turnAdapter = adapter
        ..signature = const RouteSignature(
          providerInstanceId: routeProvider,
          templateId: 'openai',
          protocol: 'openai_compatible',
          normalizedBaseUrl: 'https://opencode.invalid/v1',
          modelId: routeModel,
          configRevision: 1,
          credentialRevision: 1,
        );
      final runner = AgentRunner(
        adapter,
        ToolsRegistry(),
        sessionManager,
        existingSessionId: sessionId,
      );

      await runner.debugPrepareProviderHistory();

      expect(
        runner.debugConfirmedInputUsageBaseline,
        isNull,
        reason:
            'a row without any provider identity must not match a null '
            'candidate alias',
      );
      expect(
        runner.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.estimated,
      );
    });

    test('changed prompt and prefix material after a restore invalidates the restored baseline', () async {
      const sessionId = 'session-generic-material-drift';
      // 40000 keeps the fixture below the auto threshold: these assertions are
      // about baseline validity, not about triggering compaction.
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          providerId: routeProvider,
          model: routeModel,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      sessions.replaceMessages(sessionId, [
        ...receiptHistory(
          confirmedMetadata: confirmedMetadata(contextUsageInput: 40_000),
        ),
        Message(role: MessageRole.tool, content: 'trailing tool output'),
        Message(role: MessageRole.user, content: 'continue the review'),
      ]);
      final runner = openAiRunner(sessionId: sessionId);
      final proof = await wireProofForAssistantRow(runner);
      sessions.replaceMessages(
        sessionId,
        bindNewestAssistantRowWithProof(
          history: sessions.getMessages(sessionId),
          wireProof: proof,
        ),
      );

      await runner.debugPrepareProviderHistory();
      expect(runner.debugConfirmedInputUsageBaseline?.inputTokens, 40_000);
      expect(runner.debugLastPreflightPressure?.confirmedInputTokens, 40_000);

      // The assembled system prompt is the first projected message, so a
      // changed runtime context after the restore must invalidate the baseline.
      await runner.debugPrepareProviderHistory(
        runtimeSystemPrompt: 'changed workspace context',
      );
      expect(
        runner.debugLastPreflightPressure?.confirmedInputTokens,
        isNull,
        reason: 'changed prompt material must fail closed',
      );
      expect(
        runner.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.estimated,
      );

      // A changed earlier message must invalidate it as well.
      final messages = sessions.getMessages(sessionId).toList();
      messages[1] = messages[1].copyWith(content: 'edited prompt material');
      sessions.replaceMessages(sessionId, messages);
      await runner.debugPrepareProviderHistory();
      expect(runner.debugLastPreflightPressure?.confirmedInputTokens, isNull);
      expect(
        runner.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.estimated,
      );
    });

    test('metadata-only bookkeeping change on an earlier message does not invalidate pressure', () async {
      const sessionId = 'session-generic-metadata-resilience';
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          providerId: routeProvider,
          model: routeModel,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      sessions.replaceMessages(sessionId, [
        ...receiptHistory(
          confirmedMetadata: confirmedMetadata(contextUsageInput: 40_000),
        ),
        Message(role: MessageRole.tool, content: 'trailing tool output'),
        Message(role: MessageRole.user, content: 'continue the review'),
      ]);
      final runner = openAiRunner(sessionId: sessionId);
      final proof = await wireProofForAssistantRow(runner);
      sessions.replaceMessages(
        sessionId,
        bindNewestAssistantRowWithProof(
          history: sessions.getMessages(sessionId),
          wireProof: proof,
        ),
      );

      await runner.debugPrepareProviderHistory();
      expect(runner.debugConfirmedInputUsageBaseline?.inputTokens, 40_000);
      expect(runner.debugLastPreflightPressure?.confirmedInputTokens, 40_000);

      // Mutate only client-side metadata on an earlier message:
      final history = sessions.getMessages(sessionId).toList();
      final origMeta = history[1].metadata ?? const {};
      history[1] = history[1].copyWith(
        metadata: {
          ...origMeta,
          'client_sync_tag': 'v2-42',
          'pinned': true,
        },
      );
      sessions.replaceMessages(sessionId, history);

      await runner.debugPrepareProviderHistory();
      expect(
        runner.debugConfirmedInputUsageBaseline?.inputTokens,
        40_000,
        reason: 'metadata-only changes must not invalidate wire-confirmed pressure',
      );
      expect(runner.debugLastPreflightPressure?.confirmedInputTokens, 40_000);
      expect(
        runner.debugLastPreflightPressure?.measurementKind,
        isNot(CompactionMeasurementKind.estimated),
      );
    });

    test('changed tool schemas after a restore invalidate the restored baseline', () async {
      const sessionId = 'session-generic-schema-drift';
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          providerId: routeProvider,
          model: routeModel,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      sessions.replaceMessages(sessionId, [
        ...receiptHistory(
          confirmedMetadata: confirmedMetadata(contextUsageInput: 40_000),
        ),
        Message(role: MessageRole.tool, content: 'trailing tool output'),
        Message(role: MessageRole.user, content: 'continue the review'),
      ]);
      final runner = openAiRunner(sessionId: sessionId);
      final proof = await wireProofForAssistantRow(runner);
      sessions.replaceMessages(
        sessionId,
        bindNewestAssistantRowWithProof(
          history: sessions.getMessages(sessionId),
          wireProof: proof,
        ),
      );

      await runner.debugPrepareProviderHistory();
      expect(runner.debugLastPreflightPressure?.confirmedInputTokens, 40_000);

      runner.registry.registerTool(_SchemaDriftProbeTool());
      await runner.debugPrepareProviderHistory();
      expect(
        runner.debugLastPreflightPressure?.confirmedInputTokens,
        isNull,
        reason: 'changed tool schemas must fail closed',
      );
      expect(
        runner.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.estimated,
      );
    });

    test('a prompt change before the restore discards the bound floor', () async {
      const sessionId = 'session-generic-prompt-drift-before-restore';
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          providerId: routeProvider,
          model: routeModel,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      sessions.replaceMessages(sessionId, [
        ...receiptHistory(
          confirmedMetadata: confirmedMetadata(contextUsageInput: 40_000),
        ),
        Message(role: MessageRole.tool, content: 'trailing tool output'),
        Message(role: MessageRole.user, content: 'continue the review'),
      ]);

      // Bind the receipt to the material as it exists now, then restart with a
      // drifted prompt before any restore attempt can succeed.
      final bounded = openAiRunner(sessionId: sessionId);
      final proof = await wireProofForAssistantRow(bounded);
      sessions.replaceMessages(
        sessionId,
        bindNewestAssistantRowWithProof(
          history: sessions.getMessages(sessionId),
          wireProof: proof,
        ),
      );
      final restarted = openAiRunner(sessionId: sessionId);

      await restarted.debugPrepareProviderHistory(
        runtimeSystemPrompt: 'changed workspace context',
      );

      expect(
        restarted.debugConfirmedInputUsageBaseline,
        isNull,
        reason:
            'a persisted binding that no longer matches the current prompt '
            'must fail closed',
      );
      expect(restarted.debugLastPreflightPressure?.confirmedInputTokens, isNull);
      expect(
        restarted.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.estimated,
      );
    });

    test('a schema change before the restore discards the bound floor', () async {
      const sessionId = 'session-generic-schema-drift-before-restore';
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          providerId: routeProvider,
          model: routeModel,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      sessions.replaceMessages(sessionId, [
        ...receiptHistory(
          confirmedMetadata: confirmedMetadata(contextUsageInput: 40_000),
        ),
        Message(role: MessageRole.tool, content: 'trailing tool output'),
        Message(role: MessageRole.user, content: 'continue the review'),
      ]);

      // The persisted binding was recorded for the empty tool set; the
      // restarted route exposes a schema the producer never measured.
      final bounded = openAiRunner(sessionId: sessionId);
      final proof = await wireProofForAssistantRow(bounded);
      sessions.replaceMessages(
        sessionId,
        bindNewestAssistantRowWithProof(
          history: sessions.getMessages(sessionId),
          wireProof: proof,
        ),
      );
      final adapter = BaseOpenAIAdapter(
        getIt<Config>(),
        const ProviderProfile(
          name: 'openai',
          displayName: 'OpenAI',
          defaultBaseUrl: 'https://opencode.invalid/v1',
        ),
        baseUrlOverride: 'https://opencode.invalid/v1',
        apiKeyOverride: 'test-key',
        defaultModelOverride: routeModel,
        providerInstanceId: routeProvider,
        modelContextLimitLookup: (_) => 358_000,
      );
      final registry = ToolsRegistry()..registerTool(_SchemaDriftProbeTool());
      (getIt<AgentRuntimeService>() as _FakeRuntimeService)
        ..turnAdapter = adapter
        ..signature = const RouteSignature(
          providerInstanceId: routeProvider,
          templateId: 'openai',
          protocol: 'openai_compatible',
          normalizedBaseUrl: 'https://opencode.invalid/v1',
          modelId: routeModel,
          configRevision: 1,
          credentialRevision: 1,
        );
      final restarted = AgentRunner(
        adapter,
        registry,
        sessionManager,
        existingSessionId: sessionId,
      );

      await restarted.debugPrepareProviderHistory();

      expect(
        restarted.debugConfirmedInputUsageBaseline,
        isNull,
        reason:
            'a persisted binding that no longer matches the current tool '
            'schemas must fail closed',
      );
      expect(restarted.debugLastPreflightPressure?.confirmedInputTokens, isNull);
      expect(
        restarted.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.estimated,
      );
    });

    test('a route change before the restore discards the bound wire proof', () async {
      const sessionId = 'session-generic-route-drift-before-restore';
      sessions.saveSession(
        SessionState(
          sessionId: sessionId,
          providerId: routeProvider,
          model: routeModel,
          thinkingMode: 'max',
          createdAt: DateTime.utc(2026, 10, 18),
          updatedAt: DateTime.utc(2026, 10, 18),
          lastUserMessageAt: DateTime.utc(2026, 10, 18),
        ),
      );
      sessions.replaceMessages(sessionId, [
        ...receiptHistory(
          confirmedMetadata: confirmedMetadata(contextUsageInput: 40_000),
        ),
        Message(role: MessageRole.tool, content: 'trailing tool output'),
        Message(role: MessageRole.user, content: 'continue the review'),
      ]);

      final bounded = openAiRunner(sessionId: sessionId);
      final proof = await wireProofForAssistantRow(bounded);
      sessions.replaceMessages(
        sessionId,
        bindNewestAssistantRowWithProof(
          history: sessions.getMessages(sessionId),
          wireProof: proof,
        ),
      );

      // Route signature changed to a different model:
      final restarted = openAiRunner(
        sessionId: sessionId,
        model: 'gpt-4o-mini',
      );

      await restarted.debugPrepareProviderHistory();

      expect(
        restarted.debugConfirmedInputUsageBaseline,
        isNull,
        reason:
            'a persisted binding that was measured for a different route '
            'must fail closed',
      );
      expect(restarted.debugLastPreflightPressure?.confirmedInputTokens, isNull);
      expect(
        restarted.debugLastPreflightPressure?.measurementKind,
        CompactionMeasurementKind.estimated,
      );
    });

    test(
      'an edited historical message before the restore discards the bound wire proof',
      () async {
        const sessionId = 'session-generic-history-drift-before-restore';
        sessions.saveSession(
          SessionState(
            sessionId: sessionId,
            providerId: routeProvider,
            model: routeModel,
            thinkingMode: 'max',
            createdAt: DateTime.utc(2026, 10, 18),
            updatedAt: DateTime.utc(2026, 10, 18),
            lastUserMessageAt: DateTime.utc(2026, 10, 18),
          ),
        );
        sessions.replaceMessages(sessionId, [
          ...receiptHistory(
            confirmedMetadata: confirmedMetadata(contextUsageInput: 40_000),
          ),
          Message(role: MessageRole.tool, content: 'trailing tool output'),
          Message(role: MessageRole.user, content: 'continue the review'),
        ]);

        // Bind the receipt to the wire material as it exists now, then edit an
        // earlier canonical message before any restore can read the binding.
        final bounded = openAiRunner(sessionId: sessionId);
        final proof = await wireProofForAssistantRow(bounded);
        sessions.replaceMessages(
          sessionId,
          bindNewestAssistantRowWithProof(
            history: sessions.getMessages(sessionId),
            wireProof: proof,
          ),
        );
        final messages = sessions.getMessages(sessionId).toList();
        messages[2] = messages[2].copyWith(content: 'edited before the restore');
        sessions.replaceMessages(sessionId, messages);

        final restarted = openAiRunner(sessionId: sessionId);
        await restarted.debugPrepareProviderHistory();

        expect(
          restarted.debugConfirmedInputUsageBaseline,
          isNull,
          reason:
              'a persisted wire proof that no longer matches the historical '
              'message material must fail closed',
        );
        expect(restarted.debugLastPreflightPressure?.confirmedInputTokens, isNull);
        expect(
          restarted.debugLastPreflightPressure?.measurementKind,
          CompactionMeasurementKind.estimated,
        );
      },
    );

    test(
      'a wire-visible request-option drift discards the bound proof and a restored baseline needs a live wire extension',
      () async {
        const sessionId = 'session-generic-options-drift';
        final resolver = _DirectiveDriftResolver()
          ..directive = const OpenAiEffortDirective('high');
        getIt.registerSingleton<RouteCapabilityResolver>(resolver);

        sessions.saveSession(
          SessionState(
            sessionId: sessionId,
            providerId: routeProvider,
            model: routeModel,
            thinkingMode: 'max',
            createdAt: DateTime.utc(2026, 10, 18),
            updatedAt: DateTime.utc(2026, 10, 18),
            lastUserMessageAt: DateTime.utc(2026, 10, 18),
          ),
        );
        sessions.replaceMessages(sessionId, [
          ...receiptHistory(
            confirmedMetadata: confirmedMetadata(contextUsageInput: 40_000),
          ),
          Message(role: MessageRole.tool, content: 'trailing tool output'),
          Message(role: MessageRole.user, content: 'continue the review'),
        ]);

        final bounded = openAiRunner(sessionId: sessionId);

        // Non-vacuity: the wire-visible option must reach the stable material
        // the wire proof binds, otherwise this test proves nothing.
        final material = await bounded.debugPrepareProviderHistory();
        final measurer = bounded.adapter as WireInputUsageMeasurer;
        final tools = bounded.registry.allTools
            .map((tool) => tool.schema)
            .toList();
        final highMeasurement = await measurer.measureInput(
          material,
          tools: tools,
          modelOverride: routeModel,
          options: bounded.debugRequestOptionsForTurn(routeProvider),
        );
        resolver.directive = const OpenAiEffortDirective('low');
        final lowMeasurement = await measurer.measureInput(
          material,
          tools: tools,
          modelOverride: routeModel,
          options: bounded.debugRequestOptionsForTurn(routeProvider),
        );
        expect(
          lowMeasurement!.stableMaterialFingerprint,
          isNot(highMeasurement!.stableMaterialFingerprint),
          reason: 'the effort directive must be wire-visible for this route',
        );
        resolver.directive = const OpenAiEffortDirective('high');

        final proof = await wireProofForAssistantRow(bounded);
        sessions.replaceMessages(
          sessionId,
          bindNewestAssistantRowWithProof(
            history: sessions.getMessages(sessionId),
            wireProof: proof,
          ),
        );

        // Control: unchanged wire-visible options restore the baseline.
        final restored = openAiRunner(sessionId: sessionId);
        await restored.debugPrepareProviderHistory();
        expect(restored.debugConfirmedInputUsageBaseline?.inputTokens, 40_000);
        expect(restored.debugLastPreflightPressure?.confirmedInputTokens, 40_000);

        // A wire-visible option change after the restore cannot be consumed
        // through the legacy in-memory comparison: without a live wire
        // extension the confirmed value is an unproven floor and admission
        // falls back to the explicit estimate.
        resolver.directive = const OpenAiEffortDirective('low');
        await restored.debugPrepareProviderHistory();
        expect(
          restored.debugConfirmedInputUsageBaseline,
          isNotNull,
          reason:
              'the restored baseline stays held; it is simply not consumed '
              'without a live extension proof',
        );
        expect(
          restored.debugLastPreflightPressure?.confirmedInputTokens,
          isNull,
          reason:
              'a wire-measured baseline must not be consumed without a live '
              'extension proof',
        );
        expect(
          restored.debugLastPreflightPressure?.measurementKind,
          CompactionMeasurementKind.estimated,
        );

        // Drift before the restore: a fresh runner under the changed option
        // fails the persisted proof at restore time.
        final restarted = openAiRunner(sessionId: sessionId);
        await restarted.debugPrepareProviderHistory();
        expect(
          restarted.debugConfirmedInputUsageBaseline,
          isNull,
          reason:
              'a wire-visible request-option change before the restore must '
              'fail closed',
        );
        expect(restarted.debugLastPreflightPressure?.confirmedInputTokens, isNull);
        expect(
          restarted.debugLastPreflightPressure?.measurementKind,
          CompactionMeasurementKind.estimated,
        );
      },
    );
  });

  test('provider metrics cannot mutate the request system prefix', () async {
    final now = DateTime.utc(2026, 8, 31);
    sessions.saveSession(
      SessionState(
        sessionId: 'session-stable-provider-prefix',
        providerId: 'provider-1',
        model: 'gpt-4o',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages('session-stable-provider-prefix', [
      Message(role: MessageRole.user, content: 'small request'),
    ]);
    final preflightAdapter = _PreflightAdapter(
      contextLimit: 400_000,
      wireMeasurement: WireInputMeasurement(
        estimatedTokens: 1_000,
        stableMaterialFingerprint: 'stable-route',
        inputItemFingerprints: const ['small-request'],
      ),
    );
    (getIt<AgentRuntimeService>() as _FakeRuntimeService).turnAdapter =
        preflightAdapter;
    final usageRunner = AgentRunner(
      preflightAdapter,
      ToolsRegistry(),
      sessionManager,
      existingSessionId: 'session-stable-provider-prefix',
    );

    final before = await usageRunner.debugPrepareProviderHistory();
    usageRunner.activeProvider = 'provider-name-from-response-metrics';
    final after = await usageRunner.debugPrepareProviderHistory();

    final beforeSystem = before.singleWhere(
      (message) => message.role == MessageRole.system,
    );
    final afterSystem = after.singleWhere(
      (message) => message.role == MessageRole.system,
    );
    expect(beforeSystem.content, contains('Provider: openai'));
    expect(afterSystem.content, beforeSystem.content);
  });
}
