part of '../../../sanad_dev_cli.dart';

Future<void> handleRuntimeTakeover({
  String? sanadHomePath,
  bool force = false,
  bool Function() isAgentToolCall = hasAgentToolRequester,
  ProcessTerminator terminateProcess = Process.killPid,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  Future<String?> Function(int pid) processIdentity = readProcessIdentity,
  Future<List<AgentInstance>> Function({String? sanadHomeOverride})
      discoverAgents =
      discoverAgentInstances,
  Future<List<ClientInstance>> Function() discoverClients =
      discoverClientInstances,
  Future<bool> Function(int port, String sanadHome, {bool force})
      requestPermanentRestart =
      _requestTakeoverRestart,
  Future<bool> Function(int port, String sanadHome) waitForAgentExit =
      _waitForAgentPortToStop,
  Future<AgentInstance?> Function(int port, String sanadHome) readLiveDaemon =
      readLiveDaemonInstance,
  Future<Map<int, int>> Function() readParentMap = readProcessParentMap,
  Future<List<int>> Function(int daemonPid) proveAgentChain =
      proveAgentDaemonChainForPid,
  Future<void> Function(int pid) terminateTree = terminateSanadDevProcessTree,
  Future<List<InventoryHomeState>> Function(
        SanadDevRuntime runtime,
        String activeHome,
      )
      scanHomes =
      readReclaimHomeStates,
  TakeoverManagedLaunch runManagedLaunch = launchManagedTakeover,
  TakeoverManualRestore restoreManualRuntime = _restoreManualRuntime,
  Duration launcherStopTimeout = const Duration(seconds: 15),
}) async {
  if (isAgentToolCall()) {
    stderr.writeln(
      'Takeover refused from an active Agent tool call. Run it directly in a '
      'human-owned terminal after reviewing "sanad-dev doctor".',
    );
    exitCode = 1;
    return;
  }
  final runtime = await _currentRuntime(sanadHomePath: sanadHomePath);
  final agents = await discoverAgents(sanadHomeOverride: sanadHomePath);
  final clients = await discoverClients();
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
    processIdentity: processIdentity,
  );
  if (ownership.classification == RuntimeOwnershipClass.orphaned) {
    await _reclaimOrphanedPair(
      runtime: runtime,
      state: state,
      ownership: ownership,
      activeHome: activeHome,
      force: force,
      processRunning: processRunning,
      processIdentity: processIdentity,
      requestPermanentRestart: requestPermanentRestart,
      readLiveDaemon: readLiveDaemon,
      readParentMap: readParentMap,
      proveAgentChain: proveAgentChain,
      terminateTree: terminateTree,
      scanHomes: scanHomes,
      runManagedLaunch: runManagedLaunch,
      restoreManualRuntime: restoreManualRuntime,
      launcherStopTimeout: launcherStopTimeout,
    );
    return;
  }
  if (ownership.classification != RuntimeOwnershipClass.manual ||
      state.agent == null ||
      state.ownedClients.length != 1) {
    stderr.writeln(
      'Takeover refused: expected one complete manual Agent/client pair, found '
      '${ownership.classification.name} with ${state.ownedClients.length} '
      'owned client(s).',
    );
    if (ownership.reason != null)
      stderr.writeln('Reason: ${ownership.reason}.');
    exitCode = 1;
    return;
  }

  final client = state.ownedClients.single;
  final plan = buildTakeoverLaunchPlan(
    runtime: runtime,
    client: client,
    activeHome: activeHome,
  );
  if (plan == null) {
    stderr.writeln(
      'Takeover refused: the manual client PID or config launch argument is '
      'not discoverable.',
    );
    exitCode = 1;
    return;
  }

  print(
    'Draining manual Agent ${state.agent!.port} before controlled takeover...',
  );
  if (!await requestPermanentRestart(state.agent!.port, activeHome)) {
    stderr.writeln(
      'Takeover aborted: the manual Agent rejected safe restart; the client '
      'was not signaled.',
    );
    exitCode = 1;
    return;
  }
  if (!await waitForAgentExit(state.agent!.port, activeHome)) {
    stderr.writeln(
      'Takeover aborted: the drained Agent did not exit; the client was not '
      'signaled.',
    );
    exitCode = 1;
    return;
  }
  if (!terminateProcess(client.pid!, ProcessSignal.sigterm)) {
    final restored = await restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: plan.profile,
      cloudEnabled: plan.cloudEnabled,
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
    final restored = await restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: plan.profile,
      cloudEnabled: plan.cloudEnabled,
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
    final restored = await restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: plan.profile,
      cloudEnabled: plan.cloudEnabled,
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
  if (!await runManagedLaunch(plan)) {
    final restored = await restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: plan.profile,
      cloudEnabled: plan.cloudEnabled,
      restoreClient: true,
    );
    stderr.writeln(
      'Managed takeover launch failed. Previous manual pair restoration: '
      '${restored ? 'complete' : 'failed'}.',
    );
  }
}

