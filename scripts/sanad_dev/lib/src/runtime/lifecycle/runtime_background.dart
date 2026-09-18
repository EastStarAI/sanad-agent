part of '../../../sanad_dev_cli.dart';

Future<void> handleBackgroundRun({
  required List<String> originalArguments,
  required SanadDevComponentTarget target,
  required String device,
  required String? clientInstanceSlot,
  required String? sanadHomePath,
  Duration timeout = sanadDevComponentControlTimeout,
  Duration pollInterval = const Duration(milliseconds: 100),
}) async {
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final workspaceHash = runtime.worktreeId.split('-').last;
  String? previousAttemptId;
  try {
    previousAttemptId = (await readLocatedSanadDevStartupAttempt(
      runtimeDirectory: runtime.runtimeDirectory,
      workspaceHash: workspaceHash,
    ))?.attemptId;
  } on Object {
    // A stale diagnostic cannot block a new launch attempt.
  }

  final childArguments = sanadDevBackgroundChildArguments(
    Platform.script.toFilePath(),
    originalArguments,
  );
  final process = await Process.start(
    Platform.resolvedExecutable,
    childArguments,
    workingDirectory: Directory.current.path,
    environment: {
      ...Platform.environment,
      'SANAD_DEV_CALLER_DIR': _callerDirectory,
    },
    mode: ProcessStartMode.detached,
  );
  print(
    'Starting ${target.name} in the background for ${runtime.worktreeId}...',
  );

  final deadline = DateTime.now().add(timeout);
  DateTime? childExitedAt;
  while (DateTime.now().isBefore(deadline)) {
    SanadDevStartupAttempt? attempt;
    try {
      attempt = await readLocatedSanadDevStartupAttempt(
        runtimeDirectory: runtime.runtimeDirectory,
        workspaceHash: workspaceHash,
      );
    } on Object {
      // The child may be atomically replacing the locator.
    }
    if (attempt != null && attempt.attemptId != previousAttemptId) {
      if (attempt.outcome == SanadDevStartupOutcome.managed) {
        print(
          '✓ Background runtime is managed. '
          'Use "sanad-dev status" or bounded "sanad-dev logs" commands.',
        );
        return;
      }
      if (attempt.outcome == SanadDevStartupOutcome.failed) {
        stderr.writeln(
          'Background startup failed at ${attempt.stage.name}: '
          '${attempt.failureReason ?? 'unknown failure'} '
          '(exit ${attempt.exitStatus ?? 1}).',
        );
        exitCode = attempt.exitStatus ?? 1;
        return;
      }
    }

    if (await _backgroundRequestedComponentsAreManaged(
      runtime: runtime,
      target: target,
      device: device,
      clientInstanceSlot: clientInstanceSlot,
    )) {
      print(
        '✓ Requested background components are managed. '
        'Use "sanad-dev status" or bounded "sanad-dev logs" commands.',
      );
      return;
    }
    if (!await isProcessRunning(process.pid)) {
      childExitedAt ??= DateTime.now();
      if (!isSanadDevBackgroundPublicationGraceActive(childExitedAt)) {
        stderr.writeln(
          'Background launcher exited before publishing a managed or failed '
          'startup result. Run "sanad-dev status" for diagnostics.',
        );
        exitCode = 1;
        return;
      }
    } else {
      childExitedAt = null;
    }
    await Future<void>.delayed(pollInterval);
  }
  stderr.writeln(
    'Background startup did not reach a terminal state within '
    '${timeout.inSeconds} seconds. Run "sanad-dev status" for diagnostics.',
  );
  exitCode = 1;
}

Future<bool> _backgroundRequestedComponentsAreManaged({
  required SanadDevRuntime runtime,
  required SanadDevComponentTarget target,
  required String device,
  required String? clientInstanceSlot,
}) async {
  final state = selectRuntimeProcessState(
    activeAgents: await discoverAgentInstances(
      sanadHomeOverride: runtime.sanadHome,
    ),
    activeClients: await discoverClientInstances(),
    runtime: runtime,
  );
  if (state.agent == null && state.relevantClients.isEmpty) return false;
  final ownership = await assessRuntimeOwnership(
    runtime: runtime,
    state: state,
    sanadHome: resolveActiveSanadHome(runtime, state),
  );
  if (!ownership.isManaged) return false;
  final agentReady =
      target == SanadDevComponentTarget.client || ownership.state.agent != null;
  final clientReady =
      target == SanadDevComponentTarget.agent ||
      ownership.state.ownedClients.any(
        (client) =>
            client.deviceId == device &&
            (client.launchProfile?.define(sanadDevClientInstanceSlotDefine) ??
                    '') ==
                (clientInstanceSlot ?? ''),
      );
  return agentReady && clientReady;
}
