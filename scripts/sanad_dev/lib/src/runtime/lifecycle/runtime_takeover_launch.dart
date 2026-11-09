part of '../../../sanad_dev_cli.dart';

/// The relaunch arguments a take-over derives from the live Client it replaces.
///
/// Both admitted pair shapes (a complete manual pair and a lease-owned pair
/// behind a foreign daemon) derive them the same way: from the Client's own
/// discoverable launch profile, never from defaults.
class TakeoverLaunchPlan {
  const TakeoverLaunchPlan({
    required this.client,
    required this.profile,
    required this.configPath,
    required this.cloudEnabled,
    required this.driverMode,
    required this.homeSelector,
    required this.device,
  });

  final ClientInstance client;
  final ClientLaunchProfile profile;
  final String configPath;
  final bool cloudEnabled;
  final bool driverMode;
  final String homeSelector;
  final String device;

  String? get clientInstanceSlot =>
      profile.define(sanadDevClientInstanceSlotDefine);
}

typedef TakeoverManagedLaunch = Future<bool> Function(TakeoverLaunchPlan plan);

/// Restores the previous runtime when a managed relaunch fails.
///
/// It is a seam so the failure path is verifiable without starting a real
/// Agent or Client.
typedef TakeoverManualRestore =
    Future<bool> Function({
      required SanadDevRuntime runtime,
      required int agentPort,
      required String sanadHome,
      required ClientInstance client,
      required ClientLaunchProfile profile,
      required bool cloudEnabled,
      required bool restoreClient,
    });

/// Derives the relaunch plan from one lease-verified Client.
///
/// Returns null when the Client has no discoverable pid or its profile carries
/// no config argument; both are refusals, never defaults.
TakeoverLaunchPlan? buildTakeoverLaunchPlan({
  required SanadDevRuntime runtime,
  required ClientInstance client,
  required String activeHome,
}) {
  final profile = client.launchProfile;
  if (profile == null || client.pid == null) return null;
  final configArgument = profile.compileArguments.firstWhere(
    (argument) => argument.startsWith('--dart-define-from-file='),
    orElse: () => '',
  );
  if (configArgument.isEmpty) return null;
  return TakeoverLaunchPlan(
    client: client,
    profile: profile,
    configPath: configArgument.substring('--dart-define-from-file='.length),
    cloudEnabled:
        profile.define('ENABLE_CLOUD_GATEWAY')?.toLowerCase() != 'false',
    driverMode: profile.target?.endsWith('driver_main.dart') == true,
    homeSelector:
        !runtime.isLinkedWorktree &&
            _samePath(
              activeHome,
              resolveDefaultUserSanadHome(Platform.environment),
            )
        ? 'user'
        : activeHome,
    device: client.deviceId ?? profile.deviceId ?? _defaultDesktopDevice(),
  );
}

/// Relaunches the pair under this process as the launcher.
Future<bool> launchManagedTakeover(TakeoverLaunchPlan plan) async {
  await handleRun(
    target: SanadDevComponentTarget.all,
    driverMode: plan.driverMode,
    cloudEnabled: plan.cloudEnabled,
    dryRun: false,
    device: plan.device,
    configPath: plan.configPath,
    clientInstanceSlot: plan.clientInstanceSlot,
    sanadHomePath: plan.homeSelector,
  );
  return exitCode == 0;
}
