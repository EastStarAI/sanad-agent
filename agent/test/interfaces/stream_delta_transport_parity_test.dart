/// The stream ordinal is one canonical payload field, so every transport copy of
/// one delta is identical by construction.
///
/// Both transports serialize the same envelope owner over the same translated
/// payload; this pins that contract instead of trusting it: translating one
/// response twice must not move or consume the ordinal, and a terminal response
/// must never carry one.
library;

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/support/agent_event_envelope.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:test/test.dart';

import '../support/in_memory_auth_manager.dart';

void main() {
  setUpAll(registerInMemoryAuthManager);

  GatewayResponse deltaResponse({int? streamSeq = 7}) => GatewayResponse(
    sessionId: 'session-1',
    platformId: 'local_gateway',
    message: Message(role: MessageRole.assistant, content: 'part'),
    isComplete: false,
    runId: 'run-1',
    turnId: 'turn-1',
    modelStepId: 'model_step_1',
    streamSeq: streamSeq,
  );

  test('one response translates to one payload the local and cloud copies share',
      () {
    final response = deltaResponse();

    final localCopy = buildAgentEventEnvelope(
      AgentToCanonical.translate(response),
    );
    final cloudCopy = buildAgentEventEnvelope(
      AgentToCanonical.translate(response),
    );

    expect(cloudCopy, equals(localCopy));
    expect(localCopy['event'], CanonicalEventTypes.thoughtStream);
    expect(localCopy['event_id'], response.eventId);
    expect(cloudCopy['event_id'], response.eventId);
    expect(localCopy['run_id'], 'run-1');
    expect(localCopy['session_id'], 'session-1');

    final payload = localCopy['payload'] as Map<String, dynamic>;
    expect(payload['stream_seq'], 7);
    expect(payload['content'], 'part');
    expect(payload['model_step_id'], 'model_step_1');
    expect(
      localCopy.containsKey('stream_seq'),
      isFalse,
      reason: 'the ordinal belongs to the stream payload, not the envelope',
    );
  });

  test('repeated translation never consumes or shifts the ordinal', () {
    final response = deltaResponse();

    final first = AgentToCanonical.translate(response);
    final second = AgentToCanonical.translate(response);

    expect(second.payload, equals(first.payload));
    expect(second.type, first.type);
    expect(second.eventId, first.eventId);
    expect(first.payload['stream_seq'], 7);
    expect(second.payload['stream_seq'], 7);
  });

  test('a terminal response never carries a stream ordinal', () {
    final response = GatewayResponse(
      sessionId: 'session-1',
      message: Message(role: MessageRole.assistant, content: 'complete answer'),
      runId: 'run-1',
      turnId: 'turn-1',
      modelStepId: 'model_step_1',
    );

    final canonical = AgentToCanonical.translate(response);
    expect(canonical.type, CanonicalEventTypes.finalAnswer);
    expect(canonical.payload.containsKey('stream_seq'), isFalse);
  });

  test('a legacy producer payload omits the ordinal instead of sending null', () {
    final response = deltaResponse(streamSeq: null);

    final payload = AgentToCanonical.translate(response).payload;
    expect(payload.containsKey('stream_seq'), isFalse);
    expect(
      AgentToCanonical.translate(response).type,
      CanonicalEventTypes.thoughtStream,
    );
  });

  test('reasoning deltas keep their own canonical type beside the ordinal', () {
    final response = GatewayResponse(
      sessionId: 'session-1',
      message: Message(role: MessageRole.assistant, reasoning: 'because'),
      isComplete: false,
      runId: 'run-1',
      modelStepId: 'model_step_1',
      streamSeq: 1,
    );

    final canonical = AgentToCanonical.translate(response);
    expect(canonical.type, CanonicalEventTypes.reasoningStream);
    expect(canonical.payload['stream_seq'], 1);
    expect(canonical.payload['content'], 'because');
  });
}
