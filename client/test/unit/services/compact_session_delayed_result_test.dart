import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_commands.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

import '../../mocks/mock_socket_service.dart';

/// Task 119: a slow manual compaction outlives the acknowledgement window.
/// The timeout is injected (never the production window) and every assertion
/// awaits the exact correlated result.
void main() {
  late FakeSanadSocketService socket;
  late SocketConversationCommandGateway gateway;
  late DeviceConversationStore store;

  setUp(() {
    socket = FakeSanadSocketService()..setConnected(true);
    gateway = SocketConversationCommandGateway(
      config: DeviceConfig(id: 'agent-1', name: 'SanadAgent'),
      controller: socket,
    );
    store = DeviceConversationStore();
  });

  tearDown(() {
    gateway.dispose();
    store.dispose();
    socket.dispose();
  });

  ConversationCommands commandsWith({
    Duration settlementWindow = const Duration(seconds: 30),
  }) => ConversationCommands(
    gateway: gateway,
    conversationStore: store,
    mapper: UnifiedDeviceMapper(),
    compactAcknowledgementTimeout: const Duration(milliseconds: 20),
    compactSettlementWindow: settlementWindow,
  );

  String dispatchedRequestId() {
    final command = socket.capturedCommands.single;
    expect(command['command'], 'session.compact');
    return (command['payload'] as Map<String, dynamic>)['request_id'] as String;
  }

  void routeCompactResult(Map<String, dynamic> payload) {
    socket.eventRouter.routeEvent({
      'device_id': 'agent-1',
      'event': 'session.compact_result',
      'session_id': payload['session_id'],
      'payload': payload,
    });
  }

  Future<SessionCompactResult> timedOutCompaction(
    ConversationCommands commands,
  ) async {
    final result = await commands.compactSession(sessionId: 'session-1');
    expect(result.pending, isTrue, reason: 'a timeout is pending, never failed');
    expect(result.accepted, isFalse);
    expect(result.failureReason, isNull);
    expect(result.requestId, dispatchedRequestId());
    expect(result.settlement, isNotNull);
    return result;
  }

  test('timeout then late success settles accepted with one dispatch', () async {
    final result = await timedOutCompaction(commandsWith());

    routeCompactResult({
      'session_id': 'session-1',
      'request_id': result.requestId,
      'outcome': 'accepted',
      'compaction_id': 'cmp-1',
    });

    final settled = await result.settlement!;
    expect(settled.accepted, isTrue);
    expect(settled.compactionId, 'cmp-1');
    expect(settled.requestId, result.requestId);
    expect(socket.capturedCommands, hasLength(1), reason: 'never resent');
  });

  test('timeout then late failure keeps the real failure classification', () async {
    final result = await timedOutCompaction(commandsWith());

    routeCompactResult({
      'session_id': 'session-1',
      'request_id': result.requestId,
      'outcome': 'failed',
      'failure_reason': 'summarization_failed',
      'failure_stage': 'provider',
      'failure_cause': 'timeout',
      'compaction_id': 'cmp-2',
    });

    final settled = await result.settlement!;
    expect(settled.accepted, isFalse);
    expect(settled.outcome, 'failed');
    expect(settled.failureReason, 'summarization_failed');
    expect(settled.failureStage, 'provider');
    expect(settled.failureCause, 'timeout');
    expect(socket.capturedCommands, hasLength(1));
  });

  test('timeout then late busy or in-progress rejection settles rejected', () async {
    final result = await timedOutCompaction(commandsWith());

    routeCompactResult({
      'session_id': 'session-1',
      'request_id': result.requestId,
      'outcome': 'compaction_in_progress',
      'failure_reason': 'compaction_in_progress',
      'failure_stage': 'preparation',
      'failure_cause': 'compaction_in_progress',
    });

    final settled = await result.settlement!;
    expect(settled.compactionInProgress, isTrue);
    expect(settled.accepted, isFalse);
  });

  test('late session_busy rejection settles busy', () async {
    final result = await timedOutCompaction(commandsWith());

    routeCompactResult({
      'session_id': 'session-1',
      'request_id': result.requestId,
      'outcome': 'session_busy',
    });

    expect((await result.settlement!).sessionBusy, isTrue);
  });

  test('settlement correlates by session and request and settles once', () async {
    final result = await timedOutCompaction(commandsWith());

    // Another request and the same request id under another session are not
    // this command's outcome.
    routeCompactResult({
      'session_id': 'session-1',
      'request_id': 'other-request',
      'outcome': 'failed',
    });
    routeCompactResult({
      'session_id': 'session-2',
      'request_id': result.requestId,
      'outcome': 'failed',
    });
    routeCompactResult({
      'session_id': 'session-1',
      'request_id': result.requestId,
      'outcome': 'accepted',
      'compaction_id': 'cmp-3',
    });
    // A duplicated late delivery must not produce a second outcome.
    routeCompactResult({
      'session_id': 'session-1',
      'request_id': result.requestId,
      'outcome': 'failed',
    });

    final settled = await result.settlement!;
    expect(settled.accepted, isTrue);
    expect(settled.compactionId, 'cmp-3');
    expect(socket.capturedCommands, hasLength(1));
  });

  test('no late result within the settlement window is unconfirmed, not failed', () async {
    final result = await timedOutCompaction(
      commandsWith(settlementWindow: const Duration(milliseconds: 20)),
    );

    final settled = await result.settlement!;
    expect(settled.unconfirmed, isTrue);
    expect(settled.accepted, isFalse);
    expect(settled.failureReason, isNull);
    expect(socket.capturedCommands, hasLength(1), reason: 'never resent');
  });

  test('a throwing request cancels the late-result listener and rethrows', () async {
    final listened = <bool>[];
    final events = StreamController<Map<String, dynamic>>.broadcast(
      onListen: () => listened.add(true),
      onCancel: () => listened.add(false),
    );
    addTearDown(events.close);
    final commands = ConversationCommands(
      gateway: _ThrowingGateway(events.stream),
      conversationStore: store,
      mapper: UnifiedDeviceMapper(),
    );

    await expectLater(
      commands.compactSession(sessionId: 'session-1'),
      throwsStateError,
    );
    await Future<void>.delayed(Duration.zero);

    expect(listened, [true, false], reason: 'subscription must not outlive the request');
    expect(events.hasListener, isFalse);
  });

  test('a timely acknowledgement returns directly without a settlement', () async {
    final commands = commandsWith();
    final future = commands.compactSession(sessionId: 'session-1');
    final requestId = dispatchedRequestId();

    routeCompactResult({
      'session_id': 'session-1',
      'request_id': requestId,
      'outcome': 'session_busy',
    });

    final result = await future;
    expect(result.sessionBusy, isTrue);
    expect(result.pending, isFalse);
    expect(result.settlement, isNull);
  });
}

class _ThrowingGateway implements ConversationCommandGateway {
  _ThrowingGateway(this.events);

  @override
  final Stream<Map<String, dynamic>> events;

  @override
  bool get isConnected => true;

  @override
  bool get isLocalTransport => true;

  @override
  Future<Map<String, dynamic>?> request({
    required String command,
    required Map<String, dynamic> payload,
    required String requestId,
    Duration timeout = const Duration(seconds: 10),
  }) async => throw StateError('Duplicate conversation request id: $requestId');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
