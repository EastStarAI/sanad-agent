import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/platform_session_channel.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;
import 'package:socket_io_client/src/manager.dart';
import 'package:test/test.dart';

import '../support/memory_agent_secret_store.dart';

const blockedWorkspaceCommands = <String>[
  CanonicalEventTypes.createWorkspace,
  CanonicalEventTypes.relocateWorkspace,
  CanonicalEventTypes.browseWorkspaceTree,
  CanonicalEventTypes.createFolder,
  CanonicalEventTypes.renameFolder,
  CanonicalEventTypes.deleteFolder,
];

const blockedMcpManagementCommands = <String>[
  CanonicalEventTypes.listMcpServers,
  CanonicalEventTypes.saveMcpServer,
  CanonicalEventTypes.deleteMcpServer,
  CanonicalEventTypes.replaceMcpConfig,
  CanonicalEventTypes.inspectMcpServer,
  CanonicalEventTypes.previewMcpImport,
  CanonicalEventTypes.exportMcpServers,
  CanonicalEventTypes.readAdvancedMcpServer,
  CanonicalEventTypes.previewAdvancedMcpServer,
  CanonicalEventTypes.saveAdvancedMcpServer,
  CanonicalEventTypes.startMcpOAuth,
  CanonicalEventTypes.getMcpOAuthStatus,
  CanonicalEventTypes.cancelMcpOAuth,
  CanonicalEventTypes.completeMcpOAuth,
];

