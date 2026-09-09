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
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_agent/interfaces/models/device_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/device_control_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/platform_session_channel.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;
import 'package:socket_io_client/src/manager.dart';
import 'package:test/test.dart';

import '../support/memory_agent_secret_store.dart';

const blockedMcpReplaceCommands = <String>[
  CanonicalEventTypes.replaceMcpConfig,
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
  bool? lastManagedRemote;

  @override
  Future<List<Map<String, dynamic>>> listWorkspaces() async {
    calls.add(CanonicalEventTypes.listWorkspaces);
    return const [];
  }

  @override
  Future<Map<String, dynamic>> createWorkspace({
    String? name,
    String? path,
    String? description,
    bool managedRemote = false,
  }) async {
    lastManagedRemote = managedRemote;
    calls.add(CanonicalEventTypes.createWorkspace);
    return {
      'id': 'ws-1',
      'name': name ?? 'workspace',
      'display_name': name ?? 'workspace',
      'path': '/managed/workspaces/${name ?? 'workspace'}',
      'source': 'managed_remote',
      'is_current': false,
      'is_missing': false,
      'availability': 'available',
    };
  }

  @override
  Future<String> removeWorkspace({
    required String workspaceId,
    bool managedRemote = false,
  }) async {
    lastManagedRemote = managedRemote;
    calls.add(CanonicalEventTypes.removeWorkspace);
    return workspaceId;
  }

  @override
  Future<Map<String, dynamic>> relocateWorkspace({
    required String workspaceId,
    required String newPath,
    bool managedRemote = false,
    String? expectedFingerprint,
  }) async {
    lastManagedRemote = managedRemote;
    calls.add(CanonicalEventTypes.relocateWorkspace);
    return const {};
  }

  @override
  Future<Map<String, dynamic>> browseWorkspaceTree({
    String? workspaceId,
    String? path,
    int maxEntries = 200,
    bool managedRemote = false,
  }) async {
    lastManagedRemote = managedRemote;
    calls.add(CanonicalEventTypes.browseWorkspaceTree);
    return {
      'workspace_id': '',
      'root_path': '',
      'path': '',
      'parent_path': null,
      'entries': const [],
      'truncated': false,
    };
  }

  @override
  Future<String> createFolder({
    required String parentPath,
    required String name,
    bool managedRemote = false,
  }) async {
    lastManagedRemote = managedRemote;
    calls.add(CanonicalEventTypes.createFolder);
    return parentPath;
  }

  @override
  Future<String> renameFolder({
    required String path,
    required String newName,
    bool managedRemote = false,
  }) async {
    lastManagedRemote = managedRemote;
    calls.add(CanonicalEventTypes.renameFolder);
    return path;
  }

  @override
  Future<String> deleteFolder(
    String path, {
    bool managedRemote = false,
    String? expectedFingerprint,
  }) async {
    lastManagedRemote = managedRemote;
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
    getIt.registerSingleton<DeviceCommandAdmission>(
      DeviceCommandAdmission(registeredDeviceId: () => 'test-device-id'),
    );
    getIt.registerSingleton<DaemonRestartCoordinator>(
      DaemonRestartCoordinator(exitDaemon: (_) {}),
    );
    final bridge = SanadProtocolBridge();
    getIt.registerSingleton<SanadProtocolBridge>(bridge);
    getIt.registerSingleton<DeviceControlCommandHandler>(
      DeviceControlCommandHandler(
        admission: getIt<DeviceCommandAdmission>(),
        bridge: bridge,
        restartCoordinator: getIt<DaemonRestartCoordinator>(),
        updateService: () => _ScriptedUpdateService(
          checkResult: const AgentUpdateResult(
            status: AgentUpdateStatus.upToDate,
            currentVersion: '1.0.0',
            availableVersion: '1.0.0',
          ),
          applyResult: const AgentUpdateResult(
            status: AgentUpdateStatus.upToDate,
            currentVersion: '1.0.0',
          ),
        ),
        isSupervised: () => true,
      ),
    );
    getIt.registerSingleton<PlatformRuntimeBridge>(runtimeBridge);
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspaceRuntime);

    platform = ServerSanadGatewayPlatform(
      socketFactory: (_, _) => socket,
      identityLoader: () =>
          DeviceKeyIdentity.loadOrCreate(secretStore: secrets),
      httpClient: MockClient(
        (_) async => http.Response(
          '',
          200,
          headers: {'date': HttpDate.format(DateTime.now().toUtc())},
        ),
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

  group('cloud managed workspace admission', () {
    test(
      'dispatches create_workspace as managed remote without a session',
      () async {
        await socket.trigger('execute_command', {
          'command': CanonicalEventTypes.createWorkspace,
          'device_id': 'test-device-id',
          'payload': {
            'request_id': 'req-create',
            'session_id': 'sess-123',
            'name': 'remote-notes',
            'path': '/etc/passwd',
          },
        });

        expect(workspaceRuntime.calls, [CanonicalEventTypes.createWorkspace]);
        expect(workspaceRuntime.lastManagedRemote, isTrue);
        expect(runtimeBridge.registeredSessionCount, 0);
        expect(socket.emittedEvents, isNotEmpty);
        final data =
            socket.emittedEvents.single['data'] as Map<String, dynamic>;
        expect(data['event'], CanonicalEventTypes.workspaceCreated);
      },
    );

    test(
      'dispatches empty browse as managed remote without listing through session',
      () async {
        await socket.trigger('execute_command', {
          'command': CanonicalEventTypes.browseWorkspaceTree,
          'device_id': 'test-device-id',
          'payload': {'request_id': 'req-browse', 'session_id': 'sess-123'},
        });

        expect(workspaceRuntime.calls, [
          CanonicalEventTypes.browseWorkspaceTree,
        ]);
        expect(workspaceRuntime.lastManagedRemote, isTrue);
        expect(runtimeBridge.registeredSessionCount, 0);
      },
    );

    test('dispatches workspace record removal as managed remote', () async {
      await socket.trigger('execute_command', {
        'command': CanonicalEventTypes.removeWorkspace,
        'device_id': 'test-device-id',
        'payload': {
          'request_id': 'req-remove-workspace',
          'session_id': 'sess-123',
          'workspace_id': 'ws-1',
        },
      });

      expect(workspaceRuntime.calls, [CanonicalEventTypes.removeWorkspace]);
      expect(workspaceRuntime.lastManagedRemote, isTrue);
      expect(runtimeBridge.registeredSessionCount, 0);
      final data = socket.emittedEvents.single['data'] as Map<String, dynamic>;
      expect(data['event'], CanonicalEventTypes.workspaceRemoved);
      expect((data['payload'] as Map)['workspace_id'], 'ws-1');
    });

    test('rejects a mismatched workspace command as wrong_device', () async {
      await socket.trigger('execute_command', {
        'command': CanonicalEventTypes.createWorkspace,
        'device_id': 'other-device',
        'payload': {
          'request_id': 'req-create-wrong',
          'session_id': 'sess-123',
          'name': 'blocked',
        },
      });
      _expectDisabledError(
        socket.emittedEvents,
        requestId: 'req-create-wrong',
        code: DeviceControlErrorCodes.wrongDevice,
      );
      expect(workspaceRuntime.calls, isEmpty);
      expect(runtimeBridge.registeredSessionCount, 0);
    });

    test('rejects a workspace command without device_id', () async {
      await socket.trigger('execute_command', {
        'command': CanonicalEventTypes.createWorkspace,
        'payload': {
          'request_id': 'req-create-missing-device',
          'session_id': 'sess-123',
          'name': 'blocked',
        },
      });
      expect(socket.emittedEvents, hasLength(1));
      final data = socket.emittedEvents.single['data'] as Map<String, dynamic>;
      final payload = data['payload'] as Map<String, dynamic>;
      expect(data['event'], 'error');
      expect(payload['request_id'], 'req-create-missing-device');
      expect(payload['code'], DeviceControlErrorCodes.invalidRequest);
      expect(workspaceRuntime.calls, isEmpty);
      expect(runtimeBridge.registeredSessionCount, 0);
    });

    test(
      'dispatches protocol_event workspace browse without session registration',
      () async {
        await socket.trigger('protocol_event', {
          'event': CanonicalEventTypes.browseWorkspaceTree,
          'type': CanonicalEventTypes.browseWorkspaceTree,
          'device_id': 'test-device-id',
          'session_id': 'sess-123',
          'payload': {'request_id': 'req-browse-event'},
        });

        expect(workspaceRuntime.calls, [
          CanonicalEventTypes.browseWorkspaceTree,
        ]);
        expect(workspaceRuntime.lastManagedRemote, isTrue);
        expect(runtimeBridge.registeredSessionCount, 0);
      },
    );

    test('allows list_workspaces through the cloud adapter', () async {
      await socket.trigger('execute_command', {
        'command': CanonicalEventTypes.listWorkspaces,
        'device_id': 'test-device-id',
        'payload': {'request_id': 'req-list', 'session_id': 'sess-list'},
      });

      expect(workspaceRuntime.calls, [CanonicalEventTypes.listWorkspaces]);
      expect(runtimeBridge.registeredSessionCount, 0);
      final response = socket.emittedEvents.singleWhere(
        (item) => item['event'] == 'device_event',
      );
      final data = response['data'] as Map<String, dynamic>;
      expect(data['event'], CanonicalEventTypes.workspacesList);
      expect(data['payload'], containsPair('request_id', 'req-list'));
    });

    test('rejects list_workspaces without a device id', () async {
      await socket.trigger('execute_command', {
        'command': CanonicalEventTypes.listWorkspaces,
        'payload': {
          'request_id': 'req-list-missing-device',
          'session_id': 'sess-list',
        },
      });

      expect(workspaceRuntime.calls, isEmpty);
      expect(runtimeBridge.registeredSessionCount, 0);
      final response = socket.emittedEvents.singleWhere(
        (item) => item['event'] == 'device_event',
      );
      final data = response['data'] as Map<String, dynamic>;
      expect(data['event'], 'error');
      expect(
        (data['payload'] as Map)['code'],
        DeviceControlErrorCodes.invalidRequest,
      );
    });
  });

  group('cloud remote MCP management admission', () {
    test('dispatches list_mcp_servers without registering a session', () async {
      await socket.trigger('execute_command', {
        'command': CanonicalEventTypes.listMcpServers,
        'device_id': 'test-device-id',
        'payload': {'request_id': 'req-list-mcp', 'session_id': 'sess-123'},
      });

      expect(workspaceRuntime.calls, [CanonicalEventTypes.listMcpServers]);
      expect(runtimeBridge.registeredSessionCount, 0);
      final data = socket.emittedEvents.single['data'] as Map<String, dynamic>;
      expect(data['event'], CanonicalEventTypes.mcpServersList);
      expect((data['payload'] as Map)['request_id'], 'req-list-mcp');
    });

    test(
      'issues a save preview then mutates only after confirmation',
      () async {
        await socket.trigger('execute_command', {
          'command': CanonicalEventTypes.saveMcpServer,
          'device_id': 'test-device-id',
          'payload': {
            'request_id': 'req-save-preview',
            'session_id': 'sess-123',
            'scope': 'global',
            'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
            'secrets': {'bearer_token': 'must-not-persist-in-preview'},
          },
        });

        expect(workspaceRuntime.calls, isEmpty);
        expect(runtimeBridge.registeredSessionCount, 0);
        final preview =
            socket.emittedEvents.single['data'] as Map<String, dynamic>;
        expect(preview['event'], CanonicalEventTypes.mcpServerSavePreview);
        final previewPayload = Map<String, dynamic>.from(
          preview['payload'] as Map,
        );
        expect(previewPayload.toString(), isNot(contains('must-not-persist')));
        final token = previewPayload['confirmation_token']?.toString() ?? '';
        final fingerprint =
            previewPayload['confirmation_fingerprint']?.toString() ?? '';
        expect(token, isNotEmpty);
        expect(fingerprint, isNotEmpty);

        socket.emittedEvents.clear();
        await socket.trigger('execute_command', {
          'command': CanonicalEventTypes.saveMcpServer,
          'device_id': 'test-device-id',
          'payload': {
            'request_id': 'req-save-confirm',
            'session_id': 'sess-123',
            'scope': 'global',
            'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
            'secrets': {'bearer_token': 'must-not-persist-in-preview'},
            'confirmation_token': token,
            'confirmation_fingerprint': fingerprint,
          },
        });

        expect(workspaceRuntime.calls, [CanonicalEventTypes.saveMcpServer]);
        expect(runtimeBridge.registeredSessionCount, 0);
        final saved =
            socket.emittedEvents.single['data'] as Map<String, dynamic>;
        expect(saved['event'], CanonicalEventTypes.mcpServerSaved);
      },
    );

    test(
      'still rejects replace_mcp_config before session or MCP runtime access',
      () async {
        for (final command in blockedMcpReplaceCommands) {
          socket.emittedEvents.clear();
          await socket.trigger('execute_command', {
            'command': command,
            'device_id': 'test-device-id',
            'payload': {
              'request_id': 'req-$command',
              'session_id': 'sess-123',
              'scope': 'global',
              'document': <String, dynamic>{},
            },
          });
          _expectDisabledError(
            socket.emittedEvents,
            requestId: 'req-$command',
            code: 'remote_mcp_management_disabled',
          );
        }

        socket.emittedEvents.clear();
        await socket.trigger('protocol_event', {
          'event': CanonicalEventTypes.replaceMcpConfig,
          'type': CanonicalEventTypes.replaceMcpConfig,
          'session_id': 'sess-123',
          'payload': {
            'request_id': 'req-replace-event',
            'scope': 'global',
            'document': <String, dynamic>{},
          },
        });
        _expectDisabledError(
          socket.emittedEvents,
          requestId: 'req-replace-event',
          code: 'remote_mcp_management_disabled',
        );

        expect(runtimeBridge.registeredSessionCount, 0);
        expect(workspaceRuntime.calls, isEmpty);
      },
    );

    test('rejects a mismatched MCP command as wrong_device', () async {
      await socket.trigger('execute_command', {
        'command': CanonicalEventTypes.listMcpServers,
        'device_id': 'other-device',
        'payload': {'request_id': 'req-mcp-wrong', 'session_id': 'sess-123'},
      });
      _expectDisabledError(
        socket.emittedEvents,
        requestId: 'req-mcp-wrong',
        code: DeviceControlErrorCodes.wrongDevice,
      );
      expect(workspaceRuntime.calls, isEmpty);
      expect(runtimeBridge.registeredSessionCount, 0);
    });

    test(
      'dispatches protocol_event MCP list without session registration',
      () async {
        await socket.trigger('protocol_event', {
          'event': CanonicalEventTypes.listMcpServers,
          'type': CanonicalEventTypes.listMcpServers,
          'device_id': 'test-device-id',
          'session_id': 'sess-123',
          'payload': {'request_id': 'req-list-mcp-event'},
        });

        expect(workspaceRuntime.calls, [CanonicalEventTypes.listMcpServers]);
        expect(runtimeBridge.registeredSessionCount, 0);
      },
    );
  });

  group('cloud device-control admission', () {
    test(
      'dispatches a matching update check without registering a session',
      () async {
        await socket.trigger('execute_command', {
          'command': DeviceControlCommands.updateCheck,
          'device_id': 'test-device-id',
          'payload': {'request_id': 'req-check', 'session_id': 'sess-123'},
        });
        expect(socket.emittedEvents, hasLength(1));
        final emitted = socket.emittedEvents.single;
        expect(emitted['event'], 'device_event');
        final data = emitted['data'] as Map<String, dynamic>;
        expect(data['event'], DeviceControlCommands.updateCheckResult);
        expect(
          (data['payload'] as Map)['status'],
          AgentUpdateStatus.upToDate.wireName,
        );
        expect(runtimeBridge.registeredSessionCount, 0);
      },
    );

    test(
      'rejects apply without confirmation as confirmation_required',
      () async {
        await socket.trigger('execute_command', {
          'command': DeviceControlCommands.updateApply,
          'device_id': 'test-device-id',
          'payload': {
            'request_id': 'req-apply',
            'session_id': 'sess-123',
            'target_version': '1.2.3',
            'manifest_revision': 'rev-1',
            'manifest_fingerprint': 'fp-1',
          },
        });
        _expectDisabledError(
          socket.emittedEvents,
          requestId: 'req-apply',
          code: DeviceControlErrorCodes.confirmationRequired,
        );
        expect(runtimeBridge.registeredSessionCount, 0);
      },
    );

    test('rejects a mismatched device_id without listing workspaces', () async {
      await socket.trigger('execute_command', {
        'command': CanonicalEventTypes.listWorkspaces,
        'device_id': 'other-device',
        'payload': {'request_id': 'req-wrong', 'session_id': 'sess-123'},
      });
      _expectDisabledError(
        socket.emittedEvents,
        requestId: 'req-wrong',
        code: DeviceControlErrorCodes.wrongDevice,
      );
      expect(workspaceRuntime.calls, isEmpty);
      expect(runtimeBridge.registeredSessionCount, 0);
    });

    test(
      'rejects a mismatched device-control command as wrong_device',
      () async {
        await socket.trigger('execute_command', {
          'command': DeviceControlCommands.updateCheck,
          'device_id': 'other-device',
          'payload': {'request_id': 'req-check', 'session_id': 'sess-123'},
        });
        _expectDisabledError(
          socket.emittedEvents,
          requestId: 'req-check',
          code: DeviceControlErrorCodes.wrongDevice,
        );
        expect(runtimeBridge.registeredSessionCount, 0);
      },
    );
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

class _ScriptedUpdateService extends AgentUpdateService {
  _ScriptedUpdateService({required this.checkResult, required this.applyResult})
    : super(
        currentVersion: '1.0.0',
        executablePath: '/tmp/sanad-agent',
        isSourceManaged: false,
        client: http.Client(),
      );

  final AgentUpdateResult checkResult;
  final AgentUpdateResult applyResult;

  @override
  Future<AgentUpdateResult> check({String? targetVersion}) async => checkResult;

  @override
  Future<AgentUpdateResult> update({
    String? targetVersion,
    String? expectedManifestTag,
    String? expectedManifestCommit,
  }) async => applyResult;
}
