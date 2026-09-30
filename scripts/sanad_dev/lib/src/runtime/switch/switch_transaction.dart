part of '../../../sanad_dev_cli.dart';

List<int>? exactManagedClientPids({
  required Iterable<ClientInstance> discoveredClients,
  required Set<int> expectedVmServicePorts,
  required String launcherId,
  required String runtimeNonce,
  required String workspaceHash,
}) {
  final pids = <int>[];
  for (final expectedPort in expectedVmServicePorts) {
    final matches = discoveredClients.where((client) {
      final profile = client.launchProfile;
      return client.port == expectedPort &&
          client.pid != null &&
          profile?.define('SANAD_DEV_LAUNCHER_ID') == launcherId &&
          profile?.define('SANAD_DEV_RUNTIME_NONCE') == runtimeNonce &&
          profile?.define('SANAD_DEV_WORKSPACE_HASH') == workspaceHash;
    }).toList();
    if (matches.length != 1) return null;
    pids.add(matches.single.pid!);
  }
  return pids;
}

class _SwitchTransactionRunner {
  _SwitchTransactionRunner(this._controller);

  final _SwitchableRuntimeController _controller;

  SanadDevRuntime get _runtime => _controller.runtime;
  String get _manifestPath => _controller._manifestPath;

  Future<void> performSwitch(RuntimeSwitchRequest request) async {
    if (_controller._agent == null ||
        (_controller._client == null &&
            _controller._additionalClients.isEmpty)) {
      await writeRuntimeSwitchRequest(
        _manifestPath,
        request.copyWith(
          status: 'failed',
          message: 'Source switch requires a complete Agent/Client group.',
        ),
      );
      return;
    }
    if (request.launcherId != _controller._launcherRecord.launcherId ||
        request.runtimeNonce != _controller._launcherRecord.runtimeNonce ||
        request.agentPort != _runtime.agentPort ||
        _samePath(
          _controller._clientDirectory,
          '${request.targetRepositoryRoot}${Platform.pathSeparator}client',
        )) {
      await writeRuntimeSwitchRequest(
        _manifestPath,
        request.copyWith(
          status: 'failed',
          message: 'Target is invalid or already active.',
        ),
      );
      return;
    }

    final discoveredClients = clientsForAgentPort(
      await discoverClientInstances(),
      _runtime.agentPort,
    );
    final previousClients = <_RuntimeClientLaunch>[];
    for (final client in discoveredClients) {
      final profile = client.launchProfile;
      if (profile == null || client.pid == null) {
        await writeRuntimeSwitchRequest(
          _manifestPath,
          request.copyWith(
            status: 'failed',
            message: 'A runtime client has incomplete launch identity.',
          ),
        );
        return;
      }
      previousClients.add(
        _RuntimeClientLaunch(
          directory: client.path,
          arguments: buildSwitchedClientRunArguments(
            currentProfile: profile,
            targetWorktreeName: profile.define('SANAD_DEV_WORKTREE_NAME') ?? '',
            targetBranch: profile.define('SANAD_DEV_WORKTREE_BRANCH') ?? '',
            targetIsLinkedWorktree:
                profile.define('SANAD_DEV_WORKTREE_NAME')?.isNotEmpty == true,
            vmServicePort: client.port,
            deviceId:
                profile.deviceId ?? client.deviceId ?? _defaultDesktopDevice(),
          ),
          vmServicePort: client.port,
          deviceId:
              profile.deviceId ?? client.deviceId ?? _defaultDesktopDevice(),
          pid: client.pid,
        ),
      );
    }
    if (previousClients.isEmpty) {
      await writeRuntimeSwitchRequest(
        _manifestPath,
        request.copyWith(
          status: 'failed',
          message: 'No runtime clients found.',
        ),
      );
      return;
    }

    final previousAgentDirectory = _controller._agentDirectory;
    final previousWorkspaceHash = _controller._currentWorkspaceHash;
    _controller._launcherRecord = _controller._launcherRecord.copyWith(
      status: 'switching',
    );
    await writeRuntimeLauncherRecord(_controller._launcherRecord);
    await writeRuntimeSwitchRequest(
      _manifestPath,
      request.copyWith(
        status: 'draining',
        message: 'Waiting for safe restart.',
      ),
    );

    final accepted = await _requestSafeRestart(request);
    if (!accepted) {
      _controller._launcherRecord = _controller._launcherRecord.copyWith(
        status: 'running',
      );
      await writeRuntimeLauncherRecord(_controller._launcherRecord);
      await writeRuntimeSwitchRequest(
        _manifestPath,
        request.copyWith(
          status: 'failed',
          message: 'Safe restart was rejected.',
        ),
      );
      return;
    }
    final childExited = await _waitForAgentUnavailable(
      timeout: const Duration(seconds: 75),
    );
    if (!childExited) {
      _controller._launcherRecord = _controller._launcherRecord.copyWith(
        status: 'running',
      );
      await writeRuntimeLauncherRecord(_controller._launcherRecord);
      await writeRuntimeSwitchRequest(
        _manifestPath,
        request.copyWith(
          status: 'failed',
          message: 'The drained agent did not reach its exit checkpoint.',
        ),
      );
      return;
    }

    await writeRuntimeSwitchRequest(
      _manifestPath,
      request.copyWith(status: 'starting', message: 'Starting target sources.'),
    );
    for (final client in previousClients) {
      await _controller._terminatePidTree(client.pid!);
    }
    _controller._additionalClients.clear();
    if (_controller._agent != null) {
      await _controller._terminateProcessTree(_controller._agent!);
    }
    await _controller._cancelAgentOutput();

    final targetAgentDirectory =
        '${request.targetRepositoryRoot}${Platform.pathSeparator}agent';
    final targetClientDirectory =
        '${request.targetRepositoryRoot}${Platform.pathSeparator}client';
    final targetClients = previousClients
        .map(
          (client) => _RuntimeClientLaunch(
            directory: targetClientDirectory,
            arguments: buildSwitchedClientRunArguments(
              currentProfile: extractClientLaunchProfile(client.arguments),
              targetWorktreeName: request.targetWorktreeName,
              targetBranch: request.targetBranch,
              targetWorkspaceHash: request.targetWorkspaceHash,
              targetIsLinkedWorktree: request.targetIsLinkedWorktree,
              vmServicePort: client.vmServicePort,
              deviceId: client.deviceId,
            ),
            vmServicePort: client.vmServicePort,
            deviceId: client.deviceId,
          ),
        )
        .toList();

    try {
      if (!await waitForClientResourcesUnavailable(
        clientPidsByVmPort: {
          for (final client in previousClients)
            client.vmServicePort: client.pid,
        },
      )) {
        throw StateError(
          'Previous Client identity remained active after termination.',
        );
      }
      await _controller._startAgent(targetAgentDirectory);
      final agentHealthy = await _controller._waitForAgentHash(
        request.targetWorkspaceHash,
        timeout: const Duration(seconds: 30),
      );
      if (!agentHealthy) {
        throw StateError('Target agent did not become healthy.');
      }
      await _startClients(targetClients);
      for (final client in targetClients) {
        final clientHealthy = await _waitForVmService(
          client.vmServicePort,
          timeout: sanadDevClientStartupTimeout,
        );
        if (!clientHealthy) {
          throw StateError(
            'Target client ${client.deviceId} did not expose VM ${client.vmServicePort}.',
          );
        }
      }
      _controller._agentDirectory = targetAgentDirectory;
      _controller._clientDirectory = targetClientDirectory;
      _controller._currentWorkspaceHash = request.targetWorkspaceHash;
      final managedClientPids = await _managedClientPids(
        targetClients,
        workspaceHash: request.targetWorkspaceHash,
      );
      _controller._launcherRecord = _controller._launcherRecord.copyWith(
        workspaceHash: request.targetWorkspaceHash,
        sourceRoot: request.targetRepositoryRoot,
        clientPids: managedClientPids,
        vmServicePorts: targetClients
            .map((item) => item.vmServicePort)
            .toList(),
        status: 'running',
      );
      await writeRuntimeLauncherRecord(_controller._launcherRecord);
      await writeRuntimeSwitchRequest(
        _manifestPath,
        request.copyWith(
          status: 'complete',
          message: 'Runtime switch complete.',
        ),
      );
      print('✓ Runtime switched to ${request.targetWorktreeName}.');
    } on Object catch (error) {
      stderr.writeln(
        'Runtime switch failed; restoring previous sources: $error',
      );
      await _controller._terminateCurrentClients();
      if (_controller._agent != null) {
        await _controller._terminateProcessTree(_controller._agent!);
      }
      await _controller._cancelAgentOutput();
      var restored = await _restorePreviousGroup(
        agentDirectory: previousAgentDirectory,
        clients: previousClients,
        workspaceHash: previousWorkspaceHash,
      );
      List<int>? restoredClientPids;
      if (restored) {
        try {
          restoredClientPids = await _managedClientPids(
            previousClients,
            workspaceHash: previousWorkspaceHash,
          );
        } on Object {
          restored = false;
        }
      }
      if (restored) {
        _controller._launcherRecord = _controller._launcherRecord.copyWith(
          workspaceHash: previousWorkspaceHash,
          sourceRoot: Directory(previousAgentDirectory).parent.path,
          clientPids: restoredClientPids,
          vmServicePorts: previousClients
              .map((item) => item.vmServicePort)
              .toList(),
          status: 'running',
        );
        await writeRuntimeLauncherRecord(_controller._launcherRecord);
      }
      await writeRuntimeSwitchRequest(
        _manifestPath,
        request.copyWith(
          status: restored ? 'rolled_back' : 'recovery_failed',
          message: restored
              ? 'Target startup failed; previous sources restored.'
              : 'Target startup and rollback both failed.',
        ),
      );
      if (!restored) _controller._stopping = true;
    }
  }

