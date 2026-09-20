part of '../../../sanad_dev_cli.dart';

String? staleAgentRecoveryBlocker({
  required SanadDevRuntime runtime,
  required RuntimeProcessState state,
  required RuntimeLauncherRecord record,
  required String activeHome,
  required bool launcherLive,
}) {
  if (launcherLive) return 'the recorded launcher is still live';
  if (state.agentAmbiguous) return 'multiple matching Agents were discovered';
  if (!state.mutationAllowed) return 'Client ownership is ambiguous or foreign';
  if (state.relevantClients.isNotEmpty) {
    return 'live Clients must remain under a live launcher';
  }
  if (record.status != 'agent-only' ||
      record.clientPids.isNotEmpty ||
      record.vmServicePorts.isNotEmpty) {
    return 'the stale lease is not an exact Agent-only record';
  }
  final agent = state.agent;
  if (agent == null) return 'no live Agent requires a controlled drain';
  final workspaceHash = runtime.worktreeId.split('-').last;
  if (record.agentPort != runtime.agentPort || agent.port != record.agentPort) {
    return 'Agent port does not match the stale lease';
  }
  if (record.workspaceHash != workspaceHash ||
      agent.workspaceHash != workspaceHash) {
    return 'workspace identity does not match the stale lease';
  }
  if (!_samePath(record.sourceRoot, runtime.repositoryRoot)) {
    return 'source root does not match the stale lease';
  }
  if (!_samePath(record.sanadHome, activeHome) ||
      agent.sanadHome == null ||
      !_samePath(agent.sanadHome, record.sanadHome)) {
    return 'Sanad Home does not match the stale lease';
  }
  if (agent.launcherId != record.launcherId ||
      agent.runtimeNonce != record.runtimeNonce) {
    return 'Agent launcher identity or nonce does not match the stale lease';
  }
  return null;
}

Future<String?> recoverStaleAgentLease({
  required SanadDevRuntime runtime,
  required RuntimeProcessState state,
  required RuntimeLauncherRecord record,
  required String activeHome,
  required bool launcherLive,
  required Future<bool> Function() requestPermanentRestart,
  required Future<bool> Function() waitForAgentExit,
  required Future<bool> Function() launcherIsRunning,
  required Future<List<AgentInstance>> Function() discoverAgents,
  required Future<List<ClientInstance>> Function() discoverClients,
  required Future<void> Function() deleteRecord,
}) async {
  final blocker = staleAgentRecoveryBlocker(
    runtime: runtime,
    state: state,
    record: record,
    activeHome: activeHome,
    launcherLive: launcherLive,
  );
  if (blocker != null) return blocker;
  if (!await requestPermanentRestart()) {
    return 'the Agent rejected the controlled permanent restart';
  }
  if (!await waitForAgentExit()) {
    return 'the Agent endpoint did not stop within the recovery window';
  }
  if (await launcherIsRunning()) {
    return 'the recorded launcher became live during recovery';
  }

  final remainingAgents = await discoverAgents();
  if (remainingAgents.any(
    (agent) =>
        agent.port == record.agentPort ||
        agent.launcherId == record.launcherId ||
        agent.runtimeNonce == record.runtimeNonce,
  )) {
    return 'an Agent matching the stale lease is still live';
  }
  final remainingClients = await discoverClients();
  if (remainingClients.any((client) {
    final profile = client.launchProfile;
    return clientAgentPort(client) == record.agentPort ||
        profile?.define('SANAD_DEV_LAUNCHER_ID') == record.launcherId ||
        profile?.define('SANAD_DEV_RUNTIME_NONCE') == record.runtimeNonce;
  })) {
    return 'a Client matching the stale lease is still live';
  }

  await deleteRecord();
  return null;
}

bool get _hasAgentToolRequester =>
    Platform.environment['SANAD_REQUESTER_SESSION_ID']?.isNotEmpty == true ||
    Platform.environment['SANAD_REQUESTER_TOOL_CALL_ID']?.isNotEmpty == true;
