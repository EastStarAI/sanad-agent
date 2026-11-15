/// Every assistant delta source publishes through the run's one ordinal
/// allocator, so a consumer never sees two numbering schemes for one stream.
///
/// The sources are ordinary streamed content, typed thought deltas, and visible
/// provider reasoning. Each case asserts the wire result (`stream_seq` inside the
/// canonical payload) and the in-flight projection's watermark together, because
/// they must always agree on the same number.
library;

import 'dart:async';
import 'dart:io';

import 'package:mockito/mockito.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:sanad_agent/interfaces/runtime/session_turn_executor.dart';
import 'package:sanad_agent/interfaces/runtime/turn_event_publisher.dart';
import 'package:test/test.dart';

import '../support/in_memory_auth_manager.dart';
import 'interfaces_test.mocks.dart';

void main() {
  late Directory tempDir;
  late AgentStateDatabase state;
  late SessionManager sessions;
  late MockAgentRunner runner;
  late String? modelStepId;
  late List<GatewayResponse> responses;
  late TurnEventPublisher publisher;
  late ActiveRun run;
  late GatewayEvent event;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('stream_delta_');
    Directory('${tempDir.path}/memories').createSync(recursive: true);
    setSanadHomeOverride(tempDir.path);
    SessionManager.resetForTesting();
    getIt.allowReassignment = true;
    if (getIt.isRegistered<SessionManager>()) {
      getIt.unregister<SessionManager>();
    }
    registerInMemoryAuthManager();
    state = AgentStateDatabase.atPath(tempDir.path);
    getIt.registerSingleton<AgentStateDatabase>(state);
    sessions = SessionManager();
    getIt.registerSingleton<SessionManager>(sessions);

    modelStepId = 'model_step_1';
    runner = MockAgentRunner();
    when(runner.currentModelStepId).thenAnswer((_) => modelStepId);

    run = ActiveRun(
      sessionId: 'session-1',
      generation: 1,
      runId: 'run-1',
      workItemId: 'work-1',
      completer: Completer<void>(),
      agentRunner: runner,
      turnId: 'turn-1',
    );
    event = GatewayEvent(
      sessionId: 'session-1',
      platformId: 'local_gateway',
      message: Message(role: MessageRole.user, content: 'prompt'),
    );

    responses = <GatewayResponse>[];
    publisher = TurnEventPublisher(
      emitResponse: responses.add,
      // Mirrors the executor's owner predicate closely enough for this owner:
      // a run that lost its generation publishes nothing.
      ownsRun: (candidate) => !candidate.invalidated,
      captureContextUsage:
          ({required String sessionId, required AgentRunner agentRunner}) async =>
              null,
    );
  });

  tearDown(() {
    SessionManager.resetForTesting();
    if (getIt.isRegistered<SessionManager>()) {
      getIt.unregister<SessionManager>();
    }
    state.dispose();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      try {
        tempDir.deleteSync(recursive: true);
      } catch (_) {}
    }
  });

  List<int?> publishedSequences() =>
      responses.map((response) => response.streamSeq).toList(growable: false);

  List<String> publishedTypes() => responses
      .map((response) => AgentToCanonical.translate(response).type)
      .toList(growable: false);

  List<int?> publishedWireSequences() => responses
      .map(
        (response) =>
            AgentToCanonical.translate(response).payload['stream_seq'] as int?,
      )
      .toList(growable: false);

  test('content, thought, and reasoning deltas keep one contiguous per-key '
      'sequence and agree with the in-flight watermark', () {
    publisher.emitContentDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      content: 'Hel',
    );
    publisher.emitThoughtDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      thought: 'lo',
    );
    publisher.emitReasoningDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      fallbackRunId: 'run-1',
      reasoning: 'why',
    );

    expect(publishedSequences(), [1, 2, 1]);
    expect(publishedWireSequences(), [1, 2, 1]);
    expect(publishedTypes(), [
      CanonicalEventTypes.thoughtStream,
      CanonicalEventTypes.thoughtStream,
      CanonicalEventTypes.reasoningStream,
    ]);

    final snapshot = sessions.getInFlightSnapshot('session-1')!;
    expect(snapshot['type'], CanonicalEventTypes.reasoningStream);
    expect(snapshot['stream_seq'], 1);
    expect(snapshot['content'], 'why');
    expect(snapshot['snapshot'], isTrue);
    expect(snapshot['model_step_id'], 'model_step_1');
    expect(snapshot['run_id'], 'run-1');
  });

  test('the projection text covers exactly the watermark it reports', () {
    publisher.emitContentDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      content: 'a',
    );
    publisher.emitContentDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      content: 'b',
    );
    publisher.emitThoughtDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      thought: 'c',
    );

    final snapshot = sessions.getInFlightSnapshot('session-1')!;
    expect(snapshot['content'], 'abc');
    expect(snapshot['stream_seq'], 3);
    expect(responses.last.streamSeq, 3);
  });

  test('a new model step continues the run but restarts its key', () {
    publisher.emitContentDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      content: 'first',
    );
    modelStepId = 'model_step_2';
    publisher.emitContentDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      content: 'second',
    );

    expect(publishedSequences(), [1, 1]);
    expect(responses.last.modelStepId, 'model_step_2');
    expect(
      sessions.getInFlightSnapshot('session-1')!['stream_seq'],
      1,
      reason: 'the projection restarts with its own stream key',
    );
  });

  test('a whitespace-only reasoning delta keeps its reasoning stream key', () {
    publisher.emitReasoningDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      fallbackRunId: 'run-1',
      reasoning: '\n',
    );

    // The chunk was numbered on the reasoning key before translation, so the
    // wire event must stay reasoning — a visible-weight test would reclassify
    // it as ordinary text and lose the chunk the ordinal already covers.
    final reasoning = AgentToCanonical.translate(responses.single);
    expect(reasoning.type, CanonicalEventTypes.reasoningStream);
    expect(reasoning.payload['content'], '\n');
    expect(reasoning.payload['stream_seq'], 1);
    expect(responses.single.streamSeq, 1);
    expect(sessions.getInFlightSnapshot('session-1')!['stream_seq'], 1);

    publisher.emitContentDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      content: 'answer',
    );

    expect(
      responses.last.streamSeq,
      1,
      reason: 'the ordinary-text key never pays for a reasoning chunk',
    );
    expect(
      AgentToCanonical.translate(responses.last).type,
      CanonicalEventTypes.thoughtStream,
    );
  });

  test('an empty delta publishes nothing and consumes no ordinal', () {
    publisher.emitThoughtDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      thought: '',
    );
    publisher.emitContentDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      content: 'x',
    );

    expect(responses, hasLength(1));
    expect(responses.single.streamSeq, 1);
  });

  test('row-ownership failure publishes nothing and consumes no ordinal', () {
    final invalidated = ActiveRun(
      sessionId: 'session-1',
      generation: 2,
      runId: 'run-1',
      workItemId: 'work-1',
      completer: Completer<void>(),
      agentRunner: runner,
      turnId: 'turn-1',
    )..invalidated = true;

    publisher.emitThoughtDelta(
      owner: invalidated,
      event: event,
      agentRunner: runner,
      thought: 'dropped',
    );
    publisher.emitThoughtDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      thought: 'kept',
    );

    expect(responses, hasLength(1));
    expect(responses.single.streamSeq, 1);
  });

  test('the published delta keeps run, turn, and step identity', () {
    publisher.emitContentDelta(
      owner: run,
      event: event,
      agentRunner: runner,
      content: 'x',
    );

    final canonical = AgentToCanonical.translate(responses.single);
    expect(canonical.sessionId, 'session-1');
    expect(canonical.runId, 'run-1');
    expect(canonical.payload['run_id'], 'run-1');
    expect(canonical.payload['turn_id'], 'turn-1');
    expect(canonical.payload['model_step_id'], 'model_step_1');
    expect(canonical.payload['status'], 'running');
  });
}
