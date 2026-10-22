import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:meta/meta.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/setup/cli_path_manager.dart';
import 'package:sanad_agent/core/setup/linux_service_manager.dart';
import 'package:sanad_agent/core/setup/service_health_verifier.dart';
import 'package:sanad_agent/core/setup/service_models.dart';
import 'package:sanad_agent/core/setup/windows_launcher_bundle.dart';

export 'service_models.dart';

class ServiceManager {
  static String get _instance {
    final value = Platform.environment['SANAD_SERVICE_INSTANCE']?.trim() ?? '';
    if (value.isEmpty) return '';
    if (!RegExp(r'^[A-Za-z0-9-]{1,32}$').hasMatch(value)) {
      throw const FormatException('Invalid SANAD_SERVICE_INSTANCE.');
    }
    return value;
  }

  static String get label => _instance.isEmpty
      ? 'com.eaststarai.sanad.agent'
      : 'com.eaststarai.sanad.agent.$_instance';
  static String get serviceName => _instance.isEmpty
      ? 'sanad-agent.service'
      : 'sanad-agent-$_instance.service';
  static String get taskName =>
      _instance.isEmpty ? 'SanadAgent' : 'SanadAgent-$_instance';

  /// Runs one `launchctl` invocation.
  ///
  /// Tests replace it so the launchd lifecycle can be exercised without a real
  /// user domain.
  @visibleForTesting
  static Future<ProcessResult> Function(List<String> arguments) launchctl =
      (arguments) => Process.run('launchctl', arguments);

  /// The uid that names the `gui` domain [launchdBootoutArguments] targets.
  ///
  /// Tests replace it so a stop does not depend on the account running them.
  @visibleForTesting
  static Future<int> Function() launchdUserId = _readLaunchdUserId;

  static Future<int> _readLaunchdUserId() async {
    final result = await Process.run('id', ['-u']);
    final uid = int.tryParse(result.stdout.toString().trim());
    if (uid == null) {
      throw const FormatException('The current user id is unavailable.');
    }
    return uid;
  }

  static String getHomeDirectory() => Platform.isWindows
      ? Platform.environment['USERPROFILE'] ?? ''
      : Platform.environment['HOME'] ?? '';

  static String getServiceConfigPath() {
    final home = getHomeDirectory();
    if (Platform.isMacOS) {
      return p.join(home, 'Library', 'LaunchAgents', '$label.plist');
    }
    if (Platform.isLinux) {
      return p.join(home, '.config', 'systemd', 'user', serviceName);
    }
    return '';
  }

