/// Task 116 D3/D4 — the data-driven replay policy seam and its pre-dispatch
/// rejection, observed through the actual Chat adapter (zero HTTP requests on
/// rejection). The shipped defaults are probe-pending `asRecorded`; these
/// tests inject the alternative a probe outcome would select.
library;

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_thinking/native_thinking_directive.dart';
import 'package:sanad_agent/engine/adapters/base_openai_adapter.dart';
import 'package:sanad_agent/engine/adapters/chat_reasoning_replay_policy.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/adapters/provider_history_projection_exception.dart';
import 'package:sanad_agent/engine/adapters/provider_registry.dart';
import 'package:test/test.dart';

import 'projection_fixtures.dart';

const _thinkingOn = LLMRequestOptions(
  providerInstanceId: goInstance,
  thinkingDirective: OpenAiEffortDirective('max'),
);

BaseOpenAIAdapter _adapter(
  WireRecorder recorder,
  ChatReasoningReplayPolicy policy,
) => BaseOpenAIAdapter(
  FixedRouteConfig(goBaseUrl),
  ProviderRegistry.findByNameOrAlias('opencode-go')!,
  client: recorder.client,
  modelsDevService: fixtureModelsDev(),
  providerInstanceId: goInstance,
  replayPolicy: policy,
);

/// Earlier turn: foreign Codex tool exchange. Current turn: one foreign
/// unrecorded tool exchange and one same-route empty-reasoning exchange.
List<Message> _history() => [
  Message(role: MessageRole.user, content: 'secret user text'),
  toolTurn('c-early', state: codexState()),
  toolResult('c-early'),
  Message(role: MessageRole.user, content: 'continue'),
  toolTurn('c-now', metadata: {'model': codexModel}),
  toolResult('c-now'),
  toolTurn('d-empty', state: chatState(reasoning: '', field: 'string')),
  toolResult('d-empty'),
];

Matcher _rejection(String code, int count) =>
    isA<ProviderHistoryProjectionException>()
        .having((e) => e.reasonCode, 'reasonCode', code)
        .having((e) => e.affectedCount, 'affectedCount', count)
        .having((e) => e.route, 'route', '$goInstance/$deepseek');

