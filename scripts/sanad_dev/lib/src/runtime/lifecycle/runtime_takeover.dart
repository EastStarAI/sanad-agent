part of '../../../sanad_dev_cli.dart';

Future<void> handleRuntimeTakeover({
  String? sanadHomePath,
  ProcessTerminator terminateProcess = Process.killPid,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  if (Platform.environment['SANAD_REQUESTER_SESSION_ID']?.isNotEmpty == true ||
      Platform.environment['SANAD_REQUESTER_TOOL_CALL_ID']?.isNotEmpty ==
          true) {
    stderr.writeln(
      'Takeover refused from an active Agent tool call. Run it directly in a '
      'human-owned terminal after reviewing "sanad-dev doctor".',
    );
    exitCode = 1;
    return;
  }
  final runtime = await _currentRuntime(sanadHomePath: sanadHomePath);
  final agents = await discoverAgentInstances(sanadHomeOverride: sanadHomePath);
  final clients = await discoverClientInstances();
  final state = selectRuntimeProcessState(
    activeAgents: agents,
    activeClients: clients,
    runtime: runtime,
  );
  final activeHome = resolveActiveSanadHome(runtime, state);
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: state,
    sanadHome: activeHome,
    processRunning: processRunning,
  );
  if (ownership.classification != RuntimeOwnershipClass.manual ||
      state.agent == null ||
      state.ownedClients.length != 1) {
    stderr.writeln(
      'Takeover refused: expected one complete manual Agent/client pair, found '
      '${ownership.classification.name} with ${state.ownedClients.length} '
      'owned client(s).',
    );
    exitCode = 1;
    return;
  }

  final client = state.ownedClients.single;
  final profile = client.launchProfile!;
  final configArgument = profile.compileArguments.firstWhere(
    (argument) => argument.startsWith('--dart-define-from-file='),
    orElse: () => '',
  );
  if (client.pid == null || configArgument.isEmpty) {
    stderr.writeln(
      'Takeover refused: the manual client PID or config launch argument is '
      'not discoverable.',
    );
    exitCode = 1;
    return;
  }
  final configPath = configArgument.substring(
    '--dart-define-from-file='.length,
  );
  final cloudEnabled =
      profile.define('ENABLE_CLOUD_GATEWAY')?.toLowerCase() != 'false';
  final driverMode = profile.target?.endsWith('driver_main.dart') == true;
  final homeSelector =
      !runtime.isLinkedWorktree &&
          _samePath(
            activeHome,
            resolveDefaultUserSanadHome(Platform.environment),
          )
      ? 'user'
      : activeHome;

  print(
    'Draining manual Agent ${state.agent!.port} before controlled takeover...',
  );
  if (!await _requestTakeoverRestart(state.agent!.port, activeHome)) {
    stderr.writeln(
      'Takeover aborted: the manual Agent rejected safe restart; the client '
      'was not signaled.',
    );
    exitCode = 1;
    return;
  }
  if (!await _waitForAgentPortToStop(state.agent!.port, activeHome)) {
    stderr.writeln(
      'Takeover aborted: the drained Agent did not exit; the client was not '
      'signaled.',
    );
    exitCode = 1;
    return;
  }
  if (!terminateProcess(client.pid!, ProcessSignal.sigterm)) {
    final restored = await _restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: profile,
      cloudEnabled: cloudEnabled,
      restoreClient: false,
    );
    stderr.writeln(
      'Takeover failed: the manual client could not be stopped after the safe '
      'Agent drain. Previous Agent restoration: '
      '${restored ? 'complete' : 'failed'}.',
    );
    exitCode = 1;
    return;
  }
  final deadline = DateTime.now().add(const Duration(seconds: 10));
  while (await processRunning(client.pid) &&
      DateTime.now().isBefore(deadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (await processRunning(client.pid)) {
    final restored = await _restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: profile,
      cloudEnabled: cloudEnabled,
      restoreClient: false,
    );
    stderr.writeln(
      'Takeover failed: the manual client did not exit; managed relaunch was '
      'not attempted. Previous Agent restoration: '
      '${restored ? 'complete' : 'failed'}.',
    );
    exitCode = 1;
    return;
  }
  final vmDeadline = DateTime.now().add(const Duration(seconds: 10));
  while (await _vmServiceIsAvailable(client.port) &&
      DateTime.now().isBefore(vmDeadline)) {
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  if (await _vmServiceIsAvailable(client.port)) {
    final restored = await _restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: profile,
      cloudEnabled: cloudEnabled,
      restoreClient: false,
    );
    stderr.writeln(
      'Takeover failed: the manual VM service remained active. Previous Agent '
      'restoration: ${restored ? 'complete' : 'failed'}.',
    );
    exitCode = 1;
    return;
  }

  print('Manual pair drained; relaunching under one sanad-dev lease.');
  await handleRun(
    target: SanadDevComponentTarget.all,
    driverMode: driverMode,
    cloudEnabled: cloudEnabled,
    dryRun: false,
    device: client.deviceId ?? profile.deviceId ?? _defaultDesktopDevice(),
    configPath: configPath,
    clientInstanceSlot: profile.define(sanadDevClientInstanceSlotDefine),
    sanadHomePath: homeSelector,
  );
  if (exitCode != 0) {
    final restored = await _restoreManualRuntime(
      runtime: runtime,
      agentPort: state.agent!.port,
      sanadHome: activeHome,
      client: client,
      profile: profile,
      cloudEnabled: cloudEnabled,
      restoreClient: true,
    );
    stderr.writeln(
      'Managed takeover launch failed. Previous manual pair restoration: '
      '${restored ? 'complete' : 'failed'}.',
    );
  }
}

