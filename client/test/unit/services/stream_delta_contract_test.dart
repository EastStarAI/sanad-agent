// Contract coverage for the stream-ordering wire fields on the Client side.
//
// Three owners meet here: the capability declaration the Agent sends, the
// mapper that turns a payload into a canonical event, and the narrow repair
// command. Each is proved on its own boundary so no case depends on a socket.

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/data/mappers/unified_device_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_commands.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';

class _FakeGateway implements ConversationCommandGateway {
  _FakeGateway({this.connected = true});

  final bool connected;
  final List<Map<String, dynamic>> requests = <Map<String, dynamic>>[];
  Map<String, dynamic>? reply;
  Object? failure;
  final StreamController<Map<String, dynamic>> _events =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  bool get isConnected => connected;

  @override
  bool get isLocalTransport => true;

  @override
  Stream<Map<String, dynamic>> get events => _events.stream;

  @override
  void sendCommand({required String command, Map<String, dynamic>? payload}) {}

  @override
  Future<List<String>> admitHostedAttachments({
    required String sessionId,
    required String requestId,
    required List<Map<String, dynamic>> attachments,
  }) async => const <String>[];

  @override
  Future<Map<String, dynamic>?> request({
    required String command,
    required Map<String, dynamic> payload,
    required String requestId,
    Duration timeout = const Duration(seconds: 10),
  }) async {
    requests.add(<String, dynamic>{
      'command': command,
      'payload': payload,
      'requestId': requestId,
      'timeout': timeout,
    });
    if (failure != null) throw failure!;
    return reply;
  }

  @override
  void dispose() {
    unawaited(_events.close());
  }
}

