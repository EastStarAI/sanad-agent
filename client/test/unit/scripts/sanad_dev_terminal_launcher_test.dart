import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import '../../../../scripts/sanad_dev/terminal_launcher.dart';

void main() {
  test('client sidecar waits for journal and preserves POSIX paths', () {
    final command = buildClientLogTerminalCommand(
      repositoryRoot: '/repo with spaces',
      agentPort: 58091,
      vmServicePort: 51091,
      sanadHome: '/home with spaces',
    );

    expect(command, contains("cd '/repo with spaces'"));
    expect(command, contains('logs client -f --wait -n 50 -p 51091'));
    expect(command, contains('--agent-port 58091'));
    expect(command, contains("--home '/home with spaces'"));
  });

  test('Windows watcher uses PowerShell-safe quoting', () {
    final command = buildClientLogTerminalCommand(
      repositoryRoot: r"C:\repo with 'quote'",
      agentPort: 58091,
      vmServicePort: 51091,
      sanadHome: r"C:\home with 'quote'",
      platform: SanadDevHostPlatform.windows,
    );

    expect(command, startsWith('Set-Location '));
    expect(command, contains("''quote''"));
    expect(command, contains('sanad-dev.ps1'));
    expect(command, contains('logs client -f --wait -n 50'));
    expect(command, isNot(contains(' && ')));
  });

  test('Linux adapter selects a declared terminal capability', () async {
    final home = await Directory.systemTemp.createTemp('sanad-terminal-test-');
    addTearDown(() => home.delete(recursive: true));
    final executable = File('${home.path}${Platform.pathSeparator}gnome-terminal');
    await executable.writeAsString('');
    final invocation = terminalInvocation(
      'echo ready',
      platform: SanadDevHostPlatform.linux,
      environment: {'PATH': home.path},
    );

    expect(invocation?.executable, 'gnome-terminal');
    expect(invocation?.arguments, contains('echo ready; exec bash'));
  });

  test('headless execution never opens a GUI terminal', () async {
    var calls = 0;
    expect(
      await openClientLogTerminal(
        repositoryRoot: '/repo with spaces',
        agentPort: 58091,
        vmServicePort: 51091,
        sanadHome: '/home with spaces',
        interactive: false,
        runProcess: (executable, arguments) async {
          calls++;
          return ProcessResult(1, 0, '', '');
        },
      ),
      isFalse,
    );
    expect(calls, 0);
  });

  test('unsupported terminal gracefully returns false', () async {
    expect(
      await openSanadDevTerminal(
        'echo ready',
        platform: SanadDevHostPlatform.unsupported,
        environment: const {},
        runProcess: (executable, arguments) async => ProcessResult(1, 0, '', ''),
      ),
      isFalse,
    );
  });
}
