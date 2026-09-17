part of '../../../sanad_dev_cli.dart';

Future<void> handleRuntimeStatus({
  int? portOverride,
  String? sanadHomePath,
}) async {
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final activeAgents = await discoverAgentInstances(
    sanadHomeOverride: sanadHomePath,
  );
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
  SanadDevStartupAttempt? startupAttempt;
  try {
    startupAttempt = await readLocatedSanadDevStartupAttempt(
      runtimeDirectory: runtime.runtimeDirectory,
      workspaceHash: runtime.worktreeId.split('-').last,
    );
    if (startupAttempt != null) {
      print('Startup requested home: ${startupAttempt.requestedHome}');
      print('Startup resolved home: ${startupAttempt.resolvedHome}');
      print(
        'Startup attempt: ${startupAttempt.outcome.name} '
        '(stage=${startupAttempt.stage.name}, '
        'exit=${startupAttempt.exitStatus ?? '-'})',
      );
      if (startupAttempt.failureReason != null) {
        print('Startup failure: ${startupAttempt.failureReason}');
      }
    }
  } on Object catch (error) {
    print('Startup attempt: invalid ($error)');
  }
  final startupInProgress = isSanadDevStartupAttemptInProgress(startupAttempt);
  print(
    startupInProgress
        ? 'Status: starting (stage=${startupAttempt!.stage.name})'
        : 'Status: ${runtimeStatusLabel(ownership.isManaged ? ownership.state : processState)}',
  );
  print(
    'Runtime class: ${startupInProgress ? 'starting' : ownership.classification.name}',
  );
  if (!startupInProgress && ownership.reason != null) {
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
