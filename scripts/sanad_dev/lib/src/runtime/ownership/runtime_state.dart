part of '../../../sanad_dev_cli.dart';

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
  final agentIdentityMatches =
      state.agent == null ||
      (state.agent!.launcherId == activeRecord.launcherId &&
          state.agent!.runtimeNonce == activeRecord.runtimeNonce);
  final recordError = validateManagedRuntimeRecord(
    record: record,
    agentPort: state.agent?.port ?? runtime.agentPort,
    sanadHome: activeHome,
    workspaceHash: agentIdentityMatches
        ? activeRecord.workspaceHash
        : (state.agent?.workspaceHash ?? activeRecord.workspaceHash),
    launcherRunning: await processRunning(record.launcherPid),
    launcherProcessIdentity: await processIdentity(record.launcherPid),
    clientDefines: managedClients.map(
      (client) => client.launchProfile?.defines ?? const {},
    ),
    clientPids: managedClients.map((client) => client.pid),
    vmServicePorts: managedClients.map((client) => client.port),
  );
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
  final agents = activeAgents.toList(growable: false);
  final clients = activeClients.toList(growable: false);
  final workspaceAgents = agents
      .where((agent) => agent.workspaceHash == workspaceHash)
      .toList(growable: false);
  final sourceAttachedAgents = agents
      .where(
        (agent) => clients.any((client) {
          if (!matchesPath(client.path, clientDirectory)) return false;
          final profile = client.launchProfile;
          final gateway = Uri.tryParse(
            profile?.define('LOCAL_GATEWAY_URL') ?? '',
          );
          return gateway?.hasPort == true &&
              gateway!.port == agent.port &&
              agent.launcherId != null &&
              agent.runtimeNonce != null &&
              profile?.define('SANAD_DEV_LAUNCHER_ID') == agent.launcherId &&
              profile?.define('SANAD_DEV_RUNTIME_NONCE') == agent.runtimeNonce;
        }),
      )
      .toList(growable: false);
  final matchingAgents = requestedAgentPort != null
      ? agents
            .where((agent) => agent.port == requestedAgentPort)
            .toList(growable: false)
      : workspaceAgents.isNotEmpty
      ? workspaceAgents
      : sourceAttachedAgents.isNotEmpty
      ? sourceAttachedAgents
      : agents
            .where((agent) => agent.port == runtime.agentPort)
            .toList(growable: false);
  final agentAmbiguous = matchingAgents.length > 1;
  final matchingAgent = matchingAgents.length == 1
      ? matchingAgents.single
      : null;

  final agentsByPort = {for (final agent in agents) agent.port: agent};
  final primaryHome = resolveDefaultUserSanadHome(Platform.environment);
  final owned = <ClientInstance>[];
  final crossOwned = <ClientInstance>[];
  final ambiguous = <ClientInstance>[];
  for (final client in clients) {
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

    final clientMatchesAgentLease =
        matchingAgent?.launcherId != null &&
        matchingAgent?.runtimeNonce != null &&
        discoveredProfile?.define('SANAD_DEV_LAUNCHER_ID') ==
            matchingAgent!.launcherId &&
        discoveredProfile?.define('SANAD_DEV_RUNTIME_NONCE') ==
            matchingAgent.runtimeNonce;
    if (!sourceMatches ||
        (attachedToSelected &&
            matchingAgent.workspaceHash != workspaceHash &&
            !clientMatchesAgentLease)) {
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

bool _samePath(String? first, String second) => equivalentPaths(first, second);
