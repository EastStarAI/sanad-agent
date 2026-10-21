import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/llm_provider_state.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:test/test.dart';

/// Task 118 Stage3A replay-aware tail selection.
///
/// Privacy-safe synthetic pair modelled on Task 106's production observation
/// (same route, effort, instructions and tools in both operations):
///
/// | case | replay items | tool/result pairs | estimated tail | provider tail |
/// |------|--------------|-------------------|----------------|---------------|
/// | A    | 4            | 8                 | 20031          | 19689         |
/// | B    | 23           | 39                | 20666          | 32557         |
///
/// Provider receipts are fixture-scoped: every assistant row of the active
/// run carries `context_usage` produced by [_Fixture], bound to the fixture
/// wire measurement by a real `wire_proof`. The fixture wire codec prices
/// visible text only and never the opaque `encrypted_content` replay state,
/// exactly like the production codecs.

const _route = RouteSignature(
  providerInstanceId: 'provider-replay',
  templateId: 'openai',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'replay-model',
  configRevision: 1,
  credentialRevision: 1,
);

String _text(int tokens) => 'word ' * (tokens * 4 ~/ 5);

Map<String, dynamic> _toolSchema() => {
  'name': 'workspace_shell',
  'description': _text(2_100),
  'parameters': const {'type': 'object', 'properties': <String, dynamic>{}},
};

class _Case {
  final String name;
  final int pairs;
  final Set<int> replayPairs;
  final int estimatedTail;
  final int providerTail;
  final int replayCost;
  final int toolResultTokens;

  const _Case({
    required this.name,
    required this.pairs,
    required this.replayPairs,
    required this.estimatedTail,
    required this.providerTail,
    required this.replayCost,
    required this.toolResultTokens,
  });
}

final _caseA = _Case(
  name: 'A',
  pairs: 8,
  replayPairs: const {1, 3, 5, 7},
  estimatedTail: 20031,
  providerTail: 19689,
  replayCost: 478,
  toolResultTokens: 2000,
);

final _caseB = _Case(
  name: 'B',
  pairs: 39,
  replayPairs: {for (var i = 1; i <= 23; i++) i},
  estimatedTail: 20666,
  providerTail: 32557,
  replayCost: 418,
  toolResultTokens: 400,
);

/// Deterministic wire codec of the fixture route: visible fields priced by
/// the provider-neutral estimator, opaque provider state excluded from the
/// price but part of each item's identity.
class _FixtureWire {
  final int toolTokens = CompactionTokenEstimator.estimateToolSchemas([
    _toolSchema(),
  ]);

  static String _item(Message message) => jsonEncode({
    'role': message.role.name,
    'content': message.content,
    'tool_calls': [
      for (final call in message.toolCalls ?? const <ToolCall>[])
        '${call.id}|${call.name}|${jsonEncode(call.arguments)}',
    ],
    'tool_call_id': message.toolCallId,
    'state': message.providerState?.toJson(),
  });

  Future<WireInputMeasurement?> call(List<Message> projection) async =>
      WireInputMeasurement(
        estimatedTokens:
            CompactionTokenEstimator.estimateMessages(projection) + toolTokens,
        stableMaterialFingerprint: 'fixture-stable-v1',
        inputItemFingerprints: [
          for (final message in projection)
            sha256.convert(utf8.encode(_item(message))).toString(),
        ],
      );
}

class _Fixture {
  final _Case shape;
  final List<IndexedConversationMessage> timeline;
  final List<Message> projection;
  final List<int> providerCost;
  final int tailStartIndex;
  final _FixtureWire wire;

  _Fixture._(
    this.shape,
    this.timeline,
    this.projection,
    this.providerCost,
    this.tailStartIndex,
    this.wire,
  );

  /// Provider-attributed cost of the rows from [start] to the end.
  int providerTokensFrom(int start) =>
      providerCost.skip(start).fold(0, (sum, value) => sum + value);

  int estimatedTokensFrom(int start) =>
      CompactionTokenEstimator.estimateMessages(
        timeline.skip(start).map((entry) => entry.message),
      );

