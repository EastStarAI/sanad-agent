part of '../../sanad_dev_cli.dart';

Future<void> _sendManagedClientDeveloperKey({
  required String sanadHome,
  required int agentPort,
  required int vmServicePort,
  required String key,
}) async {
  final record = await _readRuntimeLauncherRecordSafely(sanadHome, agentPort);
  if (record == null || !record.vmServicePorts.contains(vmServicePort)) {
    stderr.writeln('Client command refused: managed ownership is unavailable.');
    return;
  }
  final action = runtimeClientActionForInteractiveKey(key);
  if (action == null) return;
  print('\n[sanad-dev] Client ${action.name} requested.');
  final succeeded = await requestManagedComponentAction(
    record,
    action: action,
    target: RuntimeComponentTarget.client,
    vmServicePort: vmServicePort,
    openClientTerminal: false,
    timeout: const Duration(seconds: 10),
  );
  if (!succeeded) exitCode = 1;
}

Future<void> handleClientDeveloperAction(
  String action,
  int? portOverride, {
  String? sanadHomePath,
}) async {
  final instance = await selectClientInstance(
    portOverride,
    sanadHomePath: sanadHomePath,
  );
  if (instance == null) exit(1);

  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final expectedClientDirectory =
      '${runtime.repositoryRoot}${Platform.pathSeparator}client';
  if (!_samePath(instance.path, expectedClientDirectory)) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: the selected '
      'VM service does not belong to ${runtime.worktreeId}.',
    );
    exitCode = 1;
    return;
  }

  final discoveredProfile = instance.launchProfile;
  if (discoveredProfile == null) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: the running '
      'client launch profile could not be discovered.',
    );
    exitCode = 1;
    return;
  }
  final activeAgents = await discoverAgentInstances(
    sanadHomeOverride: sanadHomePath,
  );
  final activeClients = await discoverClientInstances();
  final processState = selectRuntimeProcessState(
    activeAgents: activeAgents,
    activeClients: activeClients,
    runtime: runtime,
  );
  final matchingAgent = processState.agent;
  if (matchingAgent == null || processState.agentAmbiguous) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: expected one '
      'verifiable running agent for ${runtime.worktreeId}.',
    );
    exitCode = 1;
    return;
  }
  final primarySanadHome = resolveDefaultUserSanadHome(Platform.environment);
  final profile = withImplicitPrimaryClientDefaults(
    discoveredProfile,
    allowed:
        !runtime.isLinkedWorktree &&
        matchingAgent.port == canonicalPrimaryAgentPort &&
        _samePath(runtime.sanadHome, primarySanadHome),
    primarySanadHome: primarySanadHome,
  );
  final profileError = validateClientLaunchProfile(
    profile,
    isLinkedWorktree: runtime.isLinkedWorktree,
    expectedWorktreeName: runtime.worktreeDisplayName,
    expectedBranch: runtime.branch,
    expectedAgentPort: matchingAgent.port,
    emptyPreferencesSanadHome: runtime.isLinkedWorktree
        ? resolveDefaultUserSanadHome(Platform.environment)
        : runtime.sanadHome,
    derivePreferencesPrefix: deriveSanadDevPreferencesPrefix,
  );
  if (profileError != null) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: $profileError.',
    );
    exitCode = 1;
    return;
  }
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: processState,
    sanadHome: profile.define('SANAD_HOME'),
  );
  final selectedClientIsManaged =
      ownership.isManaged &&
      ownership.state.ownedClients.any(
        (client) => client.port == instance.port && client.pid == instance.pid,
      );
  if (!selectedClientIsManaged) {
    stderr.writeln(
      'Client ${action == 'R' ? 'restart' : 'reload'} aborted: the selected '
      'client is ${ownership.isManaged ? 'unmanaged' : ownership.classification.name}, not owned by the live '
      'sanad-dev launcher.',
    );
    exitCode = 1;
    return;
  }

  final componentAction = runtimeClientActionForInteractiveKey(action);
  if (componentAction == null) {
    stderr.writeln('Unsupported Client developer action.');
    exitCode = 1;
    return;
  }
  print(
    'Requesting managed Client ${componentAction.name} on VM ${instance.port}...',
  );
  final succeeded = await requestManagedComponentAction(
    ownership.record!,
    action: componentAction,
    target: RuntimeComponentTarget.client,
    clientPid: instance.pid,
    vmServicePort: instance.port,
    openClientTerminal: false,
  );
  if (!succeeded) exitCode = 1;
}

Future<void> handleClientDevTools(int? portOverride) async {
  final instance = await selectClientInstance(portOverride);
  if (instance == null) exit(1);

  final vmUrl = instance.token.isEmpty
      ? 'http://127.0.0.1:${instance.port}'
      : 'http://127.0.0.1:${instance.port}/${instance.token}';

  print('Opening Flutter DevTools for client on port ${instance.port}...');
  print('VM Service URL: $vmUrl');

  if (Platform.isMacOS) {
    try {
      final pbcopy = await Process.start('pbcopy', []);
      pbcopy.stdin.write(vmUrl);
      await pbcopy.stdin.close();
      print('📋 VM Service URL copied to clipboard!');
    } catch (_) {}
  }

  print('\n💡 Tip: To attach VS Code debugger to this running instance:');
  print('   1. Open the Run & Debug panel in VS Code.');
  print('   2. Select "Attach to Running Client" and click play.');
  print('   3. Paste the copied URL and press Enter.\n');

  final process = await Process.start(
    'fvm',
    ['dart', 'devtools', vmUrl],
    runInShell: Platform.isWindows,
    mode: ProcessStartMode.inheritStdio,
  );

  final exitCode = await process.exitCode;
  exit(exitCode);
}
