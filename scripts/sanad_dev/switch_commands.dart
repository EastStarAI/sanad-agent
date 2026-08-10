part of '../sanad_dev.dart';

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
    if (existing != null &&
        const {'requested', 'draining', 'starting'}.contains(existing.status)) {
      stderr.writeln('Switch aborted: another runtime handoff is active.');
      exitCode = 1;
      return;
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

Future<bool> waitForClientResourcesUnavailable({
  required Map<int, int?> clientPidsByVmPort,
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 100),
  Future<bool> Function(int pid)? processRunning,
  Future<bool> Function(int port)? vmServiceAvailable,
}) async {
  final isRunning = processRunning ?? isProcessRunning;
  final vmAvailable = vmServiceAvailable ?? _vmServiceIsAvailable;
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    var unavailable = true;
    for (final client in clientPidsByVmPort.entries) {
      if ((client.value != null && await isRunning(client.value!)) ||
          await vmAvailable(client.key)) {
        unavailable = false;
        break;
      }
    }
    if (unavailable) return true;
    await Future<void>.delayed(pollInterval);
  }
  return false;
}

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

Future<void> terminateSanadDevProcessTree(int processId) async {
  if (Platform.isWindows) {
    await Process.run('taskkill', ['/PID', '$processId', '/T', '/F']);
    return;
  }
  final result = await Process.run('ps', ['-axo', 'pid=,ppid=']);
  final processIds = result.exitCode == 0
      ? orderUnixProcessTree(result.stdout.toString(), processId)
      : [processId];
  for (final childPid in processIds.reversed) {
    try {
      Process.killPid(childPid, ProcessSignal.sigterm);
    } on Object {}
  }
  await Future<void>.delayed(const Duration(milliseconds: 500));
  for (final childPid in processIds.reversed) {
    if (await isProcessRunning(childPid)) {
      try {
        Process.killPid(childPid, ProcessSignal.sigkill);
      } on Object {}
    }
  }
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

class _SwitchableRuntimeController {
  _SwitchableRuntimeController({
    required this.runtime,
    required Process? agent,
    required Process? client,
    required Map<String, String> agentEnvironment,
    required List<String> agentArguments,
    required List<String> clientArguments,
    required Map<String, String> clientEnvironment,
    required String agentDirectory,
    required String clientDirectory,
    required ComponentProcessJournal? agentJournal,
    required ComponentProcessJournal? initialClientJournal,
    required RuntimeLauncherRecord launcherRecord,
    required SanadDevComponentTarget interactiveComponent,
  }) : _agent = agent,
       _client = client,
       _agentEnvironment = Map.unmodifiable(agentEnvironment),
       _agentArguments = List.unmodifiable(agentArguments),
       _clientArguments = List.unmodifiable(clientArguments),
       _clientEnvironment = Map.unmodifiable(clientEnvironment),
       _agentDirectory = agentDirectory,
       _clientDirectory = clientDirectory,
       _agentJournal = agentJournal,
       _launcherRecord = launcherRecord,
       _interactiveComponent = interactiveComponent,
       _currentWorkspaceHash = runtime.worktreeId.split('-').last {
    if (client != null && launcherRecord.vmServicePorts.isNotEmpty) {
      final port = launcherRecord.vmServicePorts.first;
      _clientProcessesByVmPort[port] = client;
      if (initialClientJournal != null) {
        _clientJournalsByVmPort[port] = initialClientJournal;
      }
    }
  }

  final SanadDevRuntime runtime;
  Process? _agent;
  Process? _client;
  final List<Process> _additionalClients = [];
  final Map<int, Process> _clientProcessesByVmPort = {};
  final Map<int, ComponentProcessJournal> _clientJournalsByVmPort = {};
  final Map<String, String> _agentEnvironment;
  final List<String> _agentArguments;
  final List<String> _clientArguments;
  final Map<String, String> _clientEnvironment;
  final SanadDevComponentTarget _interactiveComponent;
  String _agentDirectory;
  String _clientDirectory;
  String _currentWorkspaceHash;
  ComponentProcessJournal? _agentJournal;
  RuntimeLauncherRecord _launcherRecord;
  final Completer<void> _controllerStopped = Completer<void>();
  final RuntimeSwitchManifestWarningGate _manifestWarningGate =
      RuntimeSwitchManifestWarningGate();
  bool _stopping = false;
  bool _agentTerminalActionInProgress = false;

  String get _manifestPath =>
      runtimeSwitchManifestPath(runtime.sanadHome, runtime.agentPort);
  String get _componentControlPath =>
      runtimeComponentControlPath(runtime.sanadHome, runtime.agentPort);

  Future<int> run() async {
    final shutdown = Completer<_ShutdownRequested>();
    StreamSubscription<ProcessSignal>? sigint;
    StreamSubscription<ProcessSignal>? sigterm;
    StreamSubscription<List<int>>? stdinKeys;
    if (stdin.hasTerminal) {
      try {
        stdin.lineMode = false;
        stdin.echoMode = false;
      } on Object {
        // Continue with terminal defaults when raw input is unavailable.
      }
      stdinKeys = stdin.listen((bytes) {
        for (final byte in bytes) {
          final key = String.fromCharCode(byte);
          if (_interactiveComponent == SanadDevComponentTarget.client) {
            if (runtimeClientActionForInteractiveKey(key) == null) continue;
            final port = _clientProcessesByVmPort.keys.firstOrNull;
            final process = port == null
                ? null
                : _clientProcessesByVmPort[port];
            if (process != null) {
              process.stdin.write(key);
              unawaited(process.stdin.flush());
            }
          } else if ((key == 'r' || key == 'R') && _agent != null) {
            unawaited(handleAgentRestart(runtime.agentPort));
          } else if ((key == 's' || key == 'q') &&
              _agent != null &&
              !_agentTerminalActionInProgress) {
            unawaited(_stopAgentFromTerminal());
          }
        }
      });
    }
    sigint = ProcessSignal.sigint.watch().listen((_) {
      if (!shutdown.isCompleted) {
        shutdown.complete(const _ShutdownRequested());
      }
    });
    if (!Platform.isWindows) {
      sigterm = ProcessSignal.sigterm.watch().listen((_) {
        if (!shutdown.isCompleted) {
          shutdown.complete(const _ShutdownRequested());
        }
      });
    }

    var clientExitCode = 0;
    try {
      while (!_stopping) {
        final currentAgent = _agent;
        final currentClients = _clientProcessesByVmPort.values.toList();
        if (currentAgent == null && currentClients.isEmpty) break;
        final events = <Future<Object>>[
          _waitForControllerCommand(),
          shutdown.future,
          if (currentAgent != null)
            currentAgent.exitCode.then<Object>(
              (code) => _AgentStopped(currentAgent.pid, code),
            ),
          ...currentClients.map(
            (client) => client.exitCode.then<Object>(
              (code) => _ClientStopped(client.pid, code),
            ),
          ),
        ];
        final event = await Future.any<Object>(events);
        if (event is _ShutdownRequested) break;
        if (event is _AgentStopped && _agent?.pid == event.pid) {
          _agent = null;
          await _cancelAgentOutput();
          await _writeCurrentComponentRecord();
          continue;
        }
        if (event is _ClientStopped) {
          clientExitCode = event.exitCode;
          if (_client?.pid == event.pid) _client = null;
          _additionalClients.removeWhere((item) => item.pid == event.pid);
          final stoppedPorts = _clientProcessesByVmPort.entries
              .where((entry) => entry.value.pid == event.pid)
              .map((entry) => entry.key)
              .toList();
          _clientProcessesByVmPort.removeWhere(
            (_, process) => process.pid == event.pid,
          );
          for (final port in stoppedPorts) {
            await _clientJournalsByVmPort.remove(port)?.cancel();
          }
          await _writeCurrentComponentRecord();
          continue;
        }
        if (event is RuntimeComponentControlRequest) {
          await _performComponentControl(event);
          continue;
        }
        if (event is RuntimeSwitchRequest) {
          await _performSwitch(event);
        }
      }
    } finally {
      _stopping = true;
      if (!_controllerStopped.isCompleted) _controllerStopped.complete();
      await _stopCurrentPair();
      await deleteRuntimeLauncherRecord(runtime.sanadHome, runtime.agentPort);
      final stopRequest = File(
        runtimeLauncherStopRequestPath(runtime.sanadHome, runtime.agentPort),
      );
      if (await stopRequest.exists()) await stopRequest.delete();
      await sigint.cancel();
      await sigterm?.cancel();
      await stdinKeys?.cancel();
      if (stdin.hasTerminal) {
        try {
          stdin.lineMode = true;
          stdin.echoMode = true;
        } on Object {
          // The host terminal may not expose mutable modes.
        }
      }
    }
    return clientExitCode;
  }

  Future<void> _stopAgentFromTerminal() async {
    _agentTerminalActionInProgress = true;
    try {
      print('\n[sanad-dev] Safe Agent stop requested.');
      final succeeded = await requestManagedComponentAction(
        _launcherRecord,
        action: RuntimeComponentAction.stop,
        target: RuntimeComponentTarget.agent,
      );
      if (!succeeded) {
        stderr.writeln(
          'Agent stop failed; the managed runtime remains active.',
        );
      }
    } finally {
      _agentTerminalActionInProgress = false;
    }
  }

  Future<Object> _waitForControllerCommand() async {
    while (!_controllerStopped.isCompleted) {
      if (await consumeRuntimeLauncherStopRequest(_launcherRecord)) {
        return const _ShutdownRequested();
      }
      try {
        final componentRequest = await readRuntimeComponentControl(
          _componentControlPath,
        );
        if (componentRequest != null &&
            componentRequest.status == 'requested') {
          return componentRequest;
        }
      } on Object catch (error) {
        stderr.writeln('Ignoring invalid runtime component request: $error');
      }
      try {
        final request = await readRuntimeSwitchRequest(_manifestPath);
        _manifestWarningGate.reset();
        if (request != null && request.status == 'requested') return request;
      } on Object catch (error) {
        if (await _manifestWarningGate.shouldReport(_manifestPath, error)) {
          stderr.writeln('Ignoring invalid runtime switch request: $error');
        }
      }
      await Future.any<void>([
        Future<void>.delayed(const Duration(milliseconds: 250)),
        _controllerStopped.future,
      ]);
    }
    return Completer<Object>().future;
  }

  Future<void> _performComponentControl(
    RuntimeComponentControlRequest request,
  ) async {
    if (request.launcherId != _launcherRecord.launcherId ||
        request.runtimeNonce != _launcherRecord.runtimeNonce) {
      await writeRuntimeComponentControl(
        _componentControlPath,
        request.copyWith(
          status: 'failed',
          message: 'Launcher identity does not match the active runtime.',
        ),
      );
      return;
    }
    try {
      if (request.action == RuntimeComponentAction.start) {
        await _startRequestedComponents(request);
      } else if (request.action == RuntimeComponentAction.stop) {
        await _stopRequestedComponents(request);
      } else {
        await _sendClientDeveloperKey(request);
      }
      await _writeCurrentComponentRecord();
      await writeRuntimeComponentControl(
        _componentControlPath,
        request.copyWith(
          status: 'complete',
          message: '${request.target.name} ${request.action.name} complete.',
        ),
      );
    } on Object catch (error) {
      await writeRuntimeComponentControl(
        _componentControlPath,
        request.copyWith(status: 'failed', message: '$error'),
      );
    }
  }

  Future<void> _startRequestedComponents(
    RuntimeComponentControlRequest request,
  ) async {
    final startsAgent =
        request.target == RuntimeComponentTarget.agent ||
        request.target == RuntimeComponentTarget.all;
    final startsClient =
        request.target == RuntimeComponentTarget.client ||
        request.target == RuntimeComponentTarget.all;
    if (startsAgent && _agent == null) {
      await _startAgent(_agentDirectory);
      if (!await _waitForAgentHash(
        _currentWorkspaceHash,
        timeout: sanadDevAgentStartupTimeout,
      )) {
        throw StateError('Agent did not become healthy.');
      }
    }
    if (startsClient) {
      final discovered = await discoverClientInstances();
      final sameDevice = discovered.where(
        (client) =>
            _clientProcessesByVmPort.containsKey(client.port) &&
            client.deviceId == request.deviceId,
      );
      if (sameDevice.isNotEmpty) return;
      final port = request.vmServicePort ?? runtime.vmServicePort;
      if (await _vmServiceIsAvailable(port)) {
        throw StateError('VM-service port $port is already active.');
      }
      final arguments = _clientArguments.toList();
      final deviceIndex = arguments.indexOf('-d');
      if (deviceIndex >= 0 && deviceIndex + 1 < arguments.length) {
        arguments[deviceIndex + 1] =
            request.deviceId ?? _defaultDesktopDevice();
      }
      final vmIndex = arguments.indexWhere(
        (argument) => argument.startsWith('--host-vmservice-port='),
      );
      if (vmIndex >= 0) arguments[vmIndex] = '--host-vmservice-port=$port';
      final process = await Process.start(
        'fvm',
        arguments,
        workingDirectory: _clientDirectory,
        environment: _clientEnvironment,
        runInShell: Platform.isWindows,
      );
      if (_client == null) {
        _client = process;
      } else {
        _additionalClients.add(process);
      }
      _clientProcessesByVmPort[port] = process;
      _clientJournalsByVmPort[port] = await ComponentProcessJournal.attach(
        process: process,
        writer: ComponentJournalWriter(
          sanadHome: runtime.sanadHome,
          agentPort: runtime.agentPort,
          component: 'client',
          vmServicePort: port,
          launcherId: _launcherRecord.launcherId,
          runtimeNonce: _launcherRecord.runtimeNonce,
        ),
      );
      if (request.openClientTerminal) {
        final opened = await openClientLogTerminal(
          repositoryRoot: Directory(_clientDirectory).parent.path,
          agentPort: runtime.agentPort,
          vmServicePort: port,
          sanadHome: runtime.sanadHome,
        );
        if (!opened) {
          print('Client logs: sanad-dev logs client -n 50 -p $port');
        }
      }
      final identity = await _waitForManagedClientIdentity(
        vmServicePort: port,
        launcherId: _launcherRecord.launcherId,
        runtimeNonce: _launcherRecord.runtimeNonce,
      );
      if (identity?.pid == null) {
        await _terminateProcessTree(process);
        if (_client?.pid == process.pid) _client = null;
        _additionalClients.removeWhere((item) => item.pid == process.pid);
        _clientProcessesByVmPort.remove(port);
        await _clientJournalsByVmPort.remove(port)?.cancel();
        throw StateError('Client did not expose a matching managed identity.');
      }
      _launcherRecord = _launcherRecord.copyWith(
        clientPids: [..._launcherRecord.clientPids, identity!.pid!],
        vmServicePorts: [..._launcherRecord.vmServicePorts, port],
      );
    }
  }

  Future<void> _sendClientDeveloperKey(
    RuntimeComponentControlRequest request,
  ) async {
    if (request.target != RuntimeComponentTarget.client ||
        request.vmServicePort == null) {
      throw StateError('Client command requires one VM-service port.');
    }
    final process = _clientProcessesByVmPort[request.vmServicePort];
    if (process == null ||
        !_launcherRecord.vmServicePorts.contains(request.vmServicePort)) {
      throw StateError('Selected Client is not owned by this launcher.');
    }
    final key = runtimeClientInteractiveKeyForAction(request.action);
    if (key == null) {
      throw StateError('Unsupported Client interactive command.');
    }
    process.stdin.write(key);
    await process.stdin.flush();
  }

  Future<void> _stopRequestedComponents(
    RuntimeComponentControlRequest request,
  ) async {
    final stopsAgent =
        request.target == RuntimeComponentTarget.agent ||
        request.target == RuntimeComponentTarget.all;
    final stopsClient =
        request.target == RuntimeComponentTarget.client ||
        request.target == RuntimeComponentTarget.all;
    if (stopsAgent && _agent != null) {
      final accepted = await _requestAgentShutdown(force: request.force);
      if (!accepted) {
        throw StateError(
          request.force
              ? 'Agent cancellation shutdown was rejected.'
              : 'Agent has not reached a resumable checkpoint.',
        );
      }
      final process = _agent!;
      try {
        await process.exitCode.timeout(const Duration(seconds: 70));
      } on TimeoutException {
        throw StateError('Agent accepted shutdown but did not exit.');
      }
      _agent = null;
      await _cancelAgentOutput();
    }
    if (stopsClient) {
      if (request.target == RuntimeComponentTarget.client) {
        final pid = request.clientPid;
        if (pid == null || !_launcherRecord.clientPids.contains(pid)) {
          throw StateError('Selected Client is not owned by this launcher.');
        }
        final port = request.vmServicePort;
        final process = port == null ? null : _clientProcessesByVmPort[port];
        if (process == null) {
          throw StateError('Selected Client process is no longer active.');
        }
        await _terminateProcessTree(process);
        if (_client?.pid == process.pid) _client = null;
        _additionalClients.removeWhere((item) => item.pid == process.pid);
        _clientProcessesByVmPort.remove(port);
        await _clientJournalsByVmPort.remove(port)?.cancel();
      } else {
        await _terminateCurrentClients();
      }
    }
  }

  Future<bool> _requestAgentShutdown({required bool force}) async {
    final client = HttpClient();
    try {
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${runtime.agentPort}/shutdown').replace(
          queryParameters: {
            'mode': force ? 'cancel' : 'pause',
            'timeout_seconds': '60',
          },
        ),
      );
      await authorizeLocalGatewayRequest(request, runtime.sanadHome);
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

  Future<void> _writeCurrentComponentRecord() async {
    final activePorts = _clientProcessesByVmPort.keys.toSet();
    final retainedPids = <int>[];
    final retainedPorts = <int>[];
    for (var index = 0; index < _launcherRecord.clientPids.length; index++) {
      if (index >= _launcherRecord.vmServicePorts.length) continue;
      final port = _launcherRecord.vmServicePorts[index];
      if (!activePorts.contains(port)) continue;
      retainedPids.add(_launcherRecord.clientPids[index]);
      retainedPorts.add(port);
    }
    _launcherRecord = _launcherRecord.copyWith(
      clientPids: retainedPids,
      vmServicePorts: retainedPorts,
      status: _agent == null
          ? 'client-only'
          : retainedPorts.isEmpty
          ? 'agent-only'
          : 'running',
    );
    await writeRuntimeLauncherRecord(_launcherRecord);
  }

  Future<void> _performSwitch(RuntimeSwitchRequest request) async {
    if (_agent == null || (_client == null && _additionalClients.isEmpty)) {
      await writeRuntimeSwitchRequest(
        _manifestPath,
        request.copyWith(
          status: 'failed',
          message: 'Source switch requires a complete Agent/Client group.',
        ),
      );
      return;
    }
    if (request.launcherId != _launcherRecord.launcherId ||
        request.runtimeNonce != _launcherRecord.runtimeNonce ||
        request.agentPort != runtime.agentPort ||
        _samePath(
          _clientDirectory,
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
      runtime.agentPort,
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

    final previousAgentDirectory = _agentDirectory;
    final previousWorkspaceHash = _currentWorkspaceHash;
    _launcherRecord = _launcherRecord.copyWith(status: 'switching');
    await writeRuntimeLauncherRecord(_launcherRecord);
    await writeRuntimeSwitchRequest(
      _manifestPath,
      request.copyWith(
        status: 'draining',
        message: 'Waiting for safe restart.',
      ),
    );

    final accepted = await _requestSafeRestart(request);
    if (!accepted) {
      _launcherRecord = _launcherRecord.copyWith(status: 'running');
      await writeRuntimeLauncherRecord(_launcherRecord);
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
      _launcherRecord = _launcherRecord.copyWith(status: 'running');
      await writeRuntimeLauncherRecord(_launcherRecord);
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
      await _terminatePidTree(client.pid!);
    }
    _additionalClients.clear();
    if (_agent != null) await _terminateProcessTree(_agent!);
    await _cancelAgentOutput();

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
      await _startAgent(targetAgentDirectory);
      final agentHealthy = await _waitForAgentHash(
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
      _agentDirectory = targetAgentDirectory;
      _clientDirectory = targetClientDirectory;
      _currentWorkspaceHash = request.targetWorkspaceHash;
      final managedClientPids = await _managedClientPids(
        targetClients,
        workspaceHash: request.targetWorkspaceHash,
      );
      _launcherRecord = _launcherRecord.copyWith(
        workspaceHash: request.targetWorkspaceHash,
        sourceRoot: request.targetRepositoryRoot,
        clientPids: managedClientPids,
        vmServicePorts: targetClients
            .map((item) => item.vmServicePort)
            .toList(),
        status: 'running',
      );
      await writeRuntimeLauncherRecord(_launcherRecord);
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
      await _terminateCurrentClients();
      if (_agent != null) await _terminateProcessTree(_agent!);
      await _cancelAgentOutput();
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
        _launcherRecord = _launcherRecord.copyWith(
          workspaceHash: previousWorkspaceHash,
          sourceRoot: Directory(previousAgentDirectory).parent.path,
          clientPids: restoredClientPids,
          vmServicePorts: previousClients
              .map((item) => item.vmServicePort)
              .toList(),
          status: 'running',
        );
        await writeRuntimeLauncherRecord(_launcherRecord);
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
      if (!restored) _stopping = true;
    }
  }

  Future<bool> _restorePreviousGroup({
    required String agentDirectory,
    required List<_RuntimeClientLaunch> clients,
    required String workspaceHash,
  }) async {
    try {
      await _startAgent(agentDirectory);
      if (!await _waitForAgentHash(
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
      _agentDirectory = agentDirectory;
      _clientDirectory = clients.first.directory;
      _currentWorkspaceHash = workspaceHash;
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
          runtime.agentPort,
        ),
        expectedVmServicePorts: expectedVmServicePorts,
        launcherId: _launcherRecord.launcherId,
        runtimeNonce: _launcherRecord.runtimeNonce,
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
        Uri.parse('http://127.0.0.1:${runtime.agentPort}/restart').replace(
          queryParameters: const {'force': 'false', 'timeout_seconds': '60'},
        ),
      );
      await authorizeLocalGatewayRequest(request, runtime.sanadHome);
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

  Future<void> _startAgent(String directory) async {
    final process = await Process.start(
      'fvm',
      _agentArguments,
      workingDirectory: directory,
      environment: _agentEnvironment,
      runInShell: Platform.isWindows,
    );
    _agent = process;
    _agentJournal = await ComponentProcessJournal.attach(
      process: process,
      writer: ComponentJournalWriter(
        sanadHome: runtime.sanadHome,
        agentPort: runtime.agentPort,
        component: 'agent',
        launcherId: _launcherRecord.launcherId,
        runtimeNonce: _launcherRecord.runtimeNonce,
      ),
      mirrorStdout: true,
      mirrorStderr: true,
    );
  }

  Future<void> _startClients(List<_RuntimeClientLaunch> clients) async {
    _additionalClients.clear();
    _clientProcessesByVmPort.clear();
    for (final journal in _clientJournalsByVmPort.values) {
      await journal.cancel();
    }
    _clientJournalsByVmPort.clear();
    for (var index = 0; index < clients.length; index++) {
      final client = clients[index];
      final profile = extractClientLaunchProfile(client.arguments);
      final process = await Process.start(
        'fvm',
        client.arguments,
        workingDirectory: client.directory,
        environment: buildUnifiedSanadHomeEnvironment(
          Platform.environment,
          sanadHome: profile.define('SANAD_HOME') ?? runtime.sanadHome,
        ),
        runInShell: Platform.isWindows,
      );
      if (index == 0) {
        _client = process;
      } else {
        _additionalClients.add(process);
      }
      _clientProcessesByVmPort[client.vmServicePort] = process;
      _clientJournalsByVmPort[client.vmServicePort] =
          await ComponentProcessJournal.attach(
            process: process,
            writer: ComponentJournalWriter(
              sanadHome: runtime.sanadHome,
              agentPort: runtime.agentPort,
              component: 'client',
              vmServicePort: client.vmServicePort,
              launcherId: _launcherRecord.launcherId,
              runtimeNonce: _launcherRecord.runtimeNonce,
            ),
          );
    }
  }

  Future<bool> _waitForAgentUnavailable({required Duration timeout}) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (!await _agentHealthMatches(null)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    }
    return false;
  }

  Future<bool> _waitForAgentHash(
    String workspaceHash, {
    required Duration timeout,
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (await _agentHealthMatches(workspaceHash)) return true;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }
    return false;
  }

  Future<bool> _agentHealthMatches(String? workspaceHash) async {
    final client = HttpClient();
    try {
      final request = await client.getUrl(
        Uri.parse('http://127.0.0.1:${runtime.agentPort}/health'),
      );
      await authorizeLocalGatewayRequest(request, runtime.sanadHome);
      final response = await request.close().timeout(
        const Duration(milliseconds: 150),
      );
      final body = await response.transform(utf8.decoder).join();
      if (response.statusCode != HttpStatus.ok) return false;
      if (workspaceHash == null) return true;
      final decoded = jsonDecode(body);
      return decoded is Map && decoded['workspace_hash'] == workspaceHash;
    } on Object {
      return false;
    } finally {
      client.close(force: true);
    }
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

  Future<void> _stopCurrentPair() async {
    try {
      final client = HttpClient();
      final request = await client.postUrl(
        Uri.parse('http://127.0.0.1:${runtime.agentPort}/stop'),
      );
      await authorizeLocalGatewayRequest(request, runtime.sanadHome);
      final response = await request.close().timeout(
        const Duration(seconds: 2),
      );
      await response.drain<void>();
      client.close(force: true);
    } on Object {}
    await _terminateCurrentClients();
    if (_agent != null) await _terminateProcessTree(_agent!);
    await _cancelAgentOutput();
  }

  Future<void> _terminateCurrentClients() async {
    final processes = _clientProcessesByVmPort.values.toSet();
    for (final process in processes) {
      await _terminateProcessTree(process);
    }
    _clientProcessesByVmPort.clear();
    for (final journal in _clientJournalsByVmPort.values) {
      await journal.cancel();
    }
    _clientJournalsByVmPort.clear();
    _client = null;
    _additionalClients.clear();
  }

  Future<void> _cancelAgentOutput() async {
    await _agentJournal?.cancel();
    _agentJournal = null;
  }

  Future<void> _terminateProcessTree(Process process) async {
    await _terminatePidTree(process.pid);
    try {
      await process.exitCode.timeout(const Duration(seconds: 5));
    } on TimeoutException {}
  }

  Future<void> _terminatePidTree(int processId) =>
      terminateSanadDevProcessTree(processId);
}