  static Future<_Fixture> build(
    _Case shape, {
    int systemTokens = 8_944,
    bool replayOnNewestAssistant = false,
    String receiptModel = 'replay-model',
    bool staleProof = false,
    bool withReceipts = true,
  }) async {
    final wire = _FixtureWire();
    final system = Message(
      role: MessageRole.system,
      content: _text(systemTokens),
    );
    final rows = <Message>[
      for (var turn = 0; turn < 40; turn++) ...[
        Message(role: MessageRole.user, content: 'earlier ${_text(1000)}'),
        Message(role: MessageRole.assistant, content: 'reply ${_text(1000)}'),
      ],
    ];
    final tailStart = rows.length;
    final pairs = <Message>[];
    final replay = {
      ...shape.replayPairs,
      if (replayOnNewestAssistant) shape.pairs,
    };
    for (var pair = 1; pair <= shape.pairs; pair++) {
      pairs.add(
        Message(
          role: MessageRole.assistant,
          toolCalls: [
            ToolCall(
              id: 'call-$pair',
              name: 'shell',
              arguments: {'cmd': 'step $pair'},
            ),
          ],
          providerState: replay.contains(pair)
              ? LLMProviderState(
                  namespace: 'fixture',
                  issuer: 'fixture-issuer',
                  data: {
                    'reasoning_items': [
                      {
                        'type': 'reasoning',
                        'id': 'rs_$pair',
                        'encrypted_content': 'gAAAA${'Q' * 1200}',
                      },
                    ],
                  },
                )
              : null,
        ),
      );
      pairs.add(
        Message(
          role: MessageRole.tool,
          toolCallId: 'call-$pair',
          content: 'out $pair ${_text(shape.toolResultTokens)}',
        ),
      );
    }
    // The run's user request is padded so the tail estimate is exact.
    final pairsEstimate = CompactionTokenEstimator.estimateMessages(pairs);
    final userTokens = shape.estimatedTail - pairsEstimate;
    var user = Message(role: MessageRole.user, content: _text(userTokens));
    final userDrift =
        CompactionTokenEstimator.estimateMessage(user) - userTokens;
    if (userDrift != 0) {
      user = Message(
        role: MessageRole.user,
        content: _text(userTokens - userDrift),
      );
    }
    rows
      ..add(user)
      ..addAll(pairs);

    // Fixture provider: visible text at the estimator rate, plus each replay
    // item's own cost, plus a per-tool-result tokenizer adjustment that
    // reproduces the observed provider totals. The newest pair and the user
    // request lie outside the receipt-proven span and cost their estimate.
    final cost = [
      for (final row in rows) CompactionTokenEstimator.estimateMessage(row),
    ];
    final coveredPairs = shape.pairs - 1;
    final replayInSpan =
        replay.where((pair) => pair <= coveredPairs).length * shape.replayCost;
    var adjustment = shape.providerTail - shape.estimatedTail - replayInSpan;
    for (var pair = 1; pair <= coveredPairs; pair++) {
      final assistant = tailStart + 1 + (pair - 1) * 2;
      if (replay.contains(pair)) cost[assistant] += shape.replayCost;
      final share = adjustment ~/ (coveredPairs - pair + 1);
      cost[assistant + 1] += share;
      adjustment -= share;
    }
    if (replay.contains(shape.pairs)) {
      // Unknown at selection time: the newest item has no later receipt.
      cost[rows.length - 2] += shape.replayCost;
    }

    final fixedProvider = (await wire([system]))!.estimatedTokens;
    final stamped = <Message>[];
    var input = fixedProvider;
    for (var index = 0; index < rows.length; index++) {
      final row = rows[index];
      final inRun = index > tailStart && row.role == MessageRole.assistant;
      if (withReceipts && inRun) {
        final prefix = (await wire([system, ...rows.sublist(0, index)]))!;
        final proof = RequestPressureEvaluator.wireProof(
          wireMeasurement: prefix,
          routeSignature: _route,
        );
        stamped.add(
          Message(
            role: row.role,
            toolCalls: row.toolCalls,
            providerState: row.providerState,
            metadata: {
              'context_usage': {
                'input_tokens': input,
                'provider_instance_id': _route.providerInstanceId,
                'model_id': receiptModel,
                'wire_proof': staleProof ? 'v1:${'0' * 64}' : proof,
              },
            },
          ),
        );
      } else {
        stamped.add(row);
      }
      input += cost[index];
    }
    return _Fixture._(
      shape,
      [
        for (var index = 0; index < stamped.length; index++)
          IndexedConversationMessage(rowId: index + 1, message: stamped[index]),
      ],
      [system, ...stamped],
      cost,
      tailStart,
      wire,
    );
  }

