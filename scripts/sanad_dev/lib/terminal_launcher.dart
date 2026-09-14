import 'dart:io';

enum SanadDevHostPlatform { macos, linux, windows, unsupported }

SanadDevHostPlatform get currentSanadDevHostPlatform {
  if (Platform.isMacOS) return SanadDevHostPlatform.macos;
  if (Platform.isLinux) return SanadDevHostPlatform.linux;
  if (Platform.isWindows) return SanadDevHostPlatform.windows;
  return SanadDevHostPlatform.unsupported;
}

Future<bool> openClientLogTerminal({
  required String repositoryRoot,
  required int agentPort,
  required int vmServicePort,
  required String sanadHome,
  bool? interactive,
  SanadDevHostPlatform? platform,
  Map<String, String>? environment,
  Future<ProcessResult> Function(String executable, List<String> arguments)?
  runProcess,
}) async {
  if (!(interactive ?? stdin.hasTerminal)) return false;
  final hostPlatform = platform ?? currentSanadDevHostPlatform;
  final command = buildClientLogTerminalCommand(
    repositoryRoot: repositoryRoot,
    agentPort: agentPort,
    vmServicePort: vmServicePort,
    sanadHome: sanadHome,
    platform: hostPlatform,
  );
  return openSanadDevTerminal(
    command,
    platform: hostPlatform,
    environment: environment ?? Platform.environment,
    runProcess: runProcess ?? Process.run,
  );
}

String buildClientLogTerminalCommand({
  required String repositoryRoot,
  required int agentPort,
  required int vmServicePort,
  required String sanadHome,
  SanadDevHostPlatform platform = SanadDevHostPlatform.macos,
}) {
  if (platform == SanadDevHostPlatform.windows) {
    return 'Set-Location ${powerShellQuote(repositoryRoot)}; '
        '& ${powerShellQuote('$repositoryRoot${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev.ps1')} '
        'logs client -f --wait -n 50 -p $vmServicePort --agent-port $agentPort '
        '--home ${powerShellQuote(sanadHome)}';
  }
  return [
    'cd ${shellQuote(repositoryRoot)}',
    '${shellQuote('$repositoryRoot/scripts/sanad-dev')} logs client -f --wait -n 50 -p $vmServicePort --agent-port $agentPort --home ${shellQuote(sanadHome)}',
  ].join(' && ');
}

Future<bool> openSanadDevTerminal(
  String command, {
  required SanadDevHostPlatform platform,
  required Map<String, String> environment,
  required Future<ProcessResult> Function(
    String executable,
    List<String> arguments,
  )
  runProcess,
}) async {
  try {
    final invocation = terminalInvocation(
      command,
      platform: platform,
      environment: environment,
    );
    if (invocation == null) return false;
    final result = await runProcess(
      invocation.executable,
      invocation.arguments,
    );
    return result.exitCode == 0;
  } on Object {
    return false;
  }
}

TerminalInvocation? terminalInvocation(
  String command, {
  required SanadDevHostPlatform platform,
  required Map<String, String> environment,
}) {
  switch (platform) {
    case SanadDevHostPlatform.macos:
      final escaped = command.replaceAll(r'\', r'\\').replaceAll('"', r'\"');
      return TerminalInvocation('osascript', [
        '-e',
        'tell application "Terminal" to do script "$escaped"',
        '-e',
        'tell application "Terminal" to activate',
      ]);
    case SanadDevHostPlatform.linux:
      final path = environment['PATH'] ?? '';
      final terminal = const ['gnome-terminal', 'konsole', 'xterm'].firstWhere(
        (candidate) => executableOnPath(candidate, path),
        orElse: () => '',
      );
      return switch (terminal) {
        'gnome-terminal' => TerminalInvocation(terminal, [
          '--',
          'bash',
          '-lc',
          '$command; exec bash',
        ]),
        'konsole' => TerminalInvocation(terminal, [
          '-e',
          'bash',
          '-lc',
          '$command; exec bash',
        ]),
        'xterm' => TerminalInvocation(terminal, ['-e', 'bash', '-lc', command]),
        _ => null,
      };
    case SanadDevHostPlatform.windows:
      final path = environment['PATH'] ?? '';
      if (executableOnPath('wt.exe', path)) {
        return TerminalInvocation('wt.exe', [
          'new-tab',
          'powershell.exe',
          '-NoExit',
          '-Command',
          command,
        ]);
      }
      if (executableOnPath('powershell.exe', path)) {
        return TerminalInvocation('powershell.exe', [
          '-NoProfile',
          '-Command',
          'Start-Process powershell.exe -ArgumentList @("-NoExit", "-Command", ${powerShellQuote(command)})',
        ]);
      }
      return null;
    case SanadDevHostPlatform.unsupported:
      return null;
  }
}

class TerminalInvocation {
  const TerminalInvocation(this.executable, this.arguments);
  final String executable;
  final List<String> arguments;
}

bool executableOnPath(String executable, String path) {
  for (final directory in path.split(Platform.isWindows ? ';' : ':')) {
    if (directory.isEmpty) continue;
    if (File('$directory${Platform.pathSeparator}$executable').existsSync()) {
      return true;
    }
  }
  return false;
}

String shellQuote(String value) => "'${value.replaceAll("'", "'\\''")}'";

String powerShellQuote(String value) => "'${value.replaceAll("'", "''")}'";
