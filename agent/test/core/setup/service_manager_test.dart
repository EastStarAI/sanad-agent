import 'dart:convert';

import 'package:sanad_agent/core/setup/service_manager.dart';
import 'package:test/test.dart';

void main() {
  test('Windows daemon command preserves isolated lifecycle environment', () {
    final command = ServiceManager.buildWindowsDaemonCommand(
      executable: r"C:\Sanad Test\sanad'agent.exe",
      arguments: const ['daemon'],
      sanadHome: r"C:\Sanad Test\home'67b",
      serviceInstance: 'gate-e',
    );

    expect(command, contains(r"$env:SANAD_HOME = 'C:\Sanad Test\home''67b'"));
    expect(command, contains(r"$env:SANAD_SERVICE_INSTANCE = 'gate-e'"));
    expect(command, contains(r"& 'C:\Sanad Test\sanad''agent.exe' 'daemon'"));
    expect(command, contains(r'exit $LASTEXITCODE'));
  });

  test(
    'Windows Scheduled Task has reboot and long-running daemon settings',
    () {
      final command = ServiceManager.buildWindowsTaskRegistrationCommand(
        encodedDaemonCommand: 'encoded-child',
        sanadHome: r'C:\Sanad Test\home',
        taskName: 'SanadAgent-gate-e',
      );

      expect(command, contains('New-ScheduledTaskTrigger -AtLogOn'));
      expect(command, contains('-MultipleInstances IgnoreNew'));
      expect(command, contains('-RestartCount 3'));
      expect(
        command,
        contains('-ExecutionTimeLimit (New-TimeSpan -Seconds 0)'),
      );
      expect(command, contains('-WindowStyle Hidden'));
      expect(command, contains("-EncodedCommand encoded-child"));
      expect(command, contains("-TaskName 'SanadAgent-gate-e'"));
    },
  );

  test('Windows release task runs the native launcher directly', () {
    final command = ServiceManager.buildWindowsTaskRegistrationCommand(
      launcherExecutable: r'C:\Sanad Test\sanad-launcher-abc.exe',
      sanadHome: r'C:\Sanad Test\home',
      taskName: 'SanadAgent-gate-e',
      serviceInstance: 'gate-e',
    );

    expect(
      command,
      contains(
        "New-ScheduledTaskAction -Execute 'C:\\Sanad Test\\sanad-launcher-abc.exe'",
      ),
    );
    expect(command, contains('--home "C:\\Sanad Test\\home"'));
    expect(command, contains('--service-instance "gate-e"'));
    expect(command, isNot(contains("-Execute 'powershell.exe'")));
    expect(command, isNot(contains('-WindowStyle Hidden')));
  });

  test('Windows uninstall stops the owned task before unregistering it', () {
    final command = ServiceManager.buildWindowsTaskUnregistrationCommand(
      'SanadAgent-gate-e',
    );

    expect(command, contains('Stop-ScheduledTask'));
    expect(command, contains('Unregister-ScheduledTask'));
    expect(
      command.indexOf('Stop-ScheduledTask'),
      lessThan(command.indexOf('Unregister-ScheduledTask')),
    );
  });

  test('PowerShell command encoding is UTF-16LE', () {
    const command = r"$env:SANAD_HOME = 'C:\test'";
    final encoded = ServiceManager.encodePowerShellCommand(command);
    final bytes = base64Decode(encoded);
    final codeUnits = <int>[];
    for (var index = 0; index < bytes.length; index += 2) {
      codeUnits.add(bytes[index] | (bytes[index + 1] << 8));
    }

    expect(String.fromCharCodes(codeUnits), command);
  });
}
