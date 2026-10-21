import 'dart:async';
import 'dart:convert';

import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

/// Task 118 Stage2: bounded handling of failed summary shapes through the
/// real provider-backed summarizer classification.
const _route = RouteSignature(
  providerInstanceId: 'provider-1',
  templateId: 'openai',
  protocol: 'openai_compatible',
  normalizedBaseUrl: 'https://api.example.com/v1',
  modelId: 'slow-model',
  configRevision: 1,
  credentialRevision: 1,
);

/// Raw provider text that must never reach durable diagnostics.
const _privateMarker = 'PRIVATE-SUMMARY-TEXT-7f3a';

String _validJson() => jsonEncode({
  'schemaVersion': 1,
  'currentGoal': 'finish the migration',
  'latestUserRequest': 'finish the migration',
  'successCriteria': 'tests pass',
  'constraints': 'none',
  'completedWork': 'discovery',
  'activeState': 'implementing',
  'criticalContext': 'finish the migration',
  'decisions': 'typed JSON',
  'blockers': 'none',
  'filesAndPaths': 'agent/lib/example.dart',
  'pendingAsks': 'none',
  'remainingWork': 'run tests',
});

/// Valid JSON with every key, but a string field holds structured data
/// (live r2 on gpt-4o-mini: `filesAndPaths` was an object).
String _typedFieldJson(Object value) {
  final map = jsonDecode(_validJson()) as Map<String, dynamic>;
  map['filesAndPaths'] = value;
  return jsonEncode(map);
}

enum _Shape {
  valid,
  objectField,
  listField,
  empty,
  reasoningOnly,
  truncated,
  invalidJson,
  toolCall,
  incomplete,
  timeout,
  overflow,
}

class _ScriptedAdapter implements LLMAdapter {
  _ScriptedAdapter(this.script);

  final List<_Shape> script;
  int calls = 0;

  /// The appended compaction instruction of every call, in order.
  final instructions = <String>[];

  @override
  Future<AgentResponse> generateResponse(
    List<Message> history, {
    List<ToolSchema>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    final shape = script[calls++];
    instructions.add(history.last.content ?? '');
    const usage = {'prompt_tokens': 100, 'completion_tokens': 10};
    switch (shape) {
      case _Shape.objectField:
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: _typedFieldJson({'files': [_privateMarker]}),
          ),
          usage: usage,
          finishReason: LLMFinishReason.stop,
        );
      case _Shape.listField:
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: _typedFieldJson([_privateMarker, 'agent/lib/b.dart']),
          ),
          usage: usage,
          finishReason: LLMFinishReason.stop,
        );
      case _Shape.valid:
        return AgentResponse(
          message: Message(role: MessageRole.assistant, content: _validJson()),
          usage: usage,
          finishReason: LLMFinishReason.stop,
        );
      case _Shape.empty:
        return AgentResponse(
          message: Message(role: MessageRole.assistant, content: '  '),
          usage: usage,
          finishReason: LLMFinishReason.stop,
        );
      case _Shape.reasoningOnly:
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: '<think>$_privateMarker</think>',
            reasoning: _privateMarker,
          ),
          usage: usage,
          finishReason: LLMFinishReason.stop,
        );
      case _Shape.truncated:
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: '{"schemaVersion":1,"currentGoal":"$_privateMarker',
          ),
          usage: usage,
          finishReason: LLMFinishReason.length,
        );
      case _Shape.invalidJson:
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: 'Here is the summary: $_privateMarker',
          ),
          usage: usage,
          finishReason: LLMFinishReason.stop,
        );
      case _Shape.toolCall:
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: _privateMarker,
            toolCalls: [
              ToolCall(id: 'call-1', name: 'shell_execute', arguments: {}),
            ],
          ),
          isToolCall: true,
          usage: usage,
          finishReason: LLMFinishReason.toolCalls,
        );
      case _Shape.incomplete:
        return AgentResponse(
          message: Message(
            role: MessageRole.assistant,
            content: '{"schemaVersion":1,"currentGoal":"$_privateMarker',
          ),
          usage: usage,
          finishReason: LLMFinishReason.failed,
        );
      case _Shape.timeout:
        await Future<void>.delayed(const Duration(milliseconds: 5));
        throw TimeoutException('generateResponse');
      case _Shape.overflow:
        throw const LlmHttpException(
          statusCode: 400,
          body: 'maximum context length exceeded',
          headers: {},
          operation: 'chat.completions',
        );
    }
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
  _Runtime(super.config, super.repo, this.adapter);

  final LLMAdapter adapter;

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) =>
      _route;

  @override
  LLMAdapter adapterFor(RouteSignature signature) => adapter;
}