void main() {
  test('shipped defaults are the conservative probe-pending seam', () {
    expect(
      ChatReasoningReplayPolicy.defaultDecisions.values,
      everyElement(ReplayDecision.asRecorded),
    );
    expect(ChatReasoningReplayPolicy.defaultDecisions.keys, ReplayCell.values);
    expect(ChatReasoningReplayPolicy.routeOverrides, isEmpty);
  });

  test('P5 reject outcome fails before HTTP with bounded fields only', () async {
    final recorder = WireRecorder();
    final adapter = _adapter(
      recorder,
      const ChatReasoningReplayPolicy(
        decisions: {ReplayCell.foreignCurrentTurn: ReplayDecision.reject},
      ),
    );
    Object? error;
    try {
      await adapter.generateResponse(
        _history(),
        modelOverride: deepseek,
        options: _thinkingOn,
      );
    } catch (e) {
      error = e;
    }
    expect(
      error,
      _rejection(
        ProviderHistoryProjectionException.foreignToolTurnRequiresReasoning,
        1,
      ),
      reason: 'only the current-turn foreign exchange is affected',
    );
    expect(recorder.bodies, isEmpty, reason: 'no HTTP dispatch');
    expect(error.toString(), isNot(contains('secret user text')));
    expect(error.toString(), isNot(contains('sealed-codex')));

    await expectLater(
      adapter
          .generateStream(_history(), modelOverride: deepseek, options: _thinkingOn)
          .toList(),
      throwsA(
        _rejection(
          ProviderHistoryProjectionException.foreignToolTurnRequiresReasoning,
          1,
        ),
      ),
    );
    expect(recorder.bodies, isEmpty);
  });

  test('measurement never rejects so preflight cannot loop on it', () async {
    final recorder = WireRecorder();
    final adapter = _adapter(
      recorder,
      const ChatReasoningReplayPolicy(
        decisions: {
          ReplayCell.foreignCurrentTurn: ReplayDecision.reject,
          ReplayCell.foreignEarlierTurn: ReplayDecision.reject,
        },
      ),
    );
    final measurement = await adapter.measureInput(
      _history(),
      modelOverride: deepseek,
      options: _thinkingOn,
    );
    expect(measurement, isNotNull);
    expect(measurement!.estimatedTokens, greaterThan(0));
    expect(recorder.bodies, isEmpty);
  });

  test('P1 reject outcome classifies same-route empty reasoning', () async {
    final recorder = WireRecorder();
    final adapter = _adapter(
      recorder,
      const ChatReasoningReplayPolicy(
        decisions: {ReplayCell.sameRouteEmpty: ReplayDecision.reject},
      ),
    );
    await expectLater(
      adapter.generateResponse(
        _history(),
        modelOverride: deepseek,
        options: _thinkingOn,
      ),
      throwsA(
        _rejection(
          ProviderHistoryProjectionException.sameRouteReasoningUnrecoverable,
          1,
        ),
      ),
    );
    expect(recorder.bodies, isEmpty);
  });

  test('thinking explicitly off never rejects and sends as recorded', () async {
    final recorder = WireRecorder();
    final adapter = _adapter(
      recorder,
      const ChatReasoningReplayPolicy(
        decisions: {
          ReplayCell.foreignCurrentTurn: ReplayDecision.reject,
          ReplayCell.foreignEarlierTurn: ReplayDecision.reject,
        },
      ),
    );
    await adapter.generateResponse(
      _history(),
      modelOverride: deepseek,
      options: const LLMRequestOptions(
        providerInstanceId: goInstance,
        thinkingDirective: ThinkingToggleDirective(enabled: false),
      ),
    );
    expect(recorder.bodies, hasLength(1));
  });

  test('an exact-route override applies to that route only', () async {
    const policy = ChatReasoningReplayPolicy(
      overrides: {
        'opencode-go/$deepseek': {
          ReplayCell.foreignEarlierTurn: ReplayDecision.reject,
        },
      },
    );
    final kimiRecorder = WireRecorder();
    await _adapter(kimiRecorder, policy).generateResponse(
      _history(),
      modelOverride: kimi,
      options: _thinkingOn,
    );
    expect(kimiRecorder.bodies, hasLength(1));

    final deepRecorder = WireRecorder();
    await expectLater(
      _adapter(deepRecorder, policy).generateResponse(
        _history(),
        modelOverride: deepseek,
        options: _thinkingOn,
      ),
      throwsA(
        _rejection(
          ProviderHistoryProjectionException.foreignToolTurnRequiresReasoning,
          1,
        ),
      ),
    );
    expect(deepRecorder.bodies, isEmpty);
  });

  test('routes without an echo declaration never reject', () async {
    final recorder = WireRecorder();
    final adapter = BaseOpenAIAdapter(
      FixedRouteConfig(goBaseUrl),
      ProviderRegistry.findByNameOrAlias('opencode-go')!,
      client: recorder.client,
      providerInstanceId: goInstance,
      replayPolicy: const ChatReasoningReplayPolicy(
        decisions: {
          ReplayCell.foreignCurrentTurn: ReplayDecision.reject,
          ReplayCell.foreignEarlierTurn: ReplayDecision.reject,
        },
      ),
    );
    await adapter.generateResponse(
      _history(),
      modelOverride: deepseek,
      options: _thinkingOn,
    );
    expect(recorder.bodies, hasLength(1));
  });

  test('user message is bounded and never suggests compaction', () {
    final error = ProviderHistoryProjectionException(
      route: '$goInstance/$deepseek',
      reasonCode:
          ProviderHistoryProjectionException.foreignToolTurnRequiresReasoning,
      affectedCount: 3,
    );
    final message = error.userMessage(
      providerDisplayName: 'OpenCode Go',
      modelId: deepseek,
    );
    expect(message, contains('$deepseek on OpenCode Go'));
    expect(message, contains('3 steps'));
    expect(message.toLowerCase(), isNot(contains('compact')));
    expect(message.toLowerCase(), isNot(contains('summar')));
    expect(
      () => ProviderHistoryProjectionException(
        route: 'r',
        reasonCode: 'free text',
        affectedCount: 1,
      ),
      throwsArgumentError,
    );
  });
}
