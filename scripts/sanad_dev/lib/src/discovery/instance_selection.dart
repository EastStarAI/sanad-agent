part of '../../sanad_dev_cli.dart';

class ClientInstance {
  final int port;
  final String token;
  final String path;
  final String? deviceId;
  final int? pid;

  /// Process id of the Dart development service that serves [port].
  ///
  /// It is discovery evidence for narrowing one later scan to the same
  /// endpoint; it never grants ownership, which stays with [pid] and the lease.
  final int? devServicePid;
  final ClientLaunchProfile? launchProfile;
  ClientInstance(
    this.port,
    this.token,
    this.path,
    this.deviceId, {
    this.pid,
    this.devServicePid,
    this.launchProfile,
  });
}

enum ClientSelectionKind { exact, missing, ambiguous }

class ClientSelectionResult {
  const ClientSelectionResult(this.kind, this.matches);

  final ClientSelectionKind kind;
  final List<ClientInstance> matches;

  ClientInstance? get selected =>
      kind == ClientSelectionKind.exact ? matches.single : null;
}

ClientSelectionResult selectClientByDevice({
  required Iterable<ClientInstance> clients,
  String? deviceId,
  int? vmServicePort,
}) {
  final matches = clients.where((client) {
    if (deviceId != null && client.deviceId != deviceId) return false;
    if (vmServicePort != null && client.port != vmServicePort) return false;
    return true;
  }).toList()..sort((left, right) => left.port.compareTo(right.port));
  return ClientSelectionResult(
    matches.isEmpty
        ? ClientSelectionKind.missing
        : matches.length == 1
        ? ClientSelectionKind.exact
        : ClientSelectionKind.ambiguous,
    List.unmodifiable(matches),
  );
}

int? clientAgentPort(ClientInstance client) {
  final gateway = Uri.tryParse(
    client.launchProfile?.define('LOCAL_GATEWAY_URL') ?? '',
  );
  return gateway?.hasPort == true ? gateway!.port : null;
}

List<ClientInstance> clientsForAgentPort(
  Iterable<ClientInstance> clients,
  int agentPort,
) {
  final matches = clients
      .where((client) => clientAgentPort(client) == agentPort)
      .toList();
  matches.sort((left, right) {
    final byDevice = (left.deviceId ?? '').compareTo(right.deviceId ?? '');
    return byDevice != 0 ? byDevice : left.port.compareTo(right.port);
  });
  return matches;
}

/// Names the predicate that excluded every discovered Client.
///
/// `selectClientInstance` used to print one generic "no clients" line for a
/// manual runtime, a foreign Agent, and an incomplete launch profile. During one
/// incident that was the whole diagnosis: the Client existed, attached to a
/// daemon carrying another launcher identity, and the command said nothing.
/// Every branch below names the evidence it has instead of the absence it saw.
String? clientSelectionFailureReason(
  RuntimeProcessState state, {
  required int agentPort,
}) {
  if (state.agentAmbiguous) {
    return 'more than one Agent matches this worktree, so none can own a Client';
  }
  final agent = state.agent;
  final blocked = state.blockedClients;
  if (agent == null) {
    if (blocked.isEmpty) return 'no Agent answers on port $agentPort';
    return 'the Client on VM port ${blocked.first.port} '
        '${_clientBlockReason(blocked.first, agent: null)}';
  }
  if (agent.launcherId == null || agent.runtimeNonce == null) {
    return 'the Agent on port ${agent.port} reports no managed launcher '
        'identity, so it cannot own a Client';
  }
  if (blocked.isNotEmpty) {
    return 'the Client on VM port ${blocked.first.port} '
        '${_clientBlockReason(blocked.first, agent: agent)}';
  }
  // Silence here was the whole diagnosis for a Client that never attached: a
  // managed Agent was answering, no Client was owned, and the command printed
  // no reason at all. Only an actually-owned Client removes the reason.
  if (state.ownedClients.isNotEmpty) return null;
  return 'the Agent on port ${agent.port} is managed, but no launched Client '
      'reports this worktree\'s launcher identity';
}

