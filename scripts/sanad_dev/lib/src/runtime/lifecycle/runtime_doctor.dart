part of '../../../sanad_dev_cli.dart';

bool canRemoveStaleLauncherRecord({
  required bool launcherLive,
  required bool endpointLive,
  required bool clientLive,
}) => !launcherLive && !endpointLive && !clientLive;

Future<void> handleRuntimeDoctor({
  required bool fix,
  String? sanadHomePath,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final runtime = await _currentRuntime(sanadHomePath: sanadHomePath);
  final agents = await discoverAgentInstances(sanadHomeOverride: sanadHomePath);
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
  var staleAgentRecoveryAvailable = false;
  var staleRecordRemovalAvailable = false;
  if (record != null) {
    final launcherLive = await processRunning(record.launcherPid);
    print(
      'Launcher lease: PID ${record.launcherPid} '
      '(${launcherLive ? 'live' : 'stale'})',
    );
    final staleAgentRecoveryError = staleAgentRecoveryBlocker(
      runtime: runtime,
      state: state,
      record: record,
      activeHome: activeHome,
      launcherLive: launcherLive,
    );
    staleAgentRecoveryAvailable =
        ownership.classification == RuntimeOwnershipClass.orphaned &&
        staleAgentRecoveryError == null;
    final endpointLive = agents.any(
      (agent) => agentMatchesLauncherRecord(agent, record),
    );
    final clientLive = clients.any(
      (client) => clientMatchesLauncherRecord(client, record),
    );
    staleRecordRemovalAvailable = canRemoveStaleLauncherRecord(
      launcherLive: launcherLive,
      endpointLive: endpointLive,
      clientLive: clientLive,
    );
    if (fix) {
      final switchPath = runtimeSwitchManifestPath(
        activeHome,
        state.agent?.port ?? runtime.agentPort,
      );
      try {
        final handoff = await readRuntimeSwitchRequest(switchPath);
        if (handoff != null &&
            isActiveRuntimeSwitch(handoff) &&
            !isRuntimeSwitchOwnedByLauncher(
              handoff,
              launcherId: record.launcherId,
              runtimeNonce: record.runtimeNonce,
            )) {
          await writeRuntimeSwitchRequest(
            switchPath,
            handoff.copyWith(
              status: 'failed',
              message:
                  'Stale runtime handoff discarded because its owning launcher is no longer active.',
            ),
          );
          print(
            'Fixed: terminalized stale runtime handoff ${handoff.id}; '
            'no process was signaled.',
          );
          return;
        }
      } on Object catch (error) {
        stderr.writeln(
          'No fix applied: runtime handoff record is invalid: $error',
        );
        exitCode = 1;
        return;
      }
      if (staleRecordRemovalAvailable) {
        await deleteRuntimeLauncherRecord(record.sanadHome, record.agentPort);
        print(
          'Fixed: removed one stale launcher record; no process was signaled.',
        );
        return;
      }
      if (staleAgentRecoveryAvailable) {
        if (_hasAgentToolRequester) {
          stderr.writeln(
            'No fix applied: stale Agent recovery must run from a '
            'human-owned terminal so the recovering Agent cannot interrupt '
            'its own tool call. Run "sanad-dev doctor --fix" there.',
          );
          exitCode = 1;
          return;
        }
        print(
          'Draining the exact Agent-only orphan through its authenticated '
          'restart boundary...',
        );
        final recoveryError = await recoverStaleAgentLease(
          runtime: runtime,
          state: state,
          record: record,
          activeHome: activeHome,
          launcherLive: launcherLive,
          requestPermanentRestart: () =>
              _requestTakeoverRestart(record.agentPort, record.sanadHome),
          waitForAgentExit: () =>
              _waitForAgentPortToStop(record.agentPort, record.sanadHome),
          launcherIsRunning: () => processRunning(record.launcherPid),
          discoverAgents: () => discoverAgentInstances(
            sanadHomeOverride: record.sanadHome,
            runtime: runtime,
          ),
          discoverClients: discoverClientInstances,
          deleteRecord: () =>
              deleteRuntimeLauncherRecord(record.sanadHome, record.agentPort),
        );
        if (recoveryError == null) {
          print(
            'Fixed: safely drained the exact Agent-only orphan and removed '
            'its stale launcher record.',
          );
          return;
        }
        stderr.writeln(
          'No fix applied: $recoveryError; the stale launcher record was '
          'preserved.',
        );
        exitCode = 1;
        return;
      }
      stderr.writeln(
        'No fix applied: '
        '${staleAgentRecoveryError ?? 'a launcher or runtime endpoint is still live'}; '
        'the lease was preserved.',
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

  final nextAction = doctorNextAction(
    ownership: ownership,
    state: state,
    staleAgentRecoveryAvailable: staleAgentRecoveryAvailable,
    staleRecordRemovalAvailable: staleRecordRemovalAvailable,
  );
  print('Next action: $nextAction');
}

String doctorNextAction({
  required RuntimeOwnershipAssessment ownership,
  required RuntimeProcessState state,
  required bool staleAgentRecoveryAvailable,
  required bool staleRecordRemovalAvailable,
}) => staleRecordRemovalAvailable
    ? 'Run "sanad-dev doctor --fix" to remove the stale record; no process '
          'will be signaled.'
    : switch (ownership.classification) {
        RuntimeOwnershipClass.managed => 'Use sanad-dev status/stop/switch.',
        RuntimeOwnershipClass.manual =>
          'Run "sanad-dev takeover" after confirming the listed manual pair.',
        RuntimeOwnershipClass.orphaned =>
          staleAgentRecoveryAvailable
              ? 'Run "sanad-dev doctor --fix" from a human-owned terminal to '
                    'safely drain this exact Agent-only orphan.'
              : state.agent != null
              ? 'Automatic recovery is refused because the live runtime does not '
                    'match the narrow Agent-only recovery contract.'
              : 'Run "sanad-dev cleanup-target-orphans"; it will proceed only when '
                    'target-only stale Client ownership is proven.',
        RuntimeOwnershipClass.stopped => 'Run "sanad-dev run".',
        RuntimeOwnershipClass.crossOwned =>
          'Run "sanad-dev doctor" from the owning worktree shown above.',
        _ =>
          'Close the listed IDE/manual Client, then rerun "sanad-dev doctor"; '
              'automatic mutation is refused.',
      };

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
