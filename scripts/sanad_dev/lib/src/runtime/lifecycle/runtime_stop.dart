part of '../../../sanad_dev_cli.dart';

typedef ProcessTerminator = bool Function(int pid, ProcessSignal signal);
typedef LauncherStopRequester =
    Future<void> Function(RuntimeLauncherRecord record);

Future<bool> stopManagedRuntimeLauncher(
  RuntimeOwnershipAssessment ownership, {
  LauncherStopRequester requestStop = writeRuntimeLauncherStopRequest,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  Duration timeout = const Duration(seconds: 15),
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final record = ownership.record;
  if (!ownership.isManaged || record == null) return false;
  try {
    await requestStop(record);
  } on Object {
    return false;
  }
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    if (!await processRunning(record.launcherPid)) return true;
    await Future<void>.delayed(pollInterval);
  }
  return false;
}

RuntimeComponentTarget _componentControlTarget(
  SanadDevComponentTarget target,
) => switch (target) {
  SanadDevComponentTarget.all => RuntimeComponentTarget.all,
  SanadDevComponentTarget.agent => RuntimeComponentTarget.agent,
  SanadDevComponentTarget.client => RuntimeComponentTarget.client,
};

Future<bool> requestManagedComponentAction(
  RuntimeLauncherRecord record, {
  required RuntimeComponentAction action,
  required RuntimeComponentTarget target,
  String? deviceId,
  String? clientInstanceSlot,
  int? clientPid,
  int? vmServicePort,
  bool force = false,
  bool openClientTerminal = true,
  Duration timeout = sanadDevComponentControlTimeout,
}) async {
  final path = runtimeComponentControlPath(record.sanadHome, record.agentPort);
  final existing = await readRuntimeComponentControl(path);
  if (existing != null && !existing.isTerminal) {
    stderr.writeln('Another runtime component action is already pending.');
    return false;
  }
  final request = RuntimeComponentControlRequest(
    requestId: _newRuntimeOwnershipToken(),
    launcherId: record.launcherId,
    runtimeNonce: record.runtimeNonce,
    action: action,
    target: target,
    status: 'requested',
    requestedAt: DateTime.now().toUtc(),
    deviceId: deviceId,
    clientInstanceSlot: clientInstanceSlot,
    clientPid: clientPid,
    vmServicePort: vmServicePort,
    force: force,
    openClientTerminal: openClientTerminal,
  );
  await writeRuntimeComponentControl(path, request);
  final deadline = DateTime.now().add(timeout);
  while (DateTime.now().isBefore(deadline)) {
    final result = await readRuntimeComponentControl(path);
    if (result?.requestId == request.requestId && result!.isTerminal) {
      final succeeded = result.status == 'complete';
      if (!succeeded) {
        stderr.writeln(result.message ?? 'Runtime component action failed.');
      }
      final file = File(path);
      if (await file.exists()) await file.delete();
      return succeeded;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  final pending = await readRuntimeComponentControl(path);
  if (pending?.requestId == request.requestId && !pending!.isTerminal) {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }
  stderr.writeln('Runtime component action timed out.');
  return false;
}

Future<void> handleRuntimeStop({
  SanadDevComponentTarget target = SanadDevComponentTarget.all,
  String? device,
  int? vmServicePort,
  bool force = false,
  String? sanadHomePath,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
}) async {
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final processState = selectRuntimeProcessState(
    activeAgents: await discoverAgentInstances(
      sanadHomeOverride: sanadHomePath,
    ),
    activeClients: await discoverClientInstances(),
    runtime: runtime,
    requestedAgentPort: target == SanadDevComponentTarget.agent
        ? vmServicePort
        : null,
  );

  if (processState.agent == null &&
      processState.relevantClients.isEmpty &&
      !processState.agentAmbiguous) {
    print(noActiveRuntimeMessage(runtime));
    return;
  }
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: processState,
    sanadHome: resolveActiveSanadHome(runtime, processState),
    processRunning: processRunning,
  );
  if (!ownership.isManaged) {
    stderr.writeln(
      'Refusing to stop ${runtime.worktreeId}: runtime class is '
      '${ownership.classification.name} '
      '(${ownership.reason ?? 'launcher ownership is not proven'}). '
      'Run "sanad-dev doctor" for a safe next action.',
    );
    exitCode = 1;
    return;
  }
  ClientInstance? selectedClient;
  if (target == SanadDevComponentTarget.client) {
    final selection = selectClientByDevice(
      clients: ownership.state.ownedClients,
      deviceId: device,
      vmServicePort: vmServicePort,
    );
    if (selection.kind != ClientSelectionKind.exact) {
      stderr.writeln(
        selection.kind == ClientSelectionKind.missing
            ? 'No owned Client matches the requested device/VM selector.'
            : 'Client selector is ambiguous; add -p <vm-port>.',
      );
      for (final client
          in selection.matches.isEmpty
              ? ownership.state.ownedClients
              : selection.matches) {
        stderr.writeln('  - ${runtimeClientSummary(client)}');
      }
      exitCode = 1;
      return;
    }
    selectedClient = selection.selected;
  }
  final stopped = await requestManagedComponentAction(
    ownership.record!,
    action: RuntimeComponentAction.stop,
    target: _componentControlTarget(target),
    deviceId: selectedClient?.deviceId,
    clientPid: selectedClient?.pid,
    vmServicePort: selectedClient?.port,
    force: force,
  );
  if (!stopped) {
    exitCode = 1;
    return;
  }
  print('Stopped ${target.name} for ${runtime.worktreeId}.');
}
