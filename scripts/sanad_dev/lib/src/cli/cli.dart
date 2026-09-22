part of '../../sanad_dev_cli.dart';

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

  final rawCommand = args[0].toLowerCase();
  if (rawCommand != 'driver' &&
      rawCommand != 'ui' &&
      args.skip(1).any((arg) => arg == '-h' || arg == '--help')) {
    printUsage();
    return;
  }

  final parsed = parseSanadDevInvocation(args);
  if (parsed == null) return;

  final command = parsed.command;
  final target = parsed.target;
  final componentCommand = parsed.componentCommand;
  var sanadHomePath = parsed.sanadHomePath;

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
    if (parsed.clientInstanceSlot != null) {
      if (componentCommand!.target == SanadDevComponentTarget.agent) {
        stderr.writeln('--client-instance requires a Client run target.');
        exitCode = 64;
        return;
      }
      try {
        sanadDevPreferencesPrefixForClientInstance(
          '',
          parsed.clientInstanceSlot,
        );
      } on FormatException catch (error) {
        stderr.writeln(error.message);
        exitCode = 64;
        return;
      }
    }
    if (parsed.backgroundMode && parsed.dryRun) {
      stderr.writeln('--background cannot be combined with --dry-run.');
      exitCode = 64;
      return;
    }
    if (parsed.backgroundMode && parsed.internalBackgroundMode) {
      stderr.writeln('Invalid nested background launch request.');
      exitCode = 64;
      return;
    }
    if (parsed.backgroundMode) {
      await handleBackgroundRun(
        originalArguments: args,
        target: componentCommand!.target,
        device: parsed.device,
        clientInstanceSlot: parsed.clientInstanceSlot,
        sanadHomePath: sanadHomePath,
      );
      return;
    }
    await handleRun(
      target: componentCommand!.target,
      driverMode: parsed.driverMode,
      cloudEnabled: parsed.cloudEnabled,
      dryRun: parsed.dryRun,
      device: parsed.device,
      configPath: parsed.configPath,
      clientInstanceSlot: parsed.clientInstanceSlot,
      sanadHomePath: sanadHomePath,
      backgroundMode: parsed.internalBackgroundMode,
    );
    return;
  }

  if (command != 'switch' && sanadHomePath == null) {
    sanadHomePath = await _inferredPostLaunchSanadHome();
  }

  if (command == 'status') {
    await handleRuntimeStatus(
      portOverride: parsed.portOverride,
      sanadHomePath: sanadHomePath,
    );
    return;
  }

  if (command == 'stop') {
    await handleRuntimeStop(
      target: componentCommand!.target,
      device: componentCommand.device,
      vmServicePort: parsed.portOverride,
      force: componentCommand.force,
      sanadHomePath: sanadHomePath,
    );
    return;
  }

  if (command == 'doctor') {
    await handleRuntimeDoctor(fix: parsed.fix, sanadHomePath: sanadHomePath);
    return;
  }

  if (command == 'takeover') {
    await handleRuntimeTakeover(sanadHomePath: sanadHomePath);
    return;
  }

  if (command == 'cleanup-target-orphans') {
    await handleTargetOrphanCleanup(sanadHomePath: sanadHomePath);
    return;
  }

  if (command == 'switch') {
    await handleRuntimeSwitch(
      runtimeSelector: parsed.runtimeSelector,
      portOverride: parsed.portOverride,
    );
    return;
  }

  var portOverride =
      parsed.portOverride ??
      await _recordedPortForTarget(target, sanadHomePath: sanadHomePath);

  if (command == 'logs') {
    if (target == 'client') {
      await handleClientLogs(
        parsed.follow,
        parsed.tailCount,
        portOverride,
        waitForJournal: parsed.waitForLogs,
        sanadHomePath: sanadHomePath,
        journalAgentPort: parsed.journalAgentPort,
      );
    } else if (target == 'agent') {
      await handleAgentLogs(
        parsed.follow,
        parsed.tailCount,
        portOverride,
        waitForInstance: parsed.waitForLogs,
        sanadHomePath: sanadHomePath,
      );
    } else {
      print('Unknown target: $target. Supported targets: client, agent');
      exit(1);
    }
  } else if (command == 'restart') {
    if (target == 'client') {
      await handleClientDeveloperAction(
        'R',
        portOverride,
        sanadHomePath: sanadHomePath,
      ); // R = Hot Restart
    } else if (target == 'agent') {
      if (parsed.restartTimeoutSeconds < 1 ||
          parsed.restartTimeoutSeconds > 3600) {
        stderr.writeln('--timeout must be between 1 and 3600 seconds.');
        exitCode = 64;
        return;
      }
      await handleAgentRestart(
        portOverride,
        force: parsed.forceRestart,
        timeoutSeconds: parsed.restartTimeoutSeconds,
        sanadHomePath: sanadHomePath,
      );
    } else {
      print('Unknown target: $target. Supported targets: client, agent');
      exit(1);
    }
  } else if (command == 'reload') {
    if (target == 'client') {
      await handleClientDeveloperAction(
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
    await handleUiDriverCommand(args.sublist(1), sanadHomePath: sanadHomePath);
  } else {
    print('Unknown command: $command');
    printUsage();
    exit(1);
  }
}
