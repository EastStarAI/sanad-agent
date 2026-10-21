import 'dart:convert';

import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:test/test.dart';

/// Task 117 (0P-F2): bounded recovery summarizer limits.
const _route = RouteSignature(
  providerInstanceId: 'provider-1',
  templateId: 'openai',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'gpt-test',
  configRevision: 1,
  credentialRevision: 1,
);

const _contextWindow = 12_000;
const _toolSchemas = [
  {
    'name': 'read_file',
    'description': 'Read a file',
    'parameters': {'type': 'object'},
  },
];

String _summaryJson({String goal = 'finish the task', String padding = ''}) =>
    jsonEncode({
      'schemaVersion': 1,
      'currentGoal': goal,
      'latestUserRequest': 'finish the task',
      'successCriteria': 'tests pass',
      'constraints': 'none',
      'completedWork': 'discovery',
      'activeState': 'implementing',
      'criticalContext': 'port 58085 $padding',
      'decisions': 'typed JSON',
      'blockers': 'none',
      'filesAndPaths': 'agent/lib/example.dart',
      'pendingAsks': 'finish',
      'remainingWork': 'run tests',
    });

/// A source of [windows] context windows of assistant text, plus a short tail.
List<IndexedConversationMessage> _timeline({
  required double windows,
  int messageChars = 2_400,
  String? oversizedMessage,
}) {
  final perMessageTokens = messageChars ~/ 4;
  final count = (windows * _contextWindow / perMessageTokens).ceil();
  var rowId = 1;
  return [
    IndexedConversationMessage(
      rowId: rowId++,
      message: Message(role: MessageRole.user, content: 'finish the task'),
    ),
    if (oversizedMessage != null)
      IndexedConversationMessage(
        rowId: rowId++,
        message: Message(
          role: MessageRole.assistant,
          content: oversizedMessage,
        ),
      ),
    for (var index = 0; index < count; index++)
      IndexedConversationMessage(
        rowId: rowId++,
        message: Message(
          role: MessageRole.assistant,
          content: 'step $index ${'w' * messageChars}',
        ),
      ),
    IndexedConversationMessage(
      rowId: rowId++,
      message: Message(role: MessageRole.user, content: 'continue'),
    ),
    IndexedConversationMessage(
      rowId: rowId++,
      message: Message(role: MessageRole.assistant, content: 'continuing'),
    ),
  ];
}

CompactionEngineRequest _request(
  List<IndexedConversationMessage> timeline, {
  CompactionInternalSummary? previousSummary,
}) {
  return CompactionEngineRequest(
    compactionId: 'cmp-117',
    sessionId: 'session-117',
    trigger: CompactionTrigger.auto,
    sourceRevision: const CompactionHistoryRevision(1),
    routeSignature: _route,
    contextWindowTokens: _contextWindow,
    timeline: timeline,
    systemPrompt: 'stable system',
    runtimeContext: '',
    toolSchemas: _toolSchemas,
    providerProjection: [
      Message(role: MessageRole.system, content: 'stable system'),
      ...timeline.map((entry) => entry.message),
    ],
    providerTools: [
      ToolSchema(
        name: 'read_file',
        description: 'Read a file',
        parameters: const {'type': 'object'},
      ),
    ],
    providerRequestOptions: const LLMRequestOptions(
      sessionId: 'session-117',
      requestId: 'compaction:cmp-117',
    ),
    previousSummary: previousSummary,
    targetRequestTokens: 1_000,
    thresholdRatio: 0.10,
  );
}

int _requestTokens(CompactionProviderRequest request) =>
    CompactionTokenEstimator.estimateMessages(request.baseProjection) +
    CompactionTokenEstimator.estimateMediaTokens(request.baseProjection) +
    CompactionTokenEstimator.estimateText(request.instruction) +
    CompactionTokenEstimator.estimateToolSchemas(_toolSchemas);

