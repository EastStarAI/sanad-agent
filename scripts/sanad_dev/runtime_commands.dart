part of '../sanad_dev.dart';

class RuntimeProcessState {
  const RuntimeProcessState({
    required this.agent,
    required this.ownedClients,
    required this.crossOwnedClients,
    required this.ambiguousClients,
    this.agentAmbiguous = false,
  });

  final AgentInstance? agent;
  final List<ClientInstance> ownedClients;
  final List<ClientInstance> crossOwnedClients;
  final List<ClientInstance> ambiguousClients;
  final bool agentAmbiguous;

  List<ClientInstance> get pairedClients => ownedClients;
  List<ClientInstance> get blockedClients =>
      List.unmodifiable([...crossOwnedClients, ...ambiguousClients]);
  List<ClientInstance> get relevantClients =>
      List.unmodifiable([...ownedClients, ...blockedClients]);
  bool get mutationAllowed => blockedClients.isEmpty && !agentAmbiguous;
}

class RuntimeOwnershipAssessment {
  const RuntimeOwnershipAssessment({
    required this.classification,
    required this.state,
    this.record,
    this.reason,
  });

  final RuntimeOwnershipClass classification;
  final RuntimeProcessState state;
  final RuntimeLauncherRecord? record;
  final String? reason;

  bool get isManaged => classification == RuntimeOwnershipClass.managed;
}

String resolveActiveSanadHome(
  SanadDevRuntime runtime,
  RuntimeProcessState state,
) =>
    state.relevantClients
        .map((client) => client.launchProfile?.define('SANAD_HOME'))
        .whereType<String>()
        .firstOrNull ??
    state.agent?.sanadHome ??
    runtime.sanadHome;

Future<RuntimeOwnershipAssessment> assessRuntimeOwnership({
  required SanadDevRuntime runtime,
  required RuntimeProcessState state,
  String? sanadHome,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  Future<String?> Function(int pid) processIdentity = readProcessIdentity,
}) async {
  if (state.agent == null && state.relevantClients.isEmpty) {
    if (state.agentAmbiguous) {
      return RuntimeOwnershipAssessment(
        classification: RuntimeOwnershipClass.ambiguous,
        state: state,
        reason: 'more than one Agent matches the requested workspace',
      );
    }
    return RuntimeOwnershipAssessment(
      classification: RuntimeOwnershipClass.stopped,
      state: state,
    );
  }
  final activeHome = sanadHome ?? resolveActiveSanadHome(runtime, state);
  RuntimeLauncherRecord? record;
  try {
    record = await readRuntimeLauncherRecord(
      activeHome,
      state.agent?.port ?? runtime.agentPort,
    );
  } on Object {
    return RuntimeOwnershipAssessment(
      classification: RuntimeOwnershipClass.unverifiable,
      state: state,
      reason: 'launcher record is invalid',
    );
  }
  if (record == null) {
    if (state.crossOwnedClients.isNotEmpty) {
      return RuntimeOwnershipAssessment(
        classification: RuntimeOwnershipClass.crossOwned,
        state: state,
        reason: 'one or more clients belong to another runtime group',
      );
    }
    if (state.ambiguousClients.isNotEmpty) {
      return RuntimeOwnershipAssessment(
        classification: RuntimeOwnershipClass.unverifiable,
        state: state,
        reason: 'one or more client launch profiles are incomplete',
      );
    }
    return RuntimeOwnershipAssessment(
      classification: RuntimeOwnershipClass.manual,
      state: state,
      reason: 'no live sanad-dev launcher lease exists',
    );
  }
  final activeRecord = record;
  final managedClients = state.ownedClients
      .where((client) {
        final profile = client.launchProfile;
        return client.pid != null &&
            activeRecord.clientPids.contains(client.pid) &&
            activeRecord.vmServicePorts.contains(client.port) &&
            profile?.define('SANAD_DEV_LAUNCHER_ID') ==
                activeRecord.launcherId &&
            profile?.define('SANAD_DEV_RUNTIME_NONCE') ==
                activeRecord.runtimeNonce;
      })
      .toList(growable: false);
  final recordError = validateManagedRuntimeRecord(
    record: record,
    agentPort: state.agent?.port ?? runtime.agentPort,
    sanadHome: activeHome,
    workspaceHash: state.agent?.workspaceHash ?? record.workspaceHash,
    launcherRunning: await processRunning(record.launcherPid),
    launcherProcessIdentity: await processIdentity(record.launcherPid),
    clientDefines: managedClients.map(
      (client) => client.launchProfile?.defines ?? const {},
    ),
    clientPids: managedClients.map((client) => client.pid),
    vmServicePorts: managedClients.map((client) => client.port),
  );
  final agentIdentityMatches =
      state.agent == null ||
      (state.agent!.launcherId == activeRecord.launcherId &&
          state.agent!.runtimeNonce == activeRecord.runtimeNonce);
  if (recordError != null || !agentIdentityMatches) {
    return RuntimeOwnershipAssessment(
      classification: RuntimeOwnershipClass.orphaned,
      state: state,
      record: record,
      reason:
          recordError ??
          'Agent launcher identity or nonce does not match the lease',
    );
  }
  return RuntimeOwnershipAssessment(
    classification: RuntimeOwnershipClass.managed,
    state: RuntimeProcessState(
      agent: state.agent,
      ownedClients: List.unmodifiable(managedClients),
      crossOwnedClients: const [],
      ambiguousClients: const [],
      agentAmbiguous: state.agentAmbiguous,
    ),
    record: activeRecord,
  );
}

