import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client_impl.dart';

import '../../mocks/mock_socket_service.dart';

void main() {
  late FakeSanadSocketService local;
  late FakeSanadSocketService cloud;
  late DeviceConnectionCoordinator coordinator;
  late ProviderSetupClientImpl client;

  setUp(() {
    local = FakeSanadSocketService()..setConnected(true);
    cloud = FakeSanadSocketService()..setConnected(true);
    coordinator = DeviceConnectionCoordinator(
      cloudSocketService: cloud,
      localSocketService: local,
      currentDeviceId: 'this-hardware',
    );
    client = ProviderSetupClientImpl(
      connectionCoordinator: coordinator,
      commandClient: DeviceCommandClient(connectionCoordinator: coordinator),
    );
  });

  tearDown(() {
    coordinator.dispose();
    local.dispose();
    cloud.dispose();
  });

  group('ProviderSetupClientImpl.modelUpdates', () {
    test('projects local socket model.cache_updated events into ModelCacheUpdateEvent', () async {
      final events = <ModelCacheUpdateEvent>[];
      final sub = client.modelUpdates.listen(events.add);

      local.debugEmitEvent({
        'device_id': 'this-hardware',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'updated',
          'models': [
            {'id': 'o3'},
          ],
        },
      });

      await pumpEventQueue();

      expect(events.length, 1);
      expect(events.first.providerInstanceId, 'provider-1');
      expect(events.first.status, 'updated');
      expect(events.first.isUpdated, isTrue);
      expect(events.first.deviceId, 'this-hardware');

      await sub.cancel();
    });

    test('projects cloud socket model.cache_updated events', () async {
      final events = <ModelCacheUpdateEvent>[];
      final sub = client.modelUpdates.listen(events.add);

      cloud.debugEmitEvent({
        'device_id': 'remote-hardware',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-2',
          'status': 'failed',
          'error': 'Remote failure',
        },
      });

      await pumpEventQueue();

      expect(events.length, 1);
      expect(events.first.providerInstanceId, 'provider-2');
      expect(events.first.status, 'failed');
      expect(events.first.isFailed, isTrue);

      await sub.cancel();
    });

    test('ignores unrelated socket events', () async {
      final events = <ModelCacheUpdateEvent>[];
      final sub = client.modelUpdates.listen(events.add);

      local.debugEmitEvent({
        'event': 'capabilities_changed',
        'payload': {'caps': {}},
      });
      local.debugEmitEvent({
        'event': 'session.updated',
        'payload': {'session_id': 's1'},
      });

      await pumpEventQueue();

      expect(events, isEmpty);

      await sub.cancel();
    });

    test('supports multiple concurrent listeners on modelUpdates', () async {
      final events1 = <ModelCacheUpdateEvent>[];
      final events2 = <ModelCacheUpdateEvent>[];
      final sub1 = client.modelUpdates.listen(events1.add);
      final sub2 = client.modelUpdates.listen(events2.add);

      local.debugEmitEvent({
        'device_id': 'this-hardware',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'updated',
        },
      });

      await pumpEventQueue();

      expect(events1.length, 1);
      expect(events2.length, 1);
      expect(events1.first.providerInstanceId, 'provider-1');
      expect(events2.first.providerInstanceId, 'provider-1');

      await sub1.cancel();
      await sub2.cancel();
    });

    test('supports cancel and resubscribe without leaking or duplicating events', () async {
      final events1 = <ModelCacheUpdateEvent>[];
      final sub1 = client.modelUpdates.listen(events1.add);

      local.debugEmitEvent({
        'device_id': 'this-hardware',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'updated',
        },
      });
      await pumpEventQueue();
      expect(events1.length, 1);

      await sub1.cancel();

      // Emit while no listeners
      local.debugEmitEvent({
        'device_id': 'this-hardware',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'updated',
        },
      });
      await pumpEventQueue();

      // Resubscribe with fresh listener
      final events2 = <ModelCacheUpdateEvent>[];
      final sub2 = client.modelUpdates.listen(events2.add);

      local.debugEmitEvent({
        'device_id': 'this-hardware',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'updated',
        },
      });
      await pumpEventQueue();

      expect(events2.length, 1);
      expect(events1.length, 1); // unmutated after cancel

      await sub2.cancel();
    });

    test('rejects unscoped cloud socket events without fabricating local identity', () async {
      final events = <ModelCacheUpdateEvent>[];
      final sub = client.modelUpdates.listen(events.add);

      cloud.debugEmitEvent({
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'updated',
        },
      });

      await pumpEventQueue();

      expect(events, isEmpty);

      await sub.cancel();
    });

    test('derives local attribution from coordinator currentDeviceId when local event omits device identity', () async {
      final events = <ModelCacheUpdateEvent>[];
      final sub = client.modelUpdates.listen(events.add);

      local.debugEmitEvent({
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'updated',
        },
      });

      await pumpEventQueue();

      expect(events.length, 1);
      expect(events.first.deviceId, 'this-hardware');

      await sub.cancel();
    });

    test('rejects malformed provider ID or unknown status before admission', () async {
      final events = <ModelCacheUpdateEvent>[];
      final sub = client.modelUpdates.listen(events.add);

      local.debugEmitEvent({
        'device_id': 'this-hardware',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': '',
          'status': 'updated',
        },
      });
      local.debugEmitEvent({
        'device_id': 'this-hardware',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'in_progress',
        },
      });

      await pumpEventQueue();

      expect(events, isEmpty);

      await sub.cancel();
    });
  });
}