/// Why one Client is not part of the selected Agent's ownership.
String _clientBlockReason(
  ClientInstance client, {
  required AgentInstance? agent,
}) {
  final profile = client.launchProfile;
  if (profile == null) return 'has no readable launch profile';
  final launcherId = profile.define('SANAD_DEV_LAUNCHER_ID');
  final runtimeNonce = profile.define('SANAD_DEV_RUNTIME_NONCE');
  if (launcherId == null || runtimeNonce == null) {
    return 'has an incomplete launch profile (no launcher id or runtime nonce)';
  }
  if (agent == null) {
    return 'was launched by launcher $launcherId, which no live Agent answers '
        'for';
  }
  if (launcherId != agent.launcherId) {
    return 'was launched by launcher $launcherId, but the Agent on port '
        '${agent.port} answers as ${agent.launcherId}';
  }
  if (runtimeNonce != agent.runtimeNonce) {
    return 'was launched with runtime nonce $runtimeNonce, but the Agent on '
        'port ${agent.port} answers as ${agent.runtimeNonce}';
  }
  return 'is not owned by the live sanad-dev launcher';
}

Future<ClientInstance?> selectClientInstance(
  int? portOverride, {
  String? sanadHomePath,
}) async {
  final instances = await discoverClientInstances();
  if (instances.isEmpty) {
    print(
      'Error: No running client instances found. Make sure the client app is running in debug mode.',
    );
    exit(1);
  }

  if (portOverride != null) {
    for (final inst in instances) {
      if (inst.port == portOverride) {
        return inst;
      }
    }
    final recorded = await _recordedClientInstance(portOverride);
    if (recorded != null) return recorded;
    print('Error: No running client instance found on port $portOverride.');
    print('Active instances:');
    for (final inst in instances) {
      print('  Port: ${inst.port} | Path: ${inst.path}');
    }
    exit(1);
  }

  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final activeAgents = await discoverAgentInstances(
    sanadHomeOverride: sanadHomePath,
  );
  final state = selectRuntimeProcessState(
    activeAgents: activeAgents,
    activeClients: instances,
    runtime: runtime,
  );
  final matchingInstances = state.ownedClients;
  final launcherMatchedInstances = matchingInstances
      .where((client) {
        final profile = client.launchProfile;
        return state.agent?.launcherId != null &&
            state.agent?.runtimeNonce != null &&
            profile?.define('SANAD_DEV_LAUNCHER_ID') ==
                state.agent!.launcherId &&
            profile?.define('SANAD_DEV_RUNTIME_NONCE') ==
                state.agent!.runtimeNonce;
      })
      .toList(growable: false);

  if (launcherMatchedInstances.length == 1) {
    return launcherMatchedInstances.single;
  }

  if (matchingInstances.length == 1) {
    return matchingInstances.first;
  }

  if (matchingInstances.isEmpty) {
    print(
      'Error: No owned running client instances found for the current worktree (${runtime.worktreeId}).',
    );
    final reason = clientSelectionFailureReason(
      state,
      agentPort: runtime.agentPort,
    );
    print(
      'Reason: ${reason ?? 'no Client reports this worktree launcher identity'}.',
    );
    final ownerHint = explicitHomeOwnerHint(
      explicitHome: sanadHomePath,
      runtime: runtime,
      homeRecords: await _explicitHomeLauncherRecords(
        sanadHomePath,
        activeAgents,
      ),
    );
    if (ownerHint != null) print(ownerHint);
    print('Active instances in other worktrees:');
    for (final inst in instances) {
      print('  Port: ${inst.port} | Path: ${inst.path}');
    }
    exit(1);
  }

  print(
    'Error: Multiple running client instances found for the current worktree. Please specify which instance to target using the -p/--port option:',
  );
  for (final inst in matchingInstances) {
    print('  Port: ${inst.port} | Path: ${inst.path}');
  }
  exit(1);
}

/// Explains why an explicit `--home` selected no Client from this worktree.
///
/// Developer actions select by the invoking worktree identity, so a Home whose
/// live launcher lease was started from another source root is reported with
/// that owner instead of being followed. Returns null when no explicit
/// absolute Home was supplied or no lease for it belongs elsewhere.
String? explicitHomeOwnerHint({
  required String? explicitHome,
  required SanadDevRuntime runtime,
  required Iterable<RuntimeLauncherRecord> homeRecords,
}) {
  final home = explicitHome?.trim();
  if (home == null || home.isEmpty || !isAbsoluteFileSystemPath(home)) {
    return null;
  }
  final foreign = homeRecords
      .where(
        (record) =>
            _samePath(record.sanadHome, home) &&
            !_samePath(record.sourceRoot, runtime.repositoryRoot),
      )
      .toList(growable: false);
  if (foreign.isEmpty) return null;
  final owners = foreign
      .map(
        (record) =>
            '  Agent port ${record.agentPort} | Source: '
            '${record.sourceRoot}',
      )
      .join('\n');
  return 'The selected Home $home is served by a sanad-dev runtime launched '
      'from another worktree:\n$owners\n'
      'Developer actions select by the invoking worktree; run this command '
      'from that worktree.';
}

