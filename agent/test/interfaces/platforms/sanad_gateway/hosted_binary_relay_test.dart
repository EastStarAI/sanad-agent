import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/hosted_binary_relay.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;
import 'package:test/test.dart';

final class _FakeSocket implements io.Socket {
  final listeners = <String, List<Function>>{};
  final emitted = <(String, dynamic)>[];

  @override
  Function() on(String event, Function fn) {
    listeners.putIfAbsent(event, () => []).add(fn);
    return () {};
  }

  @override
  void emit(String event, [dynamic data]) => emitted.add((event, data));

  Future<void> receive(String event, dynamic data) async {
    for (final listener in listeners[event] ?? const <Function>[]) {
      final result = Function.apply(listener, [data]);
      if (result is Future) await result;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  late Directory home;
  late AgentStateDatabase state;
  late AttachmentStore store;
  late List<Message> history;
  late _FakeSocket socket;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-hosted-relay-');
    state = AgentStateDatabase.inMemory();
    store = AttachmentStore(state, stateHome: home.path);
    await store.initialize();
    final now = DateTime.now().toUtc().toIso8601String();
    state.db.execute(
      '''
      INSERT INTO sessions (session_id, model, created_at, updated_at)
      VALUES ('session-a', 'test-model', ?, ?)
      ''',
      [now, now],
    );
    state.db.execute('''
      INSERT INTO messages (session_id, data, message_id)
      VALUES ('session-a', '{"role":"user","content":"inspect","attachments":[]}', 'message-a')
      ''');
    history = [];
    socket = _FakeSocket();
    HostedBinaryRelay(
      store: store,
      historyLoader: (sessionId) =>
          sessionId == 'session-a' ? history : const <Message>[],
    ).bind(socket);
  });

  tearDown(() async {
    state.dispose();
    if (await home.exists()) await home.delete(recursive: true);
  });

  test(
    'streams verified chunks and returns an opaque accepted identity',
    () async {
      final bytes = utf8.encode('remote attachment');
      final hash = sha256.convert(bytes).toString();
      await socket.receive('attachment_upload_start', {
        'version': 'v1',
        'upload_id': 'upload-a',
        'device_id': 'device-a',
        'session_id': 'session-a',
        'request_id': 'request-a',
        'name': 'private-name.txt',
        'mime_type': 'text/plain',
        'size_bytes': bytes.length,
        'sha256': hash,
        'chunk_count': 1,
        'file_index': 0,
        'turn_file_count': 1,
        'turn_total_bytes': bytes.length,
      });
      await socket.receive('attachment_upload_chunk', {
        'version': 'v1',
        'upload_id': 'upload-a',
        'index': 0,
        'sha256': hash,
        'data': bytes,
      });
      await socket.receive('attachment_upload_commit', {
        'version': 'v1',
        'upload_id': 'upload-a',
      });

      final result =
          socket.emitted
                  .singleWhere(
                    (entry) => entry.$1 == 'attachment_upload_result',
                  )
                  .$2
              as Map;
      expect(result['outcome'], 'accepted');
      expect(result['attachment_id'], isA<String>());
      expect(result.containsKey('name'), isFalse);
      expect(result.containsKey('data'), isFalse);
    },
  );

  test(
    'returns exact session-owned attachment bytes and rejects cross-session fetch',
    () async {
      final bytes = utf8.encode('remote media bytes');
      final hash = sha256.convert(bytes).toString();
      await socket.receive('attachment_upload_start', {
        'version': 'v1',
        'upload_id': 'upload-media',
        'device_id': 'device-a',
        'session_id': 'session-a',
        'request_id': 'request-media',
        'name': 'private-name.txt',
        'mime_type': 'text/plain',
        'size_bytes': bytes.length,
        'sha256': hash,
        'chunk_count': 1,
        'file_index': 0,
        'turn_file_count': 1,
        'turn_total_bytes': bytes.length,
      });
      await socket.receive('attachment_upload_chunk', {
        'version': 'v1',
        'upload_id': 'upload-media',
        'index': 0,
        'sha256': hash,
        'data': bytes,
      });
      await socket.receive('attachment_upload_commit', {
        'version': 'v1',
        'upload_id': 'upload-media',
      });
      final result =
          socket.emitted
                  .singleWhere(
                    (entry) => entry.$1 == 'attachment_upload_result',
                  )
                  .$2
              as Map;
      final attachmentId = result['attachment_id'] as String;
      history = store.claimAdmissionAndPersist(
        sessionId: 'session-a',
        admissionId: 'request-media',
        attachmentIds: [attachmentId],
        persist: (_, attachments) => [
          Message(
            role: MessageRole.user,
            content: 'inspect',
            attachments: attachments,
            metadata: const {
              'request_id': 'request-media',
              'message_id': 'message-a',
              'turn_id': 'turn-a',
            },
          ),
        ],
      );
      socket.emitted.clear();

      await socket.receive('conversation_media_fetch', {
        'version': 'v1',
        'route_id': 'route-a',
        'device_id': 'device-a',
        'session_id': 'session-a',
        'request_id': 'media-request-a',
        'media_id': history.single.attachments.single.mediaId,
        'purpose': 'view',
      });
      final chunk =
          socket.emitted
                  .singleWhere(
                    (entry) => entry.$1 == 'conversation_media_chunk',
                  )
                  .$2
              as Map;
      expect(chunk['data'], bytes);
      expect(chunk['sha256'], hash);
      expect(socket.emitted.map((entry) => entry.$1), [
        'conversation_media_start',
        'conversation_media_chunk',
        'conversation_media_complete',
      ]);

      socket.emitted.clear();
      await socket.receive('conversation_media_fetch', {
        'version': 'v1',
        'route_id': 'route-b',
        'device_id': 'device-a',
        'session_id': 'session-b',
        'request_id': 'media-request-b',
        'media_id': history.single.attachments.single.mediaId,
        'purpose': 'view',
      });
      expect(socket.emitted.single.$1, 'conversation_media_error');
      expect((socket.emitted.single.$2 as Map)['error_code'], 'unavailable');
    },
  );

