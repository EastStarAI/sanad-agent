import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:test/test.dart';

RouteSignature _route() => const RouteSignature(
  providerInstanceId: 'provider-1',
  templateId: 'openai',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'gpt-4o',
  configRevision: 1,
  credentialRevision: 1,
);

List<IndexedConversationMessage> _timeline() {
  return [
    IndexedConversationMessage(
      rowId: 1,
      message: Message(
        role: MessageRole.user,
        content: 'goal: ship compaction safely',
      ),
    ),
    IndexedConversationMessage(
      rowId: 2,
      message: Message(role: MessageRole.assistant, content: 'Acknowledged.'),
    ),
    IndexedConversationMessage(
      rowId: 3,
      message: Message(
        role: MessageRole.user,
        content: 'path: agent/lib/engine/context/context_compaction_engine.dart',
      ),
    ),
    IndexedConversationMessage(
      rowId: 4,
      message: Message(role: MessageRole.assistant, content: 'Working on it.'),
    ),
    for (var i = 5; i <= 40; i++)
      IndexedConversationMessage(
        rowId: i,
        message: Message(
          role: MessageRole.user,
          content: 'filler message $i ${'x' * 120}',
        ),
      ),
  ];
}

CompactionEngineRequest _request({
  required List<IndexedConversationMessage> timeline,
  CompactionInternalSummary? previousSummary,
}) {
  return CompactionEngineRequest(
    compactionId: 'cmp-engine',
    sessionId: 'session-1',
    trigger: CompactionTrigger.auto,
    sourceRevision: const CompactionHistoryRevision(1),
    routeSignature: _route(),
    contextWindowTokens: 3_000,
    timeline: timeline,
    systemPrompt: 'system prompt',
    runtimeContext: 'runtime',
    toolSchemas: const [],
    previousSummary: previousSummary,
    targetRequestTokens: 2_000,
  );
}