/// Reclaims a runtime whose port is served by a daemon that is not its lease.
///
/// The recorded launcher is still the runtime's owner, so this branch never
/// starts a second launcher beside it: it proves the daemon is foreign, drains
/// it, retires the recorded launcher, and only then relaunches under a new
/// lease.
Future<void> _reclaimOrphanedPair({
  required SanadDevRuntime runtime,
  required RuntimeProcessState state,
  required RuntimeOwnershipAssessment ownership,
  required String activeHome,
  required bool force,
  required Future<bool> Function(int? pid) processRunning,
  required Future<String?> Function(int pid) processIdentity,
  required Future<bool> Function(int port, String sanadHome, {bool force})
  requestPermanentRestart,
  required Future<AgentInstance?> Function(int port, String sanadHome)
  readLiveDaemon,
  required Future<Map<int, int>> Function() readParentMap,
  required Future<List<int>> Function(int daemonPid) proveAgentChain,
  required Future<void> Function(int pid) terminateTree,
  required Future<List<InventoryHomeState>> Function(
    SanadDevRuntime runtime,
    String activeHome,
  )
  scanHomes,
  required TakeoverManagedLaunch runManagedLaunch,
  required TakeoverManualRestore restoreManualRuntime,
  required Duration launcherStopTimeout,
}) async {
  final assessment = await assessOrphanReclaim(
    runtime: runtime,
    state: state,
    ownership: ownership,
    activeHome: activeHome,
    processRunning: processRunning,
    processIdentity: processIdentity,
    readParentMap: readParentMap,
    scanHomes: scanHomes,
  );
  final evidence = assessment.evidence;
  if (evidence == null) {
    stderr.writeln(
      'Takeover refused: ${assessment.blocker}. Nothing was changed.',
    );
    final holder = await describeHomeHolder(activeHome);
    if (holder != null) stderr.writeln(holder);
    stderr.writeln(
      'Next action: run "sanad-dev doctor" for this runtime, then rerun '
      'takeover only if doctor still names the same foreign daemon.',
    );
    exitCode = 1;
    return;
  }
  final plan = buildTakeoverLaunchPlan(
    runtime: runtime,
    client: evidence.client,
    activeHome: activeHome,
  );
  if (plan == null) {
    stderr.writeln(
      'Takeover refused: the lease-owned Client PID or config launch argument '
      'is not discoverable. Nothing was changed.',
    );
    exitCode = 1;
    return;
  }

  print(
    'Takeover reclaim: the daemon on port ${evidence.port} does not belong to '
    'this lease.',
  );
  print(
    '  lease      launcher ${evidence.record.launcherId}, nonce '
    '${evidence.record.runtimeNonce}, pid ${evidence.record.launcherPid} '
    '(live, identity proven)',
  );
  print('  listener   ${evidence.describeDaemon()} answered /health');
  print(
    '  home       ${evidence.activeHome} '
    '(${evidence.holder == null ? 'no holder record' : 'holder '
              '${evidence.holder!.describe()}'})',
  );
  print(
    '  claims     no other live lease names that identity, and no other Sanad '
    'Home leases port ${evidence.port}',
  );
  print(
    '  clients    1 owned (vm ${evidence.client.port}, '
    'pid ${evidence.client.pid})',
  );

  OrphanReclaimOutcome outcome;
  try {
    outcome = await sanadDevWithFileLock<OrphanReclaimOutcome>(
      File(runtimeReclaimLockPath(evidence.activeHome, evidence.port)),
      FileLock.exclusive,
      () async {
        // The evidence above is a snapshot. Both facts the ladder depends on
        // are re-read here, inside the lock, before any signal or request.
        if (!await processRunning(evidence.record.launcherPid)) {
          return const OrphanReclaimOutcome.refused(
            'the recorded launcher stopped while the reclaim was starting; '
            'nothing was changed',
          );
        }
        final launcherIdentity = await processIdentity(
          evidence.record.launcherPid,
        );
        if (launcherIdentity == null ||
            launcherIdentity != evidence.record.launcherProcessIdentity) {
          return const OrphanReclaimOutcome.refused(
            'the recorded launcher changed identity while the reclaim was '
            'starting; nothing was signalled',
          );
        }
        return reclaimOrphanedDaemon(
          evidence: evidence,
          force: force,
          readLiveDaemon: readLiveDaemon,
          requestPermanentRestart: requestPermanentRestart,
          proveChain: proveAgentChain,
          terminateTree: terminateTree,
          processRunning: processRunning,
          processIdentity: processIdentity,
          log: print,
        );
      },
      timeout: const Duration(seconds: 1),
      timeoutMessage:
          'Another takeover reclaim is already running for this runtime.',
    );
  } on Object catch (error) {
    stderr.writeln('Takeover aborted: $error. Nothing further was changed.');
    exitCode = 1;
    return;
  }
  if (outcome.blocker != null) {
    stderr.writeln('Takeover aborted: ${outcome.blocker}.');
    final holder = await describeHomeHolder(evidence.activeHome);
    if (holder != null) stderr.writeln(holder);
    exitCode = 1;
    return;
  }
  final tier = outcome.tier;
  if (tier == OrphanReclaimTier.provenChain) {
    print(
      '✓ The proven Agent process chain exited; port ${evidence.port} is free.',
    );
  } else if (tier == OrphanReclaimTier.forcedShutdown) {
    print(
      '✓ The daemon exited through its own forced permanent shutdown; port '
      '${evidence.port} is free.',
    );
  } else {
    print(
      '✓ The daemon exited through its own permanent restart; port '
      '${evidence.port} is free.',
    );
  }

  final lease = await _readLeaseForReclaim(evidence);
  if (lease == null) {
    stderr.writeln(
      'Takeover aborted: the launcher lease of this runtime changed or '
      'disappeared after the daemon stopped. No launcher was started; rerun '
      '"sanad-dev status".',
    );
    exitCode = 1;
    return;
  }
  if (await processRunning(lease.launcherPid)) {
    final launcherIdentity = await processIdentity(lease.launcherPid);
    if (launcherIdentity == null ||
        launcherIdentity != lease.launcherProcessIdentity) {
      stderr.writeln(
        'Takeover aborted: launcher pid ${lease.launcherPid} no longer matches '
        'the lease identity. No process was signalled.',
      );
      exitCode = 1;
      return;
    }
    print(
      'Stopping the previous launcher (pid ${lease.launcherPid}) so it cannot '
      'race the new lease...',
    );
    await terminateTree(lease.launcherPid);
    final deadline = DateTime.now().add(launcherStopTimeout);
    while (await processRunning(lease.launcherPid) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (await processRunning(lease.launcherPid)) {
      stderr.writeln(
        'Takeover aborted: the previous launcher did not exit, so no second '
        'launcher was started. The foreign daemon is gone; rerun '
        '"sanad-dev status".',
      );
      exitCode = 1;
      return;
    }
  }

  final clientPid = evidence.client.pid!;
  if (await processRunning(clientPid)) {
    print('Stopping the previous Client (pid $clientPid)...');
    await terminateTree(clientPid);
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (await processRunning(clientPid) &&
        DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    if (await processRunning(clientPid)) {
      stderr.writeln(
        'Takeover aborted: the previous Client did not exit, so no second '
        'launcher was started.',
      );
      exitCode = 1;
      return;
    }
  }

  // The retired launcher cannot delete its own lease once it is gone, so the
  // record is removed here, and only while it still carries the exact identity
  // that was proven.
  await _deleteLeaseIfOwnedBy(
    sanadHome: evidence.activeHome,
    agentPort: evidence.port,
    launcherId: lease.launcherId,
    runtimeNonce: lease.runtimeNonce,
  );

  final live = await readLiveDaemon(evidence.port, evidence.activeHome);
  if (live != null) {
    stderr.writeln(
      'Takeover aborted: port ${evidence.port} is served again before the '
      'relaunch. No launcher was started.',
    );
    exitCode = 1;
    return;
  }

  print('Foreign daemon drained; relaunching under one new sanad-dev lease.');
  if (!await runManagedLaunch(plan)) {
    final restored = await restoreManualRuntime(
      runtime: runtime,
      agentPort: evidence.port,
      sanadHome: evidence.activeHome,
      client: evidence.client,
      profile: plan.profile,
      cloudEnabled: plan.cloudEnabled,
      restoreClient: true,
    );
    stderr.writeln(
      'Managed takeover launch failed. Previous runtime restoration: '
      '${restored ? 'complete' : 'failed'}.',
    );
  }
}

/// Re-reads the lease and requires it to still describe the proven runtime.
Future<RuntimeLauncherRecord?> _readLeaseForReclaim(
  OrphanReclaimEvidence evidence,
) async {
  try {
    final record = await readRuntimeLauncherRecord(
      evidence.activeHome,
      evidence.port,
    );
    if (record == null) return null;
    if (record.launcherId != evidence.record.launcherId ||
        record.runtimeNonce != evidence.record.runtimeNonce) {
      return null;
    }
    return record;
  } on Object {
    return null;
  }
}

/// Deletes the lease only while it still carries the identity proven above.
Future<void> _deleteLeaseIfOwnedBy({
  required String sanadHome,
  required int agentPort,
  required String launcherId,
  required String runtimeNonce,
}) async {
  try {
    final record = await readRuntimeLauncherRecord(sanadHome, agentPort);
    if (record == null) return;
    if (record.launcherId != launcherId ||
        record.runtimeNonce != runtimeNonce) {
      return;
    }
    await deleteRuntimeLauncherRecord(sanadHome, agentPort);
  } on Object {
    // A lease that cannot be re-read is left in place; the relaunch decision
    // never depends on removing it.
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
      final deadline = DateTime.now().add(sanadDevClientStartupTimeout);
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

Future<bool> _requestTakeoverRestart(
  int port,
  String sanadHome, {
  bool force = false,
}) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/restart').replace(
        queryParameters: {
          'force': force ? 'true' : 'false',
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
