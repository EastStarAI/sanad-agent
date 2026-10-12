import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/runtime/workspace_path_resolver.dart';
import 'package:sanad_agent/capabilities/runtime/workspace_tools/view_image_handler.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/hosted_binary_relay.dart';
import 'package:socket_io_client/socket_io_client.dart' as io;

Future<void> main() async {
  final stateHome = Platform.environment['SANAD_STATE_HOME'];
  if (stateHome == null || stateHome.trim().isEmpty) {
    stderr.writeln('SANAD_STATE_HOME is required.');
    exitCode = 64;
    return;
  }
  final state = AgentStateDatabase.inMemory();
  final store = AttachmentStore(state, stateHome: stateHome);
  await store.initialize();
  final now = DateTime.now().toUtc().toIso8601String();
  state.db.execute(
    '''INSERT INTO sessions (session_id, model, created_at, updated_at)
       VALUES ('remote-session', 'sanad-e2e-model', ?, ?)''',
    [now, now],
  );
  var history = <Message>[];
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  stdout.writeln('READY:${server.port}');

  late final StreamSubscription<HttpRequest> serverSubscription;
  serverSubscription = server.listen((request) async {
    if (!WebSocketTransformer.isUpgradeRequest(request)) {
      request.response.statusCode = HttpStatus.badRequest;
      await request.response.close();
      return;
    }
    final webSocket = await WebSocketTransformer.upgrade(request);
    final socket = _FixtureSocket(webSocket);
    HostedBinaryRelay(
      store: store,
      historyLoader: (sessionId) =>
          sessionId == 'remote-session' ? history : const <Message>[],
    ).bind(socket);

    webSocket.listen((raw) async {
      final frame = jsonDecode(raw as String) as Map<String, dynamic>;
      final event = frame['event'] as String;
      final data = _normalize(frame['data']);
      if (event == 'device_command') {
        final envelope = Map<String, dynamic>.from(data as Map);
        final payload = Map<String, dynamic>.from(envelope['payload'] as Map);
        if (envelope['command'] != 'think' ||
            payload.containsKey('attachments') ||
            jsonEncode(payload).contains('data_base64')) {
          socket.push('fixture_error', {'code': 'unsafe_turn'});
          return;
        }
        final requestId = payload['request_id'] as String;
        final attachmentIds = List<String>.from(
          payload['attachment_ids'] as List,
        );
        final messageId = 'message-$requestId';
        state.db.execute(
          '''INSERT INTO messages (session_id, data, message_id)
             VALUES (?, ?, ?)''',
          [
            'remote-session',
            jsonEncode({
              'role': 'user',
              'content': payload['message'],
              'attachments': const [],
            }),
            messageId,
          ],
        );
        history = store.claimAdmissionAndPersist(
          sessionId: 'remote-session',
          admissionId: requestId,
          attachmentIds: attachmentIds,
          persist: (_, attachments) => [
            Message(
              role: MessageRole.user,
              content: payload['message'] as String,
              attachments: attachments,
              metadata: {
                'request_id': requestId,
                'message_id': messageId,
                'turn_id': 'turn-$requestId',
              },
            ),
          ],
        );
        final paths = await store.resolveAttachedPaths('remote-session');
        final toolResult = await ViewImageHandler(const WorkspacePathResolver())
            .executeResult(
              {'path': paths.single, 'detail': 'original'},
              workspacePath: null,
              admittedAttachmentPaths: paths,
              authorizeExternal: (_, _, _) async {},
            );
        socket.push('fixture_turn_result', {
          'request_id': requestId,
          'attachment_count': history.single.attachments.length,
          'model_path_count': paths.length,
          'view_image_selected': true,
          'view_image_succeeded':
              !toolResult.isError &&
              toolResult.blocks.whereType<ToolImageBlock>().length == 1,
          'media_id': history.single.attachments.single.mediaId,
        });
        return;
      }
      final emittedBefore = socket.terminalUploads.length;
      await socket.receive(event, data);
      final id = data is Map ? data['upload_id']?.toString() : null;
      if (id == null || socket.terminalUploads.contains(id)) return;
      if (event == 'attachment_upload_start') {
        socket.push('attachment_upload_ack', {
          'version': 'v1',
          'upload_id': id,
          'state': 'started',
          'next_index': 0,
        });
      } else if (event == 'attachment_upload_chunk' &&
          socket.terminalUploads.length == emittedBefore) {
        socket.push('attachment_upload_ack', {
          'version': 'v1',
          'upload_id': id,
          'state': 'chunk',
          'index': (data as Map)['index'],
          'next_index': (data['index'] as int) + 1,
          'duplicate': false,
        });
      }
    });
  });

  Future<void> shutdown() async {
    await serverSubscription.cancel();
    await server.close(force: true);
    state.dispose();
  }

  ProcessSignal.sigterm.watch().listen((_) async {
    await shutdown();
    exit(0);
  });
  await Completer<void>().future;
}

Object? _normalize(Object? value) {
  if (value is List) return value.map(_normalize).toList();
  if (value is Map) {
    final result = value.map(
      (key, item) => MapEntry(key.toString(), _normalize(item)),
    );
    if (result['data'] is List) {
      result['data'] = List<int>.from(result['data'] as List);
    }
    return result;
  }
  return value;
}

final class _FixtureSocket implements io.Socket {
  _FixtureSocket(this.webSocket);

  final WebSocket webSocket;
  final listeners = <String, List<Function>>{};
  final terminalUploads = <String>{};

  @override
  Function() on(String event, Function fn) {
    listeners.putIfAbsent(event, () => []).add(fn);
    return () {};
  }

  Future<void> receive(String event, Object? data) async {
    for (final listener in listeners[event] ?? const <Function>[]) {
      final result = Function.apply(listener, [data]);
      if (result is Future) await result;
    }
  }

  @override
  void emit(String event, [Object? data]) {
    if (event == 'attachment_upload_result') {
      final result = Map<String, dynamic>.from(data as Map);
      final uploadId = result['upload_id'] as String;
      terminalUploads.add(uploadId);
      push('attachment_upload_ack', {...result, 'state': 'terminal'});
      return;
    }
    push(event, data);
  }

  void push(String event, Object? data) {
    webSocket.add(jsonEncode({'event': event, 'data': data}));
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}
