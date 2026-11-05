import 'dart:convert';

import 'package:sanad_agent/capabilities/models/tool_schema.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/engine/context/context.dart';
import 'package:sanad_agent/engine/runtime/compaction_coordinator.dart';
import 'package:sanad_agent/evolution/compaction/compaction_activation_service.dart';
import 'package:sanad_agent/evolution/compaction/model_projection_builder.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/db/session_history_revision_repository.dart';
import 'package:sanad_agent/evolution/db/session_projection_revision_repository.dart';
import 'package:sanad_agent/evolution/models/session_state.dart';
import 'package:test/test.dart';

/// Regression: an automatic compaction in a `sanad run` (oneshot) session.
///
/// The oneshot brief is the first user message of the session, so every
/// automatic compaction of that session summarizes it. Its `Task: …` line and
/// its `## Blocker: …` heading used to arm a critical `ask`/`blocker` anchor
/// through an unanchored label pattern, and the whole 240-character brief line
/// then had to appear verbatim in the summary. No reasonable summary does that,
/// so every oneshot compaction failed `continuity_validation_failed` and the
/// session ran uncompacted for its whole life.

const _sessionId = 'oneshot-336f2a58-da5c-4b32-9d5f-7a1e0f7c3380';

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

/// The oneshot brief: a single `Task:` line long enough that reproducing it
/// verbatim inside a summary is impossible, and a `## Blocker:` heading whose
/// text is a genuine anchor.
const _brief =
    'Task: fix GitHub issue #338 - "Installer rollback on Linux". The '
    'installer copies the release payload into the application directory and '
    'then fails while writing the rollback journal, so a failed install leaves '
    'half-copied files behind; the fix must roll back the copy and keep the '
    'previous version runnable.\n\n'
    '## Blocker: the rollback journal is written after the copy';

const _blockerText = 'the rollback journal is written after the copy';

/// The summary a deterministic summarizer returns: it restates the goal, the
/// blocker and the pending asks, and never the brief line.
final _deterministicSummary = jsonEncode({
  'schemaVersion': 1,
  'currentGoal': 'fix the installer rollback for GitHub issue #338',
  'latestUserRequest': 'make a failed install roll back the copied files',
  'successCriteria': 'a failed install leaves the previous version runnable',
  'constraints': 'keep the release payload layout unchanged',
  'completedWork': 'read the installer copy and journal ordering',
  'activeState': 'writing the journal before the copy',
  'criticalContext': 'the blocker is about journal write ordering',
  'decisions': 'write the journal first, then copy',
  'blockers': _blockerText,
  'filesAndPaths': 'agent/lib/install/rollback.dart',
  'pendingAsks': 'finish the rollback fix and verify it on Linux',
  'remainingWork': 'run the installer regression suite',
});

/// A tool-heavy oneshot history: the brief, then tool exchanges that push the
/// conversation past one context window.
List<Message> _oneshotHistory() {
  final messages = <Message>[
    Message(role: MessageRole.user, content: _brief),
  ];
  for (var index = 0; index < 12; index++) {
    final callId = 'call-$index';
    messages.add(
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(
            id: callId,
            name: 'read_file',
            arguments: {'path': 'agent/lib/install/step_$index.dart'},
          ),
        ],
      ),
    );
    messages.add(
      Message(
        role: MessageRole.tool,
        toolCallId: callId,
        content: 'file $index ${'c' * 2_400}',
      ),
    );
    messages.add(
      Message(role: MessageRole.assistant, content: 'step $index ${'w' * 2_400}'),
    );
  }
  messages.addAll([
    Message(role: MessageRole.user, content: 'continue with the rollback fix'),
    Message(role: MessageRole.assistant, content: 'continuing'),
  ]);
  return messages;
}

/// A deterministic summarizer that never reproduces the brief line, for either
/// the ordinary pass or a bounded recovery pass.
class _DeterministicSummarizer
    implements CompactionSummarizer, ProviderProjectionCompactionSummarizer {
  final requests = <CompactionProviderRequest>[];

  @override
  Future<String> summarize({required String prompt}) async =>
      _deterministicSummary;

  @override
  Future<CompactionProviderResult> summarizeProvider(
    CompactionProviderRequest request,
  ) async {
    requests.add(request);
    return CompactionProviderResult(
      content: _deterministicSummary,
      usage: const {'prompt_tokens': 100, 'completion_tokens': 20},
      duration: const Duration(milliseconds: 1),
    );
  }
}

