import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport.dart';
import 'package:sanad_client/features/dictation/domain/dictation_transport_resolver.dart';
import 'package:sanad_client/features/dictation/domain/hosted_dictation_transport.dart';

import '../../mocks/mock_socket_service.dart';

/// A store seeded with one capability snapshot, so the resolver's hosted branch
/// can be exercised without a live `device.capabilities` round trip.
class _SeededCapabilitiesStore extends DeviceCapabilitiesStore {
  _SeededCapabilitiesStore(
    DeviceConnectionCoordinator coordinator,
    this._capability, {
    this.failFetch = false,
  }) : super(coordinator);

  final Capability _capability;
  final bool failFetch;

  @override
  Capability getForAgent(String deviceId) => _capability;

  @override
  Map<String, Capability> get capabilitiesByAgentId => {
    'agent-remote': _capability,
  };

  @override
  Future<Capability> ensureFreshForAgent(
    DeviceConfig agent, {
    bool force = false,
  }) async {
    if (failFetch) throw StateError('capability fetch failed');
    return _capability;
  }
}

/// A store that has never cached this device but can still fetch it fresh.
class _ColdCapabilitiesStore extends DeviceCapabilitiesStore {
  _ColdCapabilitiesStore(
    DeviceConnectionCoordinator coordinator,
    this._capability,
  ) : super(coordinator);

  final Capability _capability;

  @override
  Capability getForAgent(String deviceId) => const Capability();

  @override
  Map<String, Capability> get capabilitiesByAgentId => {
    'agent-remote': _capability,
  };

  @override
  Future<Capability> ensureFreshForAgent(
    DeviceConfig agent, {
    bool force = false,
  }) async => _capability;
}

const _relayCapability = Capability(
  supportsDictation: true,
  dictationRelayVersion: Capability.dictationRelayVersion1,
  dictationRelayMaxFrameBytes: 8192,
  dictationRelayMaxSessionBytes: 4096,
  dictationRelayMaxSessionSeconds: 45,
);

