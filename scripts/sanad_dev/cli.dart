part of '../sanad_dev.dart';

void main(List<String> args) async {
  if (args.isEmpty) {
    printUsage();
    exit(1);
  }

  if (args.length == 1 &&
      (args.first == '-h' || args.first == '--help' || args.first == 'help')) {
    printUsage();
    exit(0);
  }

  final command = args[0].toLowerCase();
  if (command != 'driver' &&
      command != 'ui' &&
      args.skip(1).any((arg) => arg == '-h' || arg == '--help')) {
    printUsage();
    return;
  }

  SanadDevComponentCommand? componentCommand;
  if (command == 'run' || command == 'stop') {
    try {
      componentCommand = parseSanadDevComponentCommand(args);
    } on FormatException catch (error) {
      stderr.writeln(error.message);
      exitCode = 64;
      return;
    }
  }
  String target = componentCommand?.target.name ?? 'client';
  if (componentCommand == null && args.length > 1 && !args[1].startsWith('-')) {
    target = args[1].toLowerCase();
  }

  // Parse options: --follow/-f, --tail/-n, and --port/-p
  bool follow = false;
  bool waitForLogs = false;
  int? tailCount;
  int? portOverride;
  int? journalAgentPort;
  bool driverMode = false;
  final cloudEnabled = resolveSanadDevCloudEnabled(args);
  bool dryRun = false;
  bool backgroundMode = false;
  bool internalBackgroundMode = false;
  bool forceRestart = false;
  bool fix = false;
  int restartTimeoutSeconds = 60;
  String device = _defaultDesktopDevice();
  String configPath = defaultSanadDevClientConfig;
  String? sanadHomePath;
  String runtimeSelector = 'current';

  for (int i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '-f' || arg == '--follow') {
      follow = true;
    } else if (arg == '--wait') {
      waitForLogs = true;
    } else if (arg == '-n' || arg == '--tail') {
      if (i + 1 < args.length) {
        tailCount = int.tryParse(args[i + 1]);
      }
    } else if (arg.startsWith('--tail=')) {
      tailCount = int.tryParse(arg.substring(7));
    } else if (arg == '-p' || arg == '--port') {
      if (i + 1 < args.length) {
        portOverride = int.tryParse(args[i + 1]);
      }
    } else if (arg.startsWith('--port=')) {
      portOverride = int.tryParse(arg.substring(7));
    } else if (arg == '--agent-port' && i + 1 < args.length) {
      journalAgentPort = int.tryParse(args[i + 1]);
    } else if (arg.startsWith('--agent-port=')) {
      journalAgentPort = int.tryParse(arg.substring(13));
    } else if (arg == '--driver') {
      driverMode = true;
    } else if (arg == '--dry-run') {
      dryRun = true;
    } else if (arg == '--background') {
      backgroundMode = true;
    } else if (arg == '--internal-background') {
      internalBackgroundMode = true;
    } else if (arg == '--force') {
      forceRestart = true;
    } else if (arg == '--fix') {
      fix = true;
    } else if (arg == '--timeout' && i + 1 < args.length) {
      restartTimeoutSeconds = int.tryParse(args[i + 1]) ?? -1;
    } else if (arg.startsWith('--timeout=')) {
      restartTimeoutSeconds = int.tryParse(arg.substring(10)) ?? -1;
    } else if ((arg == '-d' || arg == '--device') && i + 1 < args.length) {
      device = args[i + 1];
    } else if (arg.startsWith('--device=')) {
      device = arg.substring(9);
    } else if (arg == '--config' && i + 1 < args.length) {
      configPath = args[i + 1];
    } else if (arg.startsWith('--config=')) {
      configPath = arg.substring(9);
    } else if (arg == '--home' && i + 1 < args.length) {
      sanadHomePath = args[i + 1];
    } else if (arg.startsWith('--home=')) {
      sanadHomePath = arg.substring(7);
    } else if (arg == '--runtime' && i + 1 < args.length) {
      runtimeSelector = args[i + 1].toLowerCase();
    } else if (arg.startsWith('--runtime=')) {
      runtimeSelector = arg.substring(10).toLowerCase();
    }
  }

  if (command == 'run') {
    final homeOptionIndex = args.indexOf('--home');
    if (homeOptionIndex >= 0 &&
        (homeOptionIndex + 1 >= args.length ||
            args[homeOptionIndex + 1].startsWith('-'))) {
      stderr.writeln('--home requires "user" or an absolute path.');
      exitCode = 64;
      return;
    }
    if (sanadHomePath != null && !isSanadDevHomeSelector(sanadHomePath)) {
      stderr.writeln(
        '--home requires "user" or an absolute path: $sanadHomePath',
      );
      exitCode = 64;
      return;
    }
    if (backgroundMode && dryRun) {
      stderr.writeln('--background cannot be combined with --dry-run.');
      exitCode = 64;
      return;
    }
    if (backgroundMode && internalBackgroundMode) {
      stderr.writeln('Invalid nested background launch request.');
      exitCode = 64;
      return;
    }
    if (backgroundMode) {
      await handleBackgroundRun(
        originalArguments: args,
        target: componentCommand!.target,
        device: device,
        sanadHomePath: sanadHomePath,
      );
      return;
    }
    await handleRun(
      target: componentCommand!.target,
      driverMode: driverMode,
      cloudEnabled: cloudEnabled,
      dryRun: dryRun,
      device: device,
      configPath: configPath,
      sanadHomePath: sanadHomePath,
      backgroundMode: internalBackgroundMode,
    );
    return;
  }

  if (command == 'status') {
    await handleRuntimeStatus(
      portOverride: portOverride,
      sanadHomePath: sanadHomePath,
    );
    return;
  }

  if (command == 'stop') {
    await handleRuntimeStop(
      target: componentCommand!.target,
      device: componentCommand.device,
      vmServicePort: portOverride,
      force: componentCommand.force,
    );
    return;
  }

  if (command == 'doctor') {
    await handleRuntimeDoctor(fix: fix);
    return;
  }

  if (command == 'takeover') {
    await handleRuntimeTakeover();
    return;
  }

  if (command == 'cleanup-target-orphans') {
    await handleTargetOrphanCleanup();
    return;
  }

  if (command == 'switch') {
    await handleRuntimeSwitch(
      runtimeSelector: runtimeSelector,
      portOverride: portOverride,
    );
    return;
  }

  portOverride ??= await _recordedPortForTarget(target);

  if (command == 'logs') {
    if (target == 'client') {
      await handleClientLogs(
        follow,
        tailCount,
        portOverride,
        waitForJournal: waitForLogs,
        sanadHomePath: sanadHomePath,
        journalAgentPort: journalAgentPort,
      );
    } else if (target == 'agent') {
      await handleAgentLogs(
        follow,
        tailCount,
        portOverride,
        waitForInstance: waitForLogs,
        sanadHomePath: sanadHomePath,
      );
    } else {
      print('Unknown target: $target. Supported targets: client, agent');
      exit(1);
    }
  } else if (command == 'restart') {
    if (target == 'client') {
      await handleClientAttachAction(
        'R',
        portOverride,
        sanadHomePath: sanadHomePath,
      ); // R = Hot Restart
    } else if (target == 'agent') {
      if (restartTimeoutSeconds < 1 || restartTimeoutSeconds > 3600) {
        stderr.writeln('--timeout must be between 1 and 3600 seconds.');
        exitCode = 64;
        return;
      }
      await handleAgentRestart(
        portOverride,
        force: forceRestart,
        timeoutSeconds: restartTimeoutSeconds,
        sanadHomePath: sanadHomePath,
      );
    } else {
      print('Unknown target: $target. Supported targets: client, agent');
      exit(1);
    }
  } else if (command == 'reload') {
    if (target == 'client') {
      await handleClientAttachAction(
        'r',
        portOverride,
        sanadHomePath: sanadHomePath,
      ); // r = Hot Reload
    } else {
      print('Unknown target: $target. Supported targets: client');
      exit(1);
    }
  } else if (command == 'inspect' || command == 'devtools') {
    if (target == 'client') {
      await handleClientDevTools(portOverride);
    } else {
      print('Unknown target: $target. Supported targets: client');
      exit(1);
    }
  } else if (command == 'driver' || command == 'ui') {
    await handleUiDriverCommand(args.sublist(1));
  } else {
    print('Unknown command: $command');
    printUsage();
    exit(1);
  }
}

