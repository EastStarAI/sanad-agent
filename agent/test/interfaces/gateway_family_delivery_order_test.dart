/// Family delivery keeps one session's events in emission order without
/// serializing independent sessions.
///
/// Ordering is not a courtesy the transports can be assumed to provide: a delta
/// stream is only meaningful in order, and two transports (or one untrusted
/// relay) may deliver the same events in a different order. This suite pins the
/// Agent's half of the contract — it must never create the disorder itself — and
/// the properties that keep that guarantee cheap: one chain per session, no
/// chain across sessions, a failing delivery never breaks the tail, and no entry
/// outlives the delivery it ordered.
library;

import 'dart:async';

import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:test/test.dart';

class _FakePlatform implements BasePlatform {
  _FakePlatform({
    required this.platformId,
    required this.descriptor,
    this.onSend,
  });

  @override
  final String platformId;

  @override
  final PlatformDescriptor descriptor;

  @override
  bool get receivesMirroredResponses => false;

  @override
  bool get shouldReceiveUserEcho => false;

  final FutureOr<void> Function(GatewayResponse response)? onSend;
  final List<GatewayResponse> delivered = <GatewayResponse>[];
  final StreamController<GatewayEvent> _events =
      StreamController<GatewayEvent>.broadcast();

  int _expectedDeliveries = 0;
  Completer<void>? _deliveryReached;

  @override
  Stream<GatewayEvent> get eventStream => _events.stream;

  /// Completes once [count] sends have finished on this platform.
  Future<void> waitForDeliveries(int count) {
    if (delivered.length >= count) return Future<void>.value();
    _expectedDeliveries = count;
    return (_deliveryReached ??= Completer<void>()).future;
  }

  @override
  Future<void> sendResponse(GatewayResponse response) async {
    await onSend?.call(response);
    delivered.add(response);
    final reached = _deliveryReached;
    if (reached != null &&
        !reached.isCompleted &&
        delivered.length >= _expectedDeliveries) {
      reached.complete();
    }
  }

  @override
  Future<void> initialize() async {}

  @override
  Future<void> dispose() async => _events.close();
}

/// A zero-duration macrotask yield: every already-scheduled microtask (the
/// delivery chain's continuations) has run by the time this completes.
Future<void> settle() => Future<void>.delayed(Duration.zero);