  Future<bool> _restorePreviousGroup({
    required String agentDirectory,
    required List<_RuntimeClientLaunch> clients,
    required String workspaceHash,
  }) async {
    try {
      await _controller._startAgent(agentDirectory);
      if (!await _controller._waitForAgentHash(
        workspaceHash,
        timeout: const Duration(seconds: 30),
      )) {
        return false;
      }
      await _startClients(clients);
      for (final client in clients) {
        if (!await _waitForVmService(
          client.vmServicePort,
          timeout: sanadDevClientStartupTimeout,
        )) {
          return false;
        }
      }
      _controller._agentDirectory = agentDirectory;
      _controller._clientDirectory = clients.first.directory;
      _controller._currentWorkspaceHash = workspaceHash;
      return true;
    } on Object catch (error) {
      stderr.writeln('Previous runtime restoration failed: $error');
      return false;
    }
  }

  Future<List<int>> _managedClientPids(
    List<_RuntimeClientLaunch> expected, {
    required String workspaceHash,
    Duration timeout = sanadDevClientStartupTimeout,
  }) async {
    final expectedVmServicePorts = expected
        .map((client) => client.vmServicePort)
        .toSet();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      final pids = exactManagedClientPids(
        discoveredClients: clientsForAgentPort(
          await discoverClientInstances(),
          _runtime.agentPort,
        ),
        expectedVmServicePorts: expectedVmServicePorts,
        launcherId: _controller._launcherRecord.launcherId,
        runtimeNonce: _controller._launcherRecord.runtimeNonce,
        workspaceHash: workspaceHash,
      );
      if (pids != null) return pids;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    throw StateError('Managed client process identity is incomplete.');
  }

