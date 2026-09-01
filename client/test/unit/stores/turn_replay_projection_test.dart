import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_state.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';

void main() {
  CanonicalEvent user({
    required String id,
    required String requestId,
    String? messageId,
    String? turnId,
    String? inputKind,
    bool? replayEligible,
    bool steer = false,
  }) {
    return CanonicalEvent(
      id: id,
      kind: EventKind.userMessage,
      text: id,
      timestamp: DateTime.utc(2026, 7, 18),
      metadata: {
        'request_id': requestId,
        if (messageId != null) 'message_id': messageId,
        if (turnId != null) 'turn_id': turnId,
        if (inputKind != null) 'input_kind': inputKind,
        if (replayEligible != null) 'replay_eligible': replayEligible,
        if (steer) 'steer': true,
      },
    );
  }

  test('durable live echo upgrades an optimistic root with replay identity', () {
    final state = ConversationState();
    state.apply(
      CanonicalEvent(
        id: 'optimistic-request-1',
        kind: EventKind.userMessage,
        text: 'hello',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {
          'request_id': 'request-1',
          'optimistic': true,
        },
      ),
    );

    state.apply(
      user(
        id: 'durable-message-1',
        requestId: 'request-1',
        messageId: 'message-1',
        turnId: 'turn-1',
        inputKind: 'root_turn',
        replayEligible: true,
      ),
    );

    expect(state.events, hasLength(1));
    expect(state.events.single.id, 'durable-message-1');
    expect(state.events.single.isReplayableRootTurn, isTrue);
  });

  test('accepted replay hides superseded identities without truncating earlier turns', () {
    final state = ConversationState();
    state.setHistory([
      user(id: 'user-1', requestId: 'request-1', messageId: 'msg-1', turnId: 'turn-1'),
      CanonicalEvent(
        id: 'answer-1',
        kind: EventKind.finalAnswer,
        text: 'first answer',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {'turn_id': 'turn-1'},
      ),
      user(id: 'user-2', requestId: 'request-2', messageId: 'msg-2', turnId: 'turn-2'),
      CanonicalEvent(
        id: 'answer-2',
        kind: EventKind.finalAnswer,
        text: 'second answer',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {'turn_id': 'turn-2'},
      ),
    ]);

    expect(
      state.hideSupersededIdentities(turnId: 'turn-2', messageId: 'msg-2'),
      isTrue,
    );
    expect(state.events.map((event) => event.id), ['user-1', 'answer-1']);
  });

  test('late live events for a superseded turn are ignored', () {
    final state = ConversationState();
    state.setHistory([
      user(id: 'user-1', requestId: 'request-1', messageId: 'msg-1', turnId: 'turn-1'),
    ]);
    state.hideSupersededIdentities(turnId: 'turn-1', messageId: 'msg-1');
    state.apply(
      CanonicalEvent(
        id: 'late-1',
        kind: EventKind.finalAnswer,
        text: 'should not resurrect',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {'turn_id': 'turn-1'},
      ),
    );
    expect(state.events, isEmpty);
  });

  test('reconnect history cannot resurrect a locally superseded turn', () {
    final state = ConversationState();
    final oldRoot = user(
      id: 'old-root',
      requestId: 'request-old',
      messageId: 'message-old',
      turnId: 'turn-old',
    );
    state.setHistory([
      oldRoot,
      CanonicalEvent(
        id: 'old-answer',
        kind: EventKind.finalAnswer,
        text: 'old answer',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {'turn_id': 'turn-old'},
      ),
    ]);
    state.hideSupersededIdentities(
      turnId: 'turn-old',
      messageId: 'message-old',
    );

    state.setHistory([
      oldRoot,
      CanonicalEvent(
        id: 'old-answer',
        kind: EventKind.finalAnswer,
        text: 'stale snapshot answer',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {'turn_id': 'turn-old'},
      ),
      user(
        id: 'replacement-root',
        requestId: 'request-new',
        messageId: 'message-new',
        turnId: 'turn-new',
      ),
    ]);

    expect(state.events.map((event) => event.id), ['replacement-root']);
  });

  test('only daemon-eligible roots are replayable across steer projections', () {
    expect(
      user(
        id: 'delivered-steer',
        requestId: 'steer-req',
        messageId: 'msg-steer',
        turnId: 'turn-root',
        inputKind: 'steer',
        replayEligible: false,
      ).isReplayableRootTurn,
      isFalse,
    );
    expect(
      user(
        id: 'late-steer-user-row',
        requestId: 'late-steer-req',
        messageId: 'msg-late-steer',
        turnId: 'turn-root',
        inputKind: 'steer',
        replayEligible: false,
        steer: true,
      ).isReplayableRootTurn,
      isFalse,
    );
    expect(
      user(
        id: 'embedded-steer-projection',
        requestId: 'embedded-steer-req',
        messageId: 'msg-embedded-steer',
        turnId: 'turn-root',
        inputKind: 'steer',
        replayEligible: false,
      ).isReplayableRootTurn,
      isFalse,
    );
    expect(
      CanonicalEvent(
        id: 'pending-1',
        kind: EventKind.userMessage,
        text: 'nudge',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {
          'request_id': 'pending-req',
          'message_id': 'pending-message',
          'turn_id': 'turn-root',
          'input_kind': 'steer',
          'replay_eligible': false,
          'pending_steer_state': 'pending',
        },
      ).isReplayableRootTurn,
      isFalse,
    );
    expect(
      user(
        id: 'root-1',
        requestId: 'root-req',
        messageId: 'msg-root',
        turnId: 'turn-root',
        inputKind: 'root_turn',
        replayEligible: true,
      ).isReplayableRootTurn,
      isTrue,
    );
    expect(
      user(
        id: 'daemon-ineligible-root',
        requestId: 'ineligible-req',
        messageId: 'msg-ineligible',
        turnId: 'turn-ineligible',
        inputKind: 'root_turn',
        replayEligible: false,
      ).isReplayableRootTurn,
      isFalse,
    );
    expect(
      user(
        id: 'unclassified-user',
        requestId: 'unclassified-req',
        messageId: 'msg-unclassified',
        turnId: 'turn-unclassified',
        replayEligible: true,
      ).isReplayableRootTurn,
      isFalse,
    );
    expect(
      user(id: 'legacy-1', requestId: 'legacy-req').isReplayableRootTurn,
      isFalse,
    );
  });

  test('store hides the superseded turn only after accepted replay', () {
    final store = DeviceConversationStore();
    addTearDown(store.dispose);
    store.activateSession('session-1');
    store.setHistory([
      user(id: 'user-1', requestId: 'request-1', messageId: 'msg-1', turnId: 'turn-1'),
      CanonicalEvent(
        id: 'answer-1',
        kind: EventKind.finalAnswer,
        text: 'first answer',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {'turn_id': 'turn-1'},
      ),
      user(id: 'user-2', requestId: 'request-2', messageId: 'msg-2', turnId: 'turn-2'),
      CanonicalEvent(
        id: 'answer-2',
        kind: EventKind.finalAnswer,
        text: 'second answer',
        timestamp: DateTime.utc(2026, 7, 18),
        metadata: const {'turn_id': 'turn-2'},
      ),
    ]);

    store.applyTurnReplayAccepted(
      sessionId: 'other-session',
      targetRequestId: 'request-2',
      targetTurnId: 'turn-2',
      targetMessageId: 'msg-2',
    );
    expect(store.currentMessages.map((event) => event.id), [
      'user-1',
      'answer-1',
      'user-2',
      'answer-2',
    ]);

    store.applyTurnReplayAccepted(
      sessionId: 'session-1',
      targetRequestId: 'request-2',
      targetTurnId: 'turn-2',
      targetMessageId: 'msg-2',
    );
    expect(store.currentMessages.map((event) => event.id), ['user-1', 'answer-1']);
  });
}
