part of '../../../sanad_dev_cli.dart';

typedef BackgroundChildStarter =
    Future<int> Function({
      required String executable,
      required List<String> arguments,
      required String workingDirectory,
      required String callerDirectory,
    });

typedef StartupAttemptLocatorReader =
    Future<SanadDevStartupAttempt?> Function({
      required String runtimeDirectory,
      required String workspaceHash,
    });

typedef BackgroundComponentsManagedChecker =
    Future<bool> Function({
      required SanadDevRuntime runtime,
      required SanadDevComponentTarget target,
      required String device,
      required String? clientInstanceSlot,
    });

Future<void> handleBackgroundRun({
  required List<String> originalArguments,
  required SanadDevComponentTarget target,
  required String device,
  required String? clientInstanceSlot,
  required String? sanadHomePath,
  Duration timeout = sanadDevComponentControlTimeout,
  Duration pollInterval = const Duration(milliseconds: 100),
  Duration publicationGrace = const Duration(seconds: 2),
  BackgroundChildStarter startChild = startSanadDevBackgroundChild,
  StartupAttemptLocatorReader readAttempt = readLocatedSanadDevStartupAttempt,
  BackgroundComponentsManagedChecker componentsManagedChecker =
      _backgroundRequestedComponentsAreManaged,
  Future<bool> Function(int? pid) processRunning = isProcessRunning,
  void Function(String message)? printMessage,
  void Function(String message)? printError,
}) async {
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: _callerDirectory,
    sanadHomeOverride: sanadHomePath,
  );
  final workspaceHash = runtime.worktreeId.split('-').last;
  String? previousAttemptId;
  try {
    previousAttemptId = (await readAttempt(
      runtimeDirectory: runtime.runtimeDirectory,
      workspaceHash: workspaceHash,
    ))?.attemptId;
  } on Object {
    // A stale diagnostic cannot block a new launch attempt.
  }

  void log(String message) => (printMessage ?? print)(message);
  void logError(String message) => (printError ?? stderr.writeln)(message);

  final scriptPath = Platform.script.toFilePath();
  final childArguments = sanadDevBackgroundChildArguments(
    scriptPath,
    originalArguments,
    nativeExecutable: sanadDevUsesNativeRuntimeExecutable(
      executablePath: Platform.resolvedExecutable,
      scriptPath: scriptPath,
    ),
  );
  final childPid = await startChild(
    executable: Platform.resolvedExecutable,
    arguments: childArguments,
    workingDirectory: Directory.current.path,
    callerDirectory: _callerDirectory,
  );
  log('Starting ${target.name} in the background for ${runtime.worktreeId}...');

  final deadline = DateTime.now().add(timeout);
  DateTime? childExitedAt;
  while (DateTime.now().isBefore(deadline)) {
    SanadDevStartupAttempt? attempt;
    try {
      attempt = await readAttempt(
        runtimeDirectory: runtime.runtimeDirectory,
        workspaceHash: workspaceHash,
      );
    } on Object {
      // The child may be atomically replacing the locator.
    }
    if (attempt != null && attempt.attemptId != previousAttemptId) {
      if (attempt.outcome == SanadDevStartupOutcome.failed) {
        logError(
          'Background startup failed at ${attempt.stage.name}: '
          '${attempt.failureReason ?? 'unknown failure'} '
          '(exit ${attempt.exitStatus ?? 1}).',
        );
        exitCode = attempt.exitStatus ?? 1;
        return;
      }
    }

    final componentsManaged = await componentsManagedChecker(
      runtime: runtime,
      target: target,
      device: device,
      clientInstanceSlot: clientInstanceSlot,
    );
    if (componentsManaged) {
      final childRunning = await processRunning(childPid);
      final isNewAttempt =
          attempt != null && attempt.attemptId != previousAttemptId;
      if (!isNewAttempt || childRunning) {
        log(
          '✓ Background runtime is managed. '
          'Use "sanad-dev status" or bounded "sanad-dev logs" commands.',
        );
        return;
      }
    }

    if (!await processRunning(childPid)) {
      childExitedAt ??= DateTime.now();
      if (!isSanadDevBackgroundPublicationGraceActive(
        childExitedAt,
        grace: publicationGrace,
      )) {
        logError(
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
  logError(
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