void main() {
  late GatewayManager manager;
  late List<String> timeline;

  setUp(() {
    getIt.allowReassignment = true;
    manager = GatewayManager();
    timeline = <String>[];
  });

  tearDown(() async {
    await manager.stop();
  });

  _FakePlatform platform({
    required String platformId,
    required PlatformTransport transport,
    bool Function(GatewayResponse response)? throws,
    bool Function(GatewayResponse response)? gated,
    Future<void>? gate,
  }) {
    return _FakePlatform(
      platformId: platformId,
      descriptor: PlatformDescriptor.sanadClient(transport: transport),
      onSend: (response) async {
        final tag = '$platformId:${_tag(response)}';
        timeline.add('start:$tag');
        if (throws?.call(response) ?? false) {
          throw StateError('transport write failed');
        }
        if (gate != null && (gated?.call(response) ?? false)) {
          await gate;
        }
        timeline.add('end:$tag');
      },
    );
  }

  void publish(String sessionId, String chunk) {
    manager.publishFamilyEvent(
      CanonicalEvent(
        type: CanonicalEventTypes.thoughtStream,
        sessionId: sessionId,
        payload: {'content': chunk, 'status': 'running'},
      ),
    );
  }

  test('one session delivers in emission order even when the first send is slow',
      () async {
    final gate = Completer<void>();
    final local = platform(
      platformId: 'local',
      transport: PlatformTransport.local,
      gated: (response) => _tag(response) == 's1-a',
      gate: gate.future,
    );
    manager.registerPlatform(local);
    await manager.start();

    publish('s1', 'a');
    publish('s1', 'b');
    await settle();

    expect(
      timeline,
      ['start:local:s1-a'],
      reason: 'the second delta must wait for the first to finish',
    );
    expect(manager.pendingFamilyDeliveryTails, 1);

    gate.complete();
    await local.waitForDeliveries(2);

    expect(timeline, [
      'start:local:s1-a',
      'end:local:s1-a',
      'start:local:s1-b',
      'end:local:s1-b',
    ]);
    await settle();
    expect(
      manager.pendingFamilyDeliveryTails,
      0,
      reason: 'a drained chain leaves no ordering entry behind',
    );
  });

  test('two sessions deliver in parallel', () async {
    final gate = Completer<void>();
    final local = platform(
      platformId: 'local',
      transport: PlatformTransport.local,
      gated: (response) => _tag(response) == 's1-a',
      gate: gate.future,
    );
    manager.registerPlatform(local);
    await manager.start();

    publish('s1', 'a');
    publish('s2', 'b');

    await local.waitForDeliveries(1);
    expect(
      local.delivered.single.sessionId,
      's2',
      reason: 'a blocked session must not hold another session back',
    );
    expect(timeline, containsAll(<String>['start:local:s1-a', 'start:local:s2-b']));
    expect(timeline, isNot(contains('end:local:s1-a')));

    gate.complete();
    await local.waitForDeliveries(2);
    await settle();
    expect(manager.pendingFamilyDeliveryTails, 0);
  });

  test('a failing delivery never breaks the session tail', () async {
    var failed = false;
    final local = platform(
      platformId: 'local',
      transport: PlatformTransport.local,
      throws: (response) {
        if (failed || _tag(response) != 's1-a') return false;
        failed = true;
        return true;
      },
    );
    manager.registerPlatform(local);
    await manager.start();

    publish('s1', 'a');
    publish('s1', 'b');

    await local.waitForDeliveries(1);
    expect(local.delivered.single.sessionId, 's1');
    expect(
      _tag(local.delivered.single),
      's1-b',
      reason: 'the failed delta is dropped and the next one still ships',
    );
    expect(timeline.last, 'end:local:s1-b');
    await settle();
    expect(manager.pendingFamilyDeliveryTails, 0);
  });

  test('session-less family events keep their own single order', () async {
    final gate = Completer<void>();
    final local = platform(
      platformId: 'local',
      transport: PlatformTransport.local,
      gated: (response) => _tag(response) == 'device-a',
      gate: gate.future,
    );
    manager.registerPlatform(local);
    await manager.start();

    manager.publishFamilyEvent(
      CanonicalEvent(type: 'capabilities_changed', payload: {'marker': 'a'}),
    );
    manager.publishFamilyEvent(
      CanonicalEvent(type: 'capabilities_changed', payload: {'marker': 'b'}),
    );
    await settle();
    expect(timeline, ['start:local:device-a']);

    gate.complete();
    await local.waitForDeliveries(2);
    expect(timeline, [
      'start:local:device-a',
      'end:local:device-a',
      'start:local:device-b',
      'end:local:device-b',
    ]);
    await settle();
    expect(manager.pendingFamilyDeliveryTails, 0);
  });

  test('local is still delivered before cloud for every ordered event',
      () async {
    final local = platform(
      platformId: 'local',
      transport: PlatformTransport.local,
    );
    final cloud = platform(
      platformId: 'cloud',
      transport: PlatformTransport.cloud,
    );
    manager.registerPlatform(local);
    manager.registerPlatform(cloud);
    await manager.start();

    publish('s1', 'a');
    publish('s1', 'b');
    await local.waitForDeliveries(2);
    await cloud.waitForDeliveries(2);

    expect(timeline, [
      'start:local:s1-a',
      'end:local:s1-a',
      'start:cloud:s1-a',
      'end:cloud:s1-a',
      'start:local:s1-b',
      'end:local:s1-b',
      'start:cloud:s1-b',
      'end:cloud:s1-b',
    ]);
    await settle();
    expect(manager.pendingFamilyDeliveryTails, 0);
  });

  test('stop clears every pending ordering entry', () async {
    final gate = Completer<void>();
    final local = platform(
      platformId: 'local',
      transport: PlatformTransport.local,
      gated: (_) => true,
      gate: gate.future,
    );
    manager.registerPlatform(local);
    await manager.start();

    publish('s1', 'a');
    await settle();
    expect(manager.pendingFamilyDeliveryTails, 1);

    await manager.stop();
    expect(manager.pendingFamilyDeliveryTails, 0);
    gate.complete();
  });
}

String _tag(GatewayResponse response) {
  final marker = response.sessionId.isEmpty ? 'device' : response.sessionId;
  final payload = response.message.metadata?['canonical_payload'];
  final chunk = payload is Map ? payload['content'] ?? payload['marker'] : null;
  return '$marker-${chunk ?? response.eventId}';
}