CompactionEngineRequest _request() => CompactionEngineRequest(
  compactionId: 'cmp-shapes',
  sessionId: 'session-shapes',
  trigger: CompactionTrigger.auto,
  sourceRevision: const CompactionHistoryRevision(1),
  routeSignature: _route,
  contextWindowTokens: 8_000,
  timeline: [
    IndexedConversationMessage(
      rowId: 1,
      message: Message(role: MessageRole.user, content: 'finish the migration'),
    ),
    for (var index = 2; index <= 35; index++)
      IndexedConversationMessage(
        rowId: index,
        message: Message(
          role: MessageRole.assistant,
          content: 'progress $index ${'x' * 160}',
        ),
      ),
  ],
  systemPrompt: 'stable system',
  runtimeContext: '',
  toolSchemas: const [],
  providerProjection: [
    Message(role: MessageRole.system, content: 'stable system'),
    Message(role: MessageRole.user, content: 'finish the migration'),
  ],
  providerRequestOptions: const LLMRequestOptions(
    sessionId: 'session-shapes',
    requestId: 'compaction:cmp-shapes',
  ),
  targetRequestTokens: 3_000,
  thresholdRatio: 0.10,
);

/// A request whose full summary pass is close to the 8000-token window
/// (Task 118b round 5 pre-send fit check).
CompactionEngineRequest _nearWindowRequest({required int maxOutputTokens}) {
  final rows = [
    IndexedConversationMessage(
      rowId: 1,
      message: Message(role: MessageRole.user, content: 'finish the migration'),
    ),
    for (var index = 2; index <= 31; index++)
      IndexedConversationMessage(
        rowId: index,
        message: Message(
          role: MessageRole.assistant,
          content: 'progress $index ${'word ' * 180}',
        ),
      ),
  ];
  return CompactionEngineRequest(
    compactionId: 'cmp-presend',
    sessionId: 'session-shapes',
    trigger: CompactionTrigger.auto,
    sourceRevision: const CompactionHistoryRevision(1),
    routeSignature: _route,
    contextWindowTokens: 8_000,
    timeline: rows,
    systemPrompt: 'stable system',
    runtimeContext: '',
    toolSchemas: const [],
    providerProjection: [
      Message(role: MessageRole.system, content: 'stable system'),
      for (final row in rows) row.message,
    ],
    providerRequestOptions: LLMRequestOptions(
      sessionId: 'session-shapes',
      requestId: 'compaction:cmp-presend',
      maxOutputTokens: maxOutputTokens,
    ),
    targetRequestTokens: 3_000,
    thresholdRatio: 0.10,
  );
}

/// A request at a 1M window carrying [requestTokens] of history and a
/// declared [declaredOutput] from route capability (Task 118b review).
CompactionEngineRequest _largeWindowRequest({
  required int requestTokens,
  required int declaredOutput,
}) {
  const perRow = 50_000;
  final rows = [
    IndexedConversationMessage(
      rowId: 1,
      message: Message(role: MessageRole.user, content: 'finish the migration'),
    ),
    for (var index = 0; index < requestTokens ~/ perRow; index++)
      IndexedConversationMessage(
        rowId: index + 2,
        message: Message(
          role: MessageRole.assistant,
          content: 'x' * (perRow * 4),
        ),
      ),
  ];
  return CompactionEngineRequest(
    compactionId: 'cmp-large-window',
    sessionId: 'session-shapes',
    trigger: CompactionTrigger.auto,
    sourceRevision: const CompactionHistoryRevision(1),
    routeSignature: _route,
    contextWindowTokens: 1_000_000,
    timeline: rows,
    systemPrompt: 'stable system',
    runtimeContext: '',
    toolSchemas: const [],
    providerProjection: [
      Message(role: MessageRole.system, content: 'stable system'),
      for (final row in rows) row.message,
    ],
    providerRequestOptions: const LLMRequestOptions(
      sessionId: 'session-shapes',
      requestId: 'compaction:cmp-large-window',
    ),
    targetRequestTokens: 100_000,
    thresholdRatio: 0.90,
    outputReservationTokens: declaredOutput,
    outputReservationSource: 'models_dev',
  );
}