  CompactionEngineRequest request({int window = 258_000}) =>
      CompactionEngineRequest(
        compactionId: 'cmp-replay-${shape.name}',
        sessionId: 'session-replay',
        trigger: CompactionTrigger.auto,
        sourceRevision: const CompactionHistoryRevision(1),
        routeSignature: _route,
        contextWindowTokens: window,
        timeline: timeline,
        systemPrompt: projection.first.content!,
        runtimeContext: '',
        toolSchemas: [_toolSchema()],
        providerProjection: projection,
        providerTools: [ToolSchema.fromJson(_toolSchema())],
        targetRequestTokens: CompactionTargetPolicy.targetRequestTokens(
          windowTokens: window,
          ratio: 0.10,
        ),
        thresholdRatio: 0.90,
        targetRatio: 0.10,
        wireMeter: wire.call,
      );
}

class _Summarizer
    implements CompactionSummarizer, ProviderProjectionCompactionSummarizer {
  @override
  Future<String> summarize({required String prompt}) async =>
      throw UnimplementedError();

  @override
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  ) async => CompactionProviderResult(
    content: jsonEncode(
      CompactionSummaryPrompt.toJsonMap(
        CompactionInternalSummary(
          currentGoal: 'finish the multi-step run',
          latestUserRequest: 'continue',
          activeState: 'running tool steps',
          criticalContext: 'step outputs so far',
          remainingWork: _text(400),
        ),
      ),
    ),
    usage: const {'input_tokens': 120_000, 'output_tokens': 500},
    duration: const Duration(milliseconds: 5),
  );
}

