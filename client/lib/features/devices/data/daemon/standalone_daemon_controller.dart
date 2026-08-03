import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'local_daemon_controller.dart';
import 'verified_agent_bootstrap_installer.dart';
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_http_client.dart';

class StandaloneDaemonController implements LocalDaemonController {
  static final _logger = Logger('StandaloneDaemonController');

  const StandaloneDaemonController();

  LocalGatewayHttpClient get _gatewayClient => const LocalGatewayHttpClient();

  VerifiedAgentBootstrapInstaller createBootstrapInstaller() {
    return VerifiedAgentBootstrapInstaller(targetPath: getExecutablePath());
  }

  String getHomeDirectory() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? '';
    }
    return Platform.environment['HOME'] ?? '';
  }

  String getSanadHome() {
    return p.join(getHomeDirectory(), '.sanad');
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
    if (Platform.isMacOS) {
      return p.join(
        home,
        'Library',
        'LaunchAgents',
        'com.eaststarai.sanad.agent.plist',
      );
    } else if (Platform.isLinux) {
      return p.join(home, '.config', 'systemd', 'user', 'sanad-agent.service');
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
  Future<bool> updateDaemon({
    String? tag,
    void Function(double progress)? onProgress,
  }) async {
    if (!await isDaemonRunning()) {
      try {
        final installed = await createBootstrapInstaller().install(
          onProgress: onProgress,
        );
        if (!installed) return false;
        return install();
      } catch (e) {
        _logger.severe('Verified agent bootstrap failed: $e');
        return false;
      }
    }
    try {
      final response = await _gatewayClient
          .post(Uri.parse('${LocalDaemonController.defaultUrl}/update'))
          .timeout(const Duration(minutes: 2));
      if (response.statusCode != 200) return false;
      final body = jsonDecode(response.body);
      return body is Map && body['success'] == true;
    } catch (e) {
      _logger.severe('Daemon-owned update request failed: $e');
      return false;
    }
  }

  @override
  bool isServiceInstalled() {
    if (Platform.environment.containsKey('FLUTTER_TEST')) {
      return false;
    }
    final configPath = getServiceConfigPath();
    return File(configPath).existsSync();
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
