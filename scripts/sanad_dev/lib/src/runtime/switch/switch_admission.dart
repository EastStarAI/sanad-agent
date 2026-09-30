part of '../../../sanad_dev_cli.dart';

Future<void> handleRuntimeSwitch({
  required String runtimeSelector,
  int? portOverride,
}) async {
  if (runtimeSelector != 'current') {
    stderr.writeln('switch currently supports only --runtime current.');
    exitCode = 64;
    return;
  }

  final targetRuntime = await _currentRuntime();
  final targetClientDirectory =
      '${targetRuntime.repositoryRoot}${Platform.pathSeparator}client';
  final agents = await discoverAgentInstances();
  final clients = await discoverClientInstances();
  final requestedPort = portOverride ?? _requestingAgentPort();

  final matchingAgents = agents
      .where((agent) => requestedPort == null || agent.port == requestedPort)
      .toList();
  if (matchingAgents.length != 1) {
    stderr.writeln(
      matchingAgents.isEmpty
          ? 'Switch aborted: no source agent matches current.'
          : 'Switch aborted: current agent is ambiguous; pass --port <agent-port>.',
    );
    exitCode = 1;
    return;
  }

  final agent = matchingAgents.single;
  final runtimeClients = clientsForAgentPort(clients, agent.port);
  if (runtimeClients.isEmpty) {
    stderr.writeln(
      'Switch aborted: the selected agent has no discoverable clients.',
    );
    exitCode = 1;
    return;
  }

  String? sanadHome;
  String? preferencesPrefix;
  for (final client in runtimeClients) {
    final profile = client.launchProfile;
    final clientHome = profile?.define('SANAD_HOME')?.trim();
    final clientPreferences = profile?.define(
      'SANAD_SHARED_PREFERENCES_PREFIX',
    );
    if (profile == null ||
        client.pid == null ||
        clientHome == null ||
        clientHome.isEmpty ||
        clientPreferences == null ||
        profile.define('SANAD_DEV_SWITCH_CAPABLE') != 'true') {
      stderr.writeln(
        'Switch aborted: client device=${client.deviceId ?? 'unknown'} '
        'vm=${client.port} has no complete switch-capable launch identity.',
      );
      exitCode = 1;
      return;
    }
    sanadHome ??= clientHome;
    preferencesPrefix ??= clientPreferences;
    if (sanadHome != clientHome || preferencesPrefix != clientPreferences) {
      stderr.writeln(
        'Switch aborted: runtime clients do not share one Sanad Home and preferences namespace.',
      );
      exitCode = 1;
      return;
    }
  }
  RuntimeLauncherRecord? launcherRecord;
  try {
    launcherRecord = await readRuntimeLauncherRecord(sanadHome!, agent.port);
  } on Object {
    stderr.writeln('Switch aborted: the launcher ownership record is invalid.');
    exitCode = 1;
    return;
  }
  final launcherError = validateManagedRuntimeRecord(
    record: launcherRecord,
    agentPort: agent.port,
    sanadHome: sanadHome,
    workspaceHash: agent.workspaceHash,
    launcherRunning: await isProcessRunning(launcherRecord?.launcherPid),
    launcherProcessIdentity: launcherRecord == null
        ? null
        : await readProcessIdentity(launcherRecord.launcherPid),
    clientDefines: runtimeClients.map(
      (client) => client.launchProfile!.defines,
    ),
    clientPids: runtimeClients.map((client) => client.pid),
    vmServicePorts: runtimeClients.map((client) => client.port),
  );
  if (launcherError != null ||
      agent.launcherId != launcherRecord?.launcherId ||
      agent.runtimeNonce != launcherRecord?.runtimeNonce) {
    stderr.writeln(
      'Switch aborted: the source runtime is not owned by one live sanad-dev '
      'launcher (${launcherError ?? 'Agent lease identity mismatch'}). '
      'Use "sanad-dev doctor" before retrying.',
    );
    exitCode = 1;
    return;
  }
  final targetWorkspaceHash = targetRuntime.worktreeId.split('-').last;
  final targetSourceState = classifyRuntimeTargetSource(
    agentWorkspaceHash: agent.workspaceHash,
    targetWorkspaceHash: targetWorkspaceHash,
    clientPaths: runtimeClients.map((client) => client.path),
    targetClientDirectory: targetClientDirectory,
  );
  if (targetSourceState == RuntimeTargetSourceState.alreadyUsesTarget) {
    print('Runtime already uses ${targetRuntime.worktreeId}.');
    return;
  }
  if (targetSourceState == RuntimeTargetSourceState.inconsistent) {
    stderr.writeln(
      'Switch aborted: the selected Agent and Clients do not agree on the '
      'target source. Use "sanad-dev doctor" before retrying.',
    );
    exitCode = 1;
    return;
  }
  final targetAlreadyRunning =
      agents.any((agent) => agent.workspaceHash == targetWorkspaceHash) ||
      clients.any((client) => _samePath(client.path, targetClientDirectory));
  if (targetAlreadyRunning) {
    stderr.writeln(
      'Switch aborted: the target worktree already has an active runtime.',
    );
    exitCode = 1;
    return;
  }

  final request = RuntimeSwitchRequest(
    id: '${DateTime.now().microsecondsSinceEpoch}-${targetRuntime.worktreeId}',
    agentPort: agent.port,
    targetRepositoryRoot: targetRuntime.repositoryRoot,
    targetWorkspaceHash: targetWorkspaceHash,
    targetWorktreeName: targetRuntime.worktreeDisplayName,
    targetBranch: targetRuntime.branch,
    targetIsLinkedWorktree: targetRuntime.isLinkedWorktree,
    requestedAt: DateTime.now().toUtc(),
    launcherId: launcherRecord!.launcherId,
    runtimeNonce: launcherRecord.runtimeNonce,
    requesterSessionId: Platform.environment['SANAD_REQUESTER_SESSION_ID'],
    requesterToolCallId: Platform.environment['SANAD_REQUESTER_TOOL_CALL_ID'],
  );
  try {
    validateRuntimeSwitchTarget(request);
  } on FormatException catch (error) {
    stderr.writeln('Switch aborted: ${error.message}');
    exitCode = 1;
    return;
  }

  final manifestPath = runtimeSwitchManifestPath(sanadHome, agent.port);
  try {
    final existing = await readRuntimeSwitchRequest(manifestPath);
    if (existing != null && isActiveRuntimeSwitch(existing)) {
      if (isRuntimeSwitchOwnedByLauncher(
        existing,
        launcherId: launcherRecord.launcherId,
        runtimeNonce: launcherRecord.runtimeNonce,
      )) {
        stderr.writeln('Switch aborted: another runtime handoff is active.');
        exitCode = 1;
        return;
      }
      await writeRuntimeSwitchRequest(
        manifestPath,
        existing.copyWith(
          status: 'failed',
          message:
              'Stale runtime handoff discarded because its owning launcher is no longer active.',
        ),
      );
      print(
        'Recovered stale runtime handoff ${existing.id} from a previous launcher.',
      );
    }
  } on Object {
    stderr.writeln('Switch aborted: the existing handoff record is invalid.');
    exitCode = 1;
    return;
  }

  await writeRuntimeSwitchRequest(manifestPath, request);
  final requesterSessionId = request.requesterSessionId?.trim();
  final requesterToolCallId = request.requesterToolCallId?.trim();
  if (requesterSessionId?.isNotEmpty == true &&
      requesterToolCallId?.isNotEmpty == true) {
    print(
      jsonEncode({
        'sanad_deferred_tool_result': {
          'kind': 'sanad_dev_switch',
          'transaction_id': request.id,
          'manifest_path': manifestPath,
          'requester_session_id': requesterSessionId,
          'requester_tool_call_id': requesterToolCallId,
          'timeout_seconds': 300,
        },
      }),
    );
  } else {
    print(
      'Switch accepted: runtime ${agent.port} with ${runtimeClients.length} client(s) will move to '
      '${targetRuntime.worktreeDisplayName}.',
    );
  }
}