void main() {
  group('Task 118 replay-aware tail pricing (fixture receipts)', () {
    for (final shape in [_caseA, _caseB]) {
      test(
        'case ${shape.name}: ${shape.replayPairs.length} replay items and '
        '${shape.pairs} tool pairs cost the provider-attributed '
        '${shape.providerTail}, not the estimated ${shape.estimatedTail}',
        () async {
          final fixture = await _Fixture.build(shape);
          expect(
            fixture.estimatedTokensFrom(fixture.tailStartIndex),
            shape.estimatedTail,
          );
          expect(
            fixture.providerTokensFrom(fixture.tailStartIndex),
            shape.providerTail,
          );

          final measurement = await ContextCompactionEngine().measureRequest(
            fixture.request(window: 600_000),
          );
          final cost = measurement.tailCosts![fixture.tailStartIndex]!;
          expect(cost.tokens, shape.providerTail);
          expect(cost.kind, CompactionMeasurementKind.mixed);
          expect(cost.unprovenReplayItems, 0);
          expect(measurement.tailCosts!.provenReceipts, shape.pairs);
          expect(measurement.requestKind, CompactionMeasurementKind.mixed);
        },
      );
    }

    test(
      'case B selects a tail whose provider-attributed cost fits the remainder',
      () async {
        final fixture = await _Fixture.build(_caseB);
        final candidate = await ContextCompactionEngine(
          summarizer: _Summarizer(),
        ).buildCandidate(fixture.request(), force: true);

        expect(candidate, isNotNull);
        final decision = candidate!.diagnostics!.decisionSnapshot!;
        final start = fixture.timeline.indexWhere(
          (entry) => entry.rowId == candidate.retainedTailRange.start.rowId,
        );
        final providerTail = fixture.providerTokensFrom(start);
        expect(
          providerTail,
          lessThanOrEqualTo(decision['tail_budget_tokens'] as int),
        );
        expect(decision['retained_tail_cost_kind'], 'mixed');
        expect(decision['retained_tail_tokens'], providerTail);
        // Priced by the provider-neutral estimate the same budget admits an
        // older start whose actual cost overshoots: the Task 106 defect.
        final naive = const CompactionTailSelector().select(
          timeline: fixture.timeline,
          tailTokenBudget: decision['tail_budget_tokens'] as int,
        );
        final naiveStart = fixture.timeline.length - naive.tailMessages.length;
        expect(naiveStart, lessThan(start));
        expect(
          fixture.providerTokensFrom(naiveStart),
          greaterThan(decision['tail_budget_tokens'] as int),
        );
      },
    );

    test('case A stays within tolerance and meets a feasible target', () async {
      final fixture = await _Fixture.build(_caseA);
      final candidate = await ContextCompactionEngine(
        summarizer: _Summarizer(),
      ).buildCandidate(fixture.request(window: 400_000), force: true);

      final decision = candidate!.diagnostics!.decisionSnapshot!;
      expect(decision['target_feasibility'], 'feasible');
      expect(decision['estimated_target_outcome'], 'met');
      expect(
        candidate.metrics.estimatedRequestTokensAfter,
        lessThanOrEqualTo(40_000),
      );
    });

    test(
      'infeasible target keeps instructions, tools and replay intact',
      () async {
        final fixture = await _Fixture.build(_caseB, systemTokens: 30_000);
        final request = fixture.request();
        final candidate = await ContextCompactionEngine(
          summarizer: _Summarizer(),
        ).buildCandidate(request, force: true);

        final decision = candidate!.diagnostics!.decisionSnapshot!;
        expect(decision['target_feasibility'], 'infeasible');
        expect(decision['estimated_target_outcome'], 'not_met');
        expect(request.providerTools, hasLength(1));
        // The newest connected exchange (assistant call + result) is kept
        // verbatim with its provider state.
        expect(
          candidate.retainedTailRange.start.rowId,
          fixture.timeline[fixture.timeline.length - 2].rowId,
        );
      },
    );
  });

  group('Task 118 unproven replay cost stays unknown', () {
    for (final (label, build) in <(String, Future<_Fixture> Function())>[
      ('stale wire proof', () => _Fixture.build(_caseB, staleProof: true)),
      (
        'receipt from another model',
        () => _Fixture.build(_caseB, receiptModel: 'other-model'),
      ),
      ('no receipts', () => _Fixture.build(_caseB, withReceipts: false)),
    ]) {
      test(
        '$label: estimated cost with every replay item counted unknown',
        () async {
          final fixture = await build();
          final measurement = await ContextCompactionEngine().measureRequest(
            fixture.request(window: 600_000),
          );
          final cost = measurement.tailCosts![fixture.tailStartIndex]!;
          expect(cost.kind, CompactionMeasurementKind.estimated);
          expect(cost.confirmedTokens, 0);
          expect(cost.unprovenReplayItems, _caseB.replayPairs.length);
          expect(measurement.tailCosts!.provenReceipts, 0);
        },
      );
    }

    test(
      'the newest replay item after the last receipt is unknown and the outcome is not claimed',
      () async {
        final fixture = await _Fixture.build(
          _caseA,
          replayOnNewestAssistant: true,
        );
        final measurement = await ContextCompactionEngine().measureRequest(
          fixture.request(window: 600_000),
        );
        final cost = measurement.tailCosts![fixture.tailStartIndex]!;
        expect(cost.unprovenReplayItems, 1);

        final candidate = await ContextCompactionEngine(
          summarizer: _Summarizer(),
        ).buildCandidate(fixture.request(window: 400_000), force: true);
        final decision = candidate!.diagnostics!.decisionSnapshot!;
        expect(decision['unproven_replay_items'], greaterThan(0));
        expect(decision['estimated_target_outcome'], 'unknown');
      },
    );
  });
}
