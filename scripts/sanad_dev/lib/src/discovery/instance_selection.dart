part of '../../sanad_dev_cli.dart';

class ClientInstance {
  final int port;
  final String token;
  final String path;
  final String? deviceId;
  final int? pid;
  final ClientLaunchProfile? launchProfile;
  ClientInstance(
    this.port,
    this.token,
    this.path,
    this.deviceId, {
    this.pid,
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
  final state = selectRuntimeProcessState(
    activeAgents: await discoverAgentInstances(
      sanadHomeOverride: sanadHomePath,
    ),
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
      'Error: No running client instances found for the current worktree (${runtime.worktreeId}).',
    );
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
    stderr.writeln('Error: No running agent instance found on port $portOverride.');
    stderr.writeln('Active instances:');
    for (final inst in instances) {
      stderr.writeln('  Port: ${inst.port} (Workspace Hash: ${inst.workspaceHash})');
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
    stderr.writeln('Active instances in other worktrees:');
    for (final inst in instances) {
      stderr.writeln('  Port: ${inst.port} (Workspace Hash: ${inst.workspaceHash})');
    }
    if (exitOnError) exit(1);
    return null;
  }

  stderr.writeln(
    'Error: Multiple running agent instances found for the current worktree. Please specify which instance to target using the -p/--port option:',
  );
  for (final inst in matchingInstances) {
    stderr.writeln('  Port: ${inst.port} (Workspace Hash: ${inst.workspaceHash})');
  }
  if (exitOnError) exit(1);
  return null;
}