enum RuntimeTargetSourceState { different, alreadyUsesTarget, inconsistent }

RuntimeTargetSourceState classifyRuntimeTargetSource({
  required String agentWorkspaceHash,
  required String targetWorkspaceHash,
  required Iterable<String> clientPaths,
  required String targetClientDirectory,
}) {
  final agentUsesTarget = agentWorkspaceHash == targetWorkspaceHash;
  final clientsUseTarget = clientPaths.every(
    (path) => _samePath(path, targetClientDirectory),
  );
  if (agentUsesTarget && clientsUseTarget) {
    return RuntimeTargetSourceState.alreadyUsesTarget;
  }
  if (agentUsesTarget != clientsUseTarget) {
    return RuntimeTargetSourceState.inconsistent;
  }
  return RuntimeTargetSourceState.different;
}

int? _requestingAgentPort() {
  final direct = int.tryParse(
    Platform.environment['LOCAL_GATEWAY_PORT']?.trim() ?? '',
  );
  if (direct != null) return direct;
  final uri = Uri.tryParse(
    Platform.environment['LOCAL_GATEWAY_URL']?.trim() ?? '',
  );
  return uri?.hasPort == true ? uri!.port : null;
}

class _ClientStopped {
  const _ClientStopped(this.pid, this.exitCode);
  final int pid;
  final int exitCode;
}

class _AgentStopped {
  const _AgentStopped(this.pid, this.exitCode);
  final int pid;
  final int exitCode;
}

class _ShutdownRequested {
  const _ShutdownRequested();
}

class _RuntimeClientLaunch {
  const _RuntimeClientLaunch({
    required this.directory,
    required this.arguments,
    required this.vmServicePort,
    required this.deviceId,
    this.pid,
  });

  final String directory;
  final List<String> arguments;
  final int vmServicePort;
  final String deviceId;
  final int? pid;
}