  Future<bool> _requestSafeRestart(RuntimeSwitchRequest switchRequest) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${_runtime.agentPort}/restart').replace(
          queryParameters: const {'force': 'false', 'timeout_seconds': '60'},
        ),
      );
      await authorizeLocalGatewayRequest(request, _runtime.sanadHome);
      if (switchRequest.requesterSessionId != null) {
        request.headers.set(
          'x-sanad-requester-session-id',
          switchRequest.requesterSessionId!,
        );
      }
      if (switchRequest.requesterToolCallId != null) {
        request.headers.set(
          'x-sanad-requester-tool-call-id',
          switchRequest.requesterToolCallId!,
        );
      }
      final response = await request.close().timeout(
        const Duration(seconds: 65),
      );
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

  Future<void> _startClients(List<_RuntimeClientLaunch> clients) async {
    _controller._additionalClients.clear();
    _controller._clientProcessesByVmPort.clear();
    for (final journal in _controller._clientJournalsByVmPort.values) {
      await journal.cancel();
    }
    _controller._clientJournalsByVmPort.clear();
    for (var index = 0; index < clients.length; index++) {
      final client = clients[index];
      final profile = extractClientLaunchProfile(client.arguments);
      final process = await Process.start(
        'fvm',
        client.arguments,
        workingDirectory: client.directory,
        environment: buildUnifiedSanadHomeEnvironment(
          Platform.environment,
          sanadHome: profile.define('SANAD_HOME') ?? _runtime.sanadHome,
        ),
        runInShell: Platform.isWindows,
      );
      if (index == 0) {
        _controller._client = process;
      } else {
        _controller._additionalClients.add(process);
      }
      _controller._clientProcessesByVmPort[client.vmServicePort] = process;
      _controller._clientJournalsByVmPort[client.vmServicePort] =
          await ComponentProcessJournal.attach(
            process: process,
            writer: ComponentJournalWriter(
              sanadHome: _runtime.sanadHome,
              agentPort: _runtime.agentPort,
              component: 'client',
              vmServicePort: client.vmServicePort,
              launcherId: _controller._launcherRecord.launcherId,
              runtimeNonce: _controller._launcherRecord.runtimeNonce,
            ),
          );
    }
  }

  Future<bool> _waitForAgentUnavailable({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!await _controller._agentHealthMatches(null)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return false;
  }

  Future<bool> _waitForVmService(
    int vmServicePort, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      try {
        final socket = await WebSocket.connect(
          'ws://127.0.0.1:$vmServicePort/ws',
        ).timeout(const Duration(milliseconds: 300));
        await socket.close();
        return true;
      } on Object {}
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }
}
