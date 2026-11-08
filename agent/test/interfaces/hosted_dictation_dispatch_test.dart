import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/auth/device_authorization_client.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/delivery_presence_controller.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/device_control_command_handler.dart';
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
import '../stt/support/fake_dictation_channel.dart';

class FakeManager implements Manager {
  @override
  Function() on(String event, Function fn) => () {};

  @override
  dynamic noSuchMethod(Invocation invocation) => null;
}

class FakeSocket implements socket_io.Socket {
  final Map<String, List<Function>> listeners = {};
  final List<Map<String, dynamic>> emittedEvents = [];
  Future<void>? pendingConnect;
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
    pendingConnect = trigger('connect', null);
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
  String? token;

  @override
  Stream<void> get changes => _controller.stream;

  @override
  String? get deviceToken => token;

  @override
  String? get pairingToken => null;

  @override
  String? get pendingDeviceToken => null;

  @override
  bool get hasPendingDevicePairing => false;

  @override
  bool get isAuthenticated => true;

  @override
  bool get canAuthenticateCloudAgent => true;

  @override
  String get hardwareId => 'test-device-id';

  @override
  Future<bool> reload({bool notifyIfChanged = false}) async => false;

  @override
  Future<bool> refreshAccessToken(String portalUrl) async => true;

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

class _ScriptedUpdateService extends AgentUpdateService {
  _ScriptedUpdateService()
    : super(
        currentVersion: '1.0.0',
        executablePath: '/tmp/sanad-agent',
        isSourceManaged: false,
        client: http.Client(),
      );

  @override
  Future<AgentUpdateResult> check({String? targetVersion}) async =>
      const AgentUpdateResult(
        status: AgentUpdateStatus.upToDate,
        currentVersion: '1.0.0',
        availableVersion: '1.0.0',
      );

  @override
  Future<AgentUpdateResult> update({
    String? targetVersion,
    String? expectedManifestTag,
    String? expectedManifestCommit,
  }) async => const AgentUpdateResult(
    status: AgentUpdateStatus.upToDate,
    currentVersion: '1.0.0',
  );
}

/// Capability loading only needs the slash-command catalog, and this test is
/// about dictation dispatch rather than workspace discovery.
class _EmptyWorkspaceRuntimeService extends LocalWorkspaceRuntimeService {
  _EmptyWorkspaceRuntimeService({required super.sanadHomePath});

