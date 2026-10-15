part of '../../../sanad_dev_cli.dart';

Future<void> handleTargetOrphanCleanup({
  String? sanadHomePath,
  ProcessTerminator terminateProcess = Process.killPid,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  Future<List<AgentInstance>> Function({String? sanadHomeOverride})
      discoverAgents =
      discoverAgentInstances,
  Future<List<ClientInstance>> Function() discoverClients =
      discoverClientInstances,
}) async {
  final runtime = await _currentRuntime(sanadHomePath: sanadHomePath);
  final sourcePort = _requestingAgentPort();
  final agents = await discoverAgents(sanadHomeOverride: sanadHomePath);
  final clients = await discoverClients();
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