void main() {
  late AgentStateDatabase state;

  setUp(() => state = AgentStateDatabase.inMemory());
  tearDown(() => state.dispose());

  ContextCompactionEngine engineFor(_ScriptedAdapter adapter) =>
      ContextCompactionEngine(
        summarizer: ProviderBackedCompactionSummarizer(
          _Runtime(
            Config(),
            ProviderInstanceRepository.fromDatabase(state.db),
            adapter,
          ),
        ),
      );

  const expectations = <_Shape, ({String ledgerReason, String cause})>{
    _Shape.empty: (
      ledgerReason: CompactionFailureCause.summaryEmpty,
      cause: CompactionFailureCause.summaryEmpty,
    ),
    _Shape.reasoningOnly: (
      ledgerReason: CompactionFailureCause.summaryReasoningOnly,
      cause: CompactionFailureCause.summaryReasoningOnly,
    ),
    _Shape.truncated: (
      ledgerReason: CompactionFailureCause.summaryTruncated,
      cause: CompactionFailureCause.summaryTruncated,
    ),
    _Shape.invalidJson: (
      ledgerReason: CompactionFailureCause.summaryInvalidJson,
      cause: CompactionFailureCause.invalidResponse,
    ),
    // Task 118b D3: a field of the wrong type is a schema mismatch, not
    // unparseable JSON.
    _Shape.objectField: (
      ledgerReason: CompactionFailureCause.summarySchemaMismatch,
      cause: CompactionFailureCause.invalidResponse,
    ),
    _Shape.listField: (
      ledgerReason: CompactionFailureCause.summarySchemaMismatch,
      cause: CompactionFailureCause.invalidResponse,
    ),
    _Shape.toolCall: (
      ledgerReason: CompactionFailureCause.summaryToolCall,
      cause: CompactionFailureCause.invalidResponse,
    ),
    _Shape.incomplete: (
      ledgerReason: CompactionFailureCause.summaryIncomplete,
      cause: CompactionFailureCause.invalidResponse,
    ),
  };

  for (final entry in expectations.entries) {
    final shape = entry.key;
    group('${shape.name} summary', () {
      test(
        'one corrective attempt then valid success and accounting',
        () async {
          final adapter = _ScriptedAdapter([shape, _Shape.valid]);
          final candidate = await engineFor(adapter).buildCandidate(_request());

          expect(candidate, isNotNull);
          expect(adapter.calls, 2);
          expect(candidate!.metrics.summarizationAttempts, 2);
          expect(candidate.metrics.summarizationInputTokens, 200);
          final attempts = candidate.diagnostics!.attempts;
          expect(attempts.map((a) => a.outcome), [
            'invalid_response',
            'success',
          ]);
          expect(attempts.first.failureReason, entry.value.ledgerReason);
          expect(attempts.first.inputTokens, 100);
          final decision = candidate.diagnostics!.decisionSnapshot!;
          expect(decision['threshold_scope'], 'context_window');
          expect(decision['nominal_threshold_tokens'], 800);
          expect(decision['auto_threshold_tokens'], 800);
          expect(decision['threshold_capped_by_usable_budget'], isFalse);
          expect(
            jsonEncode(candidate.diagnostics!.toJson()),
            isNot(contains(_privateMarker)),
          );
        },
      );

      test('repeated shape fails safely and bounded with its cause', () async {
        final adapter = _ScriptedAdapter([shape, shape, _Shape.valid]);
        Object? failure;
        try {
          await engineFor(adapter).buildCandidate(_request());
        } catch (error) {
          failure = error;
        }

        expect(failure, isA<CompactionEngineFailure>());
        final engineFailure = failure! as CompactionEngineFailure;
        expect(adapter.calls, 2, reason: 'never a third provider call');
        expect(
          engineFailure.reason,
          CompactionFailureReason.summarizationFailed,
        );
        expect(engineFailure.stage, CompactionFailureStage.provider);
        expect(engineFailure.cause, entry.value.cause);
        final attempts = engineFailure.diagnostics!.attempts;
        expect(attempts, hasLength(2));
        expect(
          attempts.map((a) => a.failureReason),
          everyElement(entry.value.ledgerReason),
        );
        expect(engineFailure.diagnostics!.aggregateUsage['input_tokens'], 200);
        expect(
          jsonEncode(engineFailure.diagnostics!.toJson()),
          isNot(contains(_privateMarker)),
        );
      });
    });
  }

  for (final (shape, kind) in [
    (_Shape.objectField, 'object'),
    (_Shape.listField, 'array'),
  ]) {
    test(
      'Task 118b D3: the ${shape.name} correction names the field and the expected type',
      () async {
        final adapter = _ScriptedAdapter([shape, _Shape.valid]);
        await engineFor(adapter).buildCandidate(_request());

        final repair = adapter.instructions.last;
        expect(repair, contains('filesAndPaths'));
        expect(repair, contains('must be a JSON string'));
        expect(repair, contains('not a JSON $kind'));
        expect(repair, isNot(contains(_privateMarker)));
        // The targeted repair does not re-list every required field.
        expect(repair, isNot(contains('present and non-empty')));
      },
    );
  }

  test(
    'Task 118b: a full pass that cannot fit the window with its output reservation is skipped without a provider call',
    () async {
      final adapter = _ScriptedAdapter([
        for (var i = 0; i < 20; i++) _Shape.valid,
      ]);
      final candidate = await engineFor(
        adapter,
      ).buildCandidate(_nearWindowRequest(maxOutputTokens: 4_096), force: true);

      expect(candidate, isNotNull);
      final attempts = candidate!.diagnostics!.attempts;
      expect(attempts.map((a) => a.passKind), isNot(contains('full')));
      expect(attempts.first.passKind, 'chunk');
      expect(adapter.calls, attempts.length);
      final decision = candidate.diagnostics!.decisionSnapshot!;
      expect(decision['full_pass_skipped'], 'presend_over_window');
      expect(decision['output_reservation_tokens'], 4_096);
      expect(decision['output_reservation_source'], 'settings');
      expect(
        (decision['presend_request_tokens'] as int) + 4_096,
        greaterThan(8_000),
      );
    },
  );

  test(
    'Task 118b review: a large declared output is capped, so a 0.9 W full pass is still sent',
    () async {
      final adapter = _ScriptedAdapter([_Shape.valid]);
      final candidate = await engineFor(adapter).buildCandidate(
        _largeWindowRequest(requestTokens: 900_000, declaredOutput: 384_000),
        force: true,
      );

      expect(candidate, isNotNull);
      expect(candidate!.diagnostics!.attempts.first.passKind, 'full');
      final decision = candidate.diagnostics!.decisionSnapshot!;
      expect(decision['full_pass_skipped'], isNull);
    },
  );

  test(
    'Task 118b review: a request that cannot fit even with the bounded reservation is skipped',
    () async {
      final adapter = _ScriptedAdapter([
        for (var i = 0; i < 20; i++) _Shape.valid,
      ]);
      final candidate = await engineFor(adapter).buildCandidate(
        _largeWindowRequest(requestTokens: 1_000_000, declaredOutput: 384_000),
        force: true,
      );

      expect(candidate, isNotNull);
      expect(
        candidate!.diagnostics!.attempts.map((a) => a.passKind),
        isNot(contains('full')),
      );
      final decision = candidate.diagnostics!.decisionSnapshot!;
      expect(decision['full_pass_skipped'], 'presend_over_window');
      expect(decision['output_reservation_tokens'], 16_384);
      expect(decision['output_reservation_source'], 'models_dev');
      expect(decision['output_reservation_capped'], isTrue);
    },
  );

  test(
    'Task 118b: a full pass that fits the window with its output reservation is sent',
    () async {
      final adapter = _ScriptedAdapter([_Shape.valid]);
      final candidate = await engineFor(
        adapter,
      ).buildCandidate(_nearWindowRequest(maxOutputTokens: 256), force: true);

      expect(candidate, isNotNull);
      expect(candidate!.diagnostics!.attempts.single.passKind, 'full');
      expect(
        candidate.diagnostics!.decisionSnapshot!['full_pass_skipped'],
        isNull,
      );
    },
  );

  test(
    'Task 118b: the summary instruction states that every value is one string with lists as lines',
    () {
      final instruction = CompactionSummaryPrompt.buildJsonInstruction();
      expect(
        instruction,
        contains('Every value except schemaVersion is a single JSON string'),
      );
      expect(instruction, contains('write lists as separate lines inside that string'));
      expect(
        instruction,
        contains(r'"filesAndPaths": "agent/lib/a.dart\nagent/lib/b.dart"'),
      );
    },
  );

  test('timeout fails at once with its measured duration recorded', () async {
    final adapter = _ScriptedAdapter([_Shape.timeout, _Shape.valid]);
    Object? failure;
    try {
      await engineFor(adapter).buildCandidate(_request());
    } catch (error) {
      failure = error;
    }

    expect(failure, isA<CompactionEngineFailure>());
    final engineFailure = failure! as CompactionEngineFailure;
    expect(adapter.calls, 1, reason: 'a timed-out pass is not repeated');
    expect(engineFailure.stage, CompactionFailureStage.provider);
    expect(engineFailure.cause, CompactionFailureCause.timeout);
    final attempt = engineFailure.diagnostics!.attempts.single;
    expect(attempt.failureReason, CompactionFailureCause.timeout);
    expect(attempt.duration, greaterThan(Duration.zero));
  });

  test('mixed shapes keep the latest attempt cause', () async {
    final adapter = _ScriptedAdapter([_Shape.invalidJson, _Shape.truncated]);
    Object? failure;
    try {
      await engineFor(adapter).buildCandidate(_request());
    } catch (error) {
      failure = error;
    }
    final engineFailure = failure! as CompactionEngineFailure;
    expect(engineFailure.cause, CompactionFailureCause.summaryTruncated);
    expect(engineFailure.diagnostics!.attempts.map((a) => a.failureReason), [
      CompactionFailureCause.summaryInvalidJson,
      CompactionFailureCause.summaryTruncated,
    ]);
  });

  test(
    'a recovery pass with repeated invalid JSON fails as invalid_response',
    () async {
      final adapter = _ScriptedAdapter([
        _Shape.overflow,
        _Shape.invalidJson,
        _Shape.invalidJson,
        _Shape.valid,
      ]);
      Object? failure;
      try {
        await engineFor(adapter).buildCandidate(_request());
      } catch (error) {
        failure = error;
      }
      final engineFailure = failure! as CompactionEngineFailure;
      expect(adapter.calls, 3, reason: 'one bounded correction per pass');
      expect(engineFailure.reason, CompactionFailureReason.summarizationFailed);
      expect(engineFailure.cause, CompactionFailureCause.invalidResponse);
      expect(
        jsonEncode(engineFailure.diagnostics!.toJson()),
        isNot(contains(_privateMarker)),
      );
    },
  );

  // Round 2 (live finding): a recovery pass that returns an unusable shape
  // was billed by the provider; its ledger entry and every aggregate must
  // carry that usage.
  for (final entry in expectations.entries) {
    final shape = entry.key;
    test('recovery ${shape.name} attempt keeps its provider usage', () async {
      final adapter = _ScriptedAdapter([
        _Shape.overflow,
        shape,
        for (var i = 0; i < 20; i++) _Shape.valid,
      ]);
      final candidate = await engineFor(adapter).buildCandidate(_request());

      expect(candidate, isNotNull);
      final attempts = candidate!.diagnostics!.attempts;
      final unusable = attempts.singleWhere(
        (a) => a.outcome == 'invalid_response',
      );
      expect(unusable.passKind, 'chunk');
      expect(unusable.failureReason, entry.value.ledgerReason);
      expect(unusable.inputTokens, 100);
      expect(unusable.outputTokens, 10);
      final billedCalls = adapter.calls - 1; // the overflow carried no usage
      final ledgerInput = attempts.fold<int>(
        0,
        (sum, a) => sum + (a.inputTokens ?? 0),
      );
      expect(ledgerInput, 100 * billedCalls);
      expect(candidate.metrics.summarizationInputTokens, 100 * billedCalls);
      expect(
        candidate.diagnostics!.aggregateUsage['input_tokens'],
        100 * billedCalls,
      );
      expect(
        jsonEncode(candidate.diagnostics!.toJson()),
        isNot(contains(_privateMarker)),
      );
    });
  }

  test(
    'a failed recovery reduce reports the usage of every billed pass',
    () async {
      final adapter = _ScriptedAdapter([
        _Shape.overflow,
        _Shape.valid,
        _Shape.invalidJson,
        _Shape.invalidJson,
      ]);
      Object? failure;
      try {
        await engineFor(adapter).buildCandidate(_request());
      } catch (error) {
        failure = error;
      }
      final engineFailure = failure! as CompactionEngineFailure;
      expect(adapter.calls, 4);
      expect(engineFailure.cause, CompactionFailureCause.invalidResponse);
      final attempts = engineFailure.diagnostics!.attempts;
      expect(attempts.map((a) => a.passKind), [
        'full',
        'chunk',
        'reduce',
        'repair',
      ]);
      expect(attempts.skip(1).map((a) => a.inputTokens), everyElement(100));
      expect(engineFailure.diagnostics!.aggregateUsage['input_tokens'], 300);
      expect(engineFailure.diagnostics!.aggregateUsage['output_tokens'], 30);
    },
  );

  test('classify maps the new summary causes to the provider stage', () {
    for (final cause in [
      CompactionFailureCause.summaryEmpty,
      CompactionFailureCause.summaryReasoningOnly,
      CompactionFailureCause.summaryTruncated,
    ]) {
      final diagnostics = CompactionDiagnostics.classify(
        CompactionEngineFailure(
          CompactionFailureReason.summarizationFailed,
          stage: CompactionFailureStage.provider,
          cause: cause,
        ),
      );
      expect(diagnostics.cause, cause);
      expect(diagnostics.stage, CompactionFailureStage.provider);
    }
  });
}
