import 'package:sanad_client/core/config/app_config.dart';

enum AgentLifecycleStatus {
  ready,
  upToDate,
  sourceManaged,
  networkFailed,
  manifestInvalid,
  targetMismatch,
  downgradeRejected,
  unsupportedTarget,
  trustFailed,
  checksumFailed,
  replacementFailed,
  rollbackCompleted,
  serviceRegistrationFailed,
  startFailed,
  healthFailed,
  versionFailed,
  authFailed,
}

class AgentLifecycleResult {
  const AgentLifecycleResult(this.status, {this.message});

  final AgentLifecycleStatus status;
  final String? message;

  bool get isSuccess => switch (status) {
    AgentLifecycleStatus.ready || AgentLifecycleStatus.upToDate || AgentLifecycleStatus.sourceManaged => true,
    _ => false,
  };

  String get actionableMessage =>
      message ??
      switch (status) {
        AgentLifecycleStatus.networkFailed =>
          'Could not reach the official release service. Try again when the network is available.',
        AgentLifecycleStatus.manifestInvalid => 'The official release metadata is invalid. Try again later.',
        AgentLifecycleStatus.targetMismatch => 'The available agent does not match this Sanad Client version.',
        AgentLifecycleStatus.downgradeRejected =>
          'The installed agent is newer than this client. Update the client or use recovery.',
        AgentLifecycleStatus.unsupportedTarget => 'No compatible agent is published for this computer.',
        AgentLifecycleStatus.trustFailed => 'The downloaded agent did not pass platform trust verification.',
        AgentLifecycleStatus.checksumFailed => 'The downloaded agent was incomplete or corrupted. Try again.',
        AgentLifecycleStatus.replacementFailed =>
          'The verified agent could not replace the installed copy; the previous copy was kept.',
        AgentLifecycleStatus.rollbackCompleted => 'The update failed and the previous agent was restored.',
        AgentLifecycleStatus.serviceRegistrationFailed =>
          'The agent was downloaded but its background service could not be registered.',
        AgentLifecycleStatus.startFailed => 'The agent service could not be started.',
        AgentLifecycleStatus.healthFailed => 'The agent did not become healthy before the timeout.',
        AgentLifecycleStatus.versionFailed => 'The agent started, but it did not report the required version.',
        AgentLifecycleStatus.authFailed => 'The local agent rejected the client credential.',
        _ => 'The agent is ready.',
      };
}

abstract class LocalDaemonController {
  static const int defaultPort = 58085;
  static const String defaultHost = '127.0.0.1';
  static const Duration restartSafetyTimeout = Duration(minutes: 1);
  static const Duration restartRequestTimeout = Duration(seconds: 65);
  static String get defaultUrl => AppConfig.localGatewayUrl;

  Future<bool> isDaemonRunning();
  Future<Map<String, dynamic>?> getDaemonHealth();
  Future<String?> getDaemonVersion();
  Future<bool> startDaemon();
  Future<bool> stopDaemon();
  Future<bool> restartDaemon();

  Future<AgentLifecycleResult> updateDaemon({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async => const AgentLifecycleResult(
    AgentLifecycleStatus.sourceManaged,
    message: 'Source agent updates remain developer-managed.',
  );

  bool isServiceInstalled();
  bool get shouldAutoStart;
  Future<bool> install();
}
