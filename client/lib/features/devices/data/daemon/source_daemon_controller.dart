import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_client/infrastructure/local_gateway/local_gateway_http_client.dart';
import 'local_daemon_controller.dart';

class SourceDaemonController implements LocalDaemonController {
  static final _logger = Logger('SourceDaemonController');

  static Process? _spawnedProcess;

  const SourceDaemonController();

  LocalGatewayHttpClient get _gatewayClient => const LocalGatewayHttpClient();

  Directory? _findAgentSourceDir() {
    var dir = Directory.current;
    for (var i = 0; i < 12; i++) {
      final agentDir = Directory(p.join(dir.path, 'agent'));
      final entryScript = File(
        p.join(agentDir.path, 'bin', 'sanad_agent.dart'),
      );
      if (entryScript.existsSync()) {
        return agentDir;
      }

      final nestedAgentDir = Directory(
        p.join(dir.path, 'sanad-agent', 'agent'),
      );
      final nestedEntryScript = File(
        p.join(nestedAgentDir.path, 'bin', 'sanad_agent.dart'),
      );
      if (nestedEntryScript.existsSync()) {
        return nestedAgentDir;
      }

      if (dir.path == dir.parent.path) break;
      dir = dir.parent;
    }
    return null;
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
  Future<bool> startDaemon() async {
    final running = await isDaemonRunning();
    if (running) {
      _logger.info(
        'Local daemon is already running (manually or via other process). Connecting directly.',
      );
      return true;
    }

    final agentDir = _findAgentSourceDir();
    if (agentDir == null) {
      _logger.severe(
        'Could not find agent source directory containing "bin/sanad_agent.dart" in the workspace paths.',
      );
      return false;
    }

    _logger.info('Spawning source-based agent daemon in: ${agentDir.path}');

    try {
      final process = await Process.start(
        'fvm',
        ['dart', 'run', 'bin/sanad_agent.dart', 'daemon'],
        workingDirectory: agentDir.path,
        runInShell: Platform.isWindows,
      );

      _spawnedProcess = process;

      // Handle unexpected exits
      unawaited(
        process.exitCode.then((code) async {
          if (_spawnedProcess == process) {
            _logger.warning(
              'Source agent daemon process exited unexpectedly with code $code. Restarting...',
            );
            _spawnedProcess = null;
            await Future.delayed(const Duration(milliseconds: 1000));
            await startDaemon();
          }
        }),
      );

      // Wait a moment for agent to bind and listen
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      return await isDaemonRunning();
    } catch (e) {
      _logger.severe('Failed to start local agent daemon process: $e');
      return false;
    }
  }

  @override
  Future<bool> stopDaemon() async {
    final processToKill = _spawnedProcess;
    _spawnedProcess = null; // Clear first to prevent auto-restart in exit listener

    final running = await isDaemonRunning();
    if (running) {
      try {
        _logger.info('Requesting source shutdown via HTTP POST /stop...');
        final uri = Uri.parse('${LocalDaemonController.defaultUrl}/stop');
        final response = await _gatewayClient.post(uri).timeout(const Duration(seconds: 2));
        if (response.statusCode == 200) {
          await Future<void>.delayed(const Duration(milliseconds: 500));
          processToKill?.kill();
          return true;
        }
      } catch (e) {
        _logger.severe('Failed to request remote shutdown: $e');
      }
    }

    if (processToKill != null) {
      _logger.info('Killing spawned process directly...');
      processToKill.kill();
      await processToKill.exitCode;
      return true;
    }
    return false;
  }

  @override
  Future<bool> restartDaemon() async {
    // Every running source daemon must use the checkpoint-safe endpoint. A
    // direct stop/start would silently turn a safety timeout into a force kill.
    final running = await isDaemonRunning();
    if (running) {
      try {
        _logger.info(
          'Requesting manual source restart via HTTP POST /restart...',
        );
        final uri = Uri.parse('${LocalDaemonController.defaultUrl}/restart').replace(
          queryParameters: {
            'timeout_seconds': LocalDaemonController.restartSafetyTimeout.inSeconds.toString(),
          },
        );
        final response = await _gatewayClient.post(uri).timeout(LocalDaemonController.restartRequestTimeout);
        if (response.statusCode == 200) {
          // Wait for supervisor or manual runner to restart it
          await Future<void>.delayed(const Duration(milliseconds: 1500));
          return await isDaemonRunning();
        }
      } catch (e) {
        _logger.severe('Failed to request remote restart: $e');
      }
    }
    return false;
  }

  @override
  Future<AgentLifecycleResult> updateDaemon({
    required String targetVersion,
    void Function(double progress)? onProgress,
  }) async {
    // Source runs never execute Git, FVM, or package-manager commands.
    final running = await isDaemonRunning();
    if (running) {
      try {
        final uri = Uri.parse(
          '${LocalDaemonController.defaultUrl}/update',
        ).replace(queryParameters: {'target_version': targetVersion});
        final response = await _gatewayClient.post(uri).timeout(const Duration(seconds: 15));
        if (response.statusCode == 200) {
          final body = jsonDecode(response.body);
          if (body is Map && body['status'] == 'source_managed') {
            return const AgentLifecycleResult(
              AgentLifecycleStatus.sourceManaged,
            );
          }
        }
      } catch (error) {
        _logger.severe('Failed to query source update ownership: $error');
        return AgentLifecycleResult(
          AgentLifecycleStatus.networkFailed,
          message: 'Could not query the source-managed agent: $error',
        );
      }
    }

    return const AgentLifecycleResult(
      AgentLifecycleStatus.sourceManaged,
      message: 'Source agent updates remain developer-managed.',
    );
  }

  @override
  bool isServiceInstalled() => true; // Dev mode source is considered installed

  @override
  bool get shouldAutoStart => false;

  @override
  Future<bool> install() async => true; // No-op in dev mode
}