/// Rejects any request whose estimate exceeds [limitTokens] with a provider
/// overflow, like a real context window would.
class _WindowedProvider
    implements CompactionSummarizer, ProviderProjectionCompactionSummarizer {
  final int limitTokens;
  final String Function(CompactionProviderRequest request) respond;
  final requests = <CompactionProviderRequest>[];
  final overflowed = <CompactionProviderRequest>[];

  _WindowedProvider(
    this.limitTokens, {
    String Function(CompactionProviderRequest)? respond,
  }) : respond = respond ?? ((_) => _summaryJson());

  @override
  Future<String> summarize({required String prompt}) =>
      throw UnsupportedError('provider path expected');

  @override
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  ) async {
    requests.add(request);
    if (_requestTokens(request) > limitTokens) {
      overflowed.add(request);
      throw const CompactionProviderOverflow();
    }
    return CompactionProviderResult(
      content: respond(request),
      usage: const {'prompt_tokens': 100, 'completion_tokens': 20},
      duration: const Duration(milliseconds: 1),
    );
  }
}

int _effectiveBudget(CompactionEngineRequest request) =>
    ContextCompactionEngine().measurePressure(request).effectiveInputBudget;

void main() {
  test('T9 a source of six windows recovers with every request in budget and '
      'a bounded call count', () async {
    final request = _request(_timeline(windows: 6));
    final budget = _effectiveBudget(request);
    final provider = _WindowedProvider(budget);

    final candidate = await ContextCompactionEngine(
      summarizer: provider,
    ).buildCandidate(request);

    expect(candidate, isNotNull);
    final decision = candidate!.diagnostics!.decisionSnapshot!;
    final chunks = decision['recovery_chunk_count'] as int;
    expect(
      chunks,
      inInclusiveRange(2, CompactionRecoveryPolicy.defaults.maxChunks),
    );
    // Only the doomed ordinary pass overflowed.
    expect(provider.overflowed, hasLength(1));
    for (final sent in provider.requests.skip(1)) {
      expect(_requestTokens(sent), lessThanOrEqualTo(budget));
    }
    // ordinary pass + one call per chunk + reduce batches + final reduce
    expect(
      provider.requests.length,
      1 + chunks + (decision['recovery_reduce_batches'] as int) + 1,
    );
    expect(decision['recovery_provider_calls'], provider.requests.length - 1);
    expect(decision['recovery_pass_budget_tokens'], lessThan(budget));
  });

  test(
    'T10 the eligible previous summary is carried into the reduce',
    () async {
      final request = _request(
        _timeline(windows: 2),
        previousSummary: const CompactionInternalSummary(
          currentGoal: 'PREVIOUS-ANCHOR-117',
          remainingWork: 'earlier work',
        ),
      );
      final provider = _WindowedProvider(_effectiveBudget(request));

      await ContextCompactionEngine(
        summarizer: provider,
      ).buildCandidate(request);

      final reduce = provider.requests.last;
      expect(reduce.options.requestId, endsWith(':reduce:0'));
      final reduceInput = reduce.baseProjection.last.content!;
      final items = jsonDecode(reduceInput) as List;
      expect((items.first as Map)['currentGoal'], 'PREVIOUS-ANCHOR-117');
    },
  );

  test(
    'T11 a source over capacity fails before any recovery provider call',
    () async {
      final request = _request(_timeline(windows: 6));
      final provider = _WindowedProvider(_effectiveBudget(request));
      final engine = ContextCompactionEngine(
        summarizer: provider,
        recoveryPolicy: const CompactionRecoveryPolicy(
          passBudgetSafetyRatio: 0.80,
          maxChunks: 3,
          minPassBudgetTokens: 512,
        ),
      );

      final failure = await engine
          .buildCandidate(request)
          .then<CompactionEngineFailure?>((_) => null)
          .catchError((Object error) => error as CompactionEngineFailure);

      expect(failure, isNotNull);
      expect(failure!.cause, CompactionFailureCause.recoveryCapacityExceeded);
      expect(failure.stage, CompactionFailureStage.pruning);
      // The ordinary pass only; no recovery request was sent.
      expect(provider.requests, hasLength(1));
      final decision = failure.diagnostics!.decisionSnapshot!;
      expect(decision['recovery_chunk_count'], greaterThan(3));
      expect(decision['recovery_max_chunks'], 3);
      expect(decision['recovery_provider_calls'], 0);
    },
  );

  test(
    'an oversized single message is capped with an explicit marker',
    () async {
      final request = _request(
        _timeline(windows: 1, oversizedMessage: 'HEAD ${'o' * 60_000} TAIL'),
      );
      final budget = _effectiveBudget(request);
      final provider = _WindowedProvider(budget);

      final candidate = await ContextCompactionEngine(
        summarizer: provider,
      ).buildCandidate(request);

      expect(candidate, isNotNull);
      final capped = provider.requests
          .skip(1)
          .expand((sent) => sent.baseProjection)
          .map((message) => message.content ?? '')
          .firstWhere((content) => content.contains('chars for summary]'));
      expect(capped, startsWith('HEAD '));
      expect(capped, endsWith(' TAIL'));
      expect(capped, matches(RegExp(r'\[truncated \d+ chars for summary\]')));
      for (final sent in provider.requests.skip(1)) {
        expect(_requestTokens(sent), lessThanOrEqualTo(budget));
      }
    },
  );

  test('large partials are reduced in budget-packed batches', () async {
    final request = _request(_timeline(windows: 6));
    final budget = _effectiveBudget(request);
    // Each chunk partial is about a third of the budget, so one reduce
    // request cannot hold them all.
    final provider = _WindowedProvider(
      budget,
      respond: (sent) => sent.instruction.contains('partial checkpoint')
          ? _summaryJson(padding: 'p' * (budget * 4 ~/ 3))
          : _summaryJson(),
    );

    final candidate = await ContextCompactionEngine(
      summarizer: provider,
    ).buildCandidate(request);

    expect(candidate, isNotNull);
    final decision = candidate!.diagnostics!.decisionSnapshot!;
    expect(decision['recovery_reduce_batches'], greaterThan(0));
    final ids = provider.requests.map((sent) => sent.options.requestId!);
    expect(
      ids.where((id) => RegExp(r':reduce:\d+_\d+$').hasMatch(id)),
      isNotEmpty,
    );
    expect(ids.last, endsWith(':reduce:0'));
    expect(provider.overflowed, hasLength(1));
    for (final sent in provider.requests.skip(1)) {
      expect(_requestTokens(sent), lessThanOrEqualTo(budget));
    }
  });

  test('an overflowing chunk is split at most once', () async {
    final request = _request(_timeline(windows: 3));
    final budget = _effectiveBudget(request);
    // The provider window is smaller than the estimate believes: a full
    // chunk overflows, each half fits.
    final provider = _WindowedProvider((budget * 0.55).floor());

    final candidate = await ContextCompactionEngine(
      summarizer: provider,
    ).buildCandidate(request);

    expect(candidate, isNotNull);
    final decision = candidate!.diagnostics!.decisionSnapshot!;
    final chunks = decision['recovery_chunk_count'] as int;
    expect(decision['recovery_split_count'], greaterThan(0));
    expect(decision['recovery_split_count'], lessThanOrEqualTo(chunks));
    // Bounded: each chunk costs at most one overflow plus two halves.
    expect(
      provider.requests.length,
      lessThanOrEqualTo(1 + chunks * 3 + chunks + 1),
    );
  });

  test(
    'a chunk whose halves still overflow fails without further splitting',
    () async {
      final request = _request(_timeline(windows: 3));
      final budget = _effectiveBudget(request);
      final provider = _WindowedProvider((budget * 0.2).floor());

      final failure = await ContextCompactionEngine(summarizer: provider)
          .buildCandidate(request)
          .then<CompactionEngineFailure?>((_) => null)
          .catchError((Object error) => error as CompactionEngineFailure);

      expect(failure, isNotNull);
      expect(failure!.cause, CompactionFailureCause.overflow);
      // ordinary pass + first chunk + its first half (which overflows again)
      expect(provider.requests, hasLength(3));
    },
  );
}
