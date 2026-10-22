import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_approval_coordinator.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_home_resolver.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_host.dart';
import 'package:sanad_client/features/client_cli/data/client_cli_ownership.dart';
import 'package:sanad_client/features/client_cli/domain/client_cli_platform.dart';
import 'package:sanad_client/features/client_cli/presentation/bloc/client_cli_cubit.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';

/// Registers the native-only Client CLI cluster.
///
/// The host binds a loopback HTTP/WebSocket endpoint and resolves the Sanad
/// Home from native process state, so this module must only run when
/// [ClientCliPlatform.isSupported]. Callers must keep the entry point behind
/// that boundary; shared composition never registers, resolves, or inspects the
/// Client CLI on remote-only platforms.
class ClientCliModule {
  const ClientCliModule();

  /// [registry] is the active dependency registry (production `getIt`).
  void register(GetIt registry) {
    if (!ClientCliPlatform.isSupported) {
      throw StateError(
        'Client CLI dependencies require a desktop platform; '
        'guard registration with ClientCliPlatform.isSupported.',
      );
    }

    if (!registry.isRegistered<ClientCliOwnership>()) {
      registry.registerLazySingleton<ClientCliOwnership>(
        () => const ClientCliOwnership(),
      );
    }

    if (!registry.isRegistered<ClientCliHost>()) {
      registry.registerLazySingleton<ClientCliHost>(
        () {
          // Home resolution reads native process state, so it stays inside the
          // lazy factory: registration performs no native read, and remote-only
          // platforms never reach this factory. A desktop host is constructed
          // when a consumer mounts (settings cubit, tray, or auth lifecycle),
          // and Home resolution happens at that point rather than during
          // dependency setup.
          final home = const ClientCliHomeResolver().resolveSanadHome(
            explicitHome: AppConfig.sanadHome.isNotEmpty
                ? AppConfig.sanadHome
                : null,
          );
          return ClientCliHost(
            connectionCoordinator: registry<DeviceConnectionCoordinator>(),
            deviceRepository: registry<IDeviceRepository>(),
            ownership: registry<ClientCliOwnership>(),
            approvalCoordinator: registry<ClientCliApprovalCoordinator>(),
            sanadHome: home,
            clientVersion: registry<String>(instanceName: 'appVersion'),
          );
        },
        dispose: (host) => host.stop(),
      );
    }

    if (!registry.isRegistered<ClientCliCubit>()) {
      registry.registerLazySingleton<ClientCliCubit>(
        () => ClientCliCubit(
          host: registry<ClientCliHost>(),
          prefs: registry<SharedPreferences>(),
        ),
        dispose: (cubit) => cubit.close(),
      );
    }
  }
}
