import 'dart:convert';

import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:test/test.dart';

/// Task 118 Stage3A: the post-compaction target covers the complete next
/// request (system/runtime instructions + tools + summary + retained tail)
/// against the full window `W`, not the retained tail alone and not the
/// internal usable input budget.

const _window = 258_000;
const _target = 25_800; // 10% of W.

RouteSignature _route() => const RouteSignature(
  providerInstanceId: 'provider-target',
  templateId: 'openai',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'gpt-target',
  configRevision: 1,
  credentialRevision: 1,
);

/// Plain text costing exactly [tokens] under the chars/4 estimator.
String _text(int tokens) => 'word ' * (tokens * 4 ~/ 5);

List<IndexedConversationMessage> _history({
  int pairs = 120,
  int tokens = 1000,
}) {
  return [
    for (var pair = 0; pair < pairs; pair++) ...[
      IndexedConversationMessage(
        rowId: pair * 2 + 1,
        message: Message(role: MessageRole.user, content: _text(tokens)),
      ),
      IndexedConversationMessage(
        rowId: pair * 2 + 2,
        message: Message(role: MessageRole.assistant, content: _text(tokens)),
      ),
    ],
  ];
}

Map<String, dynamic> _toolSchema(int tokens) => {
  'name': 'workspace_read',
  'description': _text(tokens),
  'parameters': const {'type': 'object', 'properties': <String, dynamic>{}},
};

CompactionEngineRequest _request({
  required int systemTokens,
  int toolTokens = 2_000,
  List<IndexedConversationMessage>? timeline,
}) {
  final history = timeline ?? _history();
  final system = _text(systemTokens);
  final schema = _toolSchema(toolTokens);
  return CompactionEngineRequest(
    compactionId: 'cmp-target',
    sessionId: 'session-target',
    trigger: CompactionTrigger.auto,
    sourceRevision: const CompactionHistoryRevision(1),
    routeSignature: _route(),
    contextWindowTokens: _window,
    timeline: history,
    systemPrompt: system,
    runtimeContext: '',
    toolSchemas: [schema],
    providerProjection: [
      Message(role: MessageRole.system, content: system),
      for (final entry in history) entry.message,
    ],
    providerTools: [ToolSchema.fromJson(schema)],
    targetRequestTokens: _target,
    thresholdRatio: 0.90,
    targetRatio: 0.10,
  );
}

class _FixedSummarizer
    implements CompactionSummarizer, ProviderProjectionCompactionSummarizer {
  _FixedSummarizer({this.remainingWorkTokens = 0});

  /// A realistic two-page summary carries most of its text in transmitted
  /// fields such as the remaining work.
  final int remainingWorkTokens;
  int calls = 0;

  @override
  Future<String> summarize({required String prompt}) async =>
      throw UnimplementedError();

  @override
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  ) async {
    calls++;
    return CompactionProviderResult(
      content: jsonEncode(
        CompactionSummaryPrompt.toJsonMap(
          CompactionInternalSummary(
            currentGoal: 'continue the long-running task',
            latestUserRequest: 'keep going',
            activeState: 'in progress',
            criticalContext: _text(600),
            remainingWork:
                'finish the remaining steps ${_text(remainingWorkTokens)}',
          ),
        ),
      ),
      usage: const {'input_tokens': 240_000, 'output_tokens': 700},
      duration: const Duration(milliseconds: 5),
    );
  }
}

