import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

/// Records every response `GatewayManager` routes to this platform instance.
class _FakeFamilyPlatform implements BasePlatform {
  @override
  final String platformId;
  @override
  final PlatformDescriptor descriptor;

  final delivered = <GatewayResponse>[];
  final _controller = StreamController<GatewayEvent>.broadcast();

  _FakeFamilyPlatform({
    required this.platformId,
    required this.descriptor,
  });

  @override
  bool get receivesMirroredResponses => false;

  @override
  bool get shouldReceiveUserEcho => false;

  @override
  Stream<GatewayEvent> get eventStream => _controller.stream;

  @override
  Future<void> sendResponse(GatewayResponse response) async {
    delivered.add(response);
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async => _controller.close();

  Iterable<GatewayResponse> get sessionDeleted => delivered.where(
    (response) =>
        response.message.metadata?['canonical_event_type'] ==
        CanonicalEventTypes.sessionDeleted,
  );
}

void main() {
  late Directory tempDir;
  late GatewayManager gateway;
  late _FakeFamilyPlatform localClients;
  late _FakeFamilyPlatform cloudClients;

  setUp(() async {
    getIt.allowReassignment = true;
    tempDir = await Directory.systemTemp.createTemp(
      'sanad-agent-session-deleted-broadcast',
    );
    setSanadHomeOverride(tempDir.path);
    SessionManager.resetForTesting();
    getIt.registerSingleton<AuthManager>(AuthManager());
    getIt.registerSingleton<SessionManager>(SessionManager());

    // One local and one cloud instance of the Sanad client family: a family
    // announcement must reach both, not only the requester's transport.
    localClients = _FakeFamilyPlatform(
      platformId: 'local_gateway',
      descriptor: const PlatformDescriptor.sanadClient(
        transport: PlatformTransport.local,
        platformInstanceId: 'local-daemon',
      ),
    );
    cloudClients = _FakeFamilyPlatform(
      platformId: 'cloud_gateway',
      descriptor: const PlatformDescriptor.sanadClient(
        transport: PlatformTransport.cloud,
        platformInstanceId: 'cloud-gateway',
      ),
    );
    gateway = GatewayManager()
      ..registerPlatform(localClients)
      ..registerPlatform(cloudClients);
    getIt.registerSingleton<GatewayManager>(gateway);
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    await tempDir.delete(recursive: true);
    await getIt.reset();
  });

  test(
    'a delete_session command announces session_deleted to every Sanad client',
    () async {
      final bridge = SanadProtocolBridge();
      final emitted = <Map<String, dynamic>>[];

      await bridge.handleProtocolEvent(
        CanonicalEvent(
          type: CanonicalEventTypes.deleteSession,
          sessionId: 'session-deleted-by-cli',
          payload: {
            'request_id': 'request-cli-delete',
            'session_id': 'session-deleted-by-cli',
          },
        ),
        (envelope) async => emitted.add(envelope),
      );
      await pumpEventQueue();

      // The requester still receives its correlated acknowledgement.
      expect(emitted, hasLength(1));
      expect(emitted.single['event'], CanonicalEventTypes.sessionDeleted);
      expect(emitted.single['request_id'], 'request-cli-delete');
      expect(emitted.single['delivery']['scope'], 'origin');

      // Every other Sanad client learns about the deletion too, so a session
      // removed through the CLI cannot stay visible in a connected Client.
      for (final entry in {
        'local': localClients,
        'cloud': cloudClients,
      }.entries) {
        final announcements = entry.value.sessionDeleted.toList();
        expect(
          announcements,
          hasLength(1),
          reason: '${entry.key} clients received no session_deleted event',
        );
        final announcement = announcements.single;
        expect(announcement.sessionId, 'session-deleted-by-cli');
        expect(
          announcement.delivery.scope,
          DeliveryScope.platformFamily,
          reason: 'the announcement must fan out to the whole family',
        );
        expect(announcement.delivery.platformFamily, PlatformFamily.sanadClient);
        expect(
          announcement.message.metadata?['canonical_payload'],
          containsPair('session_id', 'session-deleted-by-cli'),
        );
      }
    },
  );
}