RuntimeProcessState selectRuntimeProcessState({
  required Iterable<AgentInstance> activeAgents,
  required Iterable<ClientInstance> activeClients,
  required SanadDevRuntime runtime,
  int? requestedAgentPort,
  bool Function(String? first, String second)? pathMatches,
}) {
  final matchesPath = pathMatches ?? _samePath;
  final workspaceHash = runtime.worktreeId.split('-').last;
  final clientDirectory =
      '${runtime.repositoryRoot}${Platform.pathSeparator}client';
  final matchingAgents = activeAgents.where(
    (agent) =>
        (requestedAgentPort != null && agent.port == requestedAgentPort) ||
        (requestedAgentPort == null && agent.workspaceHash == workspaceHash),
  );
  final agentAmbiguous = matchingAgents.length > 1;
  final matchingAgent = matchingAgents.length == 1
      ? matchingAgents.single
      : null;

  final agentsByPort = {for (final agent in activeAgents) agent.port: agent};
  final primaryHome = resolveDefaultUserSanadHome(Platform.environment);
  final owned = <ClientInstance>[];
  final crossOwned = <ClientInstance>[];
  final ambiguous = <ClientInstance>[];
  for (final client in activeClients) {
    final sourceMatches = matchesPath(client.path, clientDirectory);
    final discoveredProfile = client.launchProfile;
    final effectiveProfile = discoveredProfile == null
        ? null
        : withImplicitPrimaryClientDefaults(
            discoveredProfile,
            allowed:
                sourceMatches &&
                runtime.usesPrimaryResources &&
                matchingAgent?.port == canonicalPrimaryAgentPort &&
                _samePath(runtime.sanadHome, primaryHome),
            primarySanadHome: primaryHome,
          );
    final gateway = Uri.tryParse(
      effectiveProfile?.define('LOCAL_GATEWAY_URL') ?? '',
    );
    final gatewayPort = gateway?.hasPort == true ? gateway!.port : null;
    final attachedToSelected =
        matchingAgent != null && gatewayPort == matchingAgent.port;
    if (!sourceMatches && !attachedToSelected) continue;

    if (!sourceMatches ||
        (attachedToSelected && matchingAgent.workspaceHash != workspaceHash)) {
      crossOwned.add(client);
      continue;
    }
    if (matchingAgent == null) {
      final gatewayAgent = gatewayPort == null
          ? null
          : agentsByPort[gatewayPort];
      if (gatewayAgent != null && gatewayAgent.workspaceHash != workspaceHash) {
        crossOwned.add(client);
        continue;
      }
      if (gatewayAgent == null &&
          gatewayPort == runtime.agentPort &&
          effectiveProfile != null) {
        final profileError = validateClientLaunchProfile(
          effectiveProfile,
          isLinkedWorktree: runtime.isLinkedWorktree,
          expectedWorktreeName: runtime.worktreeDisplayName,
          expectedBranch: runtime.branch,
          expectedWorkspaceHash: workspaceHash,
          workspaceHashRequired:
              !runtime.isLinkedWorktree && !runtime.usesPrimaryResources,
          expectedAgentPort: runtime.agentPort,
          emptyPreferencesSanadHome: runtime.usesPrimaryResources
              ? runtime.sanadHome
              : primaryHome,
          derivePreferencesPrefix: deriveSanadDevPreferencesPrefix,
        );
        (profileError == null ? owned : ambiguous).add(client);
        continue;
      }
      ambiguous.add(client);
      continue;
    }
    if (!attachedToSelected) {
      (gatewayPort != null && agentsByPort[gatewayPort] != null
              ? crossOwned
              : ambiguous)
          .add(client);
      continue;
    }

    if (effectiveProfile == null) {
      ambiguous.add(client);
      continue;
    }
    final profileError = validateClientLaunchProfile(
      effectiveProfile,
      isLinkedWorktree: runtime.isLinkedWorktree,
      expectedWorktreeName: runtime.worktreeDisplayName,
      expectedBranch: runtime.branch,
      expectedWorkspaceHash: workspaceHash,
      workspaceHashRequired:
          !runtime.isLinkedWorktree && !runtime.usesPrimaryResources,
      expectedAgentPort: matchingAgent.port,
      emptyPreferencesSanadHome: runtime.usesPrimaryResources
          ? runtime.sanadHome
          : primaryHome,
      derivePreferencesPrefix: deriveSanadDevPreferencesPrefix,
    );
    (profileError == null ? owned : ambiguous).add(client);
  }

  int byPort(ClientInstance left, ClientInstance right) =>
      left.port.compareTo(right.port);
  owned.sort(byPort);
  crossOwned.sort(byPort);
  ambiguous.sort(byPort);
  return RuntimeProcessState(
    agent: matchingAgent,
    ownedClients: List.unmodifiable(owned),
    crossOwnedClients: List.unmodifiable(crossOwned),
    ambiguousClients: List.unmodifiable(ambiguous),
    agentAmbiguous: agentAmbiguous,
  );
}

