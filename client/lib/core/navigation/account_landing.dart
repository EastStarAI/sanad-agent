import 'package:flutter/widgets.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_cubit.dart';
import 'package:sanad_client/features/devices/presentation/bloc/device_state.dart';
import 'package:sanad_client/utils/app_platform.dart';

/// Where an authenticated account is allowed to land.
///
/// One rule, three consumers: the cold-start bootstrap, the Settings "back to
/// conversations" action, and the Home surface itself. A non-desktop account
/// whose inventory holds no registered device has no Home to show, so it belongs
/// on the zero-device onboarding surface — the route `GatewayBootstrap` already
/// chooses at cold start. Desktop keeps its local-first Home, and an account
/// with a device keeps the location it asked for.
///
/// Owning this here (rather than repeating the device check at each call site)
/// is what keeps an in-app back action from stranding a new account on a
/// device-less composer it cannot leave.
class AccountLanding {
  AccountLanding._();

  /// Whether [devices] holds at least one device registered to the account.
  ///
  /// A local-inventory device (the desktop Agent this computer runs) is not an
  /// account device, so it does not make Home eligible on its own.
  static bool hasRegisteredDevices(Iterable<DeviceConfig> devices) {
    return devices.any((device) => device.accountDeviceId != null);
  }

  /// The devices an inventory state holds, whichever shape it has.
  static List<DeviceConfig> registeredDevicesOf(DeviceState state) {
    return switch (state) {
      DeviceActive(:final agents) => agents,
      DeviceNoActive(:final agents) => agents,
      _ => const <DeviceConfig>[],
    };
  }

  /// True while the inventory holds no authoritative answer yet: the first load
  /// after sign-in, a retained cache while it refreshes, or a retry surface
  /// after a failed fetch. A pending inventory must never be read as "no
  /// devices", or an account with devices would be bounced to onboarding.
  static bool isInventoryPending(DeviceState state) {
    return switch (state) {
      DeviceLoading() || AgentInitial() => true,
      DeviceNoActive(:final phase) =>
        phase == DevicesPhase.loading || phase == DevicesPhase.stale || phase == DevicesPhase.error,
      _ => false,
    };
  }

  /// The location [requestedLocation] resolves to for this account.
  static String resolve({
    required bool isDesktop,
    required bool hasRegisteredDevices,
    String requestedLocation = AppRoutes.home,
  }) {
    if (isDesktop) return requestedLocation;
    return hasRegisteredDevices ? requestedLocation : AppRoutes.onboarding;
  }

  /// The location this account belongs on when it asks for
  /// [requestedLocation], read from the live device inventory.
  static String forCurrentAccount(
    BuildContext context, {
    String requestedLocation = AppRoutes.home,
  }) {
    final state = context.read<DeviceCubit>().state;
    return resolve(
      isDesktop: AppPlatform.isDesktop,
      hasRegisteredDevices: hasRegisteredDevices(registeredDevicesOf(state)),
      requestedLocation: requestedLocation,
    );
  }

  /// True when a non-desktop account has an authoritative empty inventory, so a
  /// Home surface must yield to the zero-device onboarding surface.
  static bool shouldLeaveHome(DeviceState state) {
    if (AppPlatform.isDesktop) return false;
    if (isInventoryPending(state)) return false;
    return !hasRegisteredDevices(registeredDevicesOf(state));
  }
}
