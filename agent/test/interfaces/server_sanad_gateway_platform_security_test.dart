import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/platform_session_channel.dart';
import 'package:socket_io_client/socket_io_client.dart' as socket_io;
import 'package:socket_io_client/src/manager.dart';
import 'package:test/test.dart';

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
  @override
  bool get isAuthenticated => true;

  @override
  String get hardwareId => 'test-device-id';
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

void main() {
  final getIt = GetIt.instance;
  late Directory tempDir;
  late FakeSocket socket;
  late TrackingPlatformRuntimeBridge runtimeBridge;
  late TrackingWorkspaceRuntimeService workspaceRuntime;
  late ServerSanadGatewayPlatform platform;

  setUp(() async {
    getIt.allowReassignment = true;
    tempDir = await Directory.systemTemp.createTemp('sanad-platform-test');
    socket = FakeSocket();
    runtimeBridge = TrackingPlatformRuntimeBridge();
    workspaceRuntime = TrackingWorkspaceRuntimeService(
      sanadHomePath: tempDir.path,
    );

    getIt.registerSingleton<AuthManager>(FakeAuthManager());
    getIt.registerSingleton<Config>(Config());
    getIt.registerSingleton<SanadProtocolBridge>(SanadProtocolBridge());
    getIt.registerSingleton<PlatformRuntimeBridge>(runtimeBridge);
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(workspaceRuntime);

    platform = ServerSanadGatewayPlatform();
    platform.socketForTesting = socket;
    await platform.initialize();
    await socket.trigger('register_success', {'device_id': 'test-device-id'});
    socket.emittedEvents.clear();
  });

  tearDown(() async {
    await platform.dispose();
    if (tempDir.existsSync()) {
      await tempDir.delete(recursive: true);
    }
    await getIt.reset();
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