String runtimeStatusLabel(RuntimeProcessState state) {
  if (state.agent == null && state.relevantClients.isEmpty) {
    if (state.agentAmbiguous) return 'ambiguous (mutation refused)';
    return 'not started';
  }
  if (!state.mutationAllowed) return 'ownership conflict (stop refused)';
  if (state.agent == null) return 'running (client only)';
  if (state.ownedClients.isEmpty) return 'running (agent only)';
  return 'running';
}

String runtimeClientSummary(ClientInstance client) {
  return 'device=${client.deviceId ?? 'unknown'} vm=${client.port} '
      'pid=${client.pid ?? '-'} source=${client.path}';
}

String noActiveRuntimeMessage(SanadDevRuntime runtime) =>
    'No active sanad-dev runtime found for ${runtime.worktreeId}.';

String runtimeSourceSwitchLabel(String status, [String? message]) =>
    'Last source switch: $status${message == null ? '' : ' ($message)'}';

String crossOwnedRunMessage() =>
    'A cross-owned or unverifiable Flutter client is active for this source. '
    'sanad-dev will not stop or replace it. Stop it only from its owning '
    'runtime or IDE session.';

String? primaryResourceOwnershipConflict(
  SanadDevRuntime runtime,
  Iterable<AgentInstance> activeAgents, {
  Iterable<ClientInstance> activeClients = const [],
}) {
  if (!runtime.usesPrimaryResources) return null;
  final workspaceHash = runtime.worktreeId.split('-').last;
  final clientDirectory =
      '${runtime.repositoryRoot}${Platform.pathSeparator}client';
  final agentConflict = activeAgents.any(
    (agent) =>
        agent.port == canonicalPrimaryAgentPort &&
        agent.workspaceHash != workspaceHash,
  );
  final clientConflict = activeClients.any((client) {
    final clientHome = client.launchProfile?.define('SANAD_HOME');
    return clientHome != null &&
        _samePath(clientHome, runtime.sanadHome) &&
        !_samePath(client.path, clientDirectory);
  });
  if (agentConflict || clientConflict) {
    return 'The primary sanad-dev runtime is owned by another Git workspace. '
        'This standalone checkout will not share its Home or port; rerun with '
        'an explicit absolute --home path.';
  }
  return null;
}

