import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/engine/runtime/steer_coordinator.dart';
import 'package:test/test.dart';

void main() {
  test(
    'late steer save failure rolls back history and keeps buffered text',
    () {
      final coordinator = SteerCoordinator(sessionId: 'session-1');
      coordinator.steerEvent(
        'keep this',
        requestId: 'request-1',
        receivedAt: DateTime.utc(2026, 7, 15),
      );
      final callbacks = _FailingCallbacks([]);

      expect(
        () => coordinator.appendPendingSteersAsUserMessages(callbacks),
        throwsStateError,
      );
      expect(callbacks.history, isEmpty);
      expect(callbacks.released, ['request-1']);
      expect(coordinator.snapshot().single.text, 'keep this');
    },
  );

  test('tool steer save failure restores original tool message', () {
    final coordinator = SteerCoordinator(sessionId: 'session-2');
    coordinator.steerEvent(
      'change direction',
      requestId: 'request-2',
      receivedAt: DateTime.utc(2026, 7, 15),
    );
    final callbacks = _FailingCallbacks([
      Message(
        role: MessageRole.tool,
        content: 'original result',
        metadata: {'original': true},
      ),
    ]);

    expect(() => coordinator.drainPreApiSteer(callbacks), throwsStateError);
    expect(callbacks.history.single.content, 'original result');
    expect(callbacks.history.single.metadata, {'original': true});
    expect(callbacks.released, ['request-2']);
    expect(coordinator.snapshot(), hasLength(1));
  });
}

class _FailingCallbacks implements SteerCallbacks {
  final List<Message> history;
  final List<String> released = [];

  _FailingCallbacks(this.history);

  @override
  int get currentTurnStartIndex => 0;

  @override
  int get historyLength => history.length;

  @override
  void addUserMessage(Message message) => history.add(message);

  @override
  int lastAssistantIndex() => history.lastIndexWhere(
    (message) => message.role == MessageRole.assistant,
  );

  @override
  String? messageContentAt(int index) => history[index].content;

  @override
  Map<String, dynamic>? messageMetadataAt(int index) => history[index].metadata;

  @override
  MessageRole messageRoleAt(int index) => history[index].role;

  @override
  void releasePendingSteerAfterDeliveryFailure(PendingSteer steer) {
    released.add(steer.requestId!);
  }

  @override
  bool reservePendingSteer(PendingSteer steer) => true;

  @override
  void rollbackAddedUserMessages(int count) {
    history.removeRange(history.length - count, history.length);
  }

  @override
  void commitPendingSteerDelivery(List<PendingSteerPlacement> placements) =>
      throw StateError('persistence failed');

  @override
  void updateMessage(
    int index, {
    String? content,
    Map<String, dynamic>? metadata,
  }) {
    final current = history[index];
    history[index] = current.copyWith(
      content: content ?? current.content,
      metadata: metadata ?? current.metadata,
    );
  }
}