void printUsage() {
  print('Usage: sanad-dev <command> [target] [options]');
  print('');
  print('Commands:');
  print(
    '  run [all|agent|client]    Launch all components (default) or one component.',
  );
  print(
    '  status                    Show the runtime source and all attached clients.',
  );
  print(
    '  stop [all|agent|client]   Stop all components (default) or one component.',
  );
  print(
    '  doctor [--fix]            Diagnose ownership; remove only stale records.',
  );
  print(
    '  takeover                  Relaunch a complete manual pair under sanad-dev.',
  );
  print(
    '  cleanup-target-orphans    Remove proven stale clients in this target only.',
  );
  print(
    '  switch --runtime current  Move the active runtime group to this worktree.',
  );
  print(
    '                            Requires direct user authorization; all sessions sharing the pair are affected.',
  );
  print(
    '  logs [client|agent]       Show logs for the client (default) or agent.',
  );
  print('  restart [client|agent]    Restart the client (default) or agent.');
  print('  reload [client]           Reload the client.');
  print(
    '  inspect [client]          Open Flutter DevTools / Inspector for the client.',
  );
  print(
    '  ui / driver <command>     Interact with client (snapshot, find, tap, enter-text, scroll, wait-for, screenshot, batch).',
  );
  print('');
  print('Options:');
  print('  -f, --follow              Stream logs live in real-time.');
  print('  --wait                    Wait for a managed component journal.');
  print(
    '  --agent-port <port>       Select the journal group for a Client watcher.',
  );
  print(
    '  -n, --tail <lines>        Output only the last <lines> log entries.',
  );
  print(
    '  -p, --port <port>         Target a specific running instance by its port.',
  );
  print('  --runtime current         Select the requester runtime for switch.');
  print('  --driver                  Run client/lib/driver_main.dart.');
  print(
    '  --cloud                   Explicitly enable cloud (already the default).',
  );
  print('  --no-cloud                Disable cloud and run local-only.');
  print(
    '  --home <user|absolute>    Use the primary user home or an explicit Sanad Home.',
  );
  print(
    '  -d, --device <id>         Flutter device for run client/all or stop client.',
  );
  print(
    '  --config <path>           Client config file (default: $defaultSanadDevClientConfig).',
  );
  print('  --dry-run                 Resolve and print runtime settings only.');
  print(
    '  --background              Launch detached and wait for a managed/failure result.',
  );
  print('  --fix                     Apply doctor safe stale-record repairs.');
  print(
    '  --timeout <seconds>       Agent restart safety timeout (default: 60).',
  );
  print(
    '  --force                   Force restart, or cancel work for stop agent/all.',
  );
  print('');
  print('Examples:');
  print('  sanad-dev run');
  print('  sanad-dev run --background');
  print('  sanad-dev run agent');
  print('  sanad-dev run client -d macos');
  print('  sanad-dev stop client -d macos');
  print('  sanad-dev stop agent --force');
  print('  sanad-dev run --driver');
  print('  sanad-dev logs client -n 50 -f');
  print('  sanad-dev logs client -p 50139');
  print('  sanad-dev restart agent -p 58085');
}

String _defaultDesktopDevice() {
  if (Platform.isMacOS) return 'macos';
  if (Platform.isWindows) return 'windows';
  if (Platform.isLinux) return 'linux';
  return 'macos';
}

String get _callerDirectory =>
    Platform.environment['SANAD_DEV_CALLER_DIR'] ?? Directory.current.path;

Future<SanadDevRuntime> _currentRuntime() =>
    discoverSanadDevRuntime(callerDirectory: _callerDirectory);

Future<int?> _recordedPortForTarget(String target) async {
  try {
    final runtime = await _currentRuntime();

    // Discover running instances matching the current worktree
    if (target == 'agent') {
      final activeAgents = await discoverAgentInstances();
      final currentWorkspaceHash = runtime.worktreeId.split('-').last;
      for (final inst in activeAgents) {
        if (inst.workspaceHash == currentWorkspaceHash) {
          return inst.port;
        }
      }
    } else {
      final state = selectRuntimeProcessState(
        activeAgents: await discoverAgentInstances(),
        activeClients: await discoverClientInstances(),
        runtime: runtime,
      );
      if (state.ownedClients.length == 1) {
        return state.ownedClients.single.port;
      }
    }
    return null;
  } catch (_) {
    return null;
  }
}
