import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
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
        content:
            'path: agent/lib/engine/context/context_compaction_engine.dart',
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
  CompactionMessageRange? previousSourceRange,
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
    previousSourceRange: previousSourceRange,
    targetRequestTokens: 500,
    thresholdRatio: 0.10,
  );
}

void main() {
  group('RequestPressureEvaluator', () {
    test(
      'uses adapter wire estimate instead of double-counting replay state',
      () {
        final evaluator = RequestPressureEvaluator();
        final beforeMessage = Message(
          role: MessageRole.assistant,
          content: 'c' * (359_000 * 4),
          reasoning: 'r' * (104_000 * 4),
        );
        final afterMessage = Message(
          role: MessageRole.assistant,
          content: 'c' * (82_000 * 4),
          reasoning: 'r' * (34_000 * 4),
        );
        final before = evaluator.evaluate(
          routeSignature: _route(),
          contextWindowTokens: 500_000,
          conversationMessages: [beforeMessage],
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          wireEstimatedInputTokens: 359_000,
        );
        final after = evaluator.evaluate(
          routeSignature: _route(),
          contextWindowTokens: 500_000,
          conversationMessages: [afterMessage],
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          wireEstimatedInputTokens: 82_000,
        );

        expect(before.estimatedRequestTokens, 359_000);
        expect(after.estimatedRequestTokens, 82_000);
        expect(before.components.historyTokens, 463_000);
        expect(after.components.historyTokens, 116_000);
        expect(before.components.providerReplayTokens, greaterThanOrEqualTo(0));
        expect(before.components.reasoningTokens, 0);
      },
    );

    test('applies ratio threshold to the effective input window', () {
      final evaluator = RequestPressureEvaluator(
        outputReservationTokens: 100,
        safetyBufferTokens: 100,
      );
      RequestPressureSnapshot snapshot(int tokens, double threshold) =>
          evaluator.evaluate(
            routeSignature: _route(),
            contextWindowTokens: 1_200,
            conversationMessages: const [],
            systemPrompt: '',
            runtimeContext: '',
            toolSchemas: const [],
            wireEstimatedInputTokens: tokens,
            thresholdRatio: threshold,
          );

      expect(snapshot(799, 0.80).exceedsThreshold, isFalse);
      expect(snapshot(800, 0.80).exceedsThreshold, isFalse);
      expect(snapshot(801, 0.80).exceedsThreshold, isTrue);
      expect(snapshot(851, 0.85).exceedsThreshold, isTrue);
    });

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
      expect(
        under.estimatedRequestTokens,
        lessThan(under.effectiveInputBudget),
      );

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
      expect(
        atBoundary.estimatedRequestTokens,
        atBoundary.effectiveInputBudget,
      );
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
      expect(
        openai.components.toolSchemaTokens,
        anthropic.components.toolSchemaTokens,
      );
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
          message: Message(
            role: MessageRole.tool,
            content: 'ok',
            toolCallId: 't1',
          ),
        ),
        IndexedConversationMessage(
          rowId: 4,
          message: Message(role: MessageRole.user, content: 'thanks'),
        ),
      ];
      final selection = selector.select(
        timeline: timeline,
        tailTokenBudget: 80,
      );
      expect(selection.tailMessages.first.rowId, 2);
      expect(
        selection.tailMessages.any((m) => m.message.role == MessageRole.tool),
        isTrue,
      );
      expect(
        selection.sourceRange.end.rowId <
            selection.retainedTailRange.start.rowId,
        isTrue,
      );
      expect(selection.sourceRange.start.rowId, 1);
    });

    test('keeps owning assistant when tail starts inside tool batch', () {
      const selector = CompactionTailSelector(minimumRecentMessages: 4);
      final timeline = [
        IndexedConversationMessage(
          rowId: 1,
          message: Message(role: MessageRole.user, content: 'run batch'),
        ),
        IndexedConversationMessage(
          rowId: 2,
          message: Message(
            role: MessageRole.assistant,
            toolCalls: [
              ToolCall(id: 't1', name: 'read', arguments: const {}),
              ToolCall(id: 't2', name: 'search', arguments: const {}),
              ToolCall(id: 't3', name: 'write', arguments: const {}),
            ],
          ),
        ),
        for (final entry in const [
          ('t1', 'first'),
          ('t2', 'second'),
          ('t3', 'third'),
        ])
          IndexedConversationMessage(
            rowId:
                3 +
                const [
                  ('t1', 'first'),
                  ('t2', 'second'),
                  ('t3', 'third'),
                ].indexOf(entry),
            message: Message(
              role: MessageRole.tool,
              content: entry.$2,
              toolCallId: entry.$1,
            ),
          ),
        IndexedConversationMessage(
          rowId: 6,
          message: Message(role: MessageRole.assistant, content: 'done'),
        ),
        IndexedConversationMessage(
          rowId: 7,
          message: Message(role: MessageRole.user, content: 'continue'),
        ),
      ];

      final selection = selector.select(timeline: timeline, tailTokenBudget: 0);

      expect(selection.tailMessages.first.rowId, 2);
      expect(
        selection.tailMessages
            .where((entry) => entry.message.role == MessageRole.tool)
            .map((entry) => entry.message.toolCallId),
        ['t1', 't2', 't3'],
      );
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
          message: Message(
            role: MessageRole.assistant,
            content: 'mid ${'y' * 80}',
          ),
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
      final selection = selector.select(
        timeline: timeline,
        tailTokenBudget: 40,
      );
      expect(selection.retainedTailRange.end.rowId, 400);
      expect(selection.retainedTailRange.start.rowId, isNot(0));
      expect(selection.retainedTailRange.start.rowId, isNot(1));
      expect(
        selection.sourceRange.end.rowId <
            selection.retainedTailRange.start.rowId,
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
      expect(pruner.estimatePruningSavings(messages, pruned), greaterThan(0));
    });

    test('describes media payloads for summarizer input', () {
      const pruner = CompactionToolPruner();
      final pruned = pruner.pruneSourceMessages([
        IndexedConversationMessage(
          rowId: 1,
          message: Message(
            role: MessageRole.user,
            content: 'data:image/png;base64,${'A' * 80}',
          ),
        ),
      ], protectedTailStartRowId: 99);
      expect(pruned.single.message.content, contains('media omitted'));
      expect(pruned.single.message.content, isNot(contains('AAAA')));
    });

    test(
      'preserves tool identity and provider state while pruning arguments',
      () {
        const pruner = CompactionToolPruner(maxArgumentChars: 20);
        const providerState = LLMProviderState(
          namespace: 'test',
          data: {'opaque_id': 'provider-call-1'},
        );
        final original = Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(
              id: 'call-1',
              name: 'write_file',
              arguments: {'path': 'important.txt', 'payload': 'x' * 200},
              providerState: providerState,
            ),
          ],
        );

        final pruned = pruner.pruneSourceMessages([
          IndexedConversationMessage(rowId: 1, message: original),
        ], protectedTailStartRowId: 2);
        final call = pruned.single.message.toolCalls!.single;

        expect(call.id, 'call-1');
        expect(call.name, 'write_file');
        expect(call.providerState, same(providerState));
        expect(call.arguments['_truncated'], isTrue);
        expect(call.arguments['preview'], isA<String>());
        expect(original.toolCalls!.single.arguments, contains('payload'));
      },
    );
  });

  group('CompactionContinuityValidator', () {
    test('ignores semantic labels quoted by tool output', () {
      final validator = CompactionContinuityValidator();

      final anchors = validator.extractAnchors([
        IndexedConversationMessage(
          rowId: 1,
          message: Message(
            role: MessageRole.tool,
            content: 'goal: fixture goal\nblocker: fixture blocker',
            toolCallId: 'call-read-source',
          ),
        ),
      ]);

      expect(
        anchors,
        contains(
          isA<CompactionContinuityAnchor>()
              .having((anchor) => anchor.key, 'key', 'tool_side_effect')
              .having((anchor) => anchor.value, 'value', 'call-read-source'),
        ),
      );
      expect(
        anchors.where((anchor) => anchor.key != 'tool_side_effect'),
        isEmpty,
      );
    });

    test('keeps user-authored semantic labels as continuity anchors', () {
      final validator = CompactionContinuityValidator();

      final anchors = validator.extractAnchors([
        IndexedConversationMessage(
          rowId: 1,
          message: Message(
            role: MessageRole.user,
            content: 'goal: preserve drafts\nblocker: stale composer state',
          ),
        ),
      ]);

      expect(
        anchors.where((anchor) => anchor.critical).map((anchor) => anchor.key),
        containsAll(['goal', 'blocker']),
      );
    });

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
          CompactionContinuityAnchor(key: 'goal', value: 'OAuth rollout'),
        ],
      );

      expect(result.passed, isTrue);
      expect(result.missingAnchors, isEmpty);
    });
  });

  group('CompactionSummaryPrompt', () {
    test('bounds prompt passes and redacts source material', () {
      final passes = CompactionSummaryPrompt.buildPasses(
        sourceMessages: [
          for (var index = 0; index < 12; index++)
            IndexedConversationMessage(
              rowId: index + 1,
              message: Message(
                role: MessageRole.user,
                content:
                    'goal: retain context $index sk-ant-api03-test-secret-value ${'x' * 100}',
              ),
            ),
        ],
        previousSummary: const CompactionInternalSummary(
          currentGoal: 'Previous goal',
          remainingWork: 'Previous pending work',
        ),
        maxPromptTokens: 120,
        maxPasses: 3,
      );

      expect(passes, hasLength(3));
      expect(passes.first, contains('Previous summary anchor'));
      expect(passes.join(), isNot(contains('sk-ant-api03-test-secret-value')));
    });

    test('strips provider reasoning markup before parsing', () {
      final summary = CompactionSummaryParser.parse('''
<reasoning>private provider reasoning</reasoning>
Current Goal and Success Criteria: Ship safely
Remaining Work and Safest Next Action: Run verification
''');

      expect(summary.currentGoal, 'Ship safely');
      expect(summary.remainingWork, 'Run verification');
      expect(
        CompactionSummaryPrompt.formatSummary(summary),
        isNot(contains('private provider reasoning')),
      );
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

    test('adds only a new suffix to provider-confirmed input usage', () {
      final evaluator = RequestPressureEvaluator();
      final measured = Message(
        role: MessageRole.user,
        content: 'already measured',
      );
      final snapshot = evaluator.evaluate(
        routeSignature: _route(),
        contextWindowTokens: 8_000,
        conversationMessages: [
          measured,
          Message(role: MessageRole.tool, content: 'new suffix'),
        ],
        systemPrompt: 'system',
        runtimeContext: 'runtime',
        toolSchemas: const [],
        confirmedInputUsage: ConfirmedInputUsageBaseline(
          routeSignature: _route(),
          inputTokens: 7_500,
          conversationMessages: [measured],
          systemPrompt: 'system',
          runtimeContext: 'runtime',
          toolSchemas: const [],
        ),
      );
      expect(snapshot.measurementKind, CompactionMeasurementKind.mixed);
      expect(snapshot.confirmedInputTokens, 7_500);
      expect(snapshot.estimatedRequestTokens, greaterThan(7_500));
    });

    test('uses provider input usage as baseline for unchanged request', () {
      final evaluator = RequestPressureEvaluator();
      final snapshot = evaluator.evaluate(
        routeSignature: _route(),
        contextWindowTokens: 8_000,
        conversationMessages: [
          Message(role: MessageRole.user, content: 'already measured'),
        ],
        systemPrompt: 'system',
        runtimeContext: 'runtime',
        toolSchemas: const [],
        confirmedInputUsage: ConfirmedInputUsageBaseline(
          routeSignature: _route(),
          inputTokens: 7_500,
          conversationMessages: [
            Message(role: MessageRole.user, content: 'already measured'),
          ],
          systemPrompt: 'system',
          runtimeContext: 'runtime',
          toolSchemas: const [],
        ),
      );

      expect(snapshot.estimatedRequestTokens, 7_500);
      expect(snapshot.measurementKind, CompactionMeasurementKind.confirmed);
      expect(snapshot.exceedsThreshold, isTrue);
    });

    test(
      'provider-confirmed usage outranks an inflated full-wire estimate',
      () {
        final evaluator = RequestPressureEvaluator();
        final baselineWire = WireInputMeasurement(
          estimatedTokens: 315_700,
          stableMaterialFingerprint: 'instructions-and-tools',
          inputItemFingerprints: ['measured-prefix'],
        );
        final nextWire = WireInputMeasurement(
          estimatedTokens: 316_900,
          stableMaterialFingerprint: 'instructions-and-tools',
          inputItemFingerprints: ['measured-prefix', 'small-tool-suffix'],
        );
        final snapshot = evaluator.evaluate(
          routeSignature: _route(),
          contextWindowTokens: 400_000,
          conversationMessages: [
            Message(role: MessageRole.user, content: 'local metadata changed'),
          ],
          systemPrompt: '',
          runtimeContext: '',
          toolSchemas: const [],
          confirmedInputUsage: ConfirmedInputUsageBaseline(
            routeSignature: _route(),
            inputTokens: 260_537,
            conversationMessages: [
              Message(role: MessageRole.user, content: 'older local form'),
            ],
            systemPrompt: '',
            runtimeContext: '',
            toolSchemas: const [],
            wireMeasurement: baselineWire,
          ),
          wireEstimatedInputTokens: nextWire.estimatedTokens,
          wireMeasurement: nextWire,
          thresholdRatio: 0.80,
        );

        expect(snapshot.measurementKind, CompactionMeasurementKind.mixed);
        expect(snapshot.confirmedInputTokens, 260_537);
        expect(snapshot.estimatedRequestTokens, 261_737);
        expect(snapshot.exceedsThreshold, isFalse);
      },
    );

    test(
      'invalidates confirmed usage after route or measured-prefix change',
      () {
        final evaluator = RequestPressureEvaluator();
        final measured = Message(
          role: MessageRole.user,
          content: 'measured prefix',
        );
        final baseline = ConfirmedInputUsageBaseline(
          routeSignature: _route(),
          inputTokens: 7_500,
          conversationMessages: [measured],
          systemPrompt: 'system',
          runtimeContext: 'runtime',
          toolSchemas: const [],
        );

        final changedPrefix = evaluator.evaluate(
          routeSignature: _route(),
          contextWindowTokens: 8_000,
          conversationMessages: [
            Message(role: MessageRole.user, content: 'replaced prefix'),
          ],
          systemPrompt: 'system',
          runtimeContext: 'runtime',
          toolSchemas: const [],
          confirmedInputUsage: baseline,
        );
        final changedRoute = evaluator.evaluate(
          routeSignature: RouteSignature(
            providerInstanceId: 'provider-1',
            templateId: 'openai',
            protocol: 'openai_compatible',
            normalizedBaseUrl: 'https://api.example.com/v1',
            modelId: 'gpt-4.1',
            configRevision: 1,
            credentialRevision: 1,
          ),
          contextWindowTokens: 8_000,
          conversationMessages: [measured],
          systemPrompt: 'system',
          runtimeContext: 'runtime',
          toolSchemas: const [],
          confirmedInputUsage: baseline,
        );

        for (final snapshot in [changedPrefix, changedRoute]) {
          expect(snapshot.measurementKind, CompactionMeasurementKind.estimated);
          expect(snapshot.confirmedInputTokens, isNull);
          expect(snapshot.estimatedRequestTokens, isNot(7_500));
        }
      },
    );

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
        final candidate = await engine.buildCandidate(
          _request(timeline: _timeline()),
        );
        expect(candidate, isNotNull);
        expect(candidate!.continuityResult.passed, isTrue);
        expect(
          candidate.metrics.estimatedRequestTokensAfter,
          lessThan(candidate.metrics.estimatedRequestTokensBefore),
        );
        expect(candidate.metrics.retainedTailTokens, lessThanOrEqualTo(500));
        expect(
          candidate.internalSummary.currentGoal,
          contains('ship compaction'),
        );
      });

      test('tool output labels do not fail candidate continuity', () async {
        final timeline = <IndexedConversationMessage>[
          ..._timeline().take(4),
          IndexedConversationMessage(
            rowId: 5,
            message: Message(
              role: MessageRole.assistant,
              toolCalls: [
                ToolCall(
                  id: 'call-read-plan',
                  name: 'file_read',
                  arguments: const {'path': 'docs/plan.md'},
                ),
              ],
            ),
          ),
          IndexedConversationMessage(
            rowId: 6,
            message: Message(
              role: MessageRole.tool,
              toolCallId: 'call-read-plan',
              content:
                  'goal: quoted fixture goal\nblocker: quoted fixture blocker',
            ),
          ),
          for (var rowId = 7; rowId <= 42; rowId++)
            IndexedConversationMessage(
              rowId: rowId,
              message: Message(
                role: MessageRole.user,
                content: 'filler message $rowId ${'x' * 120}',
              ),
            ),
        ];

        final candidate = await ContextCompactionEngine().buildCandidate(
          _request(timeline: timeline),
        );

        expect(candidate, isNotNull);
        expect(candidate!.continuityResult.passed, isTrue);
        expect(
          candidate.internalSummary.currentGoal,
          contains('ship compaction'),
        );
      });

      test('rejects candidate when critical anchor is dropped', () async {
        final summarizer = _DropGoalSummarizer();
        final engine = ContextCompactionEngine(summarizer: summarizer);
        await expectLater(
          engine.buildCandidate(_request(timeline: _timeline())),
          throwsA(
            isA<CompactionEngineFailure>()
                .having(
                  (failure) => failure.reason,
                  'reason',
                  CompactionFailureReason.continuityValidationFailed,
                )
                .having(
                  (failure) => failure.antiThrashing?.repairAttempts,
                  'repair attempts',
                  1,
                )
                .having(
                  (failure) => failure.antiThrashing?.noProgress,
                  'no progress',
                  isTrue,
                ),
          ),
        );
        expect(summarizer.calls, 2);
      });

      test(
        'rejects a summary projection that makes no budget progress',
        () async {
          final engine = ContextCompactionEngine(
            summarizer: _NoProgressSummarizer(),
          );

          await expectLater(
            engine.buildCandidate(_request(timeline: _timeline())),
            throwsA(
              isA<CompactionEngineFailure>().having(
                (failure) => failure.reason,
                'reason',
                CompactionFailureReason.projectionStillOverBudget,
              ),
            ),
          );
        },
      );

      test(
        'repeated compaction keeps goal anchor with previous summary',
        () async {
          final engine = ContextCompactionEngine();
          final first = await engine.buildCandidate(
            _request(timeline: _timeline()),
          );
          expect(first, isNotNull);
          final second = await engine.buildCandidate(
            _request(
              timeline: _timeline(),
              previousSummary: first!.internalSummary,
              previousSourceRange: first.sourceRange,
            ),
          );
          expect(second, isNotNull);
          expect(
            second!.sourceRange.start.rowId,
            greaterThan(first.sourceRange.end.rowId),
          );
          expect(
            second.internalSummary.currentGoal,
            contains('ship compaction'),
          );
          expect(
            second.internalSummary.remainingWork,
            isNot(contains('unrelated task')),
          );
        },
      );

      test(
        'huge recent tool output still yields measurable candidate',
        () async {
          final timeline = [
            ..._timeline(),
            IndexedConversationMessage(
              rowId: 41,
              message: Message(
                role: MessageRole.assistant,
                content: '',
                toolCalls: [
                  ToolCall(
                    id: 'huge',
                    name: 'read',
                    arguments: {'path': 'big.txt'},
                  ),
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
        },
      );
    });
  });
}

class _DropGoalSummarizer implements CompactionSummarizer {
  int calls = 0;

  @override
  Future<String> summarize({required String prompt}) async {
    calls++;
    return '''
Current Goal and Success Criteria: unrelated task
Remaining Work and Safest Next Action: do something else
''';
  }
}

class _NoProgressSummarizer implements CompactionSummarizer {
  @override
  Future<String> summarize({required String prompt}) async {
    return '''
Current Goal and Success Criteria: ship compaction safely
Remaining Work and Safest Next Action: ${'still pending ' * 2_000}
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
