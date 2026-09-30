part of '../../sanad_dev_cli.dart';

List<ClientInstance> selectManagedUiDriverClients(
  RuntimeOwnershipAssessment ownership,
) {
  if (!ownership.isManaged) return const [];
  return ownership.state.ownedClients
      .where(
        (client) =>
            client.launchProfile?.target
                ?.replaceAll('\\\\', '/')
                .endsWith('lib/driver_main.dart') ==
            true,
      )
      .toList(growable: false);
}

Future<void> handleUiDriverCommand(
  List<String> args, {
  String? sanadHomePath,
}) async {
  final callerDir =
      Platform.environment['SANAD_DEV_CALLER_DIR'] ?? Directory.current.path;
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: callerDir,
    sanadHomeOverride: sanadHomePath,
  );
  final driverArgs = <String>[];
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--home') {
      index++;
      continue;
    }
    if (arg.startsWith('--home=')) continue;
    driverArgs.add(arg);
  }
  final repoRoot = runtime.repositoryRoot;
  final clientDir = Directory('$repoRoot/client');
  final toolScript = '$repoRoot/scripts/flutter_driver_cli.dart';

  final hasExplicitVmUrl = driverArgs.any(
    (arg) =>
        arg == '--vm-url' ||
        arg == '-u' ||
        arg.startsWith('--vm-url=') ||
        arg.startsWith('-u='),
  );
  final isHelpRequest =
      driverArgs.isEmpty ||
      driverArgs.first == 'help' ||
      driverArgs.any((arg) => arg == '-h' || arg == '--help');
  final extraArgs = <String>[];
  if (!hasExplicitVmUrl && !isHelpRequest) {
    final activeClients = await discoverClientInstances();
    final processState = selectRuntimeProcessState(
      activeAgents: await discoverAgentInstances(
        sanadHomeOverride: sanadHomePath,
      ),
      activeClients: activeClients,
      runtime: runtime,
    );
    final activeHome = resolveActiveSanadHome(runtime, processState);
    final ownership = await assessRuntimeOwnership(
      runtime: runtime,
      state: processState,
      sanadHome: activeHome,
    );
    final managedClients = selectManagedUiDriverClients(ownership);
    if (managedClients.length != 1) {
      stderr.writeln(
        managedClients.isEmpty
            ? 'No active driver-enabled client is managed for this worktree. '
                  'Run `sanad-dev run --driver` first or pass --vm-url explicitly.'
            : 'Multiple managed clients are active for this worktree. '
                  'Pass --vm-url explicitly to select one.',
      );
      exitCode = 1;
      return;
    }
    final selectedClient = managedClients.single;
    final tokenPath = selectedClient.token.isEmpty
        ? ''
        : '${selectedClient.token}/';
    extraArgs.addAll([
      '--vm-url',
      'http://127.0.0.1:${selectedClient.port}/$tokenPath',
    ]);
  }

  final process = await Process.start(
    'fvm',
    [
      'dart',
      '--packages=${clientDir.path}/.dart_tool/package_config.json',
      toolScript,
      ...driverArgs,
      ...extraArgs,
    ],
    workingDirectory: clientDir.path,
    mode: ProcessStartMode.inheritStdio,
    runInShell: Platform.isWindows,
    environment: {...Platform.environment, 'SANAD_DEV_CALLER_DIR': callerDir},
  );

  final code = await process.exitCode;
  exit(code);
}