  @override
  Future<List<Map<String, dynamic>>> searchSlashCommands({
    String? query,
    String? workspaceId,
  }) async => const [];
}

void main() {
  late Directory tempDir;
  late FakeSocket socket;
  late FakeAuthManager authManager;
  late TrackingPlatformRuntimeBridge runtimeBridge;
  late ServerSanadGatewayPlatform platform;
  late DeliveryPresenceController deliveryPresence;
  late MemoryAgentSecretStore secrets;
  late DictationService dictation;

  setUp(() async {
    getIt.allowReassignment = true;
    tempDir = Directory.systemTemp.createTempSync('sanad-dictation-dispatch');
    setSanadHomeOverride(tempDir.path);
    // A whisper path override needs no native shim: the injected engine factory
    // supplies the recognizer, so the real lease path runs.
    final modelDir = Directory('${tempDir.path}/manual-model')..createSync();
    File('${modelDir.path}/ggml-tiny.bin').writeAsBytesSync(const [1, 2, 3]);
    File('${tempDir.path}/config.yaml').writeAsStringSync('''
stt:
  model_path: ${modelDir.path}
  model_idle_minutes: 0
''');
    socket = FakeSocket();
    secrets = MemoryAgentSecretStore();
    deliveryPresence = DeliveryPresenceController();
    runtimeBridge = TrackingPlatformRuntimeBridge();
    authManager = FakeAuthManager();

    dictation = DictationService(
      sanadHome: tempDir.path,
      platformSupported: true,
      engineFor: (_) => FakeSttEngine(),
    );

    getIt.registerSingleton<AuthManager>(authManager);
    getIt.registerSingleton<Config>(Config());
    getIt.registerSingleton<DictationService>(dictation);
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
        updateService: _ScriptedUpdateService.new,
        isSupervised: () => true,
      ),
    );
    getIt.registerSingleton<PlatformRuntimeBridge>(runtimeBridge);
    getIt.registerSingleton<LocalWorkspaceRuntimeService>(
      _EmptyWorkspaceRuntimeService(sanadHomePath: tempDir.path),
    );

    platform = ServerSanadGatewayPlatform(
      socketFactory: (_, _) => socket,
      deliveryPresence: deliveryPresence,
      identityLoader: () => DeviceKeyIdentity.loadOrCreate(secretStore: secrets),
      registrationRetryDelay: (_) => Completer<void>().future,
      httpClient: MockClient(
        (_) async => http.Response(
          '',
          200,
          headers: {'date': HttpDate.format(DateTime.now().toUtc())},
        ),
      ),
    );
    await platform.initialize();
    await socket.pendingConnect;
    await socket.trigger('register_success', {'device_id': 'test-device-id'});
    socket.emittedEvents.clear();
  });

  tearDown(() async {
    await platform.dispose();
    deliveryPresence.dispose();
    await authManager.close();
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) await tempDir.delete(recursive: true);
    await getIt.reset();
  });

  Map<String, dynamic> envelope({
    required String op,
    String dictationId = 'dict-1',
    String? requestId,
    String deviceId = 'test-device-id',
  }) => {
    'device_id': deviceId,
    'command': 'dictation',
    'request_id': requestId ?? dictationId,
    'payload': {
      'version': 'v1',
      'dictation_id': dictationId,
      'request_id': requestId ?? dictationId,
      'op': op,
    },
  };

  List<Map<String, dynamic>> dictationEvents() => [
    for (final entry in socket.emittedEvents)
      if (entry['event'] == 'device_event')
        Map<String, dynamic>.from(entry['data'] as Map),
  ];

  Future<void> waitForEvent(String type) async {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline)) {
      if (dictationEvents().any(
        (event) => (event['payload'] as Map)['type'] == type,
      )) {
        return;
      }
      await Future<void>.delayed(const Duration(milliseconds: 5));
    }
    fail('no "$type" relayed within the window');
  }

  group('hosted dictation dispatch', () {
    test('a dictation command creates no conversation session channel', () async {
      await socket.trigger('execute_command', envelope(op: 'status'));
      await waitForEvent('stt_status');

      expect(
        runtimeBridge.registeredSessionCount,
        0,
        reason: 'dictation identity is a transport session, never a conversation',
      );
    });

    test('a dictation event is origin scoped with a unique id', () async {
      await socket.trigger('execute_command', envelope(op: 'status'));
      await waitForEvent('stt_status');

      final event = dictationEvents().single;
      expect(event['event'], 'dictation_event');
      expect(event['device_id'], 'test-device-id');
      expect(event['delivery'], {'scope': 'origin', 'request_id': 'dict-1'});
      expect(event['request_id'], 'dict-1');
      expect(event.containsKey('session_id'), isFalse);
      final eventId = event['event_id'];
      expect(eventId, isA<String>());
      expect((eventId as String).isNotEmpty, isTrue);
      final payload = Map<String, dynamic>.from(event['payload'] as Map);
      expect(payload['type'], 'stt_status');
      expect(payload['dictation_id'], 'dict-1');
    });

    test('a canonical conversation command still registers a session', () async {
      await socket.trigger('execute_command', {
        'device_id': 'test-device-id',
        'command': 'stop',
        'payload': {'session_id': 'conv-1'},
      });
      // The fall-through path owns conversation commands; a dictation command
      // never reaches it.
      expect(runtimeBridge.registeredSessionCount, 1);
      expect(dictationEvents(), isEmpty);
    });

    test('a dictation start opens one hosted session', () async {
      await socket.trigger('execute_command', envelope(op: 'start'));
      // The channel's buffered start command is the only path that loads the
      // engine, which is what makes the session ready.
      await waitForEvent('dictation_ready');
      expect(dictation.isBusy, isTrue);

      await socket.trigger(
        'execute_command',
        envelope(op: 'start', dictationId: 'dict-2'),
      );
      await waitForEvent('dictation_error');
      final errors = dictationEvents().where(
        (event) => (event['payload'] as Map)['type'] == 'dictation_error',
      );
      final payload = Map<String, dynamic>.from(errors.last['payload'] as Map);
      expect(payload['code'], 'dictation_busy');
      expect(
        runtimeBridge.registeredSessionCount,
        0,
        reason: 'neither start registered a conversation session',
      );
    });

    test('a wrong-device dictation command is never answered', () async {
      await socket.trigger(
        'execute_command',
        envelope(op: 'status', deviceId: 'another-device'),
      );
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(dictationEvents(), isEmpty);
    });

    test('a voice session without identity is refused, never broadcast',
        () async {
      await socket.trigger('execute_command', {
        'device_id': 'test-device-id',
        'command': 'start_voice',
        'request_id': 'req-1',
        // The legacy placeholder is not an identity: the only delivery left
        // would be the account-wide broadcast this repair removes.
        'payload': {'session_id': 'default', 'request_id': 'req-1'},
      });

      final deadline = DateTime.now().add(const Duration(seconds: 5));
      Map<String, dynamic>? refusal;
      while (DateTime.now().isBefore(deadline)) {
        for (final entry in socket.emittedEvents) {
          final data = entry['data'];
          if (entry['event'] == 'device_event' &&
              data is Map &&
              data['event'] == 'voice_relay_error') {
            refusal = Map<String, dynamic>.from(data);
          }
        }
        if (refusal != null) break;
        await Future<void>.delayed(const Duration(milliseconds: 5));
      }

      expect(refusal, isNotNull);
      final payload = Map<String, dynamic>.from(refusal!['payload'] as Map);
      expect(payload['error_code'], 'identity_required');
      expect(refusal['delivery'], {'scope': 'origin', 'request_id': 'req-1'});
    });
  });
}
