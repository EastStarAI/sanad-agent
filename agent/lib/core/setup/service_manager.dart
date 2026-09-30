import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/setup/cli_path_manager.dart';
import 'package:sanad_agent/core/setup/linux_service_manager.dart';
import 'package:sanad_agent/core/setup/service_health_verifier.dart';
import 'package:sanad_agent/core/setup/service_models.dart';

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
  }) async {
    final sanadHome = getSanadHome();
    await SanadHomeBootstrap.identity().ensureDirectoryPath('logs');
    final invocation = _daemonInvocation();
    if (Platform.isLinux) {
      final result = await _linux(
        invocation,
        healthExpectation: healthExpectation,
      ).install();
      if (result.success) await CliPathManager.ensureOnPath();
      return result;
    }
    if (Platform.isMacOS) {
      final configPath = getServiceConfigPath();
      final content = _buildLaunchdPlist(
        executable: invocation.executable,
        arguments: invocation.arguments,
        sanadHome: sanadHome,
      );
      try {
        final file = File(configPath);
        await file.parent.create(recursive: true);
        await file.writeAsString(content, flush: true);
        await Process.run('launchctl', ['unload', configPath]);
        final activated = await Process.run('launchctl', ['load', configPath]);
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
      final daemonCommand = buildWindowsDaemonCommand(
        executable: invocation.executable,
        arguments: invocation.arguments,
        sanadHome: sanadHome,
        serviceInstance: _instance,
      );
      final registrationCommand = buildWindowsTaskRegistrationCommand(
        encodedDaemonCommand: encodePowerShellCommand(daemonCommand),
        sanadHome: sanadHome,
        taskName: taskName,
      );
      try {
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
        result = await Process.run('launchctl', ['unload', path]);
        final file = File(path);
        if (file.existsSync()) await file.delete();
      } else if (Platform.isWindows) {
        result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          'Unregister-ScheduledTask -TaskName "${_escapePowerShellLiteral(taskName)}" -Confirm:\$false',
        ]);
      } else {
        return _unsupported();
      }
      final status = await getStatus();
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
        final path = getServiceConfigPath();
        result = command == 'start'
            ? await Process.run('launchctl', ['load', path])
            : await Process.run('launchctl', ['unload', path]);
        if (result.exitCode != 0) {
          result = await Process.run('launchctl', [command, label]);
        }
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
        final result = await Process.run('launchctl', ['list', label]);
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

  static LinuxServiceManager _linux(
    _DaemonInvocation invocation, {
    ServiceHealthExpectation? healthExpectation,
  }) => LinuxServiceManager(
    serviceName: serviceName,
    executable: invocation.executable,
    arguments: invocation.arguments,
    sanadHome: getSanadHome(),
    loginHome: getHomeDirectory(),
    environment: Platform.environment,
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

  static _DaemonInvocation _daemonInvocation() {
    final executable = Platform.resolvedExecutable;
    final isDartVm =
        executable.contains('dart-sdk') ||
        executable.endsWith('dart') ||
        executable.endsWith('dart.exe');
    return _DaemonInvocation(
      executable,
      isDartVm ? [Platform.script.toFilePath(), 'daemon'] : const ['daemon'],
    );
  }

  static String _buildLaunchdPlist({
    required String executable,
    required List<String> arguments,
    required String sanadHome,
  }) =>
      '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>${_xml(label)}</string>
<key>ProgramArguments</key><array><string>${_xml(executable)}</string>${arguments.map((value) => '<string>${_xml(value)}</string>').join()}</array>
<key>WorkingDirectory</key><string>${_xml(sanadHome)}</string>
<key>RunAtLoad</key><true/><key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
<key>Umask</key><integer>63</integer>
<key>StandardOutPath</key><string>${_xml(p.join(sanadHome, 'logs', 'daemon.log'))}</string>
<key>StandardErrorPath</key><string>${_xml(p.join(sanadHome, 'logs', 'daemon.error.log'))}</string>
<key>EnvironmentVariables</key><dict><key>PATH</key><string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string><key>SANAD_HOME</key><string>${_xml(sanadHome)}</string>${_instance.isEmpty ? '' : '<key>SANAD_SERVICE_INSTANCE</key><string>${_xml(_instance)}</string>'}</dict>
</dict></plist>
''';

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
    required String encodedDaemonCommand,
    required String sanadHome,
    required String taskName,
  }) =>
      '''\$ErrorActionPreference = 'Stop'
\$action = New-ScheduledTaskAction -Execute 'powershell.exe' -Argument '-NoProfile -NonInteractive -WindowStyle Hidden -EncodedCommand $encodedDaemonCommand' -WorkingDirectory '${_escapePowerShellLiteral(sanadHome)}'
\$trigger = New-ScheduledTaskTrigger -AtLogOn -User \$env:USERNAME
\$settings = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries -DontStopIfGoingOnBatteries -StartWhenAvailable -MultipleInstances IgnoreNew -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) -ExecutionTimeLimit (New-TimeSpan -Seconds 0)
Register-ScheduledTask -TaskName '${_escapePowerShellLiteral(taskName)}' -Action \$action -Trigger \$trigger -Settings \$settings -Force | Out-Null
Start-ScheduledTask -TaskName '${_escapePowerShellLiteral(taskName)}'
''';

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
  const _DaemonInvocation(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
}
