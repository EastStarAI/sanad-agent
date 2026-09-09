import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_release_contract/release_contract.dart';
import 'local_daemon_controller.dart';
import 'verified_agent_bootstrap_installer.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_http_client.dart';

class StandaloneDaemonController implements LocalDaemonController {
  static final _logger = Logger('StandaloneDaemonController');

  const StandaloneDaemonController({
    this.sanadHomePath,
    this.environment,
  });

  final String? sanadHomePath;
  final Map<String, String>? environment;

  LocalGatewayHttpClient get _gatewayClient => const LocalGatewayHttpClient();

  VerifiedAgentBootstrapInstaller createBootstrapInstaller() {
    return VerifiedAgentBootstrapInstaller(targetPath: getExecutablePath());
  }

  String getHomeDirectory() {
    final environment = this.environment ?? Platform.environment;
    if (Platform.isWindows) {
      return environment['USERPROFILE'] ?? '';
    }
    return environment['HOME'] ?? '';
  }

  String getSanadHome() {
    final explicit = sanadHomePath?.trim();
    if (explicit != null && explicit.isNotEmpty) return explicit;
    final compileTime = AppConfig.sanadHome.trim();
    if (compileTime.isNotEmpty) return compileTime;
    final runtime = (environment ?? Platform.environment)['SANAD_HOME']?.trim();
    return runtime != null && runtime.isNotEmpty ? runtime : p.join(getHomeDirectory(), '.sanad');
  }

  String _serviceInstance() {
    final configured = AppConfig.sanadServiceInstance.trim();
    final value = configured.isNotEmpty
        ? configured
        : (environment ?? Platform.environment)['SANAD_SERVICE_INSTANCE']?.trim() ?? '';
    if (value.isNotEmpty && !RegExp(r'^[A-Za-z0-9-]{1,32}$').hasMatch(value)) {
      throw const FormatException('Invalid SANAD_SERVICE_INSTANCE.');
    }
    return value;
  }

  String getExecutablePath() {
    final binDir = p.join(getSanadHome(), 'bin');
    if (Platform.isWindows) {
      return p.join(binDir, 'sanad.exe');
    }
    return p.join(binDir, 'sanad');
  }

  String getServiceConfigPath() {
    final home = getHomeDirectory();
    final instance = _serviceInstance();
    if (Platform.isMacOS) {
      final label = instance.isEmpty ? 'com.eaststarai.sanad.agent' : 'com.eaststarai.sanad.agent.$instance';
      return p.join(home, 'Library', 'LaunchAgents', '$label.plist');
    } else if (Platform.isLinux) {
      final name = instance.isEmpty ? 'sanad-agent.service' : 'sanad-agent-$instance.service';
      return p.join(home, '.config', 'systemd', 'user', name);
    }
    // For Windows, we don't have a plist/service file, we check the executable itself
    return getExecutablePath();
  }

