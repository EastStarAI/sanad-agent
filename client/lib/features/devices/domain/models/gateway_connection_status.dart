import 'package:equatable/equatable.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';

enum LocalGatewayStatus {
  notFound,
  installedButStopped,
  disconnected,
  connecting,
  connected,
  needsRepair,
}

enum SanadGatewayStatus {
  loginRequired,
  disconnected,
  connecting,
  connected,
  authenticatedNoDevices,
  authenticatedWithDevices,
}

enum GatewayConnectionAction {
  signIn,
  retryCloud,
  startLocalAgent,
  repairLocalAgent,
  restartLocalAgent,
  stopLocalAgent,
  addDevice,
}

class GatewayConnectionStatus extends Equatable {
  final LocalGatewayStatus localGateway;
  final SanadGatewayStatus sanadGateway;
  final List<GatewayConnectionAction> actions;
  final String recommendedRoute;
  final bool isDesktop;

  const GatewayConnectionStatus({
    required this.localGateway,
    required this.sanadGateway,
    required this.actions,
    required this.recommendedRoute,
    required this.isDesktop,
  });

  const GatewayConnectionStatus.initial()
    : localGateway = LocalGatewayStatus.disconnected,
      sanadGateway = SanadGatewayStatus.disconnected,
      actions = const [],
      recommendedRoute = AppRoutes.splash,
      isDesktop = false;

  bool get isLocalConnected => localGateway == LocalGatewayStatus.connected;
  bool get isCloudReady =>
      sanadGateway == SanadGatewayStatus.connected ||
      sanadGateway == SanadGatewayStatus.authenticatedNoDevices ||
      sanadGateway == SanadGatewayStatus.authenticatedWithDevices;

  String get summary {
    final local = localGateway.displayLabel;
    final cloud = sanadGateway.displayLabel;
    return 'Local $local, Cloud $cloud';
  }

  @override
  List<Object?> get props => [
    localGateway,
    sanadGateway,
    actions,
    recommendedRoute,
    isDesktop,
  ];
}

extension LocalGatewayStatusLabel on LocalGatewayStatus {
  String get displayLabel {
    return switch (this) {
      LocalGatewayStatus.notFound => 'Not found',
      LocalGatewayStatus.installedButStopped => 'Installed but stopped',
      LocalGatewayStatus.disconnected => 'Disconnected',
      LocalGatewayStatus.connecting => 'Connecting',
      LocalGatewayStatus.connected => 'Connected',
      LocalGatewayStatus.needsRepair => 'Needs repair',
    };
  }
}

extension SanadGatewayStatusLabel on SanadGatewayStatus {
  String get displayLabel {
    return switch (this) {
      SanadGatewayStatus.loginRequired => 'Login to connect',
      SanadGatewayStatus.disconnected => 'Offline',
      SanadGatewayStatus.connecting => 'Connecting',
      SanadGatewayStatus.connected => 'Connected',
      SanadGatewayStatus.authenticatedNoDevices => 'No devices',
      SanadGatewayStatus.authenticatedWithDevices => 'Connected',
    };
  }
}
