import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/colocated_auth_coupling.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/models/tool_call.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/delivery_presence_controller.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_security.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/translators/agent_to_canonical.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:test/test.dart';

import '../../../support/memory_agent_secret_store.dart';

class _TransportTestConfig extends Config {
  _TransportTestConfig(this._port);

  final int _port;

  @override
  String get localGatewayHost => '127.0.0.1';

  @override
  int get localGatewayPort => _port;

  @override
  String get localGatewayUrl => 'http://127.0.0.1:$_port';
}

class _ExchangeAuthManager extends AuthManager {
  _ExchangeAuthManager() : super(secretStore: MemoryAgentSecretStore());

  final _controller = StreamController<void>.broadcast();
  int reloadCalls = 0;
  int logoutCalls = 0;
  String? cloudDeviceCredential;

  @override
  String? get deviceToken => cloudDeviceCredential;

  @override
  String? get hardwareId => 'hardware-1';

  @override
  Stream<void> get changes => _controller.stream;

  @override
  Future<bool> reload({bool notifyIfChanged = false}) async {
    reloadCalls += 1;
    if (notifyIfChanged) _controller.add(null);
    return true;
  }

  @override
  Future<void> logout() async {
    logoutCalls += 1;
    cloudDeviceCredential = null;
    _controller.add(null);
  }

  Future<void> close() => _controller.close();
}

Future<int> _reserveFreePort() async {
  final socket = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
  final port = socket.port;
  await socket.close();
  return port;
}