  @override
  Future<bool> isDaemonRunning() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return false;
    }
    try {
      final response = await _gatewayClient
          .get(Uri.parse('${LocalDaemonController.defaultUrl}/health'))
          .timeout(const Duration(milliseconds: 800));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<String?> getDaemonVersion() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return null;
    }
    try {
      final response = await _gatewayClient
          .get(Uri.parse('${LocalDaemonController.defaultUrl}/health'))
          .timeout(const Duration(milliseconds: 800));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map) {
          return data['version']?.toString();
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<Map<String, dynamic>?> getDaemonHealth() async {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return null;
    }
    try {
      final response = await _gatewayClient
          .get(Uri.parse('${LocalDaemonController.defaultUrl}/health'))
          .timeout(const Duration(milliseconds: 800));
      if (response.statusCode == 200) {
        final data = jsonDecode(response.body);
        if (data is Map<String, dynamic>) {
          return data;
        }
      }
    } catch (_) {}
    return null;
  }

  @override
  Future<bool> startDaemon() async {
    try {
      final execPath = getExecutablePath();
      final result = await Process.run(execPath, ['service', 'start']);
      _logger.info('Started daemon service: exitCode=${result.exitCode}');
      return result.exitCode == 0;
    } catch (e) {
      _logger.severe('Failed to start daemon service: $e');
    }
    return false;
  }

  @override
  Future<bool> stopDaemon() async {
    try {
      final execPath = getExecutablePath();
      final result = await Process.run(execPath, ['service', 'stop']);
      _logger.info('Stopped daemon service: exitCode=${result.exitCode}');
      return result.exitCode == 0;
    } catch (e) {
      _logger.severe('Failed to stop daemon service: $e');
    }
    return false;
  }

  @override
  Future<bool> restartDaemon() async {
    final running = await isDaemonRunning();
    if (running) {
      try {
        final uri = Uri.parse('${LocalDaemonController.defaultUrl}/restart').replace(
          queryParameters: {
            'timeout_seconds': LocalDaemonController.restartSafetyTimeout.inSeconds.toString(),
          },
        );
        final response = await _gatewayClient.post(uri).timeout(LocalDaemonController.restartRequestTimeout);
        if (response.statusCode == 200) {
          // Wait for service to auto-restart via launchd/systemd KeepAlive
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          if (await isDaemonRunning()) {
            return true;
          }
        }
      } catch (_) {}
      // A failed safe restart must not fall back to an undeclared force kill.
      return false;
    }

    return startDaemon();
  }

  @override
  Future<AgentLifecycleResult> updateDaemon({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async {
    final health = await getDaemonHealth();
    final currentVersion = health?['version']?.toString();
    if (currentVersion != null) {
      final comparison = _compareVersions(currentVersion, targetVersion);
      if (comparison > 0) {
        return const AgentLifecycleResult(
          AgentLifecycleStatus.downgradeRejected,
        );
      }
      if (comparison == 0) {
        return const AgentLifecycleResult(AgentLifecycleStatus.upToDate);
      }
    }

    if (health == null) {
      final executableExists = File(getExecutablePath()).existsSync();
      if (executableExists) {
        if (!isServiceInstalled() && !await install()) {
          return const AgentLifecycleResult(
            AgentLifecycleStatus.serviceRegistrationFailed,
          );
        }
        if (!await startDaemon()) {
          return const AgentLifecycleResult(AgentLifecycleStatus.startFailed);
        }
        for (var attempt = 0; attempt < 10; attempt++) {
          if (await getDaemonHealth() != null) {
            return updateDaemon(
              targetVersion: targetVersion,
              onProgress: onProgress,
            );
          }
          await Future<void>.delayed(
            Duration(milliseconds: 300 + attempt * 200),
          );
        }
        return const AgentLifecycleResult(AgentLifecycleStatus.healthFailed);
      }
      try {
        final bootstrap = await createBootstrapInstaller().install(
          targetVersion: targetVersion,
          onProgress: onProgress,
        );
        if (!bootstrap.isSuccess) return _bootstrapResult(bootstrap);
        if ((!isServiceInstalled() || Platform.isWindows) && !await install()) {
          return const AgentLifecycleResult(
            AgentLifecycleStatus.serviceRegistrationFailed,
          );
        }
        if (!await startDaemon()) {
          return const AgentLifecycleResult(AgentLifecycleStatus.startFailed);
        }
      } catch (error) {
        _logger.severe('Verified agent bootstrap failed: $error');
        return AgentLifecycleResult(
          AgentLifecycleStatus.replacementFailed,
          message: 'Agent installation failed: $error',
        );
      }
    } else {
      try {
        final updateUri = Uri.parse(
          '${LocalDaemonController.defaultUrl}/update',
        ).replace(queryParameters: {'target_version': targetVersion});
        final response = await _gatewayClient.post(updateUri).timeout(const Duration(minutes: 2));
        if (response.statusCode == 401 || response.statusCode == 403) {
          return const AgentLifecycleResult(AgentLifecycleStatus.authFailed);
        }
        final body = jsonDecode(response.body);
        if (body is! Map) {
          return const AgentLifecycleResult(
            AgentLifecycleStatus.manifestInvalid,
          );
        }
        final status = body['status']?.toString() ?? 'failed';
        if (status != 'restart_required' && status != 'up_to_date') {
          return AgentLifecycleResult(
            _agentStatus(status),
            message: body['message']?.toString(),
          );
        }
      } catch (error) {
        _logger.severe('Daemon-owned update request failed: $error');
        return AgentLifecycleResult(
          AgentLifecycleStatus.networkFailed,
          message: 'Agent update request failed: $error',
        );
      }
    }

    final finalState = await _waitForTargetVersion(targetVersion);
    if (!finalState.isSuccess && health != null && await _restoreRollback()) {
      return const AgentLifecycleResult(AgentLifecycleStatus.rollbackCompleted);
    }
    return finalState;
  }

  Future<bool> _restoreRollback() async {
    final target = File(getExecutablePath());
    final backup = File('${target.path}.rollback');
    if (!backup.existsSync()) return false;
    try {
      if (target.existsSync()) await target.delete();
      await backup.rename(target.path);
      final chmod = await Process.run('chmod', ['700', target.path]);
      if (chmod.exitCode != 0) return false;
      return await startDaemon();
    } catch (error) {
      _logger.severe(
        'Could not restore the previous agent after failed health: $error',
      );
      return false;
    }
  }

  Future<AgentLifecycleResult> _waitForTargetVersion(
    String targetVersion,
  ) async {
    var sawHealth = false;
    for (var attempt = 0; attempt < 15; attempt++) {
      if (attempt > 0) {
        await Future<void>.delayed(
          Duration(milliseconds: 300 + (attempt.clamp(0, 8) * 250)),
        );
      }
      final health = await getDaemonHealth();
      if (health == null) continue;
      sawHealth = true;
      final version = health['version']?.toString();
      if (version == targetVersion) {
        return const AgentLifecycleResult(AgentLifecycleStatus.ready);
      }
      if (version != null && _compareVersions(version, targetVersion) > 0) {
        return const AgentLifecycleResult(
          AgentLifecycleStatus.downgradeRejected,
        );
      }
    }
    return AgentLifecycleResult(
      sawHealth ? AgentLifecycleStatus.versionFailed : AgentLifecycleStatus.healthFailed,
    );
  }

  static int _compareVersions(String left, String right) =>
      ReleaseVersion.parse(left).compareTo(ReleaseVersion.parse(right));

  static AgentLifecycleResult _bootstrapResult(
    AgentBootstrapResult result,
  ) => AgentLifecycleResult(switch (result.status) {
    AgentBootstrapStatus.networkFailed || AgentBootstrapStatus.downloadFailed => AgentLifecycleStatus.networkFailed,
    AgentBootstrapStatus.manifestInvalid => AgentLifecycleStatus.manifestInvalid,
    AgentBootstrapStatus.targetMismatch => AgentLifecycleStatus.targetMismatch,
    AgentBootstrapStatus.unsupportedTarget => AgentLifecycleStatus.unsupportedTarget,
    AgentBootstrapStatus.checksumFailed => AgentLifecycleStatus.checksumFailed,
    AgentBootstrapStatus.trustFailed => AgentLifecycleStatus.trustFailed,
    AgentBootstrapStatus.replacementFailed => AgentLifecycleStatus.replacementFailed,
    AgentBootstrapStatus.installed => AgentLifecycleStatus.ready,
  }, message: result.message);

  static AgentLifecycleStatus _agentStatus(String status) => switch (status) {
    'network_failed' => AgentLifecycleStatus.networkFailed,
    'manifest_invalid' => AgentLifecycleStatus.manifestInvalid,
    'target_mismatch' => AgentLifecycleStatus.targetMismatch,
    'downgrade_rejected' => AgentLifecycleStatus.downgradeRejected,
    'unsupported_target' => AgentLifecycleStatus.unsupportedTarget,
    'trust_failed' => AgentLifecycleStatus.trustFailed,
    'checksum_failed' => AgentLifecycleStatus.checksumFailed,
    'rollback_completed' => AgentLifecycleStatus.rollbackCompleted,
    'start_failed' => AgentLifecycleStatus.startFailed,
    'auth_failed' => AgentLifecycleStatus.authFailed,
    _ => AgentLifecycleStatus.replacementFailed,
  };

  @override
  bool isServiceInstalled() {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return false;
    }
    if (Platform.isWindows) {
      try {
        final result = Process.runSync('schtasks', [
          '/Query',
          '/TN',
          _windowsTaskName,
        ]);
        return result.exitCode == 0;
      } catch (_) {
        return false;
      }
    }
    final configPath = getServiceConfigPath();
    return File(configPath).existsSync();
  }

  String get _windowsTaskName {
    final instance = _serviceInstance();
    return instance.isEmpty ? 'SanadAgent' : 'SanadAgent-$instance';
  }

  @override
  bool get shouldAutoStart => isServiceInstalled();

  @override
  Future<bool> install() async {
    try {
      final execPath = getExecutablePath();
      if (!File(execPath).existsSync()) {
        _logger.info(
          'Agent executable is not present yet; service registration is deferred.',
        );
        return true;
      }
      final result = await Process.run(execPath, ['service', 'install']);
      _logger.info('Installed daemon service: exitCode=${result.exitCode}');
      if (result.exitCode != 0) {
        _logger.severe('Service install stdout: ${result.stdout}');
        _logger.severe('Service install stderr: ${result.stderr}');
      }
      return result.exitCode == 0;
    } catch (e) {
      _logger.severe('Failed to install service config: $e');
    }
    return false;
  }
}