Future<List<RuntimeLauncherRecord>> _explicitHomeLauncherRecords(
  String? explicitHome,
  Iterable<AgentInstance> agents,
) async {
  final home = explicitHome?.trim();
  if (home == null || home.isEmpty || !isAbsoluteFileSystemPath(home)) {
    return const [];
  }
  final records = <RuntimeLauncherRecord>[];
  for (final agent in agents) {
    try {
      final record = await readRuntimeLauncherRecord(home, agent.port);
      if (record != null) records.add(record);
    } on Object {
      // A malformed or unreadable lease is diagnostic noise, not an owner.
    }
  }
  return records;
}

Future<ClientInstance?> _recordedClientInstance(int port) async {
  try {
    final runtime = await _currentRuntime();
    final record = await readRuntimeRecord(runtime);
    if (record?.vmServicePort != port ||
        !await isProcessRunning(record?.clientPid)) {
      return null;
    }

    final socket = await WebSocket.connect(
      'ws://127.0.0.1:$port/ws',
    ).timeout(const Duration(milliseconds: 500));
    await socket.close();
    return ClientInstance(
      port,
      '',
      '${runtime.repositoryRoot}${Platform.pathSeparator}client',
      _defaultDesktopDevice(),
    );
  } catch (_) {
    return null;
  }
}

Future<AgentInstance?> selectAgentInstance(
  int? portOverride, {
  bool allowStartupGrace = false,
  String? sanadHomePath,
  bool exitOnError = true,
}) async {
  var instances = await discoverAgentInstances(
    sanadHomeOverride: sanadHomePath,
  );
  if (instances.isEmpty && allowStartupGrace) {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline) && instances.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      instances = await discoverAgentInstances(
        sanadHomeOverride: sanadHomePath,
      );
    }
  }
  if (instances.isEmpty) {
    stderr.writeln(
      'Error: No running agent instances found. Make sure the agent daemon is running.',
    );
    if (exitOnError) exit(1);
    return null;
  }

  if (portOverride != null) {
    for (final inst in instances) {
      if (inst.port == portOverride) {
        return inst;
      }
    }
    stderr.writeln(
      'Error: No running agent instance found on port $portOverride.',
    );
    stderr.writeln('Active instances:');
    for (final inst in instances) {
      stderr.writeln(
        '  Port: ${inst.port} (Workspace Hash: ${inst.workspaceHash})',
      );
    }
    if (exitOnError) exit(1);
    return null;
  }

  // Filter instances matching the current worktree's workspace root hash
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final currentWorkspaceHash = runtime.worktreeId.split('-').last;
  var matchingInstances = instances
      .where((inst) => inst.workspaceHash == currentWorkspaceHash)
      .toList();

  if (matchingInstances.isEmpty && allowStartupGrace) {
    final deadline = DateTime.now().add(const Duration(seconds: 5));
    while (DateTime.now().isBefore(deadline) && matchingInstances.isEmpty) {
      await Future<void>.delayed(const Duration(milliseconds: 500));
      instances = await discoverAgentInstances(
        sanadHomeOverride: sanadHomePath,
      );
      matchingInstances = instances
          .where((inst) => inst.workspaceHash == currentWorkspaceHash)
          .toList();
    }
  }

  if (matchingInstances.length == 1) {
    return matchingInstances.first;
  }

  if (matchingInstances.isEmpty) {
    stderr.writeln(
      'Error: No running agent instances found for the current worktree (${runtime.worktreeId}).',
    );
    // An absent Agent and a Home held by another process look identical from
    // the port scan alone. The owner record separates them, so it is named
    // before the list of unrelated instances.
    final homes = <String>{
      runtime.sanadHome,
      for (final inst in instances)
        if (inst.sanadHome != null) inst.sanadHome!,
    };
    for (final home in homes) {
      final holder = await describeHomeHolder(home);
      if (holder != null) stderr.writeln('$home: $holder');
    }
    stderr.writeln('Active instances in other worktrees:');
    for (final inst in instances) {
      stderr.writeln(
        '  Port: ${inst.port} (Workspace Hash: ${inst.workspaceHash})',
      );
    }
    if (exitOnError) exit(1);
    return null;
  }

  stderr.writeln(
    'Error: Multiple running agent instances found for the current worktree. Please specify which instance to target using the -p/--port option:',
  );
  for (final inst in matchingInstances) {
    stderr.writeln(
      '  Port: ${inst.port} (Workspace Hash: ${inst.workspaceHash})',
    );
  }
  if (exitOnError) exit(1);
  return null;
}