Future<bool> _restoreManualRuntime({
  required SanadDevRuntime runtime,
  required int agentPort,
  required String sanadHome,
  required ClientInstance client,
  required ClientLaunchProfile profile,
  required bool cloudEnabled,
  required bool restoreClient,
}) async {
  try {
    final agentEnvironment =
        buildUnifiedSanadHomeEnvironment(
            Platform.environment,
            sanadHome: sanadHome,
          )
          ..remove('SANAD_DEV_LAUNCHER_ID')
          ..remove('SANAD_DEV_RUNTIME_NONCE')
          ..['ENABLE_LOCAL_GATEWAY'] = 'true'
          ..['LOCAL_GATEWAY_PORT'] = '$agentPort'
          ..['ENABLE_GATEWAY'] = cloudEnabled ? 'true' : 'false';
    final agent = await Process.start(
      'fvm',
      const ['dart', 'run', 'bin/sanad_agent.dart', 'daemon'],
      workingDirectory:
          '${runtime.repositoryRoot}${Platform.pathSeparator}agent',
      environment: agentEnvironment,
      runInShell: Platform.isWindows,
    );
    unawaited(agent.stdout.drain<void>());
    unawaited(agent.stderr.drain<void>());
    if (!await _waitForAgentHealthPort(
      agentPort,
      runtime.worktreeId.split('-').last,
      runtime.sanadHome,
    )) {
      return false;
    }
    if (restoreClient && !await _vmServiceIsAvailable(client.port)) {
      final arguments = [
        'flutter',
        'run',
        '-d',
        client.deviceId ?? profile.deviceId ?? _defaultDesktopDevice(),
        ...profile.compileArguments,
        '--host-vmservice-port=${client.port}',
        '--disable-service-auth-codes',
        if (profile.target?.isNotEmpty == true) ...['-t', profile.target!],
      ];
      final restoredClient = await Process.start(
        'fvm',
        arguments,
        workingDirectory:
            '${runtime.repositoryRoot}${Platform.pathSeparator}client',
        environment: buildUnifiedSanadHomeEnvironment(
          Platform.environment,
          sanadHome: sanadHome,
        ),
        mode: ProcessStartMode.inheritStdio,
        runInShell: Platform.isWindows,
      );
      unawaited(restoredClient.exitCode);
      final deadline = DateTime.now().add(sanadDevClientStartupTimeout);
      while (DateTime.now().isBefore(deadline)) {
        if (await _vmServiceIsAvailable(client.port)) return true;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return false;
    }
    return true;
  } on Object {
    return false;
  }
}

Future<bool> _requestTakeoverRestart(int port, String sanadHome) async {
  final client = HttpClient();
  try {
    final request = await client.postUrl(
      Uri.parse('http://127.0.0.1:$port/restart').replace(
        queryParameters: const {
          'force': 'false',
          'permanent': 'true',
          'timeout_seconds': '60',
        },
      ),
    );
    await authorizeLocalGatewayRequest(request, sanadHome);
    final response = await request.close().timeout(const Duration(seconds: 65));
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
