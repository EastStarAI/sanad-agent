part of '../../../sanad_dev_cli.dart';

const sanadDevWebPortEnvironmentKey = 'SANAD_DEV_WEB_PORT';

void applySanadDevWebPort(
  List<String> arguments, {
  required String device,
  required Map<String, String> environment,
}) {
  arguments.removeWhere((argument) => argument.startsWith('--web-port='));
  if (device != 'chrome') return;

  final rawPort = environment[sanadDevWebPortEnvironmentKey]?.trim() ?? '';
  if (rawPort.isEmpty) return;
  final port = int.tryParse(rawPort);
  if (port == null || port < 1 || port > 65535) {
    throw FormatException(
      '$sanadDevWebPortEnvironmentKey must be a valid TCP port: $rawPort',
    );
  }
  arguments.add('--web-port=$port');
}

Future<ClientInstance?> _waitForManagedClientIdentity({
  required int vmServicePort,
  required String launcherId,
  required String runtimeNonce,
}) async {
  final deadline = DateTime.now().add(sanadDevClientStartupTimeout);
  while (DateTime.now().isBefore(deadline)) {
    final clients = await discoverClientInstances();
    for (final client in clients) {
      if (client.port == vmServicePort &&
          client.launchProfile?.define('SANAD_DEV_LAUNCHER_ID') == launcherId &&
          client.launchProfile?.define('SANAD_DEV_RUNTIME_NONCE') ==
              runtimeNonce) {
        return client;
      }
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return null;
}

String _newRuntimeOwnershipToken() {
  final random = Random.secure();
  final bytes = List<int>.generate(24, (_) => random.nextInt(256));
  return base64Url.encode(bytes).replaceAll('=', '');
}

void _printRuntimeSummary(
  SanadDevRuntime runtime, {
  required bool driverMode,
  required bool cloudEnabled,
  int? agentPort,
  int? vmServicePort,
  String? sanadHomePath,
}) {
  print('Worktree: ${runtime.worktreeId}');
  print('Branch: ${runtime.branch}');
  print('Mode: ${driverMode ? 'interactive-driver' : 'interactive'}');
  print('Cloud gateway: ${cloudEnabled ? 'enabled' : 'disabled'}');
  print('Agent gateway: http://127.0.0.1:${agentPort ?? runtime.agentPort}');
  print(
    'Client VM service: http://127.0.0.1:${vmServicePort ?? runtime.vmServicePort}/',
  );
  print('Sanad home: ${sanadHomePath ?? runtime.sanadHome}');
}

Future<bool> _waitForAgent(
  SanadDevRuntime runtime, {
  required String launcherId,
  required String runtimeNonce,
}) async {
  final client = HttpClient();
  try {
    return await waitForSanadDevStartupProbe(
      probe: () async {
        try {
          final request = await client.getUrl(
            Uri.parse('http://127.0.0.1:${runtime.agentPort}/health'),
          );
          await authorizeLocalGatewayRequest(request, runtime.sanadHome);
          final response = await request.close().timeout(
            const Duration(milliseconds: 500),
          );
          final body = await response.transform(utf8.decoder).join();
          if (response.statusCode == 200 &&
              matchesSanadDevAgentHealth(
                jsonDecode(body),
                launcherId: launcherId,
                runtimeNonce: runtimeNonce,
              )) {
            return true;
          }
        } catch (_) {}
        return false;
      },
    );
  } finally {
    client.close(force: true);
  }
}

Future<void> handleRun({
  required SanadDevComponentTarget target,
  required bool driverMode,
  required bool cloudEnabled,
  required bool dryRun,
  required String device,
  required String configPath,
  required String? clientInstanceSlot,
  required String? sanadHomePath,
  bool backgroundMode = false,
}) async {
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final startsAgent = target != SanadDevComponentTarget.client;
  final startsClient = target != SanadDevComponentTarget.agent;

  final activeAgents = await discoverAgentInstances(
    sanadHomeOverride: sanadHomePath,
  );
  final activeClients = await discoverClientInstances();

  final agentDirectory =
      '${runtime.repositoryRoot}${Platform.pathSeparator}agent';
  final clientDirectory =
      '${runtime.repositoryRoot}${Platform.pathSeparator}client';

  final primaryConflict = primaryResourceOwnershipConflict(
    runtime,
    activeAgents,
    activeClients: activeClients,
  );
  if (primaryConflict != null) {
    stderr.writeln(primaryConflict);
    exitCode = 1;
    return;
  }
  final processState = selectRuntimeProcessState(
    activeAgents: activeAgents,
    activeClients: activeClients,
    runtime: runtime,
  );

  if (processState.agent != null ||
      processState.relevantClients.isNotEmpty ||
      processState.agentAmbiguous) {
    final activeHome = resolveActiveSanadHome(runtime, processState);
    final ownership = await assessRuntimeOwnership(
      runtime: runtime,
      state: processState,
      sanadHome: activeHome,
    );
    if (ownership.isManaged) {
      final managedState = ownership.state;
      final hasRequestedAgent = !startsAgent || managedState.agent != null;
      final hasRequestedClient =
          !startsClient ||
          managedState.ownedClients.any(
            (client) =>
                client.deviceId == device &&
                (client.launchProfile?.define(
                          sanadDevClientInstanceSlotDefine,
                        ) ??
                        '') ==
                    (clientInstanceSlot ?? ''),
          );
      if (hasRequestedAgent && hasRequestedClient) {
        print(
          'Requested sanad-dev components are already running for '
          '${runtime.worktreeId}.',
        );
        return;
      }
      final requestedVmPort = startsClient
          ? await _nextAvailableVmServicePort(runtime.vmServicePort)
          : null;
      final succeeded = await requestManagedComponentAction(
        ownership.record!,
        action: RuntimeComponentAction.start,
        target: _componentControlTarget(target),
        deviceId: startsClient ? device : null,
        clientInstanceSlot: startsClient ? clientInstanceSlot : null,
        vmServicePort: requestedVmPort,
        openClientTerminal: target == SanadDevComponentTarget.all,
      );
      if (!succeeded) {
        exitCode = 1;
        return;
      }
      if (target == SanadDevComponentTarget.client && requestedVmPort != null) {
        await handleClientLogs(
          true,
          _defaultInteractiveLogTailLines,
          requestedVmPort,
          waitForJournal: true,
          sanadHomePath: ownership.record!.sanadHome,
          journalAgentPort: ownership.record!.agentPort,
        );
      }
      return;
    }
    if (!processState.mutationAllowed) {
      stderr.writeln(crossOwnedRunMessage());
      for (final client in processState.blockedClients) {
        stderr.writeln('  - ${runtimeClientSummary(client)}');
      }
      stderr.writeln('Stop it only from its owning runtime or IDE session.');
    } else if (processState.agent == null) {
      stderr.writeln(
        'A Flutter client with incomplete runtime identity is still active for '
        '${runtime.worktreeId}; automatic stop is refused.',
      );
    } else {
      stderr.writeln(
        'A ${ownership.classification.name} runtime is active for '
        '${runtime.worktreeId}: ${ownership.reason ?? 'ownership is not proven'}. '
        'Run "sanad-dev doctor" for a safe next action.',
      );
    }
    exitCode = 1;
    return;
  }

  _printRuntimeSummary(
    runtime,
    driverMode: driverMode,
    cloudEnabled: cloudEnabled,
    sanadHomePath: runtime.sanadHome,
  );
  if (dryRun) return;

  var startupAttempt = SanadDevStartupAttempt(
    attemptId: _newRuntimeOwnershipToken(),
    workspaceHash: runtime.worktreeId.split('-').last,
    agentPort: runtime.agentPort,
    requestedHome:
        sanadHomePath ??
        (runtime.isLinkedWorktree ? 'worktree-default' : 'user'),
    resolvedHome: runtime.sanadHome,
    stage: SanadDevStartupStage.preflight,
    outcome: SanadDevStartupOutcome.starting,
    updatedAt: DateTime.now().toUtc(),
  );
  Future<void> recordStartup({
    required SanadDevStartupStage stage,
    SanadDevStartupOutcome outcome = SanadDevStartupOutcome.starting,
    int? exitStatus,
    String? failureReason,
  }) async {
    startupAttempt = startupAttempt.copyWith(
      stage: stage,
      outcome: outcome,
      updatedAt: DateTime.now().toUtc(),
      exitStatus: exitStatus,
      failureReason: failureReason,
    );
    await writeSanadDevStartupAttempt(startupAttempt);
    await writeSanadDevStartupAttemptLocator(
      runtimeDirectory: runtime.runtimeDirectory,
      attempt: startupAttempt,
    );
  }

  await secureRuntimeDirectory(runtime.sanadHome, runtime.sanadHome);
  await recordStartup(stage: SanadDevStartupStage.preflight);

  final isAbsoluteConfig =
      configPath.startsWith('/') ||
      File(configPath).isAbsolute ||
      RegExp(r'^[a-zA-Z]:[/\\]').hasMatch(configPath);
  final candidateFile = File(configPath);
  final configFile = isAbsoluteConfig
      ? candidateFile
      : candidateFile.existsSync()
      ? candidateFile
      : File('$clientDirectory${Platform.pathSeparator}$configPath');
  if (!configFile.existsSync()) {
    stderr.writeln('Client configuration not found: ${configFile.path}');
    await recordStartup(
      stage: SanadDevStartupStage.cleanup,
      outcome: SanadDevStartupOutcome.failed,
      exitStatus: 1,
      failureReason: 'client configuration not found',
    );
    exitCode = 1;
    return;
  }

  SanadCloudEndpoints? cloudEndpoints;
  if (cloudEnabled) {
    try {
      cloudEndpoints = readSanadCloudEndpoints(configFile);
    } on FormatException catch (error) {
      stderr.writeln(error.message);
      await recordStartup(
        stage: SanadDevStartupStage.cleanup,
        outcome: SanadDevStartupOutcome.failed,
        exitStatus: 64,
        failureReason: 'client cloud configuration is invalid',
      );
      exitCode = 64;
      return;
    }
  }

  await cleanupStaleComponentJournals(runtime.sanadHome);

  final preferencesPrefix = resolveSanadDevPreferencesPrefix(
    isLinkedWorktree: runtime.isLinkedWorktree,
    sanadHome: runtime.sanadHome,
    sanadHomeSelector: sanadHomePath,
  );
  final launchPreferencesPrefix = sanadDevPreferencesPrefixForClientInstance(
    preferencesPrefix,
    clientInstanceSlot,
  );
  final runtimeNonce = _newRuntimeOwnershipToken();
  final launcherId = 'launcher-$runtimeNonce';
  var launcherRecord = RuntimeLauncherRecord(
    launcherId: launcherId,
    runtimeNonce: runtimeNonce,
    launcherPid: pid,
    launcherProcessIdentity:
        await readProcessIdentity(pid) ??
        (throw StateError(
          'Could not identify the sanad-dev launcher process.',
        )),
    workspaceHash: runtime.worktreeId.split('-').last,
    sourceRoot: runtime.repositoryRoot,
    agentPort: runtime.agentPort,
    sanadHome: runtime.sanadHome,
    preferencesPrefix: preferencesPrefix,
    clientPids: const [],
    vmServicePorts: const [],
    status: 'starting',
    updatedAt: DateTime.now().toUtc(),
  );
  await writeRuntimeLauncherRecord(launcherRecord);
  await recordStartup(stage: SanadDevStartupStage.recordCreated);

  final agentEnvironment =
      buildUnifiedSanadHomeEnvironment(
          Platform.environment,
          sanadHome: runtime.sanadHome,
        )
        ..['ENABLE_LOCAL_GATEWAY'] = 'true'
        ..['LOCAL_GATEWAY_PORT'] = '${runtime.agentPort}'
        ..['ENABLE_GATEWAY'] = cloudEnabled ? 'true' : 'false'
        ..['SANAD_DEV_LAUNCHER_ID'] = launcherId
        ..['SANAD_DEV_RUNTIME_NONCE'] = runtimeNonce
        ..['SANAD_DEV_WORKSPACE_HASH'] = runtime.worktreeId.split('-').last
        ..addAll(cloudEndpoints?.toAgentEnvironment() ?? const {});
  final flutterArguments = <String>[
    'flutter',
    'run',
    '-d',
    device,
    '--dart-define-from-file=$configPath',
    '--dart-define=LOCAL_GATEWAY_URL=http://127.0.0.1:${runtime.agentPort}',
    '--dart-define=ENABLE_CLOUD_GATEWAY=${cloudEnabled ? 'true' : 'false'}',
    '--dart-define=SANAD_HOME=${runtime.sanadHome}',
    '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=$launchPreferencesPrefix',
    '--dart-define=$sanadDevClientInstanceSlotDefine=${clientInstanceSlot ?? ''}',
    '--dart-define=SANAD_DEV_SWITCH_CAPABLE=true',
    '--dart-define=SANAD_DEV_LAUNCHER_ID=$launcherId',
    '--dart-define=SANAD_DEV_RUNTIME_NONCE=$runtimeNonce',
    '--dart-define=SANAD_DEV_WORKSPACE_HASH=${runtime.worktreeId.split('-').last}',
    if (runtime.isLinkedWorktree)
      '--dart-define=SANAD_DEV_WORKTREE_NAME=${runtime.worktreeDisplayName}',
    if (runtime.isLinkedWorktree)
      '--dart-define=SANAD_DEV_WORKTREE_BRANCH=${runtime.branch}',
    '--host-vmservice-port=${runtime.vmServicePort}',
    '--disable-service-auth-codes',
    if (driverMode) '--print-dtd',
    if (driverMode) ...['-t', 'lib/driver_main.dart'],
  ];
  applySanadDevWebPort(
    flutterArguments,
    device: device,
    environment: Platform.environment,
  );
  final clientEnvironment = buildUnifiedSanadHomeEnvironment(
    Platform.environment,
    sanadHome: runtime.sanadHome,
  );

  Process? agent;
  Process? client;
  ComponentProcessJournal? agentJournal;
  ComponentProcessJournal? clientJournal;
  final bootLogs = <String>[];
  final startupSignals = <StreamSubscription<ProcessSignal>>[];
  var startupAbortInProgress = false;
  Future<void> cancelStartupSignals() async {
    for (final subscription in startupSignals) {
      await subscription.cancel();
    }
    startupSignals.clear();
  }

  Future<void> abortStartup(ProcessSignal signal) async {
    if (startupAbortInProgress) return;
    startupAbortInProgress = true;
    if (agent != null) await terminateSanadDevProcessTree(agent.pid);
    if (client != null) await terminateSanadDevProcessTree(client.pid);
    await agentJournal?.cancel();
    await clientJournal?.cancel();
    await deleteRuntimeLauncherRecord(runtime.sanadHome, runtime.agentPort);
    await recordStartup(
      stage: SanadDevStartupStage.cleanup,
      outcome: SanadDevStartupOutcome.failed,
      exitStatus: 1,
      failureReason: 'startup interrupted by ${signal.toString()}',
    );
    await cancelStartupSignals();
    exit(1);
  }

  void watchStartupSignal(ProcessSignal signal) {
    startupSignals.add(
      signal.watch().listen((value) {
        unawaited(abortStartup(value));
      }),
    );
  }

  watchStartupSignal(ProcessSignal.sigint);
  if (!Platform.isWindows) {
    watchStartupSignal(ProcessSignal.sigterm);
    watchStartupSignal(ProcessSignal.sighup);
  }

  try {
    final agentStart = startsAgent
        ? Process.start(
            'fvm',
            const ['dart', 'run', 'bin/sanad_agent.dart', 'daemon'],
            workingDirectory: agentDirectory,
            environment: agentEnvironment,
            runInShell: Platform.isWindows,
          )
        : null;
    final clientStart = startsClient
        ? Process.start(
            'fvm',
            flutterArguments,
            workingDirectory: clientDirectory,
            environment: clientEnvironment,
            runInShell: Platform.isWindows,
          )
        : null;
    Object? startError;
    try {
      agent = await agentStart;
    } on Object catch (error) {
      startError = error;
    }
    try {
      client = await clientStart;
    } on Object catch (error) {
      startError ??= error;
    }
    if (startError != null) throw startError;
  } on Object catch (error) {
    await cancelStartupSignals();
    stderr.writeln('Component failed to start: $error');
    if (agent != null) await terminateSanadDevProcessTree(agent.pid);
    if (client != null) await terminateSanadDevProcessTree(client.pid);
    await deleteRuntimeLauncherRecord(runtime.sanadHome, runtime.agentPort);
    await recordStartup(
      stage: SanadDevStartupStage.cleanup,
      outcome: SanadDevStartupOutcome.failed,
      exitStatus: 1,
      failureReason: 'component spawn failed',
    );
    exitCode = 1;
    return;
  }
  await recordStartup(stage: SanadDevStartupStage.componentsSpawned);

  var agentHealthy = !startsAgent;
  ClientInstance? discoveredClient;
  try {
    if (agent != null) {
      agentJournal = await ComponentProcessJournal.attach(
        process: agent,
        writer: ComponentJournalWriter(
          sanadHome: runtime.sanadHome,
          agentPort: runtime.agentPort,
          component: 'agent',
          launcherId: launcherId,
          runtimeNonce: runtimeNonce,
        ),
        mirrorStdout: !backgroundMode,
        mirrorStderr: !backgroundMode,
        onBytes: (_, bytes) {
          bootLogs.addAll(
            const LineSplitter().convert(
              utf8.decode(bytes, allowMalformed: true),
            ),
          );
          while (bootLogs.length > 200) {
            bootLogs.removeAt(0);
          }
        },
      );
    }
    if (client != null) {
      clientJournal = await ComponentProcessJournal.attach(
        process: client,
        writer: ComponentJournalWriter(
          sanadHome: runtime.sanadHome,
          agentPort: runtime.agentPort,
          component: 'client',
          vmServicePort: runtime.vmServicePort,
          launcherId: launcherId,
          runtimeNonce: runtimeNonce,
        ),
        mirrorStdout: !startsAgent && !backgroundMode,
        mirrorStderr: !startsAgent && !backgroundMode,
      );
    }

    if (startsAgent && startsClient && !backgroundMode) {
      final opened = await openClientLogTerminal(
        repositoryRoot: runtime.repositoryRoot,
        agentPort: runtime.agentPort,
        vmServicePort: runtime.vmServicePort,
        sanadHome: runtime.sanadHome,
      );
      if (!opened) {
        print(
          'Client logs: sanad-dev logs client -n 50 -p ${runtime.vmServicePort}',
        );
      }
    }

    await recordStartup(stage: SanadDevStartupStage.readiness);
    await Future.wait<void>([
      if (startsAgent)
        () async {
          agentHealthy = await _waitForAgent(
            runtime,
            launcherId: launcherId,
            runtimeNonce: runtimeNonce,
          );
        }(),
      if (startsClient)
        () async {
          discoveredClient = await _waitForManagedClientIdentity(
            vmServicePort: runtime.vmServicePort,
            launcherId: launcherId,
            runtimeNonce: runtimeNonce,
          );
        }(),
    ]);
  } on Object catch (error) {
    await cancelStartupSignals();
    stderr.writeln('Startup orchestration failed: $error');
    if (agent != null) await terminateSanadDevProcessTree(agent.pid);
    if (client != null) await terminateSanadDevProcessTree(client.pid);
    await agentJournal?.cancel();
    await clientJournal?.cancel();
    await deleteRuntimeLauncherRecord(runtime.sanadHome, runtime.agentPort);
    await recordStartup(
      stage: SanadDevStartupStage.cleanup,
      outcome: SanadDevStartupOutcome.failed,
      exitStatus: 1,
      failureReason: 'startup orchestration failed',
    );
    exitCode = 1;
    return;
  }
  if (!agentHealthy || (startsClient && discoveredClient?.pid == null)) {
    await cancelStartupSignals();
    if (!agentHealthy) {
      stderr.writeln('Agent failed to become healthy. Boot logs:');
      for (final log in bootLogs) {
        stderr.writeln('  $log');
      }
    }
    if (startsClient && discoveredClient?.pid == null) {
      stderr.writeln('Client failed to expose a matching managed identity.');
    }
    if (agent != null) await terminateSanadDevProcessTree(agent.pid);
    if (client != null) await terminateSanadDevProcessTree(client.pid);
    await agentJournal?.cancel();
    await clientJournal?.cancel();
    await deleteRuntimeLauncherRecord(runtime.sanadHome, runtime.agentPort);
    await recordStartup(
      stage: SanadDevStartupStage.cleanup,
      outcome: SanadDevStartupOutcome.failed,
      exitStatus: 1,
      failureReason: !agentHealthy
          ? 'agent readiness failed'
          : 'client readiness failed',
    );
    exitCode = 1;
    return;
  }

  if (agentHealthy && startsAgent) print('✓ Agent started successfully.');
  if (discoveredClient != null) print('✓ Client started on $device.');
  launcherRecord = launcherRecord.copyWith(
    clientPids: [if (discoveredClient?.pid != null) discoveredClient!.pid!],
    vmServicePorts: [if (discoveredClient != null) runtime.vmServicePort],
    status: startsAgent && startsClient
        ? 'running'
        : startsAgent
        ? 'agent-only'
        : 'client-only',
  );
  await writeRuntimeLauncherRecord(launcherRecord);
  await recordStartup(
    stage: SanadDevStartupStage.managed,
    outcome: SanadDevStartupOutcome.managed,
    exitStatus: 0,
  );
  await cancelStartupSignals();

  final staleControl = File(
    runtimeComponentControlPath(runtime.sanadHome, runtime.agentPort),
  );
  if (await staleControl.exists()) await staleControl.delete();
  final controller = _SwitchableRuntimeController(
    runtime: runtime,
    agent: agent,
    client: client,
    agentEnvironment: agentEnvironment,
    agentArguments: const ['dart', 'run', 'bin/sanad_agent.dart', 'daemon'],
    clientArguments: flutterArguments,
    clientEnvironment: clientEnvironment,
    agentDirectory: agentDirectory,
    clientDirectory: clientDirectory,
    agentJournal: agentJournal,
    initialClientJournal: clientJournal,
    launcherRecord: launcherRecord,
    interactiveComponent: startsAgent
        ? SanadDevComponentTarget.agent
        : SanadDevComponentTarget.client,
  );
  print(
    startsAgent
        ? 'Controls: r/R restart Agent; s/q safely stop Agent; Ctrl+C stops this managed runtime.'
        : 'Controls: r reload; R restart; h help; d detach; c clear; q quit; Ctrl+C stops this managed runtime.',
  );
  final clientExitCode = await controller.run();
  if (clientExitCode != 0) exitCode = clientExitCode;
}