void main() {
  late AgentStateDatabase state;
  late SessionDB sessions;
  late CompactionBoundaryRepository boundaries;
  late SessionHistoryRevisionRepository revisions;
  late List<CompactionLifecycleEvent> lifecycle;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    sessions = SessionDB.fromState(state);
    revisions = SessionHistoryRevisionRepository(state);
    boundaries = CompactionBoundaryRepository(state, revisions);
    lifecycle = [];
    final now = DateTime.utc(2026, 11, 5);
    sessions.saveSession(
      SessionState(
        sessionId: _sessionId,
        model: 'gpt-test',
        createdAt: now,
        updatedAt: now,
        lastUserMessageAt: now,
      ),
    );
    sessions.replaceMessages(_sessionId, _oneshotHistory());
  });

  tearDown(() {
    sessions.dispose();
    state.dispose();
  });

  test(
    'a oneshot-shaped automatic compaction completes with one boundary',
    () async {
      final summarizer = _DeterministicSummarizer();
      final coordinator = CompactionCoordinator(
        engine: ContextCompactionEngine(summarizer: summarizer),
        boundaries: boundaries,
        activation: CompactionActivationService(
          boundaries: boundaries,
          projectionRevisions: SessionProjectionRevisionRepository(state),
        ),
        projectionBuilder: ModelProjectionBuilder(
          sessions: sessions,
          boundaries: boundaries,
        ),
        onLifecycleEvent: lifecycle.add,
      );
      final canonical = ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ).loadCanonicalTimeline(_sessionId);
      final timeline = [
        for (final entry in canonical.messages)
          IndexedConversationMessage(rowId: entry.rowId, message: entry.message),
      ];

      final outcome = await coordinator.runCompaction(
        request: CompactionEngineRequest(
          compactionId: 'cmp-oneshot-338',
          sessionId: _sessionId,
          trigger: CompactionTrigger.auto,
          sourceRevision: revisions.read(_sessionId)!.toCompactionRevision(),
          routeSignature: _route,
          contextWindowTokens: _contextWindow,
          timeline: timeline,
          systemPrompt: 'stable system',
          runtimeContext: '',
          toolSchemas: _toolSchemas,
          providerProjection: [
            Message(role: MessageRole.system, content: 'stable system'),
            for (final entry in timeline) entry.message,
          ],
          providerTools: [
            ToolSchema(
              name: 'read_file',
              description: 'Read a file',
              parameters: const {'type': 'object'},
            ),
          ],
          providerRequestOptions: const LLMRequestOptions(
            sessionId: _sessionId,
            requestId: 'compaction:cmp-oneshot-338',
          ),
          targetRequestTokens: 1_000,
          thresholdRatio: 0.10,
        ),
        force: true,
      );

      expect(
        outcome?.failureReason,
        isNull,
        reason:
            'compaction failed with '
            '${outcome?.failureReason?.wireValue}/'
            '${outcome?.failureCause}',
      );
      expect(outcome?.status, CompactionStatus.completed);
      expect(summarizer.requests, isNotEmpty);
      // Tool-heavy history beyond one window: the doomed ordinary pass is
      // skipped and the bounded chunk/reduce recovery summarizes instead, so
      // the anchors are re-checked on every recovery pass.
      final record = boundaries.findById('cmp-oneshot-338');
      expect(
        record?.diagnostics?.decisionSnapshot?['full_pass_skipped'],
        'presend_over_window',
      );
      expect(summarizer.requests.length, greaterThan(1));
      expect(boundaries.listCompletedForSession(_sessionId), hasLength(1));
      expect(
        lifecycle.map((event) => event.status),
        [CompactionStatus.started, CompactionStatus.completed],
      );
    },
  );

  test('the brief and the blocker are the anchors a summary must cover', () {
    final anchors = CompactionContinuityValidator().extractAnchors([
      for (final entry in ModelProjectionBuilder(
        sessions: sessions,
        boundaries: boundaries,
      ).loadCanonicalTimeline(_sessionId).messages)
        IndexedConversationMessage(
          rowId: entry.rowId,
          message: entry.message,
        ),
    ]);

    final critical = {
      for (final anchor in anchors.where((anchor) => anchor.critical))
        anchor.key: anchor.value,
    };
    expect(critical, {'blocker': _blockerText});
    expect(
      CompactionContinuityValidator().validate(
        summary: CompactionSummaryParser.parse(_deterministicSummary),
        anchors: anchors,
      ).passed,
      isTrue,
    );
  });
}