void main() {
  const token = LocalGatewayCredential('transport-test-token');
  late LocalDaemonServerPlatform platform;
  late DeliveryPresenceController deliveryPresence;
  late _ExchangeAuthManager authManager;
  late int port;
  late List<Message> mediaMessages;
  Future<void> Function()? upgradeHook;

  setUp(() async {
    await getIt.reset();
    upgradeHook = null;
    port = await _reserveFreePort();
    getIt.registerSingleton<Config>(_TransportTestConfig(port));
    authManager = _ExchangeAuthManager()
      ..cloudDeviceCredential = 'vault-only-device-credential';
    getIt.registerSingleton<AuthManager>(
      authManager,
      dispose: (manager) => authManager.close(),
    );
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
    getIt.registerSingleton<PlatformRuntimeBridge>(PlatformRuntimeBridge());
    deliveryPresence = DeliveryPresenceController();
    final imageResult = ToolExecutionResult(
      blocks: [
        ToolTextBlock(text: 'Image loaded (2×1, image/png, auto).'),
        ToolImageBlock(
          dataBase64: base64.encode(const [1, 2, 3, 4]),
          mimeType: 'image/png',
          width: 2,
          height: 1,
          detail: ToolImageDetail.auto,
        ),
      ],
    );
    mediaMessages = [
      Message(
        role: MessageRole.assistant,
        toolCalls: [
          ToolCall(id: 'call-view-1', name: 'view_image', arguments: const {}),
        ],
      ),
      Message(
        role: MessageRole.tool,
        toolCallId: 'call-view-1',
        toolResult: imageResult,
      ),
      _attachmentMediaMessage('/unavailable'),
    ];
    platform = LocalDaemonServerPlatform(
      deliveryPresence: deliveryPresence,
      authCoupling: ColocatedAuthCoupling(
        authManager: authManager,
        authorizationClient: DeviceAuthorizationClient(
          portalUrl: 'https://portal.test',
          authManager: authManager,
        ),
      ),
      security: LocalGatewaySecurity(
        config: LocalGatewaySecurityConfig(
          allowedPort: port,
          preauthBudgetPerPeer: 1,
        ),
        expectedToken: token,
      ),
      beforeUpgradeAuthentication: () async {
        await upgradeHook?.call();
      },
      viewImageMediaHistoryLoader: (sessionId) =>
          sessionId == 'session-1' ? mediaMessages : const [],
    );
    await platform.initialize();
  });

  tearDown(() async {
    await platform.dispose();
    await deliveryPresence.dispose();
    await getIt.reset();
  });

  test('local dispatch is attempted with zero connected clients', () async {
    expect(deliveryPresence.localInstanceIds, isEmpty);
    deliveryPresence.acceptInterest({
      'protocol': deliveryPresenceProtocol,
      'version': deliveryPresenceVersion,
      'type': 'cloud.delivery_interest',
      'revision': 1,
      'cloud_recipient_instances_complete': true,
      'cloud_recipient_instance_ids': const <String>[],
      'lease_ms': 30000,
    });

    await platform.sendResponse(
      GatewayResponse(
        sessionId: 'no-local-recipients',
        message: Message(role: MessageRole.assistant, content: 'ready'),
      ),
    );

    expect(deliveryPresence.metrics, {'local': 1, 'cloud': 0, 'suppressed': 0});
  });

  test('HTTP rejects missing credentials before health logic', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    expect(response.statusCode, HttpStatus.unauthorized);
    expect(body['reason'], 'missing_credential');
  });

  test(
    'view-image media is binary-free publicly and exact-scope range retrieval is authenticated',
    () async {
      final media = ViewImageMediaProjection.project(
        sessionId: 'session-1',
        toolName: 'view_image',
        toolCallId: 'call-view-1',
        result: mediaMessages[1].toolResult,
      )!;
      expect(media.toPublicJson(), {
        'media_id': media.mediaId,
        'name': 'view-image.png',
        'mime_type': 'image/png',
        'width': 2,
        'height': 1,
        'availability': 'available',
      });
      expect(jsonEncode(media.toPublicJson()), isNot(contains('AQIDBA==')));
      final liveEvent = AgentToCanonical.translate(
        GatewayResponse(
          sessionId: 'session-1',
          message: mediaMessages[1],
          toolName: 'view_image',
          toolCallId: 'call-view-1',
          isToolResult: true,
        ),
      );
      expect(liveEvent.payload['media'], media.toPublicJson());
      expect(jsonEncode(liveEvent.toJson()), isNot(contains('AQIDBA==')));

      Future<HttpClientResponse> fetch({
        String sessionId = 'session-1',
        String deviceId = 'hardware-1',
        String? range,
        bool authenticated = true,
      }) async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final uri =
            Uri.parse(
              'http://127.0.0.1:$port/media/view-image/${media.mediaId}',
            ).replace(
              queryParameters: {'session_id': sessionId, 'device_id': deviceId},
            );
        final request = await client.getUrl(uri);
        if (authenticated) {
          request.headers.set(LocalGatewayCredentials.headerName, token.value);
        }
        if (range != null) request.headers.set(HttpHeaders.rangeHeader, range);
        return request.close();
      }

      final partial = await fetch(range: 'bytes=1-2');
      expect(partial.statusCode, HttpStatus.partialContent);
      expect(
        await partial.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
        [2, 3],
      );
      expect(partial.headers.contentType?.mimeType, 'image/png');
      expect(partial.headers.value('x-content-type-options'), 'nosniff');
      expect(
        partial.headers.value(HttpHeaders.cacheControlHeader),
        'private, no-store',
      );

      final unauthenticated = await fetch(authenticated: false);
      expect(unauthenticated.statusCode, HttpStatus.unauthorized);
      await unauthenticated.drain<void>();
      final invalidRange = await fetch(range: 'bytes=99-100');
      expect(invalidRange.statusCode, HttpStatus.requestedRangeNotSatisfiable);
      expect(
        await invalidRange.fold<int>(0, (count, chunk) => count + chunk.length),
        0,
      );

      final wrongDevice = await fetch(deviceId: 'hardware-2');
      expect(wrongDevice.statusCode, HttpStatus.forbidden);
      await wrongDevice.drain<void>();
      final wrongSession = await fetch(sessionId: 'session-2');
      expect(wrongSession.statusCode, HttpStatus.notFound);
      await wrongSession.drain<void>();

      mediaMessages[1] = Message(
        role: MessageRole.tool,
        content: 'Image Size: 2x1. MIME: image/png. Detail: auto.',
        toolCallId: 'call-view-1',
        toolResult: ToolExecutionResult(
          blocks: [
            ToolTextBlock(
              text: 'Image Size: 2x1. MIME: image/png. Detail: auto.',
            ),
          ],
        ),
      );
      final expired = await fetch();
      expect(expired.statusCode, HttpStatus.notFound);
      expect(
        await expired.fold<int>(0, (count, chunk) => count + chunk.length),
        0,
      );
    },
  );

  test(
    'user attachments are binary-free publicly and exact-scope retrieval revalidates bytes',
    () async {
      final directory = await Directory.systemTemp.createTemp(
        'sanad-attachment-relay-',
      );
      addTearDown(() => directory.delete(recursive: true));
      final file = File('${directory.path}/private-name.png');
      await file.writeAsBytes(const [5, 6, 7]);
      mediaMessages[2] = _attachmentMediaMessage(file.path);

      final liveEvent = AgentToCanonical.translate(
        GatewayResponse(sessionId: 'session-1', message: mediaMessages[2]),
      );
      final attachments = liveEvent.payload['attachments'] as List<dynamic>;
      expect(attachments, hasLength(1));
      expect(attachments.single, {
        'schemaVersion': 1,
        'id': 'attachment-1',
        'safeName': 'photo.png',
        'mimeType': 'image/png',
        'sizeBytes': 3,
        'sha256': sha256.convert(const [5, 6, 7]).toString(),
        'kind': 'image',
        'mediaId': 'attachment-media-1',
        'status': 'available',
      });
      expect(jsonEncode(liveEvent.toJson()), isNot(contains(directory.path)));
      expect(
        jsonEncode(liveEvent.toJson()),
        isNot(contains('agentLocalReference')),
      );

      Future<HttpClientResponse> fetch({
        String sessionId = 'session-1',
        String deviceId = 'hardware-1',
        bool authenticated = true,
      }) async {
        final client = HttpClient();
        addTearDown(() => client.close(force: true));
        final uri =
            Uri.parse(
              'http://127.0.0.1:$port/media/attachment/attachment-media-1',
            ).replace(
              queryParameters: {'session_id': sessionId, 'device_id': deviceId},
            );
        final request = await client.getUrl(uri);
        if (authenticated) {
          request.headers.set(LocalGatewayCredentials.headerName, token.value);
        }
        return request.close();
      }

      final response = await fetch();
      expect(response.statusCode, HttpStatus.ok);
      expect(
        await response.fold<List<int>>([], (all, chunk) => all..addAll(chunk)),
        [5, 6, 7],
      );
      expect(response.headers.contentType?.mimeType, 'image/png');
      expect(response.headers.value('x-content-type-options'), 'nosniff');
      expect(
        response.headers.value(HttpHeaders.cacheControlHeader),
        'private, no-store',
      );
      expect(
        response.headers.value('content-disposition'),
        'inline; filename="attachment.png"',
      );

      final unauthenticated = await fetch(authenticated: false);
      expect(unauthenticated.statusCode, HttpStatus.unauthorized);
      await unauthenticated.drain<void>();
      final wrongDevice = await fetch(deviceId: 'hardware-2');
      expect(wrongDevice.statusCode, HttpStatus.forbidden);
      await wrongDevice.drain<void>();
      final wrongSession = await fetch(sessionId: 'session-2');
      expect(wrongSession.statusCode, HttpStatus.notFound);
      await wrongSession.drain<void>();

      await file.writeAsBytes(const [5, 6, 8]);
      final tampered = await fetch();
      expect(tampered.statusCode, HttpStatus.notFound);
      expect(
        await tampered.fold<int>(0, (count, chunk) => count + chunk.length),
        0,
      );
    },
  );

  test(
    'attached payload is cloned into a distinct replay admission without Client bytes',
    () async {
      final home = await Directory.systemTemp.createTemp('sanad-replay-clone-');
      final state = AgentStateDatabase.inMemory();
      addTearDown(() async {
        state.dispose();
        await home.delete(recursive: true);
      });
      _insertAttachmentTestSession(state, 'clone-session');
      final store = AttachmentStore(state, stateHome: home.path);
      await store.initialize();
      final bytes = const [9, 8, 7];
      final upload = await store.create(
        fileName: 'private-note.txt',
        expectedSize: bytes.length,
        expectedSha256: sha256.convert(bytes).toString(),
      );
      await store.write(upload, bytes);
      final original = await store.commit(
        upload,
        sessionId: 'clone-session',
        admissionId: 'original-request',
      );
      _claimAttachment(
        store,
        sessionId: 'clone-session',
        admissionId: 'original-request',
        messageId: 'original-message',
        attachmentId: original.id,
      );

      final cloned = await store.cloneAttachedForAdmission(
        sessionId: 'clone-session',
        attachmentId: original.id,
        admissionId: 'replay-request',
      );
      expect(cloned.id, isNot(original.id));
      expect(cloned.mediaId, isNot(original.mediaId));
      expect(cloned.safeName, original.safeName);
      expect(cloned.sha256, original.sha256);
      _claimAttachment(
        store,
        sessionId: 'clone-session',
        admissionId: 'replay-request',
        messageId: 'replay-message',
        attachmentId: cloned.id,
      );
      final paths = await store.resolveAttachedPaths('clone-session');
      expect(paths, hasLength(2));
      expect(paths.toSet(), hasLength(2));
      expect(await File(paths[0]).readAsBytes(), bytes);
      expect(await File(paths[1]).readAsBytes(), bytes);

      final disposable = await store.cloneAttachedForAdmission(
        sessionId: 'clone-session',
        attachmentId: original.id,
        admissionId: 'failed-replay-request',
      );
      final disposableRow = state.db.select(
        'SELECT relative_path FROM user_attachments WHERE attachment_id = ?',
        [disposable.id],
      ).single;
      final disposableFile = File(
        p.join(
          home.path,
          'attachments',
          disposableRow['relative_path'] as String,
        ),
      );
      expect(await disposableFile.exists(), isTrue);
      await store.discardAdmission(
        sessionId: 'clone-session',
        admissionId: 'failed-replay-request',
      );
      expect(
        state.db.select(
          'SELECT 1 FROM user_attachments WHERE attachment_id = ?',
          [disposable.id],
        ),
        isEmpty,
      );
      expect(await disposableFile.exists(), isFalse);
    },
  );

  test('HTTP accepts a valid credential and loopback Host', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    expect(response.statusCode, HttpStatus.ok);
    expect(body['status'], 'ok');
  });

  test('co-located auth endpoint returns status without credentials', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/coupling'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    final response = await request.close();
    final bodyText = await response.transform(utf8.decoder).join();
    final body = jsonDecode(bodyText) as Map<String, dynamic>;

    expect(response.statusCode, HttpStatus.ok);
    expect(body, {'status': 'already_authorized'});
    expect(bodyText, isNot(contains('vault-only-device-credential')));
    expect(bodyText, isNot(contains('access_token')));
    expect(bodyText, isNot(contains('device_credential')));
  });

  test(
    'co-located auth endpoint accepts credential-free cancellation',
    () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.deleteUrl(
        Uri.parse('http://127.0.0.1:$port/auth/coupling'),
      );
      request.headers.set(LocalGatewayCredentials.headerName, token.value);
      final response = await request.close();
      final bodyText = await response.transform(utf8.decoder).join();

      expect(response.statusCode, HttpStatus.ok);
      expect(jsonDecode(bodyText), {'status': 'cancelled'});
      expect(bodyText, isNot(contains('token')));
      expect(bodyText, isNot(contains('device_code')));
    },
  );

  test('co-located auth endpoint rejects query payloads', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/auth/coupling?token=forbidden'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    final response = await request.close();

    expect(response.statusCode, HttpStatus.badRequest);
  });

  test('co-located auth endpoint rejects request bodies', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/coupling'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    request.write(jsonEncode({'access_token': 'forbidden'}));
    final response = await request.close();

    expect(response.statusCode, HttpStatus.badRequest);
  });

  test(
    'authenticated POST logout invokes Agent logout and keeps Local Gateway',
    () async {
      final client = HttpClient();
      addTearDown(() => client.close(force: true));
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:$port/auth/logout'),
      );
      request.headers.set(LocalGatewayCredentials.headerName, token.value);
      final response = await request.close();
      final bodyText = await response.transform(utf8.decoder).join();

      expect(response.statusCode, HttpStatus.ok);
      expect(jsonDecode(bodyText), {'status': 'logged_out'});
      expect(authManager.logoutCalls, 1);
      expect(bodyText, isNot(contains('vault-only-device-credential')));
      expect(bodyText, isNot(contains('token')));

      final healthRequest = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/health'),
      );
      healthRequest.headers.set(
        LocalGatewayCredentials.headerName,
        token.value,
      );
      final healthResponse = await healthRequest.close();
      expect(healthResponse.statusCode, HttpStatus.ok);
    },
  );

  test('logout endpoint rejects GET, query, and body requests', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));

    final getRequest = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/auth/logout'),
    );
    getRequest.headers.set(LocalGatewayCredentials.headerName, token.value);
    expect((await getRequest.close()).statusCode, HttpStatus.badRequest);

    final queryRequest = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/logout?extra=forbidden'),
    );
    queryRequest.headers.set(LocalGatewayCredentials.headerName, token.value);
    expect((await queryRequest.close()).statusCode, HttpStatus.badRequest);

    final bodyRequest = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/logout'),
    );
    bodyRequest.headers.set(LocalGatewayCredentials.headerName, token.value);
    bodyRequest.write(jsonEncode({'extra': 'forbidden'}));
    expect((await bodyRequest.close()).statusCode, HttpStatus.badRequest);

    expect(authManager.logoutCalls, 0);
  });

  test('logout endpoint rejects unauthenticated callers', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/auth/logout'),
    );
    final response = await request.close();

    expect(response.statusCode, HttpStatus.unauthorized);
    expect(authManager.logoutCalls, 0);
  });

  test('HTTP rejects a loopback Host on the wrong port', () async {
    final client = HttpClient();
    addTearDown(() => client.close(force: true));
    final request = await client.getUrl(
      Uri.parse('http://127.0.0.1:$port/health'),
    );
    request.headers.set(LocalGatewayCredentials.headerName, token.value);
    request.headers.set(HttpHeaders.hostHeader, '127.0.0.1:${port + 1}');
    final response = await request.close();
    final body = jsonDecode(await response.transform(utf8.decoder).join());

    expect(response.statusCode, HttpStatus.forbidden);
    expect(body['reason'], 'host_not_allowed');
  });

  test('WebSocket handshake rejects missing credentials', () async {
    await expectLater(
      WebSocket.connect('ws://127.0.0.1:$port/ws'),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('WebSocket handshake rejects an unlisted Origin', () async {
    await expectLater(
      WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {
          LocalGatewayCredentials.headerName: token.value,
          'origin': 'http://localhost:3000',
        },
      ),
      throwsA(isA<WebSocketException>()),
    );
  });

  test('WebSocket handshake accepts valid native credentials', () async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
      headers: {LocalGatewayCredentials.headerName: token.value},
    );
    final firstFrame = jsonDecode(await socket.first as String);

    expect(firstFrame['type'], 'register_success');
    await socket.close();
  });

  test(
    'platform broadcast before the first command uses local inventory identity',
    () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {LocalGatewayCredentials.headerName: token.value},
      );
      final frames = StreamIterator<dynamic>(socket);
      expect(await frames.moveNext(), isTrue); // register_success

      await platform.sendResponse(
        GatewayResponse(
          sessionId: 'unbound-session',
          message: Message(role: MessageRole.assistant, content: 'ready'),
        ),
      );

      expect(await frames.moveNext(), isTrue);
      final event = jsonDecode(frames.current as String);
      expect(event['type'], 'device_event');
      expect(event['device_id'], 'hardware-1');

      await frames.cancel();
      await socket.close();
    },
  );

  test(
    'session response preserves explicit identity after unrelated command',
    () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {LocalGatewayCredentials.headerName: token.value},
      );
      final frames = StreamIterator<dynamic>(socket);
      expect(await frames.moveNext(), isTrue); // register_success

      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'test_identity_binding_only',
          'device_id': 'session-device',
          'hardware_id': 'session-hardware',
          'payload': {'session_id': 'session-a'},
        }),
      );
      socket.add(
        jsonEncode({
          'type': 'execute_command',
          'command': 'test_identity_binding_only',
          'device_id': 'unrelated-device',
          'hardware_id': 'unrelated-hardware',
          'payload': {'session_id': 'session-b'},
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      await platform.sendResponse(
        GatewayResponse(
          sessionId: 'session-a',
          eventId: 'session-identity-event',
          message: Message(role: MessageRole.assistant, content: 'ready'),
        ),
      );

      expect(await frames.moveNext(), isTrue);
      final event = jsonDecode(frames.current as String);
      expect(event['device_id'], 'session-device');
      expect(event['hardware_id'], 'session-hardware');
      await frames.cancel();
      await socket.close();
    },
  );

  test(
    'platform-family dispatch records every connected Local instance',
    () async {
      const instances = [
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222',
      ];
      final sockets = <WebSocket>[];
      final frames = <StreamIterator<dynamic>>[];
      for (final instanceId in instances) {
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:$port/ws',
          headers: {LocalGatewayCredentials.headerName: token.value},
        );
        sockets.add(socket);
        final iterator = StreamIterator<dynamic>(socket);
        frames.add(iterator);
        expect(await iterator.moveNext(), isTrue); // register_success
        socket.add(
          jsonEncode({
            'type': 'client.hello',
            'protocol': 'sanad.identity_presence',
            'version': 1,
            'client_instance_id': instanceId,
          }),
        );
        expect(await iterator.moveNext(), isTrue); // client.hello_ack
      }
      deliveryPresence.acceptInterest({
        'protocol': deliveryPresenceProtocol,
        'version': deliveryPresenceVersion,
        'type': 'cloud.delivery_interest',
        'revision': 1,
        'cloud_recipient_instances_complete': true,
        'cloud_recipient_instance_ids': [
          ...instances,
          '33333333-3333-4333-8333-333333333333',
        ],
        'lease_ms': 30000,
      });

      await platform.sendResponse(
        GatewayResponse(
          sessionId: 'multi-local',
          eventId: 'event-multi-local',
          message: Message(role: MessageRole.assistant, content: 'ready'),
        ),
      );

      for (final iterator in frames) {
        expect(await iterator.moveNext(), isTrue);
        expect(
          jsonDecode(iterator.current as String)['event_id'],
          'event-multi-local',
        );
      }
      expect(deliveryPresence.takeLocalDelivery('event-multi-local'), {
        ...instances,
      });
      for (final iterator in frames) {
        await iterator.cancel();
      }
      for (final socket in sockets) {
        await socket.close();
      }
    },
  );

  test('authenticated client hello binds a valid instance identity', () async {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
      headers: {LocalGatewayCredentials.headerName: token.value},
    );
    final frames = StreamIterator<dynamic>(socket);
    expect(await frames.moveNext(), isTrue); // register_success compatibility

    socket.add(
      jsonEncode({
        'type': 'client.hello',
        'protocol': 'sanad.identity_presence',
        'version': 1,
        'client_instance_id': '11111111-1111-4111-8111-111111111111',
        'metadata': {'platform_family': 'macos'},
      }),
    );
    expect(await frames.moveNext(), isTrue);
    final accepted = jsonDecode(frames.current as String);
    expect(accepted, {
      'type': 'client.hello_ack',
      'protocol': 'sanad.identity_presence',
      'version': 1,
    });
    expect(deliveryPresence.localInstanceIds, {
      '11111111-1111-4111-8111-111111111111',
    });
    deliveryPresence.acceptInterest({
      'protocol': deliveryPresenceProtocol,
      'version': deliveryPresenceVersion,
      'type': 'cloud.delivery_interest',
      'revision': 1,
      'cloud_recipient_instances_complete': true,
      'cloud_recipient_instance_ids': const [
        '11111111-1111-4111-8111-111111111111',
        '22222222-2222-4222-8222-222222222222',
      ],
      'lease_ms': 30000,
    });
    await platform.sendResponse(
      GatewayResponse(
        sessionId: 'session-1',
        eventId: 'event-1',
        message: Message(role: MessageRole.assistant, content: 'ready'),
      ),
    );
    expect(await frames.moveNext(), isTrue);
    expect(jsonDecode(frames.current as String)['event_id'], 'event-1');
    expect(deliveryPresence.takeLocalDelivery('event-1'), {
      '11111111-1111-4111-8111-111111111111',
    });

    socket.add(
      jsonEncode({
        'type': 'client.hello',
        'protocol': 'sanad.identity_presence',
        'version': 1,
        'client_instance_id': 'device-or-sid-substitution',
      }),
    );
    expect(await frames.moveNext(), isTrue);
    final rejected = jsonDecode(frames.current as String);
    expect(rejected['code'], 'INVALID_CLIENT_INSTANCE');

    await frames.cancel();
    await socket.close();
    await Future<void>.delayed(Duration.zero);
    expect(deliveryPresence.localInstanceIds, isEmpty);
  });

  test(
    'authentication exchange reloads file state without returning credentials',
    () async {
      final socket = await WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {LocalGatewayCredentials.headerName: token.value},
      );
      final frames = StreamIterator<dynamic>(socket);
      expect(await frames.moveNext(), isTrue); // register_success

      socket.add(
        jsonEncode({
          'type': 'authentication_exchange',
          'access_token': 'must-not-be-trusted-or-returned',
        }),
      );
      await Future<void>.delayed(const Duration(milliseconds: 10));
      expect(authManager.reloadCalls, 0);

      socket.add(jsonEncode({'type': 'authentication_exchange'}));
      expect(await frames.moveNext(), isTrue);
      final exchange = jsonDecode(frames.current as String);
      expect(exchange, {'type': 'authentication_exchange'});
      expect(authManager.reloadCalls, 1);

      await frames.cancel();
      await socket.close();
    },
  );

  test(
    'WebSocket transport rejects excess simultaneous pre-auth work',
    () async {
      final entered = Completer<void>();
      final release = Completer<void>();
      upgradeHook = () async {
        if (!entered.isCompleted) entered.complete();
        await release.future;
      };
      final first = WebSocket.connect(
        'ws://127.0.0.1:$port/ws',
        headers: {LocalGatewayCredentials.headerName: token.value},
      );
      await entered.future;

      await expectLater(
        WebSocket.connect(
          'ws://127.0.0.1:$port/ws',
          headers: {LocalGatewayCredentials.headerName: token.value},
        ),
        throwsA(isA<WebSocketException>()),
      );

      release.complete();
      final socket = await first;
      await socket.close();
    },
  );
}