Future<void> handleRun({
  required SanadDevComponentTarget target,
  required bool driverMode,
  required bool cloudEnabled,
  required bool dryRun,
  required String device,
  required String configPath,
  required String? sanadHomePath,
}) async {
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final startsAgent = target != SanadDevComponentTarget.client;
  final startsClient = target != SanadDevComponentTarget.agent;

  final activeAgents = await discoverAgentInstances();
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
          managedState.ownedClients.any((client) => client.deviceId == device);
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

  final configFile = File(
    configPath.startsWith('/')
        ? configPath
        : '$clientDirectory${Platform.pathSeparator}$configPath',
  );
  if (!configFile.existsSync()) {
    stderr.writeln('Client configuration not found: ${configFile.path}');
    exitCode = 1;
    return;
  }

  SanadCloudEndpoints? cloudEndpoints;
  if (cloudEnabled) {
    try {
      cloudEndpoints = readSanadCloudEndpoints(configFile);
    } on FormatException catch (error) {
      stderr.writeln(error.message);
      exitCode = 64;
      return;
    }
  }

  await secureRuntimeDirectory(runtime.sanadHome, runtime.sanadHome);
  await cleanupStaleComponentJournals(runtime.sanadHome);

  final preferencesPrefix = resolveSanadDevPreferencesPrefix(
    isLinkedWorktree: runtime.isLinkedWorktree,
    sanadHome: runtime.sanadHome,
    sanadHomeSelector: sanadHomePath,
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
    '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=$preferencesPrefix',
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
  final clientEnvironment = buildUnifiedSanadHomeEnvironment(
    Platform.environment,
    sanadHome: runtime.sanadHome,
  );

  Process? agent;
  Process? client;
  ComponentProcessJournal? agentJournal;
  ComponentProcessJournal? clientJournal;
  final bootLogs = <String>[];
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
    stderr.writeln('Component failed to start: $error');
    if (agent != null) await terminateSanadDevProcessTree(agent.pid);
    if (client != null) await terminateSanadDevProcessTree(client.pid);
    await deleteRuntimeLauncherRecord(runtime.sanadHome, runtime.agentPort);
    exitCode = 1;
    return;
  }

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
      mirrorStdout: true,
      mirrorStderr: true,
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
      mirrorStdout: !startsAgent,
      mirrorStderr: !startsAgent,
    );
  }

  if (startsAgent && startsClient) {
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

  var agentHealthy = !startsAgent;
  ClientInstance? discoveredClient;
  await Future.wait<void>([
    if (startsAgent)
      () async {
        agentHealthy = await _waitForAgent(runtime, agentDirectory);
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
  if (!agentHealthy || (startsClient && discoveredClient?.pid == null)) {
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
        ? 'Controls: r/R restart Agent; Ctrl+C stops this managed runtime.'
        : 'Controls: r hot reload; R hot restart; Ctrl+C stops this managed runtime.',
  );
  final clientExitCode = await controller.run();
  if (clientExitCode != 0) exitCode = clientExitCode;
}

Future<ClientInstance?> _waitForManagedClientIdentity({
  required int vmServicePort,
  required String launcherId,
  required String runtimeNonce,
}) async {
  final deadline = DateTime.now().add(const Duration(seconds: 90));
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

Future<void> handleRuntimeStatus({int? portOverride}) async {
  final runtime = await _currentRuntime();
  final activeAgents = await discoverAgentInstances();
  final activeClients = await discoverClientInstances();
  final processState = selectRuntimeProcessState(
    activeAgents: activeAgents,
    activeClients: activeClients,
    runtime: runtime,
    requestedAgentPort: portOverride,
  );
  final matchingAgent = processState.agent;
  final runtimeClients = processState.pairedClients;
  final visibleClients = processState.relevantClients;
  final activeSanadHome = resolveActiveSanadHome(runtime, processState);
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: processState,
    sanadHome: activeSanadHome,
  );
  final sourcePaths =
      visibleClients
          .map((client) => client.path)
          .where((path) => path.isNotEmpty)
          .map((path) => Directory(path).parent.path)
          .toSet()
          .toList()
        ..sort();
  final runtimeBranches =
      visibleClients
          .map(
            (client) =>
                client.launchProfile?.define('SANAD_DEV_WORKTREE_BRANCH') ??
                'main',
          )
          .toSet()
          .toList()
        ..sort();

  print('Command worktree: ${runtime.repositoryRoot}');
  print('Command branch: ${runtime.branch}');
  print(
    'Runtime source: ${sourcePaths.isEmpty ? (matchingAgent == null ? '-' : runtime.repositoryRoot) : sourcePaths.join(', ')}',
  );
  print(
    'Runtime branch: ${runtimeBranches.isEmpty ? (matchingAgent == null ? '-' : runtime.branch) : runtimeBranches.join(', ')}',
  );
  print('Worktree: ${runtime.worktreeId}');
  print('Branch: ${runtime.branch}');

  print(
    'Cloud gateway: ${matchingAgent?.gatewayEnabled == true ? 'enabled' : 'disabled'}',
  );
  print(
    'Agent gateway: ${matchingAgent == null ? '-' : 'http://127.0.0.1:${matchingAgent.port}'}',
  );
  print('Sanad home: $activeSanadHome');
  print(
    'Status: ${runtimeStatusLabel(ownership.isManaged ? ownership.state : processState)}',
  );
  print('Runtime class: ${ownership.classification.name}');
  if (ownership.reason != null) {
    print('Ownership detail: ${ownership.reason}');
  }
  if (ownership.record != null) {
    print(
      'Launcher: PID ${ownership.record!.launcherPid} '
      'id=${ownership.record!.launcherId}',
    );
  }

  if (matchingAgent == null) {
    print('Agent PID: - (stopped)');
  } else {
    print('Agent (external): running on port ${matchingAgent.port}');
  }
  print('Clients: ${runtimeClients.length}');
  for (final client in runtimeClients) {
    final profile = client.launchProfile;
    final marker = profile?.define('SANAD_DEV_WORKTREE_NAME');
    print(
      '  - device=${client.deviceId ?? 'unknown'} vm=${client.port} '
      'pid=${client.pid ?? '-'} source=${client.path} '
      'worktree=${marker?.isNotEmpty == true ? marker : 'main'} '
      'switch_capable=${profile?.define('SANAD_DEV_SWITCH_CAPABLE') == 'true'}',
    );
  }
  print('Cross-owned clients: ${processState.crossOwnedClients.length}');
  for (final client in processState.crossOwnedClients) {
    print('  - ${runtimeClientSummary(client)} (stop refused)');
  }
  print('Unverifiable clients: ${processState.ambiguousClients.length}');
  for (final client in processState.ambiguousClients) {
    print('  - ${runtimeClientSummary(client)} (stop refused)');
  }

  if (matchingAgent != null) {
    print('Agent log: Stream logs via "sanad-dev logs agent"');
    try {
      final handoff = await readRuntimeSwitchRequest(
        runtimeSwitchManifestPath(activeSanadHome, matchingAgent.port),
      );
      if (handoff != null) {
        print(runtimeSourceSwitchLabel(handoff.status, handoff.message));
      }
    } on Object {
      print('Last source switch: invalid handoff record');
    }
  } else {
    print('Agent log: -');
  }
}

typedef ProcessTerminator = bool Function(int pid, ProcessSignal signal);
typedef LauncherStopRequester =
    Future<void> Function(RuntimeLauncherRecord record);

Future<bool> stopManagedRuntimeLauncher(
  RuntimeOwnershipAssessment ownership, {
  LauncherStopRequester requestStop = writeRuntimeLauncherStopRequest,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final record = ownership.record;
  if (!ownership.isManaged || record == null) return false;
  try {
    await requestStop(record);
  } on Object {
    return false;
  }
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!await processRunning(record.launcherPid)) return true;
    await Future<void>.delayed(pollInterval);
  }
  return false;
}

RuntimeComponentTarget _componentControlTarget(
  SanadDevComponentTarget target,
) => switch (target) {
  SanadDevComponentTarget.all => RuntimeComponentTarget.all,
  SanadDevComponentTarget.agent => RuntimeComponentTarget.agent,
  SanadDevComponentTarget.client => RuntimeComponentTarget.client,
};

Future<bool> requestManagedComponentAction(
  RuntimeLauncherRecord record, {
  required RuntimeComponentAction action,
  required RuntimeComponentTarget target,
  String? deviceId,
  int? clientPid,
  int? vmServicePort,
  bool force = false,
  bool openClientTerminal = true,
  Duration timeout = sanadDevComponentControlTimeout,
}) async {
  final path = runtimeComponentControlPath(record.sanadHome, record.agentPort);
  final existing = await readRuntimeComponentControl(path);
  if (existing != null && !existing.isTerminal) {
    stderr.writeln('Another runtime component action is already pending.');
    return false;
  }
  final request = RuntimeComponentControlRequest(
    requestId: _newRuntimeOwnershipToken(),
    launcherId: record.launcherId,
    runtimeNonce: record.runtimeNonce,
    action: action,
    target: target,
    status: 'requested',
    requestedAt: DateTime.now().toUtc(),
    deviceId: deviceId,
    clientPid: clientPid,
    vmServicePort: vmServicePort,
    force: force,
    openClientTerminal: openClientTerminal,
  );
  await writeRuntimeComponentControl(path, request);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final result = await readRuntimeComponentControl(path);
    if (result?.requestId == request.requestId && result!.isTerminal) {
      final succeeded = result.status == 'complete';
      if (!succeeded) {
        stderr.writeln(result.message ?? 'Runtime component action failed.');
      }
      final file = File(path);
      if (await file.exists()) await file.delete();
      return succeeded;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final pending = await readRuntimeComponentControl(path);
  if (pending?.requestId == request.requestId && !pending!.isTerminal) {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
  stderr.writeln('Runtime component action timed out.');
  return false;
}

Future<void> handleRuntimeStop({
  SanadDevComponentTarget target = SanadDevComponentTarget.all,
  String? device,
  int? vmServicePort,
  bool force = false,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final runtime = await _currentRuntime();
  final processState = selectRuntimeProcessState(
    activeAgents: await discoverAgentInstances(),
    activeClients: await discoverClientInstances(),
    runtime: runtime,
  );

  if (processState.agent == null &&
      processState.relevantClients.isEmpty &&
      !processState.agentAmbiguous) {
    print(noActiveRuntimeMessage(runtime));
    return;
  }
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: processState,
    sanadHome: resolveActiveSanadHome(runtime, processState),
    processRunning: processRunning,
  );
  if (!ownership.isManaged) {
    stderr.writeln(
      'Refusing to stop ${runtime.worktreeId}: runtime class is '
      '${ownership.classification.name} '
      '(${ownership.reason ?? 'launcher ownership is not proven'}). '
      'Run "sanad-dev doctor" for a safe next action.',
    );
    exitCode = 1;
    return;
  }
  ClientInstance? selectedClient;
  if (target == SanadDevComponentTarget.client) {
    final selection = selectClientByDevice(
      clients: ownership.state.ownedClients,
      deviceId: device,
      vmServicePort: vmServicePort,
    );
    if (selection.kind != ClientSelectionKind.exact) {
      stderr.writeln(
        selection.kind == ClientSelectionKind.missing
            ? 'No owned Client matches the requested device/VM selector.'
            : 'Client selector is ambiguous; add -p <vm-port>.',
      );
      for (final client
          in selection.matches.isEmpty
              ? ownership.state.ownedClients
              : selection.matches) {
        stderr.writeln('  - ${runtimeClientSummary(client)}');
      }
      exitCode = 1;
      return;
    }
    selectedClient = selection.selected;
  }
  final stopped = await requestManagedComponentAction(
    ownership.record!,
    action: RuntimeComponentAction.stop,
    target: _componentControlTarget(target),
    deviceId: selectedClient?.deviceId,
    clientPid: selectedClient?.pid,
    vmServicePort: selectedClient?.port,
    force: force,
  );
  if (!stopped) {
    exitCode = 1;
    return;
  }
  print('Stopped ${target.name} for ${runtime.worktreeId}.');
}

Future<void> handleRuntimeDoctor({
  required bool fix,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final runtime = await _currentRuntime();
  final agents = await discoverAgentInstances();
  final clients = await discoverClientInstances();
  final state = selectRuntimeProcessState(
    activeAgents: agents,
    activeClients: clients,
    runtime: runtime,
  );
  final activeHome = resolveActiveSanadHome(runtime, state);
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: state,
    sanadHome: activeHome,
    processRunning: processRunning,
  );

  print('Runtime: ${runtime.worktreeId}');
  print('Class: ${ownership.classification.name}');
  print('Agent: ${state.agent?.port ?? '-'}');
  print('Owned clients: ${state.ownedClients.length}');
  print('Cross-owned clients: ${state.crossOwnedClients.length}');
  print('Unverifiable clients: ${state.ambiguousClients.length}');
  if (ownership.reason != null) print('Reason: ${ownership.reason}');

  final record =
      ownership.record ??
      await _readRuntimeLauncherRecordSafely(
        activeHome,
        state.agent?.port ?? runtime.agentPort,
      );
  if (record != null) {
    final launcherLive = await processRunning(record.launcherPid);
    print(
      'Launcher lease: PID ${record.launcherPid} '
      '(${launcherLive ? 'live' : 'stale'})',
    );
    if (fix) {
      final endpointLive = agents.any(
        (agent) => agent.port == record.agentPort,
      );
      final clientLive = clients.any(
        (client) =>
            clientAgentPort(client) == record.agentPort ||
            client.launchProfile?.define('SANAD_DEV_LAUNCHER_ID') ==
                record.launcherId,
      );
      if (!launcherLive && !endpointLive && !clientLive) {
        await deleteRuntimeLauncherRecord(record.sanadHome, record.agentPort);
        print(
          'Fixed: removed one stale launcher record; no process was signaled.',
        );
        return;
      }
      stderr.writeln(
        'No fix applied: a launcher or runtime endpoint is still live.',
      );
      exitCode = 1;
      return;
    }
  } else if (fix) {
    final candidatePath = runtimeLauncherRecordPath(
      activeHome,
      state.agent?.port ?? runtime.agentPort,
    );
    final candidate = File(candidatePath);
    if (ownership.classification == RuntimeOwnershipClass.stopped &&
        await candidate.exists()) {
      await candidate.delete();
      print(
        'Fixed: removed one invalid stale launcher record; no process was '
        'signaled.',
      );
      return;
    }
    print('No stale launcher record requires repair.');
    return;
  }

  final nextAction = switch (ownership.classification) {
    RuntimeOwnershipClass.managed => 'Use sanad-dev status/stop/switch.',
    RuntimeOwnershipClass.manual =>
      'Use sanad-dev takeover after confirming the manual pair.',
    RuntimeOwnershipClass.orphaned =>
      'Inspect the listed ownership evidence; use target cleanup only for a '
          'non-source stale target.',
    RuntimeOwnershipClass.stopped => 'Use sanad-dev run.',
    _ => 'Resolve the owning IDE/runtime; automatic mutation is refused.',
  };
  print('Next action: $nextAction');
}

Future<RuntimeLauncherRecord?> _readRuntimeLauncherRecordSafely(
  String sanadHome,
  int agentPort,
) async {
  try {
    return await readRuntimeLauncherRecord(sanadHome, agentPort);
  } on Object {
    return null;
  }
}

Future<void> handleTargetOrphanCleanup({
  ProcessTerminator terminateProcess = Process.killPid,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final runtime = await _currentRuntime();
  final sourcePort = _requestingAgentPort();
  final agents = await discoverAgentInstances();
  final clients = await discoverClientInstances();
  final targetDirectory =
      '${runtime.repositoryRoot}${Platform.pathSeparator}client';
  final targetClients = clients
      .where((client) => _samePath(client.path, targetDirectory))
      .toList(growable: false);
  if (targetClients.isEmpty) {
    print('No target orphan clients found for ${runtime.worktreeId}.');
    return;
  }
  final targetPorts = targetClients
      .map(clientAgentPort)
      .whereType<int>()
      .toSet();
  if (sourcePort != null && targetPorts.contains(sourcePort)) {
    stderr.writeln(
      'Cleanup refused: a target client is attached to the requester/source '
      'Agent port $sourcePort.',
    );
    exitCode = 1;
    return;
  }
  if (agents.any((agent) => targetPorts.contains(agent.port))) {
    stderr.writeln(
      'Cleanup refused: the target Agent is still live; this is not an orphan.',
    );
    exitCode = 1;
    return;
  }

  RuntimeLauncherRecord? record;
  for (final client in targetClients) {
    final profile = client.launchProfile;
    final home = profile?.define('SANAD_HOME');
    final port = clientAgentPort(client);
    if (client.pid == null ||
        home == null ||
        port == null ||
        profile?.define('SANAD_DEV_LAUNCHER_ID') == null ||
        profile?.define('SANAD_DEV_RUNTIME_NONCE') == null) {
      stderr.writeln(
        'Cleanup refused: target includes a live IDE-owned or unverifiable '
        'client (${runtimeClientSummary(client)}).',
      );
      exitCode = 1;
      return;
    }
    final candidate = await _readRuntimeLauncherRecordSafely(home, port);
    if (candidate == null ||
        await processRunning(candidate.launcherPid) ||
        profile!.define('SANAD_DEV_LAUNCHER_ID') != candidate.launcherId ||
        profile.define('SANAD_DEV_RUNTIME_NONCE') != candidate.runtimeNonce ||
        (record != null && record.launcherId != candidate.launcherId)) {
      stderr.writeln(
        'Cleanup refused: stale target ownership could not be proven for '
        '${runtimeClientSummary(client)}.',
      );
      exitCode = 1;
      return;
    }
    record = candidate;
  }
  if (record == null || sourcePort == record.agentPort) {
    stderr.writeln('Cleanup refused: source-runtime protection failed.');
    exitCode = 1;
    return;
  }

  for (final client in targetClients) {
    print('Cleaning target orphan PID ${client.pid} (VM ${client.port})...');
    if (!terminateProcess(client.pid!, ProcessSignal.sigterm)) {
      stderr.writeln(
        'Cleanup failed while signaling PID ${client.pid}; no success claimed.',
      );
      exitCode = 1;
      return;
    }
  }
  await deleteRuntimeLauncherRecord(record.sanadHome, record.agentPort);
  print('Cleaned ${targetClients.length} target orphan client(s).');
}

Future<void> handleRuntimeTakeover({
  ProcessTerminator terminateProcess = Process.killPid,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  if (Platform.environment['SANAD_REQUESTER_SESSION_ID']?.isNotEmpty == true ||
      Platform.environment['SANAD_REQUESTER_TOOL_CALL_ID']?.isNotEmpty ==
          true) {
    stderr.writeln(
      'Takeover refused from an active Agent tool call. Run it directly in a '
      'human-owned terminal after reviewing "sanad-dev doctor".',
    );
    exitCode = 1;
    return;
  }
  final runtime = await _currentRuntime();
  final agents = await discoverAgentInstances();
  final clients = await discoverClientInstances();
  final state = selectRuntimeProcessState(
    activeAgents: agents,
    activeClients: clients,
    runtime: runtime,
  );
  final activeHome = resolveActiveSanadHome(runtime, state);
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: state,
    sanadHome: activeHome,
    processRunning: processRunning,
  );
  if (ownership.classification != RuntimeOwnershipClass.manual ||
      state.agent == null ||
      state.ownedClients.length != 1) {
    stderr.writeln(
      'Takeover refused: expected one complete manual Agent/client pair, found '
      '${ownership.classification.name} with ${state.ownedClients.length} '
      'owned client(s).',
    );
    exitCode = 1;
    return;
  }

  final client = state.ownedClients.single;
  final profile = client.launchProfile!;
  final configArgument = profile.compileArguments.firstWhere(
    (argument) => argument.startsWith('--dart-define-from-file='),
    orElse: () => '',
  );
  if (client.pid == null || configArgument.isEmpty) {
    stderr.writeln(
      'Takeover refused: the manual client PID or config launch argument is '
      'not discoverable.',
    );
    exitCode = 1;
    return;
  }
  final configPath = configArgument.substring(
    '--dart-define-from-file='.length,
  );
  final cloudEnabled =
      profile.define('ENABLE_CLOUD_GATEWAY')?.toLowerCase() != 'false';
  final driverMode = profile.target?.endsWith('driver_main.dart') == true;
  final homeSelector =
      !runtime.isLinkedWorktree &&
          _samePath(
            activeHome,
            resolveDefaultUserSanadHome(Platform.environment),
          )
      ? 'user'
      : activeHome;

  print(
    'Draining manual Agent ${state.agent!.port} before controlled takeover...',
  );
  if (!await _requestTakeoverRestart(state.agent!.port, activeHome)) {
    stderr.writeln(
      'Takeover aborted: the manual Agent rejected safe restart; the client '
      'was not signaled.',
    );
    exitCode = 1;
    return;
  }
  if (!await _waitForAgentPortToStop(state.agent!.port, activeHome)) {
    stderr.writeln(
      'Takeover aborted: the drained Agent did not exit; the client was not '
      'signaled.',
    );
    exitCode = 1;
    return;
  }
  if (!terminateProcess(client.pid!, ProcessSignal.sigterm)) {
    final restored = await _restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: profile,
      cloudEnabled: cloudEnabled,
      restoreClient: false,
    );
    stderr.writeln(
      'Takeover failed: the manual client could not be stopped after the safe '
      'Agent drain. Previous Agent restoration: '
      '${restored ? 'complete' : 'failed'}.',
    );
    exitCode = 1;
    return;
  }
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (await processRunning(client.pid) &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (await processRunning(client.pid)) {
    final restored = await _restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: profile,
      cloudEnabled: cloudEnabled,
      restoreClient: false,
    );
    stderr.writeln(
      'Takeover failed: the manual client did not exit; managed relaunch was '
      'not attempted. Previous Agent restoration: '
      '${restored ? 'complete' : 'failed'}.',
    );
    exitCode = 1;
    return;
  }
  final vmDeadline = DateTime.now().add(const Duration(seconds: 10));
  while (await _vmServiceIsAvailable(client.port) &&
      DateTime.now().isBefore(vmDeadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (await _vmServiceIsAvailable(client.port)) {
    final restored = await _restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: profile,
      cloudEnabled: cloudEnabled,
      restoreClient: false,
    );
    stderr.writeln(
      'Takeover failed: the manual VM service remained active. Previous Agent '
      'restoration: ${restored ? 'complete' : 'failed'}.',
    );
    exitCode = 1;
    return;
  }

  print('Manual pair drained; relaunching under one sanad-dev lease.');
  await handleRun(
    target: SanadDevComponentTarget.all,
    driverMode: driverMode,
    cloudEnabled: cloudEnabled,
    dryRun: false,
    device: client.deviceId ?? profile.deviceId ?? _defaultDesktopDevice(),
    configPath: configPath,
    sanadHomePath: homeSelector,
  );
  if (exitCode != 0) {
    final restored = await _restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: profile,
      cloudEnabled: cloudEnabled,
      restoreClient: true,
    );
    stderr.writeln(
      'Managed takeover launch failed. Previous manual pair restoration: '
      '${restored ? 'complete' : 'failed'}.',
    );
  }
}

Future<bool> _restoreManualRuntime({
  required SanadDevRuntime runtime,
  required int agentPort,
  required String sanadHome,
  required ClientInstance client,
  required ClientLaunchProfile profile,
  required bool cloudEnabled,
  required bool restoreClient,
}) async {
  try {
    final agentEnvironment =
        buildUnifiedSanadHomeEnvironment(
            Platform.environment,
            sanadHome: sanadHome,
          )
          ..remove('SANAD_DEV_LAUNCHER_ID')
          ..remove('SANAD_DEV_RUNTIME_NONCE')
          ..['ENABLE_LOCAL_GATEWAY'] = 'true'
          ..['LOCAL_GATEWAY_PORT'] = '$agentPort'
          ..['ENABLE_GATEWAY'] = cloudEnabled ? 'true' : 'false';
    final agent = await Process.start(
      'fvm',
      const ['dart', 'run', 'bin/sanad_agent.dart', 'daemon'],
      workingDirectory:
          '${runtime.repositoryRoot}${Platform.pathSeparator}agent',
      environment: agentEnvironment,
      runInShell: Platform.isWindows,
    );
    unawaited(agent.stdout.drain<void>());
    unawaited(agent.stderr.drain<void>());
    if (!await _waitForAgentHealthPort(
      agentPort,
      runtime.worktreeId.split('-').last,
      runtime.sanadHome,
    )) {
      return false;
    }
    if (restoreClient && !await _vmServiceIsAvailable(client.port)) {
      final arguments = [
        'flutter',
        'run',
        '-d',
        client.deviceId ?? profile.deviceId ?? _defaultDesktopDevice(),
        ...profile.compileArguments,
        '--host-vmservice-port=${client.port}',
        '--disable-service-auth-codes',
        if (profile.target?.isNotEmpty == true) ...['-t', profile.target!],
      ];
      final restoredClient = await Process.start(
        'fvm',
        arguments,
        workingDirectory:
            '${runtime.repositoryRoot}${Platform.pathSeparator}client',
        environment: buildUnifiedSanadHomeEnvironment(
          Platform.environment,
          sanadHome: sanadHome,
        ),
        mode: ProcessStartMode.inheritStdio,
        runInShell: Platform.isWindows,
      );
      unawaited(restoredClient.exitCode);
      final deadline = DateTime.now().add(const Duration(seconds: 90));
      while (DateTime.now().isBefore(deadline)) {
        if (await _vmServiceIsAvailable(client.port)) return true;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return false;
    }
    return true;
  } on Object {
    return false;
  }
}

Future<bool> _waitForAgentHealthPort(
  int port,
  String workspaceHash,
  String sanadHome,
) async {
  final deadline = DateTime.now().add(const Duration(seconds: 30));
  while (DateTime.now().isBefore(deadline)) {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:$port/health'),
      );
      await authorizeLocalGatewayRequest(request, sanadHome);
      final response = await request.close().timeout(
        const Duration(milliseconds: 250),
      );
      final body = await response.transform(utf8.decoder).join();
      final decoded = jsonDecode(body);
      if (response.statusCode == HttpStatus.ok &&
          decoded is Map &&
          decoded['workspace_hash'] == workspaceHash) {
        return true;
      }
    } on Object {
      // Continue until the bounded deadline.
    } finally {
      client.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 250));
  }
  return false;
}

Future<int> _nextAvailableVmServicePort(int preferred) async {
  for (var offset = 0; offset < 1000; offset++) {
    final candidate = 51000 + ((preferred - 51000 + offset) % 1000);
    if (!await _vmServiceIsAvailable(candidate)) return candidate;
  }
  throw StateError('No free Flutter VM-service port is available.');
}

Future<bool> _vmServiceIsAvailable(int port) async {
  try {
    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
    ).timeout(const Duration(milliseconds: 300));
    await socket.close();
    return true;
  } on Object {
    return false;
  }
}

Future<bool> _requestTakeoverRestart(int port, String sanadHome) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/restart').replace(
        queryParameters: const {
          'force': 'false',
          'permanent': 'true',
          'timeout_seconds': '60',
        },
      ),
    );
    await authorizeLocalGatewayRequest(request, sanadHome);
    final response = await request.close().timeout(const Duration(seconds: 65));
    final body = await response.transform(utf8.decoder).join();
    if (response.statusCode != HttpStatus.ok) return false;
    final decoded = jsonDecode(body);
    return decoded is Map && decoded['success'] == true;
  } on Object {
    return false;
  } finally {
    client.close(force: true);
  }
}

