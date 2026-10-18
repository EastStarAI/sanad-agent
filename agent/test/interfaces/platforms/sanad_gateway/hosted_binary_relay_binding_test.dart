import 'dart:async';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:socket_io_client/socket_io_client.dart' as sio;
import 'package:socket_io_client/src/manager.dart';
import 'package:test/test.dart';

/// Delivers one server-authored event through the socket's public dispatch
/// entry point so a test can observe listener registration without a network.
void _deliver(sio.Socket socket, String event, [dynamic data]) {
  final wasConnected = socket.connected;
  socket.connected = true;
  socket.onevent({'data': [event, data]});
  socket.connected = wasConnected;
}

final class _FakeManager implements Manager {
  @override
  Function() on(String event, Function fn) => () {};

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

final class _FakeAuthManager extends AuthManager {
  final _controller = StreamController<void>.broadcast();
  bool cloudAuthorized = true;

  @override
  Stream<void> get changes => _controller.stream;

  @override
  bool get isAuthenticated => true;

  @override
  bool get canAuthenticateCloudAgent => cloudAuthorized;

  @override
  String get hardwareId => 'test-device-id';

  /// Flips cloud authorization exactly like a token/authorization change does.
  void setCloudAuthorized(bool value) {
    cloudAuthorized = value;
    _controller.add(null);
  }

  Future<void> close() => _controller.close();
}

/// Mirrors the socket_io_client contract the platform binds against: one cached
/// socket instance per host, whose listeners `dispose()` clears.
final class _CachedSocket implements sio.Socket {
  final Map<String, List<Function>> listeners = {};
  final List<(String, dynamic)> emitted = [];
  bool isConnected = false;
  bool isDisposed = false;

  Iterable<String> get relayEvents =>
      listeners.keys.where((event) => event.startsWith('attachment_upload_') || event.startsWith('conversation_media_'));

  @override
  Function() on(String event, Function fn) {
    listeners.putIfAbsent(event, () => []).add(fn);
    return () {};
  }

  @override
  sio.Socket emit(String event, [dynamic data]) {
    emitted.add((event, data));
    return this;
  }

  @override
  sio.Socket connect() {
    isConnected = true;
    return this;
  }

  @override
  sio.Socket disconnect() {
    isConnected = false;
    return this;
  }

  @override
  void dispose() {
    isDisposed = true;
    isConnected = false;
    listeners.clear();
  }

  @override
  bool get connected => isConnected;

  @override
  Manager get io => _manager;

  final Manager _manager = _FakeManager();

  Future<void> receive(String event, dynamic data) async {
    for (final listener in List<Function>.from(listeners[event] ?? const [])) {
      final result = Function.apply(listener, [data]);
      if (result is Future) await result;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

void main() {
  final getIt = GetIt.instance;

  group('socket_io_client socket reuse', () {
    test('io() hands back the disposed instance with cleared listeners', () {
      const uri = 'http://127.0.0.1:59119';
      final options = sio.OptionBuilder().disableAutoConnect().build();
      final socket = sio.io(uri, options);
      var deliveries = 0;
      socket.on('probe.event', (_) => deliveries += 1);

      _deliver(socket, 'probe.event', 1);
      expect(deliveries, 1);

      socket.dispose();

      final reused = sio.io(uri, options);
      expect(
        identical(socket, reused),
        isTrue,
        reason: 'a cached socket can be handed back after dispose',
      );
      _deliver(reused, 'probe.event', 1);
      expect(
        deliveries,
        1,
        reason: 'dispose() cleared the listeners of the cached socket',
      );

      reused.on('probe.event', (_) => deliveries += 1);
      _deliver(reused, 'probe.event', 1);
      expect(deliveries, 2, reason: 're-registering restores dispatch');
    });
  });

  group('hosted binary relay binding', () {
    late Directory home;
    late AgentStateDatabase state;
    late _FakeAuthManager authManager;
    late _CachedSocket socket;
    late ServerSanadGatewayPlatform platform;

    setUp(() async {
      getIt.allowReassignment = true;
      home = await Directory.systemTemp.createTemp('sanad-relay-binding-');
      setSanadHomeOverride(home.path);
      state = AgentStateDatabase.inMemory();
      final store = AttachmentStore(state, stateHome: home.path);
      await store.initialize();
      authManager = _FakeAuthManager();
      socket = _CachedSocket();
      platform = ServerSanadGatewayPlatform(socketFactory: (_, _) => socket);
      getIt.registerSingleton<AuthManager>(authManager);
      getIt.registerSingleton<Config>(Config());
      getIt.registerSingleton<AgentStateDatabase>(state);
      getIt.registerSingleton<AttachmentStore>(store);
      getIt.registerSingleton<SessionManager>(SessionManager());
    });

    tearDown(() async {
      await platform.dispose();
      await authManager.close();
      SessionManager.resetForTesting();
      setSanadHomeOverride(null);
      if (home.existsSync()) await home.delete(recursive: true);
      await getIt.reset();
    });

    Map<String, dynamic> fetchFrame(String routeId) => {
      'version': 'v1',
      'route_id': routeId,
      'device_id': 'test-device-id',
      'session_id': 'session-a',
      'request_id': routeId,
      'media_id': '0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef',
      'purpose': 'thumbnail',
    };

    test('binds the relay on initialize', () async {
      await platform.initialize();

      expect(socket.relayEvents, isNotEmpty);

      await socket.receive('conversation_media_fetch', fetchFrame('route-1'));
      expect(
        socket.emitted.map((entry) => entry.$1),
        contains('conversation_media_error'),
      );
    });

    test('re-binds the relay after an authorization-loss socket dispose', () async {
      await platform.initialize();
      expect(socket.relayEvents, isNotEmpty, reason: 'initial binding');

      // Authorization loss disposes the socket; the cached instance keeps being
      // reused by `io()` but its listeners are gone.
      authManager.setCloudAuthorized(false);
      await pumpEventQueue();
      expect(socket.isDisposed, isTrue);
      expect(socket.relayEvents, isEmpty);

      authManager.setCloudAuthorized(true);
      await pumpEventQueue();

      expect(identical(platform.socket, socket), isTrue);
      expect(
        socket.relayEvents,
        isNotEmpty,
        reason: 'relay listeners must be restored on the reused socket',
      );

      socket.emitted.clear();
      await socket.receive('conversation_media_fetch', fetchFrame('route-2'));
      expect(
        socket.emitted.map((entry) => entry.$1),
        contains('conversation_media_error'),
        reason: 'the relay answers relay events after re-authorization',
      );
    });
  });
}
