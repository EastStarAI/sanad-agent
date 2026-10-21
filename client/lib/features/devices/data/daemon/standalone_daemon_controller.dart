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
    this.processRunner,
    this.platformOverride,
    this.bootstrapInstallerFactory,
    this.healthProvider,
    this.executableProbeTimeout = defaultExecutableProbeTimeout,
  });

  /// Upper bound for a read-only probe of the installed executable. A legacy
  /// or damaged binary must never block pairing indefinitely.
  static const Duration defaultExecutableProbeTimeout = Duration(seconds: 20);

  final Duration executableProbeTimeout;

  final String? sanadHomePath;
  final Map<String, String>? environment;
  final Future<ProcessResult> Function(String executable, List<String> arguments)? processRunner;
  final String? platformOverride;

  /// Test seam for the verified bootstrap installer bound to a target path.
  final VerifiedAgentBootstrapInstaller Function(String targetPath)? bootstrapInstallerFactory;

  /// Test seam replacing the authenticated local `/health` probe.
  final Future<Map<String, dynamic>?> Function()? healthProvider;

  bool get _isLinux => platformOverride == 'linux' || (platformOverride == null && Platform.isLinux);

  bool get _isWindows => platformOverride == 'windows' || (platformOverride == null && Platform.isWindows);

  bool get _isMacOS => platformOverride == 'macos' || (platformOverride == null && Platform.isMacOS);

  List<String> get serviceInstallArguments => [
    'service',
    'install',
    if (_isLinux) '--user-scope',
  ];

  LocalGatewayHttpClient get _gatewayClient => const LocalGatewayHttpClient();

  VerifiedAgentBootstrapInstaller createBootstrapInstaller() {
    final targetPath = getExecutablePath();
    return bootstrapInstallerFactory?.call(targetPath) ?? VerifiedAgentBootstrapInstaller(targetPath: targetPath);
  }

  String getHomeDirectory() {
    final environment = this.environment ?? Platform.environment;
    if (_isWindows) {
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
    if (_isWindows) {
      return p.join(binDir, 'sanad.exe');
    }
    return p.join(binDir, 'sanad');
  }

  String getServiceConfigPath() {
    final home = getHomeDirectory();
    final instance = _serviceInstance();
    if (_isMacOS) {
      final label = instance.isEmpty ? 'com.eaststarai.sanad.agent' : 'com.eaststarai.sanad.agent.$instance';
      return p.join(home, 'Library', 'LaunchAgents', '$label.plist');
    } else if (_isLinux) {
      final name = instance.isEmpty ? 'sanad-agent.service' : 'sanad-agent-$instance.service';
      return p.join(home, '.config', 'systemd', 'user', name);
    }
    // For Windows, we don't have a plist/service file, we check the executable itself
    return getExecutablePath();
  }

  @override
  Future<bool> isDaemonRunning() async {
    final provider = healthProvider;
    if (provider != null) return await provider() != null;
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
    final health = await getDaemonHealth();
    return health?['version']?.toString();
  }

  @override
  Future<Map<String, dynamic>?> getDaemonHealth() async {
    final provider = healthProvider;
    if (provider != null) return provider();
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

  /// Environment for read-only executable probes. It pins the probed binary to
  /// the Home this controller manages, so a probe can never initialize a
  /// different Sanad Home.
  Map<String, String> get executableProbeEnvironment => {'SANAD_HOME': getSanadHome()};

  /// The version reported by the installed executable's `--version` output,
  /// including any prerelease suffix, or null when it is absent, unparseable,
  /// fails, or exceeds [executableProbeTimeout].
  Future<String?> getInstalledExecutableVersion() async {
    final execPath = getExecutablePath();
    if (!File(execPath).existsSync()) return null;
    final result = await _probeExecutable(execPath, const ['--version']);
    if (result == null || result.exitCode != 0) return null;
    return parseAgentVersionOutput(result.stdout.toString());
  }

  static final RegExp _versionLine = RegExp(
    r'^\s*Version:\s*v?(\d+\.\d+\.\d+(?:-[0-9A-Za-z.]+)?)\s*$',
    multiLine: true,
  );

  /// Parses only the dedicated `Version:` line every released agent prints.
  /// Other numbers, such as an OS or kernel version, are never accepted.
  static String? parseAgentVersionOutput(String output) {
    final raw = _versionLine.firstMatch(output)?.group(1);
    if (raw == null) return null;
    try {
      return ReleaseVersion.parse(raw).toString();
    } catch (_) {
      return null;
    }
  }

  /// Whether the installed executable accepts every option in
  /// [serviceInstallArguments].
  ///
  /// The probe is `sanad help service install`, which is read-only on every
  /// released agent. `service install --help` is never used: v1.0.0-v1.0.4
  /// ignored `--help` there and performed a real service installation.
  Future<bool> validateServiceInstallCompatibility() async {
    final requiredOptions = serviceInstallArguments.where((arg) => arg.startsWith('--')).toList();
    if (requiredOptions.isEmpty) return true;
    final execPath = getExecutablePath();
    if (!File(execPath).existsSync()) return false;
    final subcommands = serviceInstallArguments.takeWhile((arg) => !arg.startsWith('-'));
    final usage = await _probeExecutable(execPath, ['help', ...subcommands]);
    if (usage == null || usage.exitCode != 0) return false;
    final help = '${usage.stdout}\n${usage.stderr}';
    for (final option in requiredOptions) {
      final listed = RegExp('(?:^|[\\s,\\[])${RegExp.escape(option)}(?![\\w-])', multiLine: true);
      if (!listed.hasMatch(help)) {
        _logger.info('Installed agent does not support a required service option: $option');
        return false;
      }
    }
    return true;
  }

  Future<ProcessResult?> _probeExecutable(String execPath, List<String> arguments) async {
    try {
      final runner = processRunner;
      if (runner != null) {
        return await runner(execPath, arguments).timeout(executableProbeTimeout);
      }
      return await _runBoundedProcess(
        execPath,
        arguments,
        environment: executableProbeEnvironment,
        timeout: executableProbeTimeout,
      );
    } catch (error) {
      _logger.info('Installed agent probe failed (${error.runtimeType}).');
      return null;
    }
  }

  static Future<ProcessResult> _runBoundedProcess(
    String executable,
    List<String> arguments, {
    required Map<String, String> environment,
    required Duration timeout,
  }) async {
    final process = await Process.start(executable, arguments, environment: environment);
    // EOF on stdin ends any interactive fallback in an unexpected binary.
    unawaited(process.stdin.close().catchError((_) {}));
    final stdout = process.stdout.transform(systemEncoding.decoder).join();
    final stderr = process.stderr.transform(systemEncoding.decoder).join();
    try {
      final exitCode = await process.exitCode.timeout(timeout);
      return ProcessResult(process.pid, exitCode, await stdout, await stderr);
    } on TimeoutException {
      process.kill(ProcessSignal.sigkill);
      unawaited(stdout.then((_) {}, onError: (_) {}));
      unawaited(stderr.then((_) {}, onError: (_) {}));
      rethrow;
    }
  }

  @override
  Future<bool> startDaemon() async {
    try {
      final execPath = getExecutablePath();
      final runner = processRunner ?? Process.run;
      final result = await runner(execPath, ['service', 'start']);
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
      final runner = processRunner ?? Process.run;
      final result = await runner(execPath, ['service', 'stop']);
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
      return _updateStoppedAgent(targetVersion, onProgress);
    }

    // A running agent owns its own verified replacement through /update.
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

    final finalState = await _waitForTargetVersion(targetVersion);
    if (!finalState.isSuccess && await _restoreRollback(restart: true)) {
      return const AgentLifecycleResult(AgentLifecycleStatus.rollbackCompleted);
    }
    return finalState;
  }

  @override
  bool get ownsStoppedAgentLifecycle => true;

  /// Brings a stopped agent to [targetVersion] without contacting a daemon.
  ///
  /// A compatible executable at the target version is reused. A missing,
  /// older, unparseable, or incompatible executable is replaced through the
  /// verified bootstrap installer before any service registration, so an old
  /// binary is never invoked with options it does not support. A newer
  /// executable is never replaced; it is started when compatible, matching the
  /// behavior for a newer running agent.
  Future<AgentLifecycleResult> _updateStoppedAgent(
    String targetVersion,
    void Function(double progress)? onProgress,
  ) async {
    final executable = File(getExecutablePath());
    final replacesExisting = executable.existsSync();
    if (replacesExisting) {
      final installedVersion = await getInstalledExecutableVersion();
      if (installedVersion != null) {
        final comparison = _compareVersions(installedVersion, targetVersion);
        final compatible = comparison >= 0 && await validateServiceInstallCompatibility();
        if (comparison > 0) {
          if (compatible) await _registerAndStartService();
          return const AgentLifecycleResult(AgentLifecycleStatus.downgradeRejected);
        }
        if (comparison == 0 && compatible) {
          return await _registerAndStartService() ?? await _waitForTargetVersion(targetVersion);
        }
      }
    }

    try {
      final bootstrap = await createBootstrapInstaller().install(
        targetVersion: targetVersion,
        onProgress: onProgress,
      );
      if (!bootstrap.isSuccess) return _bootstrapResult(bootstrap);
    } catch (error) {
      _logger.severe('Verified agent bootstrap failed (${error.runtimeType}).');
      return AgentLifecycleResult(
        AgentLifecycleStatus.replacementFailed,
        message: 'Agent installation failed: $error',
      );
    }

    final outcome = await _registerAndStartService() ?? await _waitForTargetVersion(targetVersion);
    if (!outcome.isSuccess && replacesExisting && await _restoreRollback(restart: false)) {
      return AgentLifecycleResult(
        AgentLifecycleStatus.rollbackCompleted,
        message: 'The update failed and the previous agent was restored: ${outcome.actionableMessage}',
      );
    }
    return outcome;
  }

  /// Registers the service when needed and starts it. Returns null on success
  /// or the failing lifecycle result.
  Future<AgentLifecycleResult?> _registerAndStartService() async {
    if (!isServiceInstalled() || _isWindows) {
      final registration = await registerService();
      if (!registration.succeeded) {
        return AgentLifecycleResult(
          AgentLifecycleStatus.serviceRegistrationFailed,
          message: registration.failureMessage,
        );
      }
    }
    if (!await startDaemon()) {
      return const AgentLifecycleResult(AgentLifecycleStatus.startFailed);
    }
    return null;
  }

  /// Restores the executable preserved by the last verified replacement.
  ///
  /// With [restart] false the agent was stopped before the update, so the
  /// failed candidate is stopped and the previous copy is left stopped.
  Future<bool> _restoreRollback({required bool restart}) async {
    final target = File(getExecutablePath());
    final backup = File('${target.path}.rollback');
    if (!backup.existsSync()) return false;
    try {
      if (!restart) await stopDaemon();
      if (target.existsSync()) await target.delete();
      await backup.rename(target.path);
      if (!_isWindows) {
        final chmod = await Process.run('chmod', ['700', target.path]);
        if (chmod.exitCode != 0) return false;
      }
      return restart ? await startDaemon() : true;
    } catch (error) {
      _logger.severe(
        'Could not restore the previous agent after a failed update (${error.runtimeType}).',
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
    if (Platform.environment.containsKey('FLUTTER_TEST') && platformOverride == null) {
      return false;
    }
    if (_isWindows) {
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

  Future<ServiceRegistrationResult> registerService() async {
    try {
      final execPath = getExecutablePath();
      if (!File(execPath).existsSync()) {
        _logger.info(
          'Agent executable is not present yet; service registration is deferred.',
        );
        return const ServiceRegistrationResult(succeeded: true);
      }
      if (!await validateServiceInstallCompatibility()) {
        _logger.warning('Daemon service registration rejected: the installed agent lacks required service options.');
        return const ServiceRegistrationResult(
          succeeded: false,
          diagnostic: ServiceRegistrationResult.incompatibleExecutableDiagnostic,
        );
      }
      final runner = processRunner ?? Process.run;
      final result = await runner(execPath, serviceInstallArguments);
      if (result.exitCode != 0) {
        final detail = sanitizeServiceRegistrationOutput(
          stderr: result.stderr.toString(),
          stdout: result.stdout.toString(),
        );
        _logger.warning(
          'Daemon service registration failed (exitCode=${result.exitCode}, hasDiagnostic=${detail != null})',
        );
        return ServiceRegistrationResult(
          succeeded: false,
          diagnostic: detail,
        );
      }
      _logger.info('Installed daemon service: exitCode=0');
      return const ServiceRegistrationResult(succeeded: true);
    } catch (e) {
      final detail = sanitizeServiceRegistrationText(e.toString());
      _logger.warning(
        'Failed to install service config (hasDiagnostic=${detail != null})',
      );
      return ServiceRegistrationResult(
        succeeded: false,
        diagnostic: detail,
      );
    }
  }

  @override
  Future<bool> install() async {
    final result = await registerService();
    return result.succeeded;
  }

  static String? sanitizeServiceRegistrationOutput({
    String? stderr,
    String? stdout,
  }) {
    final raw = (stderr != null && stderr.trim().isNotEmpty)
        ? stderr
        : (stdout != null && stdout.trim().isNotEmpty)
        ? stdout
        : null;
    if (raw == null) return null;
    return sanitizeServiceRegistrationText(raw);
  }

  static String? sanitizeServiceRegistrationText(String raw) {
    final noAnsi = raw.replaceAll(
      RegExp(r'\x1B\[[0-9;]*[a-zA-Z]|\x1B[@-Z\\-_]'),
      '',
    );
    final noControl = noAnsi.replaceAll(
      RegExp(r'[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
      ' ',
    );
    final lines = noControl.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    if (lines.isEmpty) return null;

    String candidate = lines.first;
    for (final line in lines) {
      if (line.toLowerCase().startsWith('service operation failed:')) {
        candidate = line;
        break;
      }
    }

    if (candidate.toLowerCase().startsWith('service operation failed:')) {
      candidate = candidate.substring(candidate.indexOf(':') + 1).trim();
    }

    if (RegExp(
      r'(#\d+\s+|dart:|package:|Unhandled exception:|Exception:|Traceback|at\s+[\w\.]+)',
      caseSensitive: false,
    ).hasMatch(candidate)) {
      return null;
    }
    if (RegExp(
      r'(token|bearer|password|secret|private[_-]?key)',
      caseSensitive: false,
    ).hasMatch(candidate)) {
      return null;
    }
    if (RegExp(
      r'(sudo\s|systemctl\s|rc-service\s|powershell|launchctl|install\s+-m|useradd\s|chown\s|chmod\s)',
      caseSensitive: false,
    ).hasMatch(candidate)) {
      return null;
    }
    if (candidate.startsWith('{') ||
        candidate.startsWith('[') ||
        candidate.startsWith('<') ||
        candidate.contains('```')) {
      return null;
    }

    candidate = candidate.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (candidate.isEmpty) return null;

    if (candidate.length > 120) {
      candidate = candidate.substring(0, 120).trim();
    }
    return candidate;
  }
}

class ServiceRegistrationResult {
  const ServiceRegistrationResult({
    required this.succeeded,
    this.diagnostic,
  });

  static const String incompatibleExecutableDiagnostic =
      'The installed agent does not support the required service options. Update the agent and try again.';

  static const String defaultFailureMessage =
      'The agent was downloaded but its background service could not be registered.';

  final bool succeeded;
  final String? diagnostic;

  String get failureMessage {
    final diag = diagnostic?.trim();
    if (diag != null && diag.isNotEmpty) {
      final base = defaultFailureMessage.endsWith('.')
          ? defaultFailureMessage.substring(0, defaultFailureMessage.length - 1)
          : defaultFailureMessage;
      final cleanDiag = diag.endsWith('.') ? diag.substring(0, diag.length - 1) : diag;
      return '$base: $cleanDiag.';
    }
    return defaultFailureMessage;
  }
}