  test('rejects an out-of-sequence or hash-mismatched chunk', () async {
    final bytes = utf8.encode('payload');
    await socket.receive('attachment_upload_start', {
      'version': 'v1',
      'upload_id': 'upload-b',
      'device_id': 'device-a',
      'session_id': 'session-a',
      'request_id': 'request-b',
      'name': 'private-name.txt',
      'mime_type': 'text/plain',
      'size_bytes': bytes.length,
      'sha256': sha256.convert(bytes).toString(),
      'chunk_count': 1,
      'file_index': 0,
      'turn_file_count': 1,
      'turn_total_bytes': bytes.length,
    });
    await socket.receive('attachment_upload_chunk', {
      'version': 'v1',
      'upload_id': 'upload-b',
      'index': 1,
      'sha256': sha256.convert(bytes).toString(),
      'data': bytes,
    });

    final result =
        socket.emitted
                .singleWhere((entry) => entry.$1 == 'attachment_upload_result')
                .$2
            as Map;
    expect(result, containsPair('outcome', 'rejected'));
    expect(result, containsPair('error_code', 'invalid_request'));
  });

  test('rejects file, turn, index, and chunk-count limit violations', () async {
    final valid = <String, dynamic>{
      'version': 'v1',
      'upload_id': 'upload-limits',
      'device_id': 'device-a',
      'session_id': 'session-a',
      'request_id': 'request-limits',
      'name': 'private-name.txt',
      'mime_type': 'text/plain',
      'size_bytes': 1,
      'sha256': sha256.convert([1]).toString(),
      'chunk_count': 1,
      'file_index': 0,
      'turn_file_count': 1,
      'turn_total_bytes': 1,
    };
    final violations = <Map<String, dynamic>>[
      {'size_bytes': UserAttachmentPolicy.maxFileBytes + 1},
      {'turn_file_count': UserAttachmentPolicy.maxFilesPerMessage + 1},
      {'file_index': 1},
      {'turn_total_bytes': UserAttachmentPolicy.maxTotalBytesPerMessage + 1},
      {'turn_total_bytes': 0},
      {'chunk_count': 2},
    ];

    for (final violation in violations) {
      socket.emitted.clear();
      await socket.receive('attachment_upload_start', {...valid, ...violation});
      expect(socket.emitted.single.$1, 'attachment_upload_result');
      expect(
        socket.emitted.single.$2,
        containsPair('error_code', 'invalid_request'),
      );
    }
    expect(home.listSync(recursive: true).whereType<File>(), isEmpty);
  });

  test(
    'disconnect cancels every partial upload without terminal bytes',
    () async {
      final bytes = utf8.encode('payload');
      await socket.receive('attachment_upload_start', {
        'version': 'v1',
        'upload_id': 'upload-c',
        'device_id': 'device-a',
        'session_id': 'session-a',
        'request_id': 'request-c',
        'name': 'private-name.txt',
        'mime_type': 'text/plain',
        'size_bytes': bytes.length,
        'sha256': sha256.convert(bytes).toString(),
        'chunk_count': 1,
        'file_index': 0,
        'turn_file_count': 1,
        'turn_total_bytes': bytes.length,
      });
      await socket.receive('disconnect', null);

      expect(socket.emitted, isEmpty);
      expect(home.listSync(recursive: true).whereType<File>(), isEmpty);
    },
  );
}
