import 'dart:async';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:test/test.dart';

void main() {
  tearDown(() async {
    await GetIt.I.reset();
  });

  _familyEventTests();

  test(
    'one command failure is contained and later commands are still handled',
    () async {
      final orchestrator = _ThrowingOrchestrator();
      GetIt.I.registerSingleton<SessionRunOrchestrator>(orchestrator);
      final platform = _RecordingPlatform();
      final gateway = GatewayManager()..registerPlatform(platform);
      addTearDown(gateway.stop);
      await gateway.start();

      platform.add(_event('session-failure-1'));
      platform.add(_event('session-failure-2'));
      await Future<void>.delayed(const Duration(milliseconds: 40));

      expect(
        orchestrator.handledSessions,
        equals(['session-failure-1', 'session-failure-2']),
      );
      expect(platform.responses, hasLength(2));
      expect(
        platform.responses.map((response) => response.message.content),
        everyElement('Error: The command could not be processed.'),
      );
    },
  );
}

// Plan 83 live D2: a family event must reach every Sanad client platform.
void _familyEventTests() {
  test('publishFamilyEvent reaches every Sanad client platform', () async {
    final local = _RecordingPlatform();
    final cloud = _RecordingPlatform(
      id: 'cloud-platform',
      transport: PlatformTransport.cloud,
    );
    final gateway = GatewayManager()
      ..registerPlatform(local)
      ..registerPlatform(cloud);
    gateway.publishFamilyEvent(
      CanonicalEvent(
        type: CanonicalEventTypes.workspacePolicyChanged,
        payload: const {'workspace_id': 'ws-1', 'policy': {}},
      ),
    );
    await Future<void>.delayed(const Duration(milliseconds: 20));
    for (final platform in [local, cloud]) {
      final response = platform.responses.single;
      expect(response.delivery.scope, DeliveryScope.platformFamily);
      expect(
        response.message.metadata?['canonical_event_type'],
        CanonicalEventTypes.workspacePolicyChanged,
      );
    }
  });
}

GatewayEvent _event(String sessionId) {
  return GatewayEvent(
    sessionId: sessionId,
    platformId: 'recording-platform',
    message: Message(role: MessageRole.user, content: 'run'),
  );
}

class _ThrowingOrchestrator extends SessionRunOrchestrator {
  final List<String> handledSessions = [];

  @override
  Future<void> handleEvent(GatewayEvent event) async {
    handledSessions.add(event.sessionId);
    throw StateError('command failure');
  }
}

class _RecordingPlatform extends BasePlatform {
  _RecordingPlatform({
    this.id = 'recording-platform',
    this.transport = PlatformTransport.local,
  });

  final String id;
  final PlatformTransport transport;
  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>();
  final List<GatewayResponse> responses = [];

  void add(GatewayEvent event) => _events.add(event);

  @override
  PlatformDescriptor get descriptor => PlatformDescriptor.sanadClient(
    transport: transport,
    platformInstanceId: id,
  );

  @override
  Stream<GatewayEvent> get eventStream => _events.stream;

  @override
  String get platformId => id;

  @override
  Future<void> initialize() async {}

  @override
  Future<void> sendResponse(GatewayResponse response) async {
    responses.add(response);
  }

  @override
  Future<void> dispose() => _events.close();
}