void main() {
  group('stream_sequence_v1 declaration', () {
    test('advertised contract enables the repair path', () {
      final capability = Capability.fromJson(const <String, dynamic>{
        'stream_sequence_v1': <String, dynamic>{
          'version': 1,
          'counter': 'stream_seq',
          'scope': 'stream',
          'snapshot_command': 'session.stream_state',
        },
      });

      expect(capability.supportsStreamSequence, isTrue);
    });

    test('an absent or unrelated declaration leaves it off', () {
      expect(
        Capability.fromJson(const <String, dynamic>{}).supportsStreamSequence,
        isFalse,
      );
      expect(
        Capability.fromJson(const <String, dynamic>{
          'stream_sequence_v1': false,
        }).supportsStreamSequence,
        isFalse,
      );
      expect(
        Capability.fromJson(const <String, dynamic>{
          'stream_sequence_v1': 'yes',
        }).supportsStreamSequence,
        isFalse,
      );
    });

    test('an unknown future version is not a negotiation failure', () {
      expect(
        Capability.fromJson(const <String, dynamic>{
          'stream_sequence_v1': <String, dynamic>{'version': 2},
        }).supportsStreamSequence,
        isTrue,
      );
    });

    test('the declaration participates in equality', () {
      expect(
        Capability.fromJson(const <String, dynamic>{
          'stream_sequence_v1': <String, dynamic>{'version': 1},
        }),
        isNot(const Capability()),
      );
    });
  });

  group('mapper carries the ordering fields', () {
    final mapper = UnifiedDeviceMapper();

    test('a numbered thought delta keeps its ordinal', () {
      final event = mapper.mapLiveEvent(const <String, dynamic>{
        'event': 'thought_stream',
        'payload': <String, dynamic>{
          'session_id': 's1',
          'run_id': 'run-1',
          'model_step_id': 'step-1',
          'content': 'A',
          'status': 'running',
          'stream_seq': 4,
        },
      })!;

      expect(event.kind, EventKind.thinking);
      expect(event.streamSeq, 4);
      expect(event.isSnapshot, isFalse);
    });

    test('a snapshot payload is flagged whole and keeps its watermark', () {
      final event = mapper.mapLiveEvent(const <String, dynamic>{
        'event': 'thought_stream',
        'payload': <String, dynamic>{
          'session_id': 's1',
          'run_id': 'run-1',
          'model_step_id': 'step-1',
          'content': 'ABCD',
          'status': 'running',
          'snapshot': true,
          'stream_seq': 4,
        },
      })!;

      expect(event.isSnapshot, isTrue);
      expect(event.streamSeq, 4);
      expect(event.text, 'ABCD');
    });

    test('a whitespace-only reasoning chunk survives mapping', () {
      final event = mapper.mapLiveEvent(const <String, dynamic>{
        'event': 'reasoning_stream',
        'payload': <String, dynamic>{
          'session_id': 's1',
          'run_id': 'run-1',
          'model_step_id': 'step-1',
          'content': '\n',
          'status': 'running',
          'stream_seq': 2,
        },
      })!;

      expect(event.kind, EventKind.reasoning);
      expect(event.text, '\n');
      expect(event.streamSeq, 2);
    });

    test('a legacy delta maps to no ordinal and no snapshot flag', () {
      final event = mapper.mapLiveEvent(const <String, dynamic>{
        'event': 'thought_stream',
        'payload': <String, dynamic>{
          'session_id': 's1',
          'content': 'legacy',
          'status': 'running',
        },
      })!;

      expect(event.streamSeq, isNull);
      expect(event.isSnapshot, isFalse);
    });

    test('copyWith and merge keep the ordering fields', () {
      final event = CanonicalEvent(
        id: 'thinking_step-1',
        kind: EventKind.thinking,
        text: 'A',
        timestamp: DateTime.utc(2026, 1, 1),
        streamSeq: 3,
      );

      expect(event.copyWith(text: 'AB').streamSeq, 3);
      expect(event.copyWith(isSnapshot: true).isSnapshot, isTrue);
      expect(
        event
            .merge(
              CanonicalEvent(
                id: 'thinking_step-1',
                kind: EventKind.thinking,
                timestamp: DateTime.utc(2026, 1, 1, 0, 0, 1),
              ),
            )
            .streamSeq,
        3,
      );
    });
  });

  group('session.stream_state repair command', () {
    late _FakeGateway gateway;
    late DeviceConversationStore store;
    late ConversationCommands commands;

    setUp(() {
      gateway = _FakeGateway();
      store = DeviceConversationStore();
      commands = ConversationCommands(
        gateway: gateway,
        conversationStore: store,
        mapper: UnifiedDeviceMapper(),
      );
    });

    tearDown(() {
      gateway.dispose();
      store.dispose();
    });

    test('asks the narrow query with the session and a correlated id', () async {
      gateway.reply = const <String, dynamic>{
        'payload': <String, dynamic>{
          'session_id': 's1',
          'state': 'absent',
          'reason': 'idle',
        },
      };

      await commands.readStreamState('s1');

      expect(gateway.requests, hasLength(1));
      final request = gateway.requests.single;
      expect(request['command'], 'session.stream_state');
      final payload = request['payload'] as Map<String, dynamic>;
      expect(payload['session_id'], 's1');
      expect(payload['request_id'], request['requestId']);
      expect(request['timeout'], ConversationCommands.defaultStreamStateTimeout);
    });

    test('returns the snapshot as one canonical stream event', () async {
      gateway.reply = const <String, dynamic>{
        'payload': <String, dynamic>{
          'request_id': 'request-1',
          'session_id': 's1',
          'state': 'streaming',
          'stream': <String, dynamic>{
            'type': 'thought_stream',
            'snapshot': true,
            'stream_seq': 7,
            'content': 'restored text',
            'status': 'running',
            'run_id': 'run-1',
            'model_step_id': 'step-1',
          },
        },
      };

      final snapshot = await commands.readStreamState('s1');

      expect(snapshot, isNotNull);
      expect(snapshot!.kind, EventKind.thinking);
      expect(snapshot.isSnapshot, isTrue);
      expect(snapshot.streamSeq, 7);
      expect(snapshot.text, 'restored text');
      expect(snapshot.sessionId, 's1');
      expect(snapshot.modelStepId, 'step-1');
    });

    test('an absent answer, a typed error, and an offline transport return null', () async {
      gateway.reply = const <String, dynamic>{
        'payload': <String, dynamic>{'state': 'absent', 'reason': 'unknown_session'},
      };
      expect(await commands.readStreamState('s1'), isNull);

      gateway.reply = const <String, dynamic>{
        'payload': <String, dynamic>{
          'error': <String, dynamic>{'code': 'invalid_request'},
        },
      };
      expect(await commands.readStreamState('s1'), isNull);

      gateway.failure = StateError('dropped');
      expect(await commands.readStreamState('s1'), isNull);

      final offline = _FakeGateway(connected: false);
      final offlineCommands = ConversationCommands(
        gateway: offline,
        conversationStore: store,
        mapper: UnifiedDeviceMapper(),
      );
      expect(await offlineCommands.readStreamState('s1'), isNull);
      expect(offline.requests, isEmpty);
      offline.dispose();
    });
  });
}
