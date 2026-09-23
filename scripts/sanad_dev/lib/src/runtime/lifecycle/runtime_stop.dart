part of '../../../sanad_dev_cli.dart';

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
  String? clientInstanceSlot,
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
    clientInstanceSlot: clientInstanceSlot,
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
  String? sanadHomePath,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  Future<String?> Function(int pid) processIdentity = readProcessIdentity,
  Future<void> Function(int pid) terminateProcess = terminateSanadDevProcessTree,
}) async {
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final processState = selectRuntimeProcessState(
    activeAgents: await discoverAgentInstances(
      sanadHomeOverride: sanadHomePath,
    ),
    activeClients: await discoverClientInstances(),
    runtime: runtime,
    requestedAgentPort: target == SanadDevComponentTarget.agent
        ? vmServicePort
        : null,
  );
  final activeHome = resolveActiveSanadHome(runtime, processState);
  if (processState.agent == null &&
      processState.relevantClients.isEmpty &&
      !processState.agentAmbiguous) {
    if (force) {
      final staleRecord = await _readRuntimeLauncherRecordSafely(
        activeHome,
        runtime.agentPort,
      );
      if (staleRecord != null) {
        await _forceStopOrphanedRuntime(
          runtime: runtime,
          processState: processState,
          record: staleRecord,
          activeHome: activeHome,
          processRunning: processRunning,
          processIdentity: processIdentity,
          terminateProcess: terminateProcess,
        );
        return;
      }
    }
    print(noActiveRuntimeMessage(runtime));
    return;
  }
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: processState,
    sanadHome: activeHome,
    processRunning: processRunning,
    processIdentity: processIdentity,
  );
  if (!ownership.isManaged) {
    if (force && ownership.classification == RuntimeOwnershipClass.orphaned) {
      await _forceStopOrphanedRuntime(
        runtime: runtime,
        processState: processState,
        record: ownership.record,
        activeHome: resolveActiveSanadHome(runtime, processState),
        processRunning: processRunning,
        processIdentity: processIdentity,
        terminateProcess: terminateProcess,
      );
      return;
    }
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

Future<void> _forceStopOrphanedRuntime({
  required SanadDevRuntime runtime,
  required RuntimeProcessState processState,
  required RuntimeLauncherRecord? record,
  required String activeHome,
  required Future<bool> Function(int? pid) processRunning,
  required Future<String?> Function(int pid) processIdentity,
  required Future<void> Function(int pid) terminateProcess,
}) async {
  print(
    'Forced stop requested for orphaned runtime ${runtime.worktreeId}. '
    'Cleaning up orphaned processes and records...',
  );
  if (record != null && await processRunning(record.launcherPid)) {
    final launcherIdentity = await processIdentity(record.launcherPid);
    if (launcherIdentity != null &&
        launcherIdentity == record.launcherProcessIdentity) {
      await terminateProcess(record.launcherPid);
    } else {
      stderr.writeln(
        'Skipping launcher PID ${record.launcherPid}: process identity '
        'does not match the lease (PID was reused or stale).',
      );
    }
  }

  final agent = processState.agent;
  if (agent != null) {
    try {
      await _requestTakeoverRestart(agent.port, activeHome);
    } catch (_) {}
    await _waitForAgentPortToStop(agent.port, activeHome);
  }

  final pidsToKill = await _collectProvenClientPids(
    runtime: runtime,
    processState: processState,
    record: record,
    processRunning: processRunning,
    processIdentity: processIdentity,
  );

  for (final pid in pidsToKill) {
    await terminateProcess(pid);
  }

  await deleteRuntimeLauncherRecord(activeHome, runtime.agentPort);
  final stopPath = runtimeLauncherStopRequestPath(
    activeHome,
    runtime.agentPort,
  );
  final stopFile = File(stopPath);
  if (await stopFile.exists()) await stopFile.delete();

  final controlPath = runtimeComponentControlPath(
    activeHome,
    runtime.agentPort,
  );
  final controlFile = File(controlPath);
  if (await controlFile.exists()) await controlFile.delete();

  print('✓ Orphaned runtime ${runtime.worktreeId} stopped.');
}

Future<Set<int>> _collectProvenClientPids({
  required SanadDevRuntime runtime,
  required RuntimeProcessState processState,
  required RuntimeLauncherRecord? record,
  required Future<bool> Function(int? pid) processRunning,
  required Future<String?> Function(int pid) processIdentity,
}) async {
  final provenPids = <int>{};
  if (record == null) {
    // Without a launcher lease record, ownership by launcherId and nonce
    // cannot be proven. Matching port or path alone is not permission to kill a process.
    return provenPids;
  }

  final launcherId = record.launcherId;
  final runtimeNonce = record.runtimeNonce;

  // 1. Owned clients discovered via VM service: MUST match both launcherId AND runtimeNonce together.
  for (final client in processState.ownedClients) {
    final pid = client.pid;
    if (pid == null || !await processRunning(pid)) continue;

    final profile = client.launchProfile;
    final matchesLease =
        profile?.define('SANAD_DEV_LAUNCHER_ID') == launcherId &&
        profile?.define('SANAD_DEV_RUNTIME_NONCE') == runtimeNonce;
    if (matchesLease) {
      provenPids.add(pid);
    } else {
      stderr.writeln(
        'Skipping client PID $pid: missing matching launcherId and nonce proof.',
      );
    }
  }

  // 2. Ambiguous clients: ONLY admitted if they strictly match BOTH launcherId AND runtimeNonce together.
  for (final client in processState.ambiguousClients) {
    final pid = client.pid;
    if (pid == null || !await processRunning(pid)) continue;

    final profile = client.launchProfile;
    final matchesLease =
        profile?.define('SANAD_DEV_LAUNCHER_ID') == launcherId &&
        profile?.define('SANAD_DEV_RUNTIME_NONCE') == runtimeNonce;
    if (matchesLease) {
      provenPids.add(pid);
    }
  }

  // NOTE: processState.crossOwnedClients are never stopped because they belong
  // to other active runtimes or external daemons.

  // 3. Client PIDs recorded in launcher lease: verify process identity to prove BOTH launcherId AND runtimeNonce together.
  for (final pid in record.clientPids) {
    if (provenPids.contains(pid)) continue;
    if (!await processRunning(pid)) continue;

    final identity = await processIdentity(pid);
    if (identity == null) {
      stderr.writeln(
        'Skipping client PID $pid: unable to verify process identity.',
      );
      continue;
    }
    final matchesBoth =
        identity.contains(launcherId) && identity.contains(runtimeNonce);

    if (matchesBoth) {
      provenPids.add(pid);
    } else {
      stderr.writeln(
        'Skipping client PID $pid: process identity does not contain both launcherId and runtimeNonce '
        '(matching port or path alone is not permission to kill a process).',
      );
    }
  }

  return provenPids;
}