void main() {
  group('RequestPressureEvaluator', () {
    test('flags request above effective input budget', () {
      final evaluator = RequestPressureEvaluator(
        outputReservationTokens: 1000,
        safetyBufferTokens: 500,
      );
      final snapshot = evaluator.evaluate(
        routeSignature: _route(),
        contextWindowTokens: 4000,
        conversationMessages: [
          Message(role: MessageRole.user, content: 'x' * 20_000),
        ],
        systemPrompt: 'system',
        runtimeContext: 'runtime',
        toolSchemas: const [],
      );
      expect(snapshot.exceedsThreshold, isTrue);
      expect(snapshot.measurementKind, CompactionMeasurementKind.estimated);
    });

    test('is deterministic for under, at, and over threshold', () {
      final evaluator = RequestPressureEvaluator(
        outputReservationTokens: 100,
        safetyBufferTokens: 50,
      );
      // effectiveInputBudget = 1000 - 100 - 50 = 850
      RequestPressureSnapshot snap(String content) => evaluator.evaluate(
            routeSignature: _route(),
            contextWindowTokens: 1000,
            conversationMessages: [
              Message(role: MessageRole.user, content: content),
            ],
            systemPrompt: '',
            runtimeContext: '',
            toolSchemas: const [],
          );

      final under = snap('x' * 400); // ~100 tokens
      expect(under.exceedsThreshold, isFalse);
      expect(under.estimatedRequestTokens, lessThan(under.effectiveInputBudget));

      final over = snap('x' * 4000); // ~1000 tokens
      expect(over.exceedsThreshold, isTrue);

      final atBoundary = evaluator.evaluate(
        routeSignature: _route(),
        contextWindowTokens: 1000,
        conversationMessages: const [],
        systemPrompt: 'y' * (850 * 4), // exactly 850 tokens
        runtimeContext: '',
        toolSchemas: const [],
      );
      expect(atBoundary.estimatedRequestTokens, atBoundary.effectiveInputBudget);
      expect(atBoundary.exceedsThreshold, isFalse);
    });

    test('uses inputLimitTokens when distinct from context window', () {
      final evaluator = RequestPressureEvaluator(
        outputReservationTokens: 100,
        safetyBufferTokens: 50,
      );
      final snapshot = evaluator.evaluate(
        routeSignature: _route(),
        contextWindowTokens: 100_000,
        inputLimitTokens: 1000,
        conversationMessages: [
          Message(role: MessageRole.user, content: 'x' * 4000),
        ],
        systemPrompt: '',
        runtimeContext: '',
        toolSchemas: const [],
      );
      expect(snapshot.effectiveInputBudget, 850);
      expect(snapshot.exceedsThreshold, isTrue);
    });

    test('route signature owns the evaluated window and schema cache key', () {
      final cache = <String, int>{};
      final evaluator = RequestPressureEvaluator(toolSchemaTokenCache: cache);
      const schemas = [
        {
          'name': 'read_file',
          'parameters': {'type': 'object'},
        },
      ];
      final openai = evaluator.evaluate(
        routeSignature: _route(),
        contextWindowTokens: 8_000,
        conversationMessages: const [],
        systemPrompt: '',
        runtimeContext: '',
        toolSchemas: schemas,
      );
      final anthropicRoute = RouteSignature(
        providerInstanceId: 'provider-2',
        templateId: 'anthropic',
        protocol: 'anthropic_compatible',
        normalizedBaseUrl: 'https://api.anthropic.example/v1',
        modelId: 'claude-sonnet',
        configRevision: 1,
        credentialRevision: 1,
      );
      final anthropic = evaluator.evaluate(
        routeSignature: anthropicRoute,
        contextWindowTokens: 200_000,
        conversationMessages: const [],
        systemPrompt: '',
        runtimeContext: '',
        toolSchemas: schemas,
      );
      expect(openai.routeSignature.modelId, 'gpt-4o');
      expect(openai.contextWindowTokens, 8_000);
      expect(anthropic.contextWindowTokens, 200_000);
      expect(cache.length, 2);
      expect(openai.components.toolSchemaTokens, anthropic.components.toolSchemaTokens);
    });

    test('counts declared media bytes without treating base64 as text', () {
      final evaluator = RequestPressureEvaluator();
      final base64Blob = 'A' * 800;
      final snapshot = evaluator.evaluate(
        routeSignature: _route(),
        contextWindowTokens: 8_000,
        conversationMessages: [
          Message(
            role: MessageRole.user,
            content: 'data:image/png;base64,$base64Blob',
            metadata: const {'media_bytes': 2048},
          ),
        ],
        systemPrompt: '',
        runtimeContext: '',
        toolSchemas: const [],
      );
      expect(snapshot.components.historyTokens, 0);
      expect(snapshot.components.mediaTokens, greaterThan(0));
      expect(
        snapshot.components.mediaTokens,
        lessThan(CompactionTokenEstimator.estimateText(base64Blob)),
      );
      expect(snapshot.measurementKind, CompactionMeasurementKind.estimated);
    });
  });

  group('CompactionTailSelector', () {
    test('keeps tool call and result pair inside retained tail', () {
      const selector = CompactionTailSelector(minimumRecentMessages: 1);
      final timeline = [
        IndexedConversationMessage(
          rowId: 1,
          message: Message(role: MessageRole.user, content: 'run'),
        ),
        IndexedConversationMessage(
          rowId: 2,
          message: Message(
            role: MessageRole.assistant,
            content: '',
            toolCalls: [
              ToolCall(id: 't1', name: 'read', arguments: {'path': 'a.txt'}),
            ],
          ),
        ),
        IndexedConversationMessage(
          rowId: 3,
          message: Message(role: MessageRole.tool, content: 'ok', toolCallId: 't1'),
        ),
        IndexedConversationMessage(
          rowId: 4,
          message: Message(role: MessageRole.user, content: 'thanks'),
        ),
      ];
      final selection = selector.select(timeline: timeline, tailTokenBudget: 80);
      expect(selection.tailMessages.first.rowId, 2);
      expect(selection.tailMessages.any((m) => m.message.role == MessageRole.tool), isTrue);
      expect(
        selection.sourceRange.end.rowId < selection.retainedTailRange.start.rowId,
        isTrue,
      );
      expect(selection.sourceRange.start.rowId, 1);
    });

    test('uses durable row identities independent of list indices', () {
      const selector = CompactionTailSelector(minimumRecentMessages: 2);
      final timeline = [
        IndexedConversationMessage(
          rowId: 100,
          message: Message(role: MessageRole.user, content: 'old ${'x' * 80}'),
        ),
        IndexedConversationMessage(
          rowId: 200,
          message: Message(role: MessageRole.assistant, content: 'mid ${'y' * 80}'),
        ),
        IndexedConversationMessage(
          rowId: 300,
          message: Message(role: MessageRole.user, content: 'recent-a'),
        ),
        IndexedConversationMessage(
          rowId: 400,
          message: Message(role: MessageRole.user, content: 'recent-b'),
        ),
      ];
      final selection = selector.select(timeline: timeline, tailTokenBudget: 40);
      expect(selection.retainedTailRange.end.rowId, 400);
      expect(selection.retainedTailRange.start.rowId, isNot(0));
      expect(selection.retainedTailRange.start.rowId, isNot(1));
      expect(
        selection.sourceRange.end.rowId < selection.retainedTailRange.start.rowId,
        isTrue,
      );
      expect(
        {100, 200, 300, 400}.contains(selection.sourceRange.start.rowId),
        isTrue,
      );
    });
  });

  group('CompactionToolPruner', () {
    test('truncates old tool results without touching protected tail', () {
      const pruner = CompactionToolPruner(maxToolResultChars: 20);
      final messages = [
        IndexedConversationMessage(
          rowId: 1,
          message: Message(role: MessageRole.tool, content: 'x' * 100),
        ),
        IndexedConversationMessage(
          rowId: 5,
          message: Message(role: MessageRole.tool, content: 'keep verbatim'),
        ),
      ];
      final pruned = pruner.pruneSourceMessages(
        messages,
        protectedTailStartRowId: 5,
      );
      expect(pruned.first.message.content, contains('[truncated'));
      expect(pruned.last.message.content, 'keep verbatim');
      expect(
        pruner.estimatePruningSavings(messages, pruned),
        greaterThan(0),
      );
    });

    test('describes media payloads for summarizer input', () {
      const pruner = CompactionToolPruner();
      final pruned = pruner.pruneSourceMessages(
        [
          IndexedConversationMessage(
            rowId: 1,
            message: Message(
              role: MessageRole.user,
              content: 'data:image/png;base64,${'A' * 80}',
            ),
          ),
        ],
        protectedTailStartRowId: 99,
      );
      expect(pruned.single.message.content, contains('media omitted'));
      expect(pruned.single.message.content, isNot(contains('AAAA')));
    });
  });

  group('CompactionContinuityValidator', () {
    test('redacts secret-like tokens before anchor validation', () {
      final validator = CompactionContinuityValidator();
      const secret = 'sk-ant-api03-test-secret-value';
      final result = validator.validate(
        summary: CompactionInternalSummary(
          currentGoal: 'Continue OAuth rollout',
          remainingWork: 'Rotate credentials safely',
          constraints: secret,
        ),
        anchors: const [
          CompactionContinuityAnchor(
            key: 'goal',
            value: 'OAuth rollout',
          ),
        ],
      );

      expect(result.passed, isTrue);
      expect(result.missingAnchors, isEmpty);
    });
  });

  group('ContextCompactionEngine', () {
    test('rejects empty summary sections', () async {
      final engine = ContextCompactionEngine(
        summarizer: _EmptySummarySummarizer(),
      );
      await expectLater(
        engine.buildCandidate(_request(timeline: _timeline())),
        throwsA(isA<CompactionEngineFailure>()),
      );
    });

    test('uses confirmed input tokens for mixed measurement kind', () {
      final evaluator = RequestPressureEvaluator();
      final snapshot = evaluator.evaluate(
        routeSignature: _route(),
        contextWindowTokens: 8_000,
        conversationMessages: [
          Message(role: MessageRole.user, content: 'x' * 500),
        ],
        systemPrompt: 'system',
        runtimeContext: 'runtime',
        toolSchemas: const [],
        confirmedInputTokens: 7_500,
      );
      expect(snapshot.measurementKind, CompactionMeasurementKind.mixed);
    });

  group('ContextCompactionEngine core', () {
    test('returns null when pressure is below threshold', () async {
      final engine = ContextCompactionEngine();
      final candidate = await engine.buildCandidate(
        CompactionEngineRequest(
          compactionId: 'cmp-small',
          sessionId: 'session-1',
          trigger: CompactionTrigger.auto,
          sourceRevision: const CompactionHistoryRevision(1),
          routeSignature: _route(),
          contextWindowTokens: 128_000,
          timeline: [
            IndexedConversationMessage(
              rowId: 1,
              message: Message(role: MessageRole.user, content: 'short'),
            ),
          ],
          systemPrompt: 'system prompt',
          runtimeContext: 'runtime',
          toolSchemas: const [],
          targetRequestTokens: 2_000,
        ),
      );
      expect(candidate, isNull);
    });

    test('builds validated candidate under target budget', () async {
      final engine = ContextCompactionEngine();
      final candidate = await engine.buildCandidate(_request(timeline: _timeline()));
      expect(candidate, isNotNull);
      expect(candidate!.continuityResult.passed, isTrue);
      expect(candidate.metrics.estimatedRequestTokensAfter,
          lessThan(candidate.metrics.estimatedRequestTokensBefore));
      expect(candidate.internalSummary.currentGoal, contains('ship compaction'));
    });

    test('rejects candidate when critical anchor is dropped', () async {
      final engine = ContextCompactionEngine(
        summarizer: _DropGoalSummarizer(),
      );
      await expectLater(
        engine.buildCandidate(_request(timeline: _timeline())),
        throwsA(isA<CompactionEngineFailure>()),
      );
    });

    test('repeated compaction keeps goal anchor with previous summary', () async {
      final engine = ContextCompactionEngine();
      final first = await engine.buildCandidate(_request(timeline: _timeline()));
      expect(first, isNotNull);
      final second = await engine.buildCandidate(
        _request(
          timeline: _timeline(),
          previousSummary: first!.internalSummary,
        ),
      );
      expect(second, isNotNull);
      expect(second!.internalSummary.currentGoal, contains('ship compaction'));
      expect(
        second.internalSummary.remainingWork,
        isNot(contains('unrelated task')),
      );
    });

    test('huge recent tool output still yields measurable candidate', () async {
      final timeline = [
        ..._timeline(),
        IndexedConversationMessage(
          rowId: 41,
          message: Message(
            role: MessageRole.assistant,
            content: '',
            toolCalls: [
              ToolCall(id: 'huge', name: 'read', arguments: {'path': 'big.txt'}),
            ],
          ),
        ),
        IndexedConversationMessage(
          rowId: 42,
          message: Message(
            role: MessageRole.tool,
            content: 'PAYLOAD ${'z' * 20_000}',
            toolCallId: 'huge',
          ),
        ),
      ];
      final engine = ContextCompactionEngine(
        toolPruner: const CompactionToolPruner(maxToolResultChars: 80),
      );
      final candidate = await engine.buildCandidate(
        _request(timeline: timeline),
      );
      expect(candidate, isNotNull);
      expect(candidate!.retainedTailRange.end.rowId, 42);
      expect(
        candidate.metrics.estimatedRequestTokensAfter,
        lessThan(candidate.metrics.estimatedRequestTokensBefore),
      );
    });
  });
  });
}

class _DropGoalSummarizer implements CompactionSummarizer {
  @override
  Future<String> summarize({required String prompt}) async {
    return '''
Current Goal and Success Criteria: unrelated task
Remaining Work and Safest Next Action: do something else
''';
  }
}

class _EmptySummarySummarizer implements CompactionSummarizer {
  @override
  Future<String> summarize({required String prompt}) async {
    return '''
Current Goal and Success Criteria:
Remaining Work and Safest Next Action:
''';
  }
}
