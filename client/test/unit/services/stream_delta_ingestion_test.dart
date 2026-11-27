// Integration coverage for stream ordering through the real ingestion path.
//
// The cases go through `ConversationEventHandler` and the real
// `DeviceConversationStore`/`ConversationState`, so the contract proved here is
// the one the timeline actually renders: which deltas become text, what a
// snapshot replaces, and whether a late delta can create a second bubble.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_event_handler.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:sanad_client/features/conversations/domain/stores/stream_delta_order_gate.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

import '../../helpers/manual_timer_scheduler.dart';
import '../../mocks/mock_socket_service.dart';

void main() {
  const sessionId = 'session-1';
  const localDeviceId = 'agent-1';
  const cloudDeviceId = 'cloud-agent-1';

  late FakeSanadSocketService socket;
  late SocketConversationCommandGateway gateway;
  late DeviceConfig device;
  late DeviceConversationStore store;
  late ConversationEventHandler handler;
  late ManualTimerScheduler scheduler;
  late DateTime now;
  late List<String> repairRequests;
  late Future<CanonicalEvent?> Function(String sessionId) onRepair;

  setUp(() {
    socket = FakeSanadSocketService()..setConnected(true);
    device = DeviceConfig(
      id: localDeviceId,
      name: 'SanadAgent',
      metadata: const {'cloud_device_id': cloudDeviceId},
    );
    gateway = SocketConversationCommandGateway(
      config: device,
      controller: socket,
    );
    scheduler = ManualTimerScheduler();
    now = DateTime.utc(2026, 1, 1, 12);
    final gate = StreamDeltaOrderGate(
      timerFactory: scheduler.factory,
      now: () => now,
    );
    store = DeviceConversationStore(streamDeltaGate: gate)
      ..activateSession(sessionId);
    repairRequests = <String>[];
    onRepair = (session) async {
      repairRequests.add(session);
      return null;
    };
    store.attachStreamRepair(request: (session) => onRepair(session), supported: true);
    handler = ConversationEventHandler(
      device: device,
      gateway: gateway,
      conversationStore: store,
      mapper: UnifiedDeviceMapper(),
    );
  });

  tearDown(() {
    handler.dispose();
    gateway.dispose();
    store.dispose();
    socket.dispose();
  });

  Map<String, dynamic> envelope({
    required String event,
    required Map<String, dynamic> payload,
    String deviceId = localDeviceId,
  }) {
    return <String, dynamic>{
      'event': event,
      'device_id': deviceId,
      'payload': <String, dynamic>{
        'session_id': sessionId,
        'run_id': 'run-1',
        'model_step_id': 'step-1',
        ...payload,
      },
    };
  }

  void deliver(Map<String, dynamic> event) => handler.handleIncomingEvent(event);

  void deliverThought({
    int? seq,
    required String text,
    String deviceId = localDeviceId,
    bool snapshot = false,
  }) {
    deliver(
      envelope(
        event: 'thought_stream',
        deviceId: deviceId,
        payload: <String, dynamic>{
          'content': text,
          'status': 'running',
          if (seq != null) 'stream_seq': seq,
          if (snapshot) 'snapshot': true,
        },
      ),
    );
  }

  String renderedText() => store.currentMessages
      .where((event) => event.kind == EventKind.thinking)
      .map((event) => event.text)
      .join();

  test('applies an out-of-order stream as one correctly ordered bubble', () {
    deliverThought(seq: 2, text: 'B');
    expect(renderedText(), isEmpty, reason: 'the head is missing');

    deliverThought(seq: 1, text: 'A');

    expect(store.currentMessages, hasLength(1));
    expect(renderedText(), 'AB');
    expect(store.currentMessages.single.status, EventStatus.running);
  });

  test('a duplicated delivery never duplicates the visible text', () {
    deliverThought(seq: 1, text: 'A');
    deliverThought(seq: 2, text: 'B');
    deliverThought(seq: 2, text: 'B');
    deliverThought(seq: 1, text: 'A');

    expect(renderedText(), 'AB');
  });

  test('cross-transport interleave converges on the same text', () {
    // The local and the cloud transport deliver the same stream interleaved;
    // the merged client folds them into one ordered bubble.
    deliverThought(seq: 1, text: 'A', deviceId: localDeviceId);
    deliverThought(seq: 1, text: 'A', deviceId: cloudDeviceId);
    deliverThought(seq: 3, text: 'C', deviceId: cloudDeviceId);
    deliverThought(seq: 2, text: 'B', deviceId: localDeviceId);

    expect(renderedText(), 'ABC');
    expect(store.currentMessages.where((event) => event.kind == EventKind.thinking), hasLength(1));
  });

  test('a snapshot replaces the text and its watermark drops older deltas', () {
    deliverThought(seq: 1, text: 'A');
    deliverThought(seq: 2, text: 'B');

    deliverThought(seq: 4, text: 'ABCD', snapshot: true);
    expect(renderedText(), 'ABCD', reason: 'a snapshot never appends');

    deliverThought(seq: 3, text: 'C');
    expect(renderedText(), 'ABCD');

    deliverThought(seq: 5, text: 'E');
    expect(renderedText(), 'ABCDE');
  });

  test('a final answer seals its step so a late delta creates no ghost bubble', () {
    deliverThought(seq: 1, text: 'A');
    deliver(envelope(event: 'final_answer', payload: <String, dynamic>{'content': 'answer'}));
    expect(store.currentMessages.single.kind, EventKind.finalAnswer);

    deliverThought(seq: 2, text: 'B');

    expect(store.currentMessages, hasLength(1));
    expect(store.currentMessages.single.text, 'answer');
    expect(store.currentMessages.where((event) => event.kind == EventKind.thinking), isEmpty);
  });

  test('a stop seals the run against later deltas', () {
    deliverThought(seq: 1, text: 'A');
    deliver(envelope(event: 'stopped', payload: <String, dynamic>{}));

    deliverThought(seq: 2, text: 'B');

    expect(renderedText(), isEmpty);
    expect(store.currentMessages.where((event) => event.kind == EventKind.thinking), isEmpty);
  });

  test('an unsequenced stream keeps the previous arrival-order behavior', () {
    deliverThought(text: 'A');
    deliverThought(text: 'B');
    deliverThought(text: 'C');

    expect(renderedText(), 'ABC');
    expect(scheduler.delays, isEmpty);
  });

  test('a permanent gap asks once, keeps the good text, and recovers on terminal', () async {
    deliverThought(seq: 1, text: 'A');
    deliverThought(seq: 3, text: 'C');
    expect(renderedText(), 'A');

    scheduler.fireAll();
    await Future<void>.delayed(Duration.zero);

    expect(repairRequests, [sessionId]);
    expect(renderedText(), 'A', reason: 'an absent answer never invents text');
    expect(store.currentMessages, hasLength(1));

    // Nothing was reloaded and no error surface appeared.
    expect(store.currentMessages.single.kind, EventKind.thinking);

    deliver(envelope(event: 'final_answer', payload: <String, dynamic>{'content': 'answer'}));
    expect(store.currentMessages.last.text, 'answer');
  });

  test('switching sessions drops the pending window of the previous one', () {
    deliverThought(seq: 3, text: 'C');
    expect(scheduler.activeCount, 1);

    store.activateSession('session-2');

    expect(scheduler.activeCount, 0);

    deliver(envelope(
      event: 'thought_stream',
      payload: <String, dynamic>{'content': 'second', 'status': 'running', 'stream_seq': 1, 'session_id': 'session-2'},
    ));
    expect(store.currentMessages.single.text, 'second');
  });

  test('a repair that returns after a session switch never reaches the new session', () async {
    final pending = Completer<CanonicalEvent?>();
    onRepair = (session) {
      repairRequests.add(session);
      return pending.future;
    };

    deliverThought(seq: 1, text: 'A');
    deliverThought(seq: 3, text: 'C');
    scheduler.fireAll();
    expect(repairRequests, [sessionId]);

    store.activateSession('session-2');
    pending.complete(_snapshot(seq: 3, text: 'ABC'));
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages, isEmpty, reason: 'the answer belonged to the old session');

    store.activateSession(sessionId);
    expect(renderedText(), 'A', reason: 'the retained timeline keeps only what it had');
  });

  test('a repair that returns after the final answer never reopens the bubble', () async {
    final pending = Completer<CanonicalEvent?>();
    onRepair = (session) {
      repairRequests.add(session);
      return pending.future;
    };

    deliverThought(seq: 1, text: 'A');
    deliverThought(seq: 3, text: 'C');
    scheduler.fireAll();
    expect(repairRequests, [sessionId]);

    deliver(envelope(event: 'final_answer', payload: <String, dynamic>{'content': 'answer'}));
    pending.complete(_snapshot(seq: 5, text: 'ABCDE'));
    await Future<void>.delayed(Duration.zero);

    expect(store.currentMessages, hasLength(1));
    expect(store.currentMessages.single.kind, EventKind.finalAnswer);
    expect(renderedText(), isEmpty, reason: 'a retired repair cannot resurrect a step');
  });
}

CanonicalEvent _snapshot({
  required int seq,
  required String text,
  String sessionId = 'session-1',
}) {
  return CanonicalEvent(
    id: 'thinking_step-1',
    kind: EventKind.thinking,
    status: EventStatus.running,
    text: text,
    timestamp: DateTime.utc(2026, 1, 1, 12),
    sessionId: sessionId,
    runId: 'run-1',
    modelStepId: 'step-1',
    streamSeq: seq,
    isSnapshot: true,
  );
}