  static Future<ServiceOperationResult> install({
    ServiceHealthExpectation? healthExpectation,
    bool userScope = false,
  }) async {
    final sanadHome = getSanadHome();
    await SanadHomeBootstrap.identity().ensureDirectoryPath('logs');
    final invocation = _daemonInvocation();
    if (Platform.isLinux) {
      final result = await _linux(
        invocation,
        healthExpectation: healthExpectation,
        userScope: userScope,
      ).install();
      if (result.success) await CliPathManager.ensureOnPath();
      return result;
    }
    if (Platform.isMacOS) {
      final configPath = getServiceConfigPath();
      final content = buildLaunchdPlist(
        executable: invocation.executable,
        arguments: invocation.arguments,
        sanadHome: sanadHome,
      );
      try {
        final file = File(configPath);
        await file.parent.create(recursive: true);
        await file.writeAsString(content, flush: true);
        await launchctl(['unload', configPath]);
        final activated = await launchctl(['load', configPath]);
        final status = await getStatus();
        if (activated.exitCode == 0 && status.running) {
          await CliPathManager.ensureOnPath();
          return ServiceOperationResult(success: true, status: status);
        }
        return _failure(status, _processError(activated));
      } catch (error) {
        return _failure(await getStatus(), _concise(error));
      }
    }
    if (Platform.isWindows) {
      try {
        final launcherPath = await WindowsLauncherBundle.install(
          agentExecutable: invocation.executable,
          binDirectory: p.dirname(invocation.executable),
        );
        if (launcherPath == null && !invocation.isDartVm) {
          return _failure(
            await getStatus(),
            'The packaged Windows Agent does not contain its background launcher.',
          );
        }
        final daemonCommand = launcherPath == null
            ? buildWindowsDaemonCommand(
                executable: invocation.executable,
                arguments: invocation.arguments,
                sanadHome: sanadHome,
                serviceInstance: _instance,
              )
            : null;
        final registrationCommand = buildWindowsTaskRegistrationCommand(
          encodedDaemonCommand: daemonCommand == null
              ? null
              : encodePowerShellCommand(daemonCommand),
          launcherExecutable: launcherPath,
          sanadHome: sanadHome,
          taskName: taskName,
          serviceInstance: _instance,
        );
        final result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-EncodedCommand',
          encodePowerShellCommand(registrationCommand),
        ]);
        final status = await getStatus();
        if (result.exitCode == 0 && status.running) {
          await CliPathManager.ensureOnPath();
          return ServiceOperationResult(success: true, status: status);
        }
        return _failure(status, _processError(result));
      } catch (error) {
        return _failure(await getStatus(), _concise(error));
      }
    }
    return _unsupported();
  }

  static Future<ServiceOperationResult> uninstall() async {
    if (Platform.isLinux) return _linux(_daemonInvocation()).uninstall();
    try {
      ProcessResult result;
      if (Platform.isMacOS) {
        final path = getServiceConfigPath();
        result = await launchctl(['unload', path]);
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } else if (Platform.isWindows) {
        result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          buildWindowsTaskUnregistrationCommand(taskName),
        ]);
      } else {
        return _unsupported();
      }
      final status = Platform.isWindows
          ? await _waitForWindowsTaskMissing()
          : await getStatus();
      final success =
          !status.installed &&
          (result.exitCode == 0 || status.state == ServiceState.missing);
      return ServiceOperationResult(
        success: success,
        status: status,
        error: success ? null : _processError(result),
      );
    } catch (error) {
      return _failure(await getStatus(), _concise(error));
    }
  }

  static Future<ServiceOperationResult> start() => _lifecycle('start');
  static Future<ServiceOperationResult> stop() => _lifecycle('stop');

  static Future<ServiceOperationResult> restart() async {
    if (Platform.isLinux) return _linux(_daemonInvocation()).restart();
    if (Platform.isMacOS) {
      await _lifecycle('stop');
      return _lifecycle('start');
    }
    return _lifecycle('restart');
  }

  static Future<ServiceOperationResult> _lifecycle(String command) async {
    if (Platform.isLinux) {
      final manager = _linux(_daemonInvocation());
      return command == 'start' ? manager.start() : manager.stop();
    }
    try {
      ProcessResult result;
      if (Platform.isMacOS) {
        result = await _launchdLifecycle(command);
      } else if (Platform.isWindows) {
        final verb = switch (command) {
          'start' => 'Start',
          'stop' => 'Stop',
          _ => 'Start',
        };
        if (command == 'restart') {
          await Process.run('powershell.exe', [
            '-NoProfile',
            '-NonInteractive',
            '-Command',
            'Stop-ScheduledTask -TaskName "${_escapePowerShellLiteral(taskName)}"',
          ]);
        }
        result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '$verb-ScheduledTask -TaskName "${_escapePowerShellLiteral(taskName)}"',
        ]);
      } else {
        return _unsupported();
      }
      final status = await getStatus();
      final expected = command == 'stop' ? !status.running : status.running;
      return ServiceOperationResult(
        success: result.exitCode == 0 && expected,
        status: status,
        error: result.exitCode == 0 ? status.error : _processError(result),
      );
    } catch (error) {
      return _failure(await getStatus(), _concise(error));
    }
  }

  /// Runs the `launchctl` steps for one lifecycle command until one succeeds.
  static Future<ProcessResult> _launchdLifecycle(String command) async {
    final plan = launchdLifecyclePlan(
      command: command,
      configPath: getServiceConfigPath(),
      label: label,
      // Only a stop needs the `gui` domain target. Resolving it before any
      // step also keeps a stop from falling back to signalling when the
      // domain name is unavailable.
      userId: await launchdUserId(),
    );
    var result = await launchctl(plan.first);
    for (final arguments in plan.skip(1)) {
      if (result.exitCode == 0) break;
      result = await launchctl(arguments);
    }
    return result;
  }

  /// The ordered `launchctl` invocations for one lifecycle command.
  ///
  /// The first step targets the plist path this Agent installed. The second is
  /// the fallback for a job that is loaded from somewhere else.
  ///
  /// A stop must unload the job rather than signal it. The plist keeps
  /// `KeepAlive { SuccessfulExit = false }`, so the daemon's signal exit status
  /// (`143` for `SIGTERM`) counts as an unsuccessful exit and `launchctl stop`
  /// would make `launchd` launch the Agent again. `bootout` removes the job
  /// from the user's domain, so nothing can respawn it.
  static List<List<String>> launchdLifecyclePlan({
    required String command,
    required String configPath,
    required String label,
    required int userId,
  }) => command == 'stop'
      ? <List<String>>[
          <String>['unload', configPath],
          launchdBootoutArguments(label: label, userId: userId),
        ]
      : <List<String>>[
          <String>['load', configPath],
          <String>['start', label],
        ];

  /// The `launchctl` target that unloads [label] from the caller's `gui`
  /// domain.
  static List<String> launchdBootoutArguments({
    required String label,
    required int userId,
  }) => <String>['bootout', 'gui/$userId/$label'];

  static Future<ServiceStatus> getStatus() async {
    if (Platform.isLinux) return _linux(_daemonInvocation()).status();
    if (Platform.isMacOS) {
      final path = getServiceConfigPath();
      if (!File(path).existsSync()) {
        return const ServiceStatus.missing(
          scope: ServiceScope.launchdUser,
          backend: 'launchd',
        );
      }
      try {
        final result = await launchctl(['list', label]);
        final running = result.exitCode == 0;
        return ServiceStatus(
          state: running ? ServiceState.running : ServiceState.installedStopped,
          scope: ServiceScope.launchdUser,
          backend: 'launchd',
          installed: true,
          enabled: true,
          running: running,
          error: running ? null : _processError(result),
          configPath: path,
        );
      } catch (error) {
        return ServiceStatus(
          state: ServiceState.managerUnavailable,
          scope: ServiceScope.launchdUser,
          backend: 'launchd',
          installed: true,
          enabled: false,
          running: false,
          error: _concise(error),
          configPath: path,
        );
      }
    }
    if (Platform.isWindows) {
      try {
        final result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          '(Get-ScheduledTask -TaskName "${_escapePowerShellLiteral(taskName)}").State',
        ]);
        if (result.exitCode != 0) {
          return const ServiceStatus.missing(
            scope: ServiceScope.windowsTask,
            backend: 'windows-task',
          );
        }
        final raw = result.stdout.toString().trim().toLowerCase();
        final running = raw == 'running';
        return ServiceStatus(
          state: running ? ServiceState.running : ServiceState.installedStopped,
          scope: ServiceScope.windowsTask,
          backend: 'windows-task',
          installed: true,
          enabled: raw != 'disabled',
          running: running,
        );
      } catch (error) {
        return ServiceStatus(
          state: ServiceState.managerUnavailable,
          scope: ServiceScope.windowsTask,
          backend: 'windows-task',
          installed: false,
          enabled: false,
          running: false,
          error: _concise(error),
        );
      }
    }
    return const ServiceStatus(
      state: ServiceState.managerUnavailable,
      scope: ServiceScope.unavailable,
      backend: 'none',
      installed: false,
      enabled: false,
      running: false,
      error: 'Service management is not supported on this platform.',
    );
  }

  static Future<ServiceStatus> _waitForWindowsTaskMissing() async {
    for (var attempt = 0; attempt < 20; attempt++) {
      final query = await Process.run('schtasks.exe', [
        '/Query',
        '/TN',
        taskName,
      ]);
      if (query.exitCode != 0) {
        return const ServiceStatus.missing(
          scope: ServiceScope.windowsTask,
          backend: 'windows-task',
        );
      }
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    return getStatus();
  }

  static LinuxServiceManager _linux(
    _DaemonInvocation invocation, {
    ServiceHealthExpectation? healthExpectation,
    bool userScope = false,
  }) => LinuxServiceManager(
    serviceName: serviceName,
    executable: invocation.executable,
    arguments: invocation.arguments,
    sanadHome: getSanadHome(),
    loginHome: getHomeDirectory(),
    environment: Platform.environment,
    userScope: userScope,
    runner: (executable, arguments, environment) async {
      final result = await Process.run(
        executable,
        arguments,
        environment: environment,
      );
      return ServiceProcessResult(
        exitCode: result.exitCode,
        stdout: result.stdout.toString(),
        stderr: result.stderr.toString(),
      );
    },
    postActivationVerification: healthExpectation == null
        ? null
        : () async {
            final result = await ServiceHealthVerifier().verify(
              healthExpectation,
            );
            return result.success ? null : result.error;
          },
  );

  /// The service instance this process registers (empty for the default).
  static String get serviceInstance => _instance;

  /// The executable and arguments `install` writes into the definition.
  static ({String executable, List<String> arguments}) daemonInvocation() {
    final invocation = _daemonInvocation();
    return (executable: invocation.executable, arguments: invocation.arguments);
  }

  static _DaemonInvocation _daemonInvocation() {
    final executable = Platform.resolvedExecutable;
    final isDartVm =
        executable.contains('dart-sdk') ||
        executable.endsWith('dart') ||
        executable.endsWith('dart.exe');
    return _DaemonInvocation(
      executable,
      isDartVm ? [Platform.script.toFilePath(), 'daemon'] : const ['daemon'],
      isDartVm: isDartVm,
    );
  }

  static String buildLaunchdPlist({
    required String executable,
    required List<String> arguments,
    required String sanadHome,
    String? serviceInstance,
  }) {
    final instance = serviceInstance ?? _instance;
    final label = instance.isEmpty
        ? 'com.eaststarai.sanad.agent'
        : 'com.eaststarai.sanad.agent.$instance';
    return '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${_xml(label)}</string>
<key>ProgramArguments</key><array><string>${_xml(executable)}</string>${arguments.map((value) => '<string>${_xml(value)}</string>').join()}</array>
<key>WorkingDirectory</key><string>${_xml(sanadHome)}</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>${_xml(p.join(sanadHome, 'logs', 'daemon.log'))}</string>
<key>StandardErrorPath</key><string>${_xml(p.join(sanadHome, 'logs', 'daemon.error.log'))}</string>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string><key>SANAD_HOME</key><string>${_xml(sanadHome)}</string>${instance.isEmpty ? '' : '<key>SANAD_SERVICE_INSTANCE</key><string>${_xml(instance)}</string>'}</dict>
</dict></plist>
''';
  }

  static String buildWindowsDaemonCommand({
    required String executable,
    required List<String> arguments,
    required String sanadHome,
    required String serviceInstance,
  }) {
    final escapedArguments = arguments
        .map((argument) => "'${_escapePowerShellLiteral(argument)}'")
        .join(' ');
    return '''\$ErrorActionPreference = 'Stop'
\$env:SANAD_HOME = '${_escapePowerShellLiteral(sanadHome)}'
${serviceInstance.isEmpty ? '' : "\$env:SANAD_SERVICE_INSTANCE = '${_escapePowerShellLiteral(serviceInstance)}'\n"}& '${_escapePowerShellLiteral(executable)}' $escapedArguments
exit \$LASTEXITCODE
''';
  }

  static String buildWindowsTaskRegistrationCommand({
    String? encodedDaemonCommand,
    String? launcherExecutable,
    required String sanadHome,
    required String taskName,
    String serviceInstance = '',
  }) {
    if ((encodedDaemonCommand == null) == (launcherExecutable == null)) {
      throw ArgumentError('Specify exactly one Windows daemon host.');
    }
    final action = launcherExecutable == null
        ? "New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedDaemonCommand'"
        : "New-ScheduledTaskAction -Execute '${_escapePowerShellLiteral(launcherExecutable)}' -Argument '${_escapePowerShellLiteral(_windowsLauncherArguments(sanadHome, serviceInstance))}'";
    return '''\$ErrorActionPreference = 'Stop'
\$action = $action -WorkingDirectory '${_escapePowerShellLiteral(sanadHome)}'
\$trigger = New-ScheduledTaskTrigger -AtLogOn -User \$env:USERNAME
\$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
Register-ScheduledTask -TaskName '${_escapePowerShellLiteral(taskName)}' -Action \$action -Trigger \$trigger -Settings \$settings -Force | Out-Null
Start-ScheduledTask -TaskName '${_escapePowerShellLiteral(taskName)}'
''';
  }

  static String buildWindowsTaskUnregistrationCommand(String taskName) {
    final escaped = _escapePowerShellLiteral(taskName);
    return '\$task = Get-ScheduledTask -TaskName "$escaped" -ErrorAction SilentlyContinue; '
        'if (\$null -ne \$task) { '
        'if (\$task.State -eq "Running") { Stop-ScheduledTask -TaskName "$escaped" }; '
        'Unregister-ScheduledTask -TaskName "$escaped" -Confirm:\$false }';
  }

  static String _windowsLauncherArguments(
    String sanadHome,
    String serviceInstance,
  ) {
    final buffer = StringBuffer('--home "${sanadHome.replaceAll('"', '')}"');
    if (serviceInstance.isNotEmpty) {
      buffer.write(' --service-instance "$serviceInstance"');
    }
    return buffer.toString();
  }

  static String encodePowerShellCommand(String command) {
    final bytes = BytesBuilder(copy: false);
    for (final codeUnit in command.codeUnits) {
      bytes.add([codeUnit & 0xff, codeUnit >> 8]);
    }
    return base64Encode(bytes.takeBytes());
  }

  static String _escapePowerShellLiteral(String value) =>
      value.replaceAll("'", "''");
  static String _xml(String value) => value
      .replaceAll('&', '&amp;')
      .replaceAll('<', '&lt;')
      .replaceAll('>', '&gt;')
      .replaceAll('"', '&quot;')
      .replaceAll("'", '&apos;');
  static String _processError(ProcessResult result) {
    final value = result.stderr.toString().trim().isNotEmpty
        ? result.stderr.toString().trim()
        : result.stdout.toString().trim();
    return value.isEmpty
        ? 'Service manager exited with code ${result.exitCode}.'
        : value.split('\n').first;
  }

  static String _concise(Object error) => error.toString().split('\n').first;
  static ServiceOperationResult _failure(ServiceStatus status, String error) =>
      ServiceOperationResult(success: false, status: status, error: error);
  static ServiceOperationResult _unsupported() => const ServiceOperationResult(
    success: false,
    status: ServiceStatus(
      state: ServiceState.managerUnavailable,
      scope: ServiceScope.unavailable,
      backend: 'none',
      installed: false,
      enabled: false,
      running: false,
      error: 'Service management is not supported on this platform.',
    ),
    error: 'Service management is not supported on this platform.',
  );
}

class _DaemonInvocation {
  const _DaemonInvocation(
    this.executable,
    this.arguments, {
    required this.isDartVm,
  });
  final String executable;
  final List<String> arguments;
  final bool isDartVm;
}
