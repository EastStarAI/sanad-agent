import 'dart:convert';
import 'dart:io';

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

  group('launchd lifecycle', () {
    const configPath =
        '/Users/sanad/Library/LaunchAgents/com.eaststarai.sanad.agent.plist';
    const label = 'com.eaststarai.sanad.agent';

    test('a stop unloads the job instead of signalling it', () {
      final plan = ServiceManager.launchdLifecyclePlan(
        command: 'stop',
        configPath: configPath,
        label: label,
        userId: 501,
      );

      expect(plan, <List<String>>[
        <String>['unload', configPath],
        <String>['bootout', 'gui/501/$label'],
      ]);
      // `launchctl stop` only signals the job, and the plist keeps
      // `KeepAlive { SuccessfulExit = false }`: the daemon's `143` would count
      // as an unsuccessful exit and `launchd` would launch it again.
      expect(plan.expand((arguments) => arguments), isNot(contains('stop')));
    });

    test('a start loads the plist and falls back to the label', () {
      final plan = ServiceManager.launchdLifecyclePlan(
        command: 'start',
        configPath: configPath,
        label: label,
        userId: 501,
      );

      expect(plan, <List<String>>[
        <String>['load', configPath],
        <String>['start', label],
      ]);
    });

    test(
      'a stop whose unload fails boots the job out of the user domain',
      () async {
        final runner = ServiceManager.launchctl;
        final userId = ServiceManager.launchdUserId;
        final calls = <List<String>>[];
        addTearDown(() {
          ServiceManager.launchctl = runner;
          ServiceManager.launchdUserId = userId;
        });
        ServiceManager.launchdUserId = () async => 501;
        ServiceManager.launchctl = (arguments) async {
          calls.add(arguments);
          // `unload` fails when the loaded job came from another plist path,
          // and the job is gone once it is booted out.
          final exitCode = switch (arguments.first) {
            'unload' => 1,
            'list' => 1,
            _ => 0,
          };
          return ProcessResult(0, exitCode, '', '');
        };

        final result = await ServiceManager.stop();

        expect(calls.first, <String>[
          'unload',
          ServiceManager.getServiceConfigPath(),
        ]);
        expect(calls[1], <String>[
          'bootout',
          'gui/501/${ServiceManager.label}',
        ]);
        expect(
          calls.where((arguments) => arguments.first == 'bootout'),
          hasLength(1),
        );
        expect(calls.expand((arguments) => arguments), isNot(contains('stop')));
        expect(result.success, isTrue, reason: result.error);
        expect(result.status.running, isFalse);
      },
      skip: Platform.isMacOS ? false : 'launchd runs on macOS only.',
    );

    test('a stop whose unload succeeds leaves the job alone', () async {
      final runner = ServiceManager.launchctl;
      final userId = ServiceManager.launchdUserId;
      final calls = <List<String>>[];
      addTearDown(() {
        ServiceManager.launchctl = runner;
        ServiceManager.launchdUserId = userId;
      });
      ServiceManager.launchdUserId = () async => 501;
      ServiceManager.launchctl = (arguments) async {
        calls.add(arguments);
        return ProcessResult(0, arguments.first == 'list' ? 1 : 0, '', '');
      };

      final result = await ServiceManager.stop();

      expect(calls.first, <String>[
        'unload',
        ServiceManager.getServiceConfigPath(),
      ]);
      expect(
        calls.expand((arguments) => arguments),
        isNot(contains('bootout')),
      );
      expect(result.success, isTrue, reason: result.error);
    }, skip: Platform.isMacOS ? false : 'launchd runs on macOS only.');
  });
}
