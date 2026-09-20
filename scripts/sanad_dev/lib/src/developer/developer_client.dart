part of '../../sanad_dev_cli.dart';

Future<void> _sendManagedClientDeveloperKey({
  required String sanadHome,
  required int agentPort,
  required int vmServicePort,
  required String key,
}) async {
  final record = await _readRuntimeLauncherRecordSafely(sanadHome, agentPort);
  if (record == null || !record.vmServicePorts.contains(vmServicePort)) {
    stderr.writeln('Client command refused: managed ownership is unavailable.');
    return;
  }
  final action = runtimeClientActionForInteractiveKey(key);
  if (action == null) return;
  print('\n[sanad-dev] Client ${action.name} requested.');
  final succeeded = await requestManagedComponentAction(
    record,
    action: action,
    target: RuntimeComponentTarget.client,
    vmServicePort: vmServicePort,
    openClientTerminal: false,
    timeout: const Duration(seconds: 10),
  );
  if (!succeeded) exitCode = 1;
}

Future<void> handleClientAttachAction(
  String action,
  int? portOverride, {
  String? sanadHomePath,
}) async {
  final instance = await selectClientInstance(
    portOverride,
    sanadHomePath: sanadHomePath,
  );
  if (instance == null) exit(1);

  final vmUrl = instance.token.isEmpty
      ? 'http://127.0.0.1:${instance.port}/'
      : 'http://127.0.0.1:${instance.port}/${instance.token}/';
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final expectedClientDirectory =
      '${runtime.repositoryRoot}${Platform.pathSeparator}client';
  if (!_samePath(instance.path, expectedClientDirectory)) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: the selected '
      'VM service does not belong to ${runtime.worktreeId}.',
    );
    exitCode = 1;
    return;
  }

  final discoveredProfile = instance.launchProfile;
  if (discoveredProfile == null) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: the running '
      'client launch profile could not be discovered.',
    );
    exitCode = 1;
    return;
  }
  final activeAgents = await discoverAgentInstances(
    sanadHomeOverride: sanadHomePath,
  );
  final activeClients = await discoverClientInstances();
  final processState = selectRuntimeProcessState(
    activeAgents: activeAgents,
    activeClients: activeClients,
    runtime: runtime,
  );
  final matchingAgent = processState.agent;
  if (matchingAgent == null || processState.agentAmbiguous) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: expected one '
      'verifiable running agent for ${runtime.worktreeId}.',
    );
    exitCode = 1;
    return;
  }
  final primarySanadHome = resolveDefaultUserSanadHome(Platform.environment);
  final profile = withImplicitPrimaryClientDefaults(
    discoveredProfile,
    allowed:
        !runtime.isLinkedWorktree &&
        matchingAgent.port == canonicalPrimaryAgentPort &&
        _samePath(runtime.sanadHome, primarySanadHome),
    primarySanadHome: primarySanadHome,
  );
  final profileError = validateClientLaunchProfile(
    profile,
    isLinkedWorktree: runtime.isLinkedWorktree,
    expectedWorktreeName: runtime.worktreeDisplayName,
    expectedBranch: runtime.branch,
    expectedAgentPort: matchingAgent.port,
    emptyPreferencesSanadHome: runtime.isLinkedWorktree
        ? resolveDefaultUserSanadHome(Platform.environment)
        : runtime.sanadHome,
    derivePreferencesPrefix: deriveSanadDevPreferencesPrefix,
  );
  if (profileError != null) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: $profileError.',
    );
    exitCode = 1;
    return;
  }
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: processState,
    sanadHome: profile.define('SANAD_HOME'),
  );
  final selectedClientIsManaged =
      ownership.isManaged &&
      ownership.state.ownedClients.any(
        (client) => client.port == instance.port && client.pid == instance.pid,
      );
  if (!selectedClientIsManaged) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: the selected '
      'client is ${ownership.isManaged ? 'unmanaged' : ownership.classification.name}, not owned by the live '
      'sanad-dev launcher.',
    );
    exitCode = 1;
    return;
  }

  print(
    'Attaching to Flutter app at $vmUrl to perform Hot ${action == 'R' ? 'Restart' : 'Reload'}...',
  );
  final clientDir = instance.path;
  final targetDevice =
      instance.deviceId ?? profile.deviceId ?? _defaultDesktopDevice();
  final attachArguments = buildClientAttachArguments(
    profile: profile,
    vmUrl: vmUrl,
    deviceId: targetDevice,
  );
  const executable = 'fvm';
  final args = ['flutter', ...attachArguments];
  final attachEnvironment = buildUnifiedSanadHomeEnvironment(
    Platform.environment,
    sanadHome: profile.define('SANAD_HOME')!,
  );

  final process = await Process.start(
    executable,
    args,
    workingDirectory: clientDir,
    environment: attachEnvironment,
    runInShell: Platform.isWindows,
  );

  final completer = Completer<void>();
  bool commandSent = false;
  bool actionCompleted = false;

  // Pipe stdout (filtered) and stderr to the console so user can see progress
  process.stdout
      .transform(utf8.decoder)
      .transform(const LineSplitter())
      .listen(
        (line) async {
          final trimmed = line.trim();
          if (trimmed.isEmpty) return;

          const ignorePatterns = [
            'Flutter run key commands.',
            'r Hot reload.',
            'R Hot restart.',
            'h List all available interactive',
            'c Clear the screen',
            'q Quit (terminate',
            'A Dart VM Service',
            'Detaching from application...',
            'Application finished.',
            'Waiting for attach to establish connection...',
          ];

          bool ignore = false;
          for (final pattern in ignorePatterns) {
            if (trimmed.startsWith(pattern)) {
              ignore = true;
              break;
            }
          }
          if (!ignore) {
            print(line);
          }

          // Trigger action when the terminal is ready
          if (!commandSent &&
              (trimmed.contains('r Hot reload') ||
                  trimmed.contains('Flutter run key commands'))) {
            commandSent = true;

            final now = DateTime.now();
            final libDir = Directory('$clientDir/lib');
            if (libDir.existsSync()) {
              try {
                final entities = libDir.listSync(recursive: true);
                for (final entity in entities) {
                  if (entity is File && entity.path.endsWith('.dart')) {
                    try {
                      entity.setLastModifiedSync(now);
                    } catch (_) {}
                  }
                }
              } catch (_) {}
            }

            final mainDart = File('$clientDir/lib/main.dart');
            if (mainDart.existsSync()) {
              try {
                mainDart.setLastModifiedSync(now);
              } catch (_) {}
            }

            // Wait a brief moment to ensure filesystem change is registered
            Future.delayed(const Duration(milliseconds: 150), () {
              process.stdin.write(action);
            });
          }

          // Trigger quit once reload/restart is done
          if (commandSent) {
            if (action == 'r' && trimmed.contains('Reloaded ')) {
              actionCompleted = true;
              process.stdin.write('q');
            } else if (action == 'R' &&
                trimmed.contains('Restarted application')) {
              actionCompleted = true;
              process.stdin.write('q');
            }
          }
        },
        onDone: () {
          if (!completer.isCompleted) {
            completer.complete();
          }
        },
      );

  process.stderr.transform(utf8.decoder).listen(stderr.write);

  // Safety timers to prevent hanging if stdout patterns don't match
  final safetyTimer1 = Timer(const Duration(seconds: 8), () {
    if (!commandSent) {
      commandSent = true;
      process.stdin.write(action);
    }
  });

  final safetyTimer2 = Timer(const Duration(seconds: 13), () {
    if (!completer.isCompleted) {
      process.stdin.write('q');
    }
  });

  await completer.future;
  safetyTimer1.cancel();
  safetyTimer2.cancel();
  final processExitCode = await process.exitCode;
  if (processExitCode != 0 || !actionCompleted) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} failed'
      '${processExitCode == 0 ? '' : ' (Flutter exited with code $processExitCode)'}.',
    );
    exitCode = processExitCode == 0 ? 1 : processExitCode;
  }
}

Future<void> handleClientDevTools(int? portOverride) async {
  final instance = await selectClientInstance(portOverride);
  if (instance == null) exit(1);

  final vmUrl = instance.token.isEmpty
      ? 'http://127.0.0.1:${instance.port}'
      : 'http://127.0.0.1:${instance.port}/${instance.token}';

  print('Opening Flutter DevTools for client on port ${instance.port}...');
  print('VM Service URL: $vmUrl');

  if (Platform.isMacOS) {
    try {
      final pbcopy = await Process.start('pbcopy', []);
      pbcopy.stdin.write(vmUrl);
      await pbcopy.stdin.close();
      print('📋 VM Service URL copied to clipboard!');
    } catch (_) {}
  }

  print('\n💡 Tip: To attach VS Code debugger to this running instance:');
  print('   1. Open the Run & Debug panel in VS Code.');
  print('   2. Select "Attach to Running Client" and click play.');
  print('   3. Paste the copied URL and press Enter.\n');

  final process = await Process.start(
    'fvm',
    ['dart', 'devtools', vmUrl],
    runInShell: Platform.isWindows,
    mode: ProcessStartMode.inheritStdio,
  );

  final exitCode = await process.exitCode;
  exit(exitCode);
}