class FakeManager implements Manager {
  @override
  Function() on(String event, Function fn) => () {};

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeSocket implements socket_io.Socket {
  final Map<String, List<Function>> listeners = {};
  final List<Map<String, dynamic>> emittedEvents = [];
  bool isConnected = false;

  @override
  Function() on(String event, Function fn) {
    listeners.putIfAbsent(event, () => []).add(fn);
    return () {};
  }

  @override
  socket_io.Socket emit(String event, [dynamic data]) {
    emittedEvents.add({'event': event, 'data': data});
    return this;
  }

  @override
  socket_io.Socket connect() {
    isConnected = true;
    unawaitedTrigger('connect', null);
    return this;
  }

  Future<void> trigger(String event, dynamic data) async {
    for (final callback in listeners[event] ?? const <Function>[]) {
      final result = callback(data);
      if (result is Future) {
        await result;
      }
    }
  }

  void unawaitedTrigger(String event, dynamic data) {
    for (final callback in listeners[event] ?? const <Function>[]) {
      callback(data);
    }
  }

  @override
  bool get connected => isConnected;

  @override
  socket_io.Socket disconnect() {
    isConnected = false;
    return this;
  }

  @override
  Manager get io => FakeManager();

  @override
  void dispose() {
    listeners.clear();
    isConnected = false;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class FakeAuthManager extends AuthManager {
  final _controller = StreamController<void>.broadcast();
  bool authenticated = true;
  bool cloudAuthorized = true;
  int refreshAttempts = 0;
  String? token;
  String? pairing;
  String? pending;

  @override
  Stream<void> get changes => _controller.stream;

  @override
  String? get deviceToken => token;

  @override
  String? get pairingToken => pairing;

  @override
  String? get pendingDeviceToken => pending;

  @override
  bool get hasPendingDevicePairing => pairing != null && pending != null;

  @override
  bool get isAuthenticated => authenticated;

  @override
  bool get canAuthenticateCloudAgent => cloudAuthorized;

  @override
  String get hardwareId => 'test-device-id';

  @override
  Future<bool> reload({bool notifyIfChanged = false}) async => false;

  @override
  Future<bool> refreshAccessToken(String portalUrl) async {
    refreshAttempts += 1;
    return true;
  }

  void setCloudAuthorized(bool value) {
    cloudAuthorized = value;
    _controller.add(null);
  }

  Future<void> close() => _controller.close();
}

class TrackingPlatformRuntimeBridge extends PlatformRuntimeBridge {
  int registeredSessionCount = 0;

  @override
  void registerSessionClient(
    String sessionId,
    PlatformSessionChannel channel, {
    String? deviceId,
  }) {
    registeredSessionCount += 1;
    super.registerSessionClient(sessionId, channel, deviceId: deviceId);
  }
}

class TrackingWorkspaceRuntimeService extends LocalWorkspaceRuntimeService {
  TrackingWorkspaceRuntimeService({required super.sanadHomePath});

  final List<String> calls = [];

  @override
  Future<List<Map<String, dynamic>>> listWorkspaces() async {
    calls.add(CanonicalEventTypes.listWorkspaces);
    return const [];
  }

  @override
  Future<Map<String, dynamic>> createWorkspace({
    String? name,
    String? path,
  }) async {
    calls.add(CanonicalEventTypes.createWorkspace);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> relocateWorkspace({
    required String workspaceId,
    required String newPath,
  }) async {
    calls.add(CanonicalEventTypes.relocateWorkspace);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> browseWorkspaceTree({
    String? workspaceId,
    String? path,
    int maxEntries = 200,
  }) async {
    calls.add(CanonicalEventTypes.browseWorkspaceTree);
    return const {};
  }

  @override
  Future<String> createFolder({
    required String parentPath,
    required String name,
  }) async {
    calls.add(CanonicalEventTypes.createFolder);
    return parentPath;
  }

  @override
  Future<String> renameFolder({
    required String path,
    required String newName,
  }) async {
    calls.add(CanonicalEventTypes.renameFolder);
    return path;
  }

  @override
  Future<String> deleteFolder(String path) async {
    calls.add(CanonicalEventTypes.deleteFolder);
    return path;
  }

  @override
  Future<Map<String, dynamic>> readMcpSnapshot({String? workspaceId}) async {
    calls.add(CanonicalEventTypes.listMcpServers);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> saveMcpServer({
    required String scope,
    String? workspaceId,
    required Map<String, dynamic> config,
  }) async {
    calls.add(CanonicalEventTypes.saveMcpServer);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> deleteMcpServer({
    required String scope,
    String? workspaceId,
    required String serverName,
  }) async {
    calls.add(CanonicalEventTypes.deleteMcpServer);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> replaceMcpConfig({
    required String scope,
    String? workspaceId,
    required Map<String, dynamic> document,
  }) async {
    calls.add(CanonicalEventTypes.replaceMcpConfig);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> inspectMcpServer({
    required String serverName,
    String scope = 'effective',
    String? workspaceId,
  }) async {
    calls.add(CanonicalEventTypes.inspectMcpServer);
    return const {};
  }
}

Map<String, dynamic> _proofPayload(String proof) {
  final encoded = proof.split('.')[1];
  return jsonDecode(utf8.decode(base64Url.decode(base64Url.normalize(encoded))))
      as Map<String, dynamic>;
}

void main() {
  final getIt = GetIt.instance;
  late Directory tempDir;
  late FakeSocket socket;
  late FakeAuthManager authManager;
  late TrackingPlatformRuntimeBridge runtimeBridge;
  late TrackingWorkspaceRuntimeService workspaceRuntime;
  late ServerSanadGatewayPlatform platform;
  late MemoryAgentSecretStore secrets;

  setUp(() async {
    getIt.allowReassignment = true;
    tempDir = await Directory.systemTemp.createTemp('sanad-platform-test');
    setSanadHomeOverride(tempDir.path);
    socket = FakeSocket();
    secrets = MemoryAgentSecretStore();
    runtimeBridge = TrackingPlatformRuntimeBridge();
    workspaceRuntime = TrackingWorkspaceRuntimeService(
      sanadHomePath: tempDir.path,
    );

    authManager = FakeAuthManager();
    getIt.registerSingleton<AuthManager>(authManager);
    getIt.registerSingleton<Config>(Config());
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
    getIt.registerSingleton<PlatformRuntimeBridge>(runtimeBridge);
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspaceRuntime);

    platform = ServerSanadGatewayPlatform(
      socketFactory: (_, _) => socket,
      identityLoader: () =>
          DeviceKeyIdentity.loadOrCreate(secretStore: secrets),
      httpClient: MockClient(
        (_) async => http.Response('', 200, headers: {
          'date': HttpDate.format(DateTime.now().toUtc()),
        }),
      ),
    );
    await platform.initialize();
    await socket.trigger('register_success', {'device_id': 'test-device-id'});
    socket.emittedEvents.clear();
  });

  tearDown(() async {
    await platform.dispose();
    await authManager.close();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
    await getIt.reset();
  });

  test(
    'User session alone does not keep the Agent cloud transport online',
    () async {
      expect(platform.socket, same(socket));
      expect(socket.connected, isTrue);
      expect(authManager.isAuthenticated, isTrue);

      authManager.setCloudAuthorized(false);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(authManager.isAuthenticated, isTrue);
      expect(platform.socket, isNull);
      expect(socket.connected, isFalse);

      authManager.setCloudAuthorized(true);
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(platform.socket, same(socket));
      expect(socket.connected, isTrue);
    },
  );

  test('invalid Agent credential never refreshes the User session', () async {
    socket.emittedEvents.clear();

    await socket.trigger('register_failed', {
      'error': 'Invalid or missing agent token',
      'code': 'AUTH_INVALID_TOKEN',
    });

    expect(authManager.refreshAttempts, 0);
    expect(socket.emittedEvents, isEmpty);
  });

  test(
    'key-bound registration requires and signs a Gateway challenge',
    () async {
      authManager.token = 'sanad_device_synthetic-credential';
      socket.emittedEvents.clear();

      await socket.trigger('connect', null);

      expect(socket.emittedEvents, [
        {'event': 'request_device_challenge', 'data': null},
      ]);

      socket.emittedEvents.clear();
      await socket.trigger('device_challenge', {'nonce': 'gateway-nonce-1'});

      final registration = socket.emittedEvents.singleWhere(
        (event) =>
            event['event'] == 'register_device' &&
            event['data'] is Map &&
            (event['data'] as Map).containsKey('device_proof'),
      );

      final payload = Map<String, dynamic>.from(registration['data'] as Map);
      expect(payload['device_token'], 'sanad_device_synthetic-credential');
      expect(payload, isNot(contains('pairing_token')));
      expect(payload, isNot(contains('proposed_device_token')));
      final proof = payload['device_proof'] as String;
      final claims = _proofPayload(proof);
      expect(claims['htm'], 'SOCKET');
      expect(claims['htu'], 'sanad-gateway:register_device');
      expect(claims['nonce'], 'gateway-nonce-1');
      expect(claims['jti'], isNotEmpty);
      expect(payload.toString(), isNot(contains('private_key')));
    },
  );

  test(
    'pairing registration is challenged and carries the same public key proof',
    () async {
      authManager.pairing = 'synthetic-pairing-token';
      authManager.pending = 'sanad_synthetic-pending-credential';
      socket.emittedEvents.clear();

      await socket.trigger('connect', null);
      expect(socket.emittedEvents, [
        {'event': 'request_device_challenge', 'data': null},
      ]);

      socket.emittedEvents.clear();
      await socket.trigger('device_challenge', {'nonce': 'pairing-nonce-1'});

      final registration = socket.emittedEvents.singleWhere(
        (event) =>
            event['event'] == 'register_device' &&
            event['data'] is Map &&
            (event['data'] as Map)['pairing_token'] ==
                'synthetic-pairing-token',
      );
      final payload = Map<String, dynamic>.from(registration['data'] as Map);
      expect(payload['pairing_token'], 'synthetic-pairing-token');
      expect(
        payload['proposed_device_token'],
        'sanad_synthetic-pending-credential',
      );
      expect(payload['public_jwk'], isA<Map>());
      final proof = payload['device_proof'] as String;
      final claims = _proofPayload(proof);
      expect(claims['nonce'], 'pairing-nonce-1');
      expect(claims['htu'], 'sanad-gateway:register_device');
      expect(payload.toString(), isNot(contains('private_key')));
    },
  );

  test('blocks authentication exchange on both cloud envelope paths', () async {
    await socket.trigger('execute_command', {
      'command': 'authentication_exchange',
      'payload': {'session_id': 'auth-session'},
    });
    await socket.trigger('protocol_event', {
      'type': 'authentication_exchange',
      'payload': <String, dynamic>{},
      'session_id': 'auth-session',
    });

    expect(runtimeBridge.registeredSessionCount, 0);
    expect(socket.emittedEvents, isEmpty);
  });

  group('cloud remote workspace admission', () {
    test(
      'rejects every execute_command before session or runtime mutation',
      () async {
        for (final command in blockedWorkspaceCommands) {
          socket.emittedEvents.clear();

          await socket.trigger('execute_command', {
            'command': command,
            'device_id': 'request-device',
            'payload': {
              'request_id': 'req-$command',
              'session_id': 'sess-123',
              'workspace_id': 'workspace-1',
              'path': tempDir.path,
              'new_path': tempDir.path,
              'parent_path': tempDir.path,
              'name': 'blocked-folder',
              'new_name': 'blocked-folder',
            },
          });

          _expectDisabledError(
            socket.emittedEvents,
            requestId: 'req-$command',
            code: 'remote_workspace_management_disabled',
          );
        }

        expect(runtimeBridge.registeredSessionCount, 0);
        expect(workspaceRuntime.calls, isEmpty);
        expect(
          Directory('${tempDir.path}/blocked-folder').existsSync(),
          isFalse,
        );
      },
    );

    test(
      'rejects every protocol_event before workspace runtime mutation',
      () async {
        for (final eventType in blockedWorkspaceCommands) {
          socket.emittedEvents.clear();

          await socket.trigger('protocol_event', {
            'event': eventType,
            'type': eventType,
            'session_id': 'sess-123',
            'payload': {
              'request_id': 'req-$eventType',
              'path': tempDir.path,
              'parent_path': tempDir.path,
              'name': 'blocked-folder',
            },
          });

          _expectDisabledError(
            socket.emittedEvents,
            requestId: 'req-$eventType',
            code: 'remote_workspace_management_disabled',
          );
        }

        expect(workspaceRuntime.calls, isEmpty);
        expect(
          Directory('${tempDir.path}/blocked-folder').existsSync(),
          isFalse,
        );
      },
    );

    test('allows list_workspaces through the cloud adapter', () async {
      await socket.trigger('execute_command', {
        'command': CanonicalEventTypes.listWorkspaces,
        'payload': {'request_id': 'req-list', 'session_id': 'sess-list'},
      });

      expect(workspaceRuntime.calls, [CanonicalEventTypes.listWorkspaces]);
      expect(runtimeBridge.registeredSessionCount, 1);
      final response = socket.emittedEvents.singleWhere(
        (item) => item['event'] == 'device_event',
      );
      final data = response['data'] as Map<String, dynamic>;
      expect(data['event'], CanonicalEventTypes.workspacesList);
      expect(data['payload'], containsPair('request_id', 'req-list'));
    });
  });

  group('cloud remote MCP management admission', () {
    test(
      'rejects every execute_command before session or MCP runtime access',
      () async {
        for (final command in blockedMcpManagementCommands) {
          socket.emittedEvents.clear();

          await socket.trigger('execute_command', {
            'command': command,
            'device_id': 'request-device',
            'payload': {
              'request_id': 'req-$command',
              'session_id': 'sess-123',
              'workspace_id': 'workspace-1',
              'scope': 'global',
              'server_name': 'blocked-server',
              'config': <String, dynamic>{},
              'document': <String, dynamic>{},
            },
          });

          _expectDisabledError(
            socket.emittedEvents,
            requestId: 'req-$command',
            code: 'remote_mcp_management_disabled',
          );
        }

        expect(runtimeBridge.registeredSessionCount, 0);
        expect(workspaceRuntime.calls, isEmpty);
      },
    );

    test('rejects every protocol_event before MCP runtime access', () async {
      for (final eventType in blockedMcpManagementCommands) {
        socket.emittedEvents.clear();

        await socket.trigger('protocol_event', {
          'event': eventType,
          'type': eventType,
          'session_id': 'sess-123',
          'payload': {
            'request_id': 'req-$eventType',
            'scope': 'global',
            'server_name': 'blocked-server',
            'config': <String, dynamic>{},
            'document': <String, dynamic>{},
          },
        });

        _expectDisabledError(
          socket.emittedEvents,
          requestId: 'req-$eventType',
          code: 'remote_mcp_management_disabled',
        );
      }

      expect(workspaceRuntime.calls, isEmpty);
    });
  });
}

void _expectDisabledError(
  List<Map<String, dynamic>> emittedEvents, {
  required String requestId,
  required String code,
}) {
  expect(emittedEvents, hasLength(1));
  final emitted = emittedEvents.single;
  expect(emitted['event'], 'device_event');
  final data = emitted['data'] as Map<String, dynamic>;
  expect(data['type'], 'event');
  expect(data['event'], 'error');
  expect(data['session_id'], 'sess-123');
  final payload = data['payload'] as Map<String, dynamic>;
  expect(payload['request_id'], requestId);
  expect(payload['code'], code);
}