Message _attachmentMediaMessage(String path) => Message(
  role: MessageRole.user,
  content: 'See attached',
  attachments: [
    UserAttachment(
      id: 'attachment-1',
      safeName: 'photo.png',
      mimeType: 'image/png',
      sizeBytes: 3,
      sha256: sha256.convert(const [5, 6, 7]).toString(),
      kind: UserAttachmentKind.image,
      agentLocalReference: path,
      mediaId: 'attachment-media-1',
    ),
  ],
);

void _insertAttachmentTestSession(AgentStateDatabase state, String sessionId) {
  final now = DateTime.now().toUtc().toIso8601String();
  state.db.execute(
    '''
    INSERT INTO sessions (session_id, model, created_at, updated_at)
    VALUES (?, 'test-model', ?, ?)
    ''',
    [sessionId, now, now],
  );
  for (final messageId in ['original-message', 'replay-message']) {
    state.db.execute(
      '''
      INSERT INTO messages (session_id, data, message_id)
      VALUES (?, '{"role":"user","content":"attachment test","attachments":[]}', ?)
      ''',
      [sessionId, messageId],
    );
  }
}

void _claimAttachment(
  AttachmentStore store, {
  required String sessionId,
  required String admissionId,
  required String messageId,
  required String attachmentId,
}) {
  store.claimAdmissionAndPersist(
    sessionId: sessionId,
    admissionId: admissionId,
    attachmentIds: [attachmentId],
    persist: (_, attachments) {
      final message = Message(
        role: MessageRole.user,
        content: 'attachment test',
        attachments: attachments,
        metadata: {
          'request_id': admissionId,
          'message_id': messageId,
          'turn_id': 'turn-$messageId',
        },
      );
      return [message];
    },
  );
}
