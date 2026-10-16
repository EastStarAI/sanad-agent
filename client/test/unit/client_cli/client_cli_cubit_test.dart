import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_approval_coordinator.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_host.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_ownership.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_settings.dart';
import 'package:sanad_client/features/client_cli/presentation/bloc/client_cli_cubit.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

import '../../helpers/fake_device_repository.dart';
import '../../mocks/mock_socket_service.dart';

class _FakeCoordinator extends Fake implements DeviceConnectionCoordinator {
  final SanadSocketService mockSocket;

  _FakeCoordinator(this.mockSocket);

  @override
  String get currentDeviceId => 'local-hardware-id';

  @override
  Future<ResolvedAgentEndpoint> ensureConnectedEndpointForAgent(
    DeviceConfig agent,
  ) async {
    return ResolvedAgentEndpoint(
      agent: agent,
      scope: ConnectionScope.cloud,
      socketService: mockSocket,
      isLocalReachable: false,
    );
  }
}

void main() {
  group('ClientCliCubit', () {
    late Directory tempHome;
    late ClientCliOwnership ownership;
    late ClientCliApprovalCoordinator approvalCoordinator;
    late FakeDeviceRepository deviceRepo;
    late FakeSanadSocketService mockSocket;
    late ClientCliHost host;
    late ClientCliCubit cubit;

    setUp(() async {
      SharedPreferences.setMockInitialValues({
        ClientCliCubit.keyEnabled: true,
        ClientCliCubit.keyPermissionMode: ClientCliSettings.defaultMode,
      });
      final prefs = await SharedPreferences.getInstance();

      tempHome = await Directory.systemTemp.createTemp('client_cli_cubit_test_');
      ownership = ClientCliOwnership(processAliveChecker: (_) async => true);
      approvalCoordinator = ClientCliApprovalCoordinator();
      deviceRepo = FakeDeviceRepository();
      mockSocket = FakeSanadSocketService(hardwareId: 'cloud-server')
        ..setConnected(true);

      host = ClientCliHost(
        connectionCoordinator: _FakeCoordinator(mockSocket),
        deviceRepository: deviceRepo,
        ownership: ownership,
        approvalCoordinator: approvalCoordinator,
        sanadHome: tempHome.path,
        clientVersion: '1.0.15',
      );
      cubit = ClientCliCubit(host: host, prefs: prefs);
    });

    tearDown(() async {
      await cubit.close();
      approvalCoordinator.dispose();
      if (await tempHome.exists()) {
        await tempHome.delete(recursive: true);
      }
    });

    test('load starts the endpoint for a persisted enabled setting', () async {
      await cubit.load();

      expect(cubit.state.enabled, isTrue);
      expect(host.isRunning, isTrue);
    });

    test('reconcile restores the endpoint after a login/logout cycle', () async {
      await cubit.load();
      expect(host.isRunning, isTrue);

      // The logout branch releases endpoint ownership while the setting stays
      // enabled in preferences.
      await cubit.onLogout();
      expect(host.isRunning, isFalse);

      await cubit.reconcile();

      expect(cubit.state.enabled, isTrue);
      expect(host.isRunning, isTrue);
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isTrue);
    });

    test('reconcile after disabling does not reopen the endpoint', () async {
      await cubit.load();
      await cubit.setEnabled(false);
      expect(host.isRunning, isFalse);

      await cubit.reconcile();

      expect(host.isRunning, isFalse);
      expect(await File(ownership.recordPath(tempHome.path)).exists(), isFalse);
    });
  });
}
