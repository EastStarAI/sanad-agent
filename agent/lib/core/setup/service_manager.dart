import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';

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

  static String getHomeDirectory() {
    if (Platform.isWindows) {
      return Platform.environment['USERPROFILE'] ?? '';
    }
    return Platform.environment['HOME'] ?? '';
  }

  static String getServiceConfigPath() {
    final home = getHomeDirectory();
    if (Platform.isMacOS) {
      return p.join(home, 'Library', 'LaunchAgents', '$label.plist');
    } else if (Platform.isLinux) {
      return p.join(home, '.config', 'systemd', 'user', serviceName);
    }
    return '';
  }

  static bool isServiceInstalled() {
    if (Platform.isWindows) {
      try {
        final result = Process.runSync('schtasks', ['/Query', '/TN', taskName]);
        return result.exitCode == 0;
      } catch (_) {
        return false;
      }
    } else {
      final path = getServiceConfigPath();
      if (path.isEmpty) return false;
      return File(path).existsSync();
    }
  }

  static Future<bool> install() async {
    final sanadHome = getSanadHome();
    await SanadHomeBootstrap.identity().ensureDirectoryPath('logs');
    final execPath = Platform.resolvedExecutable;
    final isDartVM =
        execPath.contains('dart-sdk') ||
        execPath.endsWith('dart') ||
        execPath.endsWith('dart.exe');

    final String finalExec;
    final List<String> args;

    if (isDartVM) {
      finalExec = execPath;
      args = [Platform.script.toFilePath(), 'daemon'];
    } else {
      finalExec = execPath;
      args = ['daemon'];
    }

    try {
      if (Platform.isMacOS) {
        final configPath = getServiceConfigPath();
        final plistContent =
            '''<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>$label</string>
    <key>ProgramArguments</key>
    <array>
        <string>$finalExec</string>
        ${args.map((a) => '<string>$a</string>').join('\n        ')}
    </array>
    <key>WorkingDirectory</key>
    <string>$sanadHome</string>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>Umask</key>
    <integer>63</integer>
    <key>StandardOutPath</key>
    <string>$sanadHome/logs/daemon.log</string>
    <key>StandardErrorPath</key>
    <string>$sanadHome/logs/daemon.error.log</string>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PATH</key>
        <string>/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin</string>
        <key>SANAD_HOME</key>
        <string>$sanadHome</string>
        ${_instance.isEmpty ? '' : '<key>SANAD_SERVICE_INSTANCE</key><string>$_instance</string>'}
    </dict>
</dict>
</plist>
''';
        final file = File(configPath);
        await file.parent.create(recursive: true);
        await file.writeAsString(plistContent);

        // Load service
        await Process.run('launchctl', ['unload', configPath]);
        final result = await Process.run('launchctl', ['load', configPath]);
        return result.exitCode == 0;
      } else if (Platform.isLinux) {
        final configPath = getServiceConfigPath();
        final serviceContent =
            '''[Unit]
Description=Sanad Local Agent Daemon
After=network.target
StartLimitIntervalSec=300
StartLimitBurst=5

[Service]
Type=simple
ExecStart=$finalExec ${args.join(' ')}
WorkingDirectory=$sanadHome
Restart=on-failure
RestartSec=10
UMask=0077
StandardOutput=append:$sanadHome/logs/daemon.log
StandardError=append:$sanadHome/logs/daemon.error.log
Environment=SANAD_HOME=$sanadHome
${_instance.isEmpty ? '' : 'Environment=SANAD_SERVICE_INSTANCE=$_instance'}

[Install]
WantedBy=default.target
''';
        final file = File(configPath);
        await file.parent.create(recursive: true);
        await file.writeAsString(serviceContent);

        await Process.run('systemctl', ['--user', 'daemon-reload']);
        final result = await Process.run('systemctl', [
          '--user',
          'enable',
          '--now',
          serviceName,
        ]);
        return result.exitCode == 0;
      } else if (Platform.isWindows) {
        final daemonCommand = buildWindowsDaemonCommand(
          executable: finalExec,
          arguments: args,
          sanadHome: sanadHome,
          serviceInstance: _instance,
        );
        final registrationCommand = buildWindowsTaskRegistrationCommand(
          encodedDaemonCommand: encodePowerShellCommand(daemonCommand),
          sanadHome: sanadHome,
          taskName: taskName,
        );
        final result = await Process.run('powershell.exe', [
          '-NoProfile',
          '-NonInteractive',
          '-WindowStyle',
          'Hidden',
          '-EncodedCommand',
          encodePowerShellCommand(registrationCommand),
        ]);
        return result.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
    return false;
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

  static Future<bool> uninstall() async {
    try {
      if (Platform.isMacOS) {
        final configPath = getServiceConfigPath();
        await Process.run('launchctl', ['unload', configPath]);
        final file = File(configPath);
        if (file.existsSync()) {
          await file.delete();
        }
        return true;
      } else if (Platform.isLinux) {
        await Process.run('systemctl', ['--user', 'stop', serviceName]);
        await Process.run('systemctl', ['--user', 'disable', serviceName]);
        final configPath = getServiceConfigPath();
        final file = File(configPath);
        if (file.existsSync()) {
          await file.delete();
        }
        await Process.run('systemctl', ['--user', 'daemon-reload']);
        return true;
      } else if (Platform.isWindows) {
        final psCommand =
            'Unregister-ScheduledTask -TaskName "$taskName" -Confirm:\$false';
        final result = await Process.run('powershell.exe', [
          '-Command',
          psCommand,
        ]);
        return result.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static Future<bool> start() async {
    try {
      if (Platform.isMacOS) {
        final configPath = getServiceConfigPath();
        final result = await Process.run('launchctl', ['load', configPath]);
        if (result.exitCode == 0) return true;
        final startResult = await Process.run('launchctl', ['start', label]);
        return startResult.exitCode == 0;
      } else if (Platform.isLinux) {
        final result = await Process.run('systemctl', [
          '--user',
          'start',
          serviceName,
        ]);
        return result.exitCode == 0;
      } else if (Platform.isWindows) {
        final result = await Process.run('powershell.exe', [
          '-Command',
          'Start-ScheduledTask -TaskName "$taskName"',
        ]);
        return result.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static Future<bool> stop() async {
    try {
      if (Platform.isMacOS) {
        final configPath = getServiceConfigPath();
        final result = await Process.run('launchctl', ['unload', configPath]);
        if (result.exitCode == 0) return true;
        final stopResult = await Process.run('launchctl', ['stop', label]);
        return stopResult.exitCode == 0;
      } else if (Platform.isLinux) {
        final result = await Process.run('systemctl', [
          '--user',
          'stop',
          serviceName,
        ]);
        return result.exitCode == 0;
      } else if (Platform.isWindows) {
        final result = await Process.run('powershell.exe', [
          '-Command',
          'Stop-ScheduledTask -TaskName "$taskName"',
        ]);
        return result.exitCode == 0;
      }
    } catch (_) {
      return false;
    }
    return false;
  }

  static Future<bool> restart() async {
    await stop();
    await Future<void>.delayed(const Duration(seconds: 1));
    return start();
  }

  static Future<String> getStatus() async {
    try {
      if (Platform.isMacOS) {
        final result = await Process.run('launchctl', ['list']);
        if (result.stdout.toString().contains(label)) {
          return 'Running';
        }
        return 'Stopped';
      } else if (Platform.isLinux) {
        final result = await Process.run('systemctl', [
          '--user',
          'is-active',
          serviceName,
        ]);
        return result.stdout.toString().trim();
      } else if (Platform.isWindows) {
        final psCommand = '(Get-ScheduledTask -TaskName "$taskName").State';
        final result = await Process.run('powershell.exe', [
          '-Command',
          psCommand,
        ]);
        return result.stdout.toString().trim();
      }
    } catch (_) {
      return 'Unknown';
    }
    return 'Unknown';
  }
}