void main() {
  // Task 118 moved-in item 3: `projection_still_over_budget` on very small
  // sessions. A manual `/compact` of a conversation whose complete request is
  // already inside the target paid for a summary larger than the rows it
  // replaced, then failed the no-progress guard with an "over budget" cause.
  group('Task 118 small sessions', () {
    for (final trigger in [CompactionTrigger.manual]) {
      test(
        '${trigger.name} compaction of a request already within the target is a no-op before any provider call',
        () async {
          final summarizer = _FixedSummarizer(remainingWorkTokens: 1_200);
          final history = _history(pairs: 3, tokens: 60);
          final base = _request(systemTokens: 8_944, timeline: history);
          final request = CompactionEngineRequest(
            compactionId: base.compactionId,
            sessionId: base.sessionId,
            trigger: trigger,
            sourceRevision: base.sourceRevision,
            routeSignature: base.routeSignature,
            contextWindowTokens: base.contextWindowTokens,
            timeline: base.timeline,
            systemPrompt: base.systemPrompt,
            runtimeContext: base.runtimeContext,
            toolSchemas: base.toolSchemas,
            providerProjection: base.providerProjection,
            providerTools: base.providerTools,
            targetRequestTokens: base.targetRequestTokens,
            thresholdRatio: base.thresholdRatio,
            targetRatio: base.targetRatio,
          );

          final candidate = await ContextCompactionEngine(
            summarizer: summarizer,
          ).buildCandidate(request, force: true);

          expect(candidate, isNull);
          expect(summarizer.calls, 0);
        },
      );
    }

    test(
      'an overflow is never treated as within the target',
      () async {
        final summarizer = _FixedSummarizer();
        final base = _request(systemTokens: 8_944);
        final request = CompactionEngineRequest(
          compactionId: base.compactionId,
          sessionId: base.sessionId,
          trigger: CompactionTrigger.overflow,
          sourceRevision: base.sourceRevision,
          routeSignature: base.routeSignature,
          contextWindowTokens: base.contextWindowTokens,
          timeline: _history(pairs: 40, tokens: 60),
          systemPrompt: base.systemPrompt,
          runtimeContext: base.runtimeContext,
          toolSchemas: base.toolSchemas,
          providerProjection: base.providerProjection,
          providerTools: base.providerTools,
          targetRequestTokens: base.targetRequestTokens,
          thresholdRatio: base.thresholdRatio,
          targetRatio: base.targetRatio,
        );

        final candidate = await ContextCompactionEngine(
          summarizer: summarizer,
        ).buildCandidate(request, force: true);

        // Provider work happens (here the bounded recovery, since the full
        // pass cannot fit the window with its output reservation).
        expect(summarizer.calls, greaterThan(0));
        expect(candidate, isNotNull);
      },
    );
  });

  group('Task 118 Stage3A complete-request target', () {
    test(
      'retained tail leaves room for instructions, tools and summary within 10% of W',
      () async {
        final candidate = await ContextCompactionEngine(
          summarizer: _FixedSummarizer(),
        ).buildCandidate(_request(systemTokens: 8_944), force: true);

        expect(candidate, isNotNull);
        final decision = candidate!.diagnostics!.decisionSnapshot!;
        expect(decision['target_scope'], 'context_window');
        expect(decision['target_request_tokens'], _target);
        expect(decision['target_feasibility'], 'feasible');
        expect(decision['estimated_target_outcome'], 'met');
        expect(
          candidate.metrics.estimatedRequestTokensAfter,
          lessThanOrEqualTo(_target),
        );
        // The tail is the remainder after the measured fixed overhead and the
        // summary, not the whole target.
        final overhead = decision['fixed_overhead_tokens'] as int;
        expect(overhead, greaterThanOrEqualTo(8_944 + 2_000));
        expect(
          candidate.metrics.retainedTailTokens + overhead,
          lessThan(_target),
        );
      },
    );

    test(
      'fixed overhead above the target compacts safely and reports measured infeasibility',
      () async {
        final candidate = await ContextCompactionEngine(
          summarizer: _FixedSummarizer(),
        ).buildCandidate(_request(systemTokens: 30_000), force: true);

        expect(candidate, isNotNull);
        final decision = candidate!.diagnostics!.decisionSnapshot!;
        expect(decision['target_feasibility'], 'infeasible');
        expect(decision['estimated_target_outcome'], 'not_met');
        expect(decision['fixed_overhead_tokens'], greaterThan(_target));
        // Only the newest connected exchange is retained; nothing is dropped
        // from the system prompt or tools to force a fit.
        expect(candidate.retainedTailRange.start.rowId, 239);
        expect(
          candidate.metrics.estimatedRequestTokensAfter,
          lessThan(candidate.metrics.estimatedRequestTokensBefore),
        );
      },
    );
  });
}