Future<bool> _waitForAgentPortToStop(int port, String sanadHome) async {
  final deadline = DateTime.now().add(const Duration(seconds: 20));
  while (DateTime.now().isBefore(deadline)) {
    final http = HttpClient();
    try {
      final request = await http.getUrl(
        Uri.parse('http://127.0.0.1:$port/health'),
      );
      await authorizeLocalGatewayRequest(request, sanadHome);
      final response = await request.close().timeout(
        const Duration(milliseconds: 150),
      );
      await response.drain<void>();
    } on Object {
      return true;
    } finally {
      http.close(force: true);
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  return false;
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
  SanadDevRuntime runtime,
  String expectedAgentDirectory,
) async {
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
          if (response.statusCode == 200) {
            final data = jsonDecode(body);
            if (data is Map && data['status'] == 'ok') {
              final currentWorkspaceHash = runtime.worktreeId.split('-').last;
              if (data['workspace_hash'] == currentWorkspaceHash) {
                return true;
              }
            }
          }
        } catch (_) {}
        return false;
      },
    );
  } finally {
    client.close(force: true);
  }
}

bool _samePath(String? first, String second) {
  if (first == null) return false;
  try {
    return Directory(first).resolveSymbolicLinksSync() ==
        Directory(second).resolveSymbolicLinksSync();
  } catch (_) {
    return Directory(first).absolute.path == Directory(second).absolute.path;
  }
}
