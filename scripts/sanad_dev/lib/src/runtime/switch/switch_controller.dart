part of '../../../sanad_dev_cli.dart';

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
    StreamSubscription<ProcessSignal>? sighup;
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
      void requestShutdown(ProcessSignal _) {
        if (!shutdown.isCompleted) {
          shutdown.complete(const _ShutdownRequested());
        }
      }

      sigterm = ProcessSignal.sigterm.watch().listen(requestShutdown);
      sighup = ProcessSignal.sighup.watch().listen(requestShutdown);
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
      await sighup?.cancel();
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
      final requestedSlot = request.clientInstanceSlot ?? '';
      final sameDeviceInstance = discovered.where(
        (client) =>
            _clientProcessesByVmPort.containsKey(client.port) &&
            client.deviceId == request.deviceId &&
            (client.launchProfile?.define(sanadDevClientInstanceSlotDefine) ??
                    '') ==
                requestedSlot,
      );
      if (sameDeviceInstance.isNotEmpty) return;
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
      final instancePrefix = sanadDevPreferencesPrefixForClientInstance(
        _launcherRecord.preferencesPrefix,
        requestedSlot,
      );
      final preferencesIndex = arguments.indexWhere(
        (argument) => argument.startsWith(
          '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=',
        ),
      );
      if (preferencesIndex >= 0) {
        arguments[preferencesIndex] =
            '--dart-define=SANAD_SHARED_PREFERENCES_PREFIX=$instancePrefix';
      }
      final slotIndex = arguments.indexWhere(
        (argument) => argument.startsWith(
          '--dart-define=$sanadDevClientInstanceSlotDefine=',
        ),
      );
      final slotArgument =
          '--dart-define=$sanadDevClientInstanceSlotDefine=$requestedSlot';
      if (slotIndex >= 0) {
        arguments[slotIndex] = slotArgument;
      } else {
        arguments.add(slotArgument);
      }
      applySanadDevWebPort(
        arguments,
        device: request.deviceId ?? _defaultDesktopDevice(),
        environment: _clientEnvironment,
      );
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

  Future<void> _performSwitch(RuntimeSwitchRequest request) =>
      _SwitchTransactionRunner(this).performSwitch(request);

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
