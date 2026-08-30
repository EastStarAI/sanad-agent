import 'dart:io';

import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
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

List<IndexedConversationMessage> _fixtureTimeline() {
  final fixture = File(
    'test/engine/fixtures/context_compaction/multi_step_goal.txt',
  ).readAsStringSync();
  final goalLine = RegExp(
    r'Implement OAuth login[^\n]*',
  ).firstMatch(fixture)?.group(0);
  final blockerLine = RegExp(
    r'Provider usage endpoint returns `unsupported`[^\n]*',
  ).firstMatch(fixture)?.group(0);
  final pathLine = 'agent/lib/core/auth/auth_manager.dart';

  final messages = <IndexedConversationMessage>[
    IndexedConversationMessage(
      rowId: 1,
      message: Message(
        role: MessageRole.user,
        content: 'goal: ${goalLine ?? 'Implement OAuth login'}',
      ),
    ),
    IndexedConversationMessage(
      rowId: 2,
      message: Message(
        role: MessageRole.user,
        content:
            'constraints: Keep Local Gateway loopback-only; no refresh tokens in history.',
      ),
    ),
    IndexedConversationMessage(
      rowId: 3,
      message: Message(
        role: MessageRole.user,
        content: 'path: $pathLine',
      ),
    ),
    IndexedConversationMessage(
      rowId: 4,
      message: Message(
        role: MessageRole.user,
        content: 'blocker: ${blockerLine ?? 'usage endpoint unsupported'}',
      ),
    ),
    for (var i = 5; i <= 35; i++)
      IndexedConversationMessage(
        rowId: i,
        message: Message(
          role: MessageRole.user,
          content: 'research note $i ${'detail ' * 40}',
        ),
      ),
  ];
  return messages;
}

CompactionEngineRequest _request({
  required List<IndexedConversationMessage> timeline,
  CompactionInternalSummary? previousSummary,
}) {
  return CompactionEngineRequest(
    compactionId: 'cmp-fixture',
    sessionId: 'session-fixture',
    trigger: CompactionTrigger.auto,
    sourceRevision: const CompactionHistoryRevision(1),
    routeSignature: _route(),
    contextWindowTokens: 4_000,
    timeline: timeline,
    systemPrompt: 'system prompt',
    runtimeContext: 'runtime',
    toolSchemas: const [],
    previousSummary: previousSummary,
    targetRequestTokens: 2_500,
  );
}

void main() {
  test('three repeated compactions retain OAuth goal and auth path anchors', () async {
    final engine = ContextCompactionEngine(
      summarizer: StructuredCompactionSummarizer(),
    );
    final timeline = _fixtureTimeline();

    final first = await engine.buildCandidate(_request(timeline: timeline));
    expect(first, isNotNull);
    expect(first!.internalSummary.currentGoal.toLowerCase(), contains('oauth'));

    final second = await engine.buildCandidate(
      _request(timeline: timeline, previousSummary: first.internalSummary),
    );
    expect(second, isNotNull);
    expect(second!.internalSummary.currentGoal.toLowerCase(), contains('oauth'));
    expect(
      second.internalSummary.filesAndPaths,
      contains('auth_manager.dart'),
    );

    final third = await engine.buildCandidate(
      _request(timeline: timeline, previousSummary: second.internalSummary),
    );
    expect(third, isNotNull);
    expect(third!.internalSummary.currentGoal.toLowerCase(), contains('oauth'));
    expect(third.metrics.estimatedRequestTokensAfter,
        lessThan(third.metrics.estimatedRequestTokensBefore));
    expect(third.continuityResult.passed, isTrue);
  });
}