void main() {
  late FakeSanadSocketService cloudSocket;
  late FakeSanadSocketService localSocket;
  late DeviceConnectionCoordinator coordinator;

  setUp(() {
    cloudSocket = FakeSanadSocketService(hardwareId: 'this-mac');
    localSocket = FakeSanadSocketService(hardwareId: 'this-mac');
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloudSocket,
      localSocketService: localSocket,
      currentDeviceId: 'this-mac',
    );
  });

  tearDown(() {
    coordinator.dispose();
    cloudSocket.dispose();
    localSocket.dispose();
  });

  /// A device that can only be reached through the cloud transport.
  DeviceConfig remoteAgent() => DeviceConfig(
    id: 'agent-remote',
    name: 'Remote Mac',
    hardwareId: 'other-host',
    metadata: const {'cloud_device_id': 'account-device-9'},
    isOnline: true,
  );

  DictationTransportResolver resolverFor(Capability capability) =>
      DictationTransportResolver(
        connectionCoordinator: coordinator,
        capabilities: _SeededCapabilitiesStore(coordinator, capability),
      );

  Future<String> refusalOf(
    DictationTransportResolver resolver, {
    DeviceConfig? device,
  }) async {
    try {
      await resolver.resolve(
        device: device ?? remoteAgent(),
        sessionId: 'session-1',
      );
    } on DictationTransportUnavailable catch (error) {
      return error.reason;
    }
    fail('Expected the resolver to refuse hosted dictation');
  }

  group('transport resolver', () {
    test('rejects an unusable session identity before choosing a transport',
        () async {
      final resolver = resolverFor(_relayCapability);

      for (final sessionId in ['', 'session with spaces', 'x' * 129]) {
        await expectLater(
          resolver.resolve(device: remoteAgent(), sessionId: sessionId),
          throwsA(
            isA<DictationTransportUnavailable>().having(
              (error) => error.reason,
              'reason',
              'invalid_session_identity',
            ),
          ),
        );
      }
    });

    test('surfaces the Agent reason when dictation itself is unavailable',
        () async {
      final resolver = resolverFor(
        const Capability(
          supportsDictation: false,
          dictationUnavailableReason: 'native_runtime_missing',
        ),
      );

      expect(await refusalOf(resolver), 'native_runtime_missing');
    });

    test('falls back to a generic reason when the Agent gives none', () async {
      final resolver = resolverFor(const Capability(supportsDictation: false));

      expect(await refusalOf(resolver), 'dictation_unavailable');
    });

    test('an Agent without the relay contract is never relayed', () async {
      // New Client, old Agent: local dictation stays available, hosted must not
      // silently degrade into an unscoped relay.
      final resolver = resolverFor(const Capability(supportsDictation: true));

      expect(await refusalOf(resolver), 'relay_unavailable');
    });

    test('an unknown relay version is not treated as v1', () async {
      final resolver = resolverFor(
        const Capability(supportsDictation: true, dictationRelayVersion: 2),
      );

      expect(await refusalOf(resolver), 'relay_unavailable');
    });

    test('a device without an account identity is refused', () async {
      cloudSocket.setConnected(true);
      final resolver = resolverFor(_relayCapability);
      // A local inventory row reached through the cloud while the local socket
      // is down has no account-owned id at all, so a relay could not be scoped.
      final sameMachine = DeviceConfig(
        id: 'this-mac',
        name: 'This Mac',
        hardwareId: 'this-mac',
        isOnline: true,
      );

      expect(
        await refusalOf(resolver, device: sameMachine),
        'relay_unavailable',
      );
    });

    test('a disconnected cloud socket is refused', () async {
      final resolver = resolverFor(_relayCapability);

      expect(await refusalOf(resolver), 'relay_unavailable');
    });

    test('a signed-out cloud socket is refused even while connected', () async {
      cloudSocket
        ..setConnected(true)
        ..fakeHasAccessToken = false;
      final resolver = resolverFor(_relayCapability);

      expect(await refusalOf(resolver), 'relay_unavailable');
    });

    test('a cold cache is refreshed before the decision', () async {
      cloudSocket.setConnected(true);
      final resolver = DictationTransportResolver(
        connectionCoordinator: coordinator,
        capabilities: _ColdCapabilitiesStore(coordinator, _relayCapability),
      );

      final transport = await resolver.resolve(
        device: remoteAgent(),
        sessionId: 'session-1',
      );

      expect(transport, isA<HostedDictationTransport>());
      await transport.close();
    });

    test('a failed capability fetch is retryable, not a verdict', () async {
      cloudSocket.setConnected(true);
      final resolver = DictationTransportResolver(
        connectionCoordinator: coordinator,
        capabilities: _SeededCapabilitiesStore(
          coordinator,
          _relayCapability,
          failFetch: true,
        ),
      );

      expect(await refusalOf(resolver), 'relay_unavailable');
    });

    test('a qualified hosted session uses the account device id', () async {
      cloudSocket.setConnected(true);
      final resolver = resolverFor(_relayCapability);

      final transport = await resolver.resolve(
        device: remoteAgent(),
        sessionId: 'session-1',
      );

      expect(transport, isA<HostedDictationTransport>());
      expect(
        (transport as HostedDictationTransport).deviceId,
        'account-device-9',
      );
      expect(transport.dictationId, 'session-1');
      // The declared bounds, not a matching constant on this side, are what the
      // transport advertises and enforces.
      expect(transport.maxSessionBytes, 4096);
      expect(transport.maxSessionSeconds, 45);
      expect(transport.maxFrameBytes, 8192);
      // Choosing a transport writes nothing: the route is opened by `start`,
      // after the claim command that authorizes it (order is contract).
      expect(
        cloudSocket.capturedCommands.where(
          (command) => command['event'] == 'dictation_start',
        ),
        isEmpty,
      );
      transport.sendCommand('start');
      final start = cloudSocket.capturedCommands.firstWhere(
        (command) => command['event'] == 'dictation_start',
      );
      expect((start['data'] as Map)['max_bytes'], 4096);
      expect(
        cloudSocket.capturedCommands.where(
          (command) => command['event'] == 'dictation_start',
        ),
        hasLength(1),
      );
      await transport.close();
    });
  });
}
