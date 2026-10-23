import 'dart:io';

import 'package:test/test.dart';

import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;
import 'package:sanad_dev/src/infrastructure/command_options.dart';
import 'package:sanad_dev/src/infrastructure/startup_attempt.dart';
import '../../support/sanad_dev_test_fixtures.dart';

/// `exitCode` is process-global under `package:test`, so a concurrently
/// running suite can set it at any moment. This suite therefore passes
/// an injected `setExitCode` callback to capture the exit status without
/// racing on or mutating the ambient process-global `exitCode`.
void main() {
  late Directory testHome;

  setUp(() {
    exitCode = 0;
    testHome = Directory.systemTemp.createTempSync('sanad-bg-test-');
  });

  tearDown(() {
    exitCode = 0;
    try {
      testHome.deleteSync(recursive: true);
    } catch (_) {}
  });

  test(
    'does not declare managed prematurely when attempt is managed but components are not yet ready',
    () async {
      final messages = <String>[];
      final errors = <String>[];
      final exitCodes = <int>[];
      var checkCount = 0;
      var attemptReadCount = 0;

      final attempt = SanadDevStartupAttempt(
        attemptId: 'attempt-new-1',
        workspaceHash: testWorkspaceHash,
        agentPort: 58092,
        requestedHome: 'worktree-default',
        resolvedHome: testHome.path,
        stage: SanadDevStartupStage.managed,
        outcome: SanadDevStartupOutcome.managed,
        updatedAt: DateTime.utc(2026, 9, 21),
      );

      await sanad_dev.handleBackgroundRun(
        originalArguments: const ['run', 'agent', '--background'],
        target: SanadDevComponentTarget.agent,
        device: 'macos',
        clientInstanceSlot: null,
        sanadHomePath: testHome.path,
        timeout: const Duration(seconds: 2),
        pollInterval: const Duration(milliseconds: 10),
        startChild: ({
          required executable,
          required arguments,
          required workingDirectory,
          required callerDirectory,
        }) async => 1234,
        readAttempt: ({
          required runtimeDirectory,
          required workspaceHash,
        }) async {
          attemptReadCount++;
          return attemptReadCount == 1 ? null : attempt;
        },
        componentsManagedChecker: ({
          required runtime,
          required target,
          required device,
          required clientInstanceSlot,
        }) async {
          checkCount++;
          return checkCount >= 3;
        },
        processRunning: (pid) async => true,
        printMessage: messages.add,
        printError: errors.add,
        setExitCode: exitCodes.add,
      );

      expect(checkCount, greaterThanOrEqualTo(3));
      expect(
        messages,
        contains(
          '✓ Background runtime is managed. '
          'Use "sanad-dev status" or bounded "sanad-dev logs" commands.',
        ),
      );
      expect(errors, isEmpty);
      expect(exitCodes, isEmpty);
    },
  );

  test(
    'does not declare managed if the child launcher process died even if attempt says managed',
    () async {
      final messages = <String>[];
      final errors = <String>[];
      final exitCodes = <int>[];
      var attemptReadCount = 0;

      final attempt = SanadDevStartupAttempt(
        attemptId: 'attempt-crashed-1',
        workspaceHash: testWorkspaceHash,
        agentPort: 58092,
        requestedHome: 'worktree-default',
        resolvedHome: testHome.path,
        stage: SanadDevStartupStage.managed,
        outcome: SanadDevStartupOutcome.managed,
        updatedAt: DateTime.utc(2026, 9, 21),
      );

      await sanad_dev.handleBackgroundRun(
        originalArguments: const ['run', 'agent', '--background'],
        target: SanadDevComponentTarget.agent,
        device: 'macos',
        clientInstanceSlot: null,
        sanadHomePath: testHome.path,
        timeout: const Duration(milliseconds: 200),
        pollInterval: const Duration(milliseconds: 10),
        publicationGrace: const Duration(milliseconds: 20),
        startChild: ({
          required executable,
          required arguments,
          required workingDirectory,
          required callerDirectory,
        }) async => 1234,
        readAttempt: ({
          required runtimeDirectory,
          required workspaceHash,
        }) async {
          attemptReadCount++;
          return attemptReadCount == 1 ? null : attempt;
        },
        componentsManagedChecker: ({
          required runtime,
          required target,
          required device,
          required clientInstanceSlot,
        }) async => true,
        processRunning: (pid) async => false,
        printMessage: messages.add,
        printError: errors.add,
        setExitCode: exitCodes.add,
      );

      expect(
        messages.any((m) => m.contains('✓ Background runtime is managed')),
        isFalse,
      );
      expect(
        errors,
        contains(
          'Background launcher exited before publishing a managed or failed '
          'startup result. Run "sanad-dev status" for diagnostics.',
        ),
      );
      expect(exitCodes, [1]);
    },
  );

  test(
    'succeeds when child launcher is alive and components are verified managed',
    () async {
      final messages = <String>[];
      final errors = <String>[];
      final exitCodes = <int>[];
      var attemptReadCount = 0;

      final attempt = SanadDevStartupAttempt(
        attemptId: 'attempt-success-1',
        workspaceHash: testWorkspaceHash,
        agentPort: 58092,
        requestedHome: 'worktree-default',
        resolvedHome: testHome.path,
        stage: SanadDevStartupStage.managed,
        outcome: SanadDevStartupOutcome.managed,
        updatedAt: DateTime.utc(2026, 9, 21),
      );

      await sanad_dev.handleBackgroundRun(
        originalArguments: const ['run', 'agent', '--background'],
        target: SanadDevComponentTarget.agent,
        device: 'macos',
        clientInstanceSlot: null,
        sanadHomePath: testHome.path,
        timeout: const Duration(seconds: 1),
        pollInterval: const Duration(milliseconds: 10),
        startChild: ({
          required executable,
          required arguments,
          required workingDirectory,
          required callerDirectory,
        }) async => 5678,
        readAttempt: ({
          required runtimeDirectory,
          required workspaceHash,
        }) async {
          attemptReadCount++;
          return attemptReadCount == 1 ? null : attempt;
        },
        componentsManagedChecker: ({
          required runtime,
          required target,
          required device,
          required clientInstanceSlot,
        }) async => true,
        processRunning: (pid) async => true,
        printMessage: messages.add,
        printError: errors.add,
        setExitCode: exitCodes.add,
      );

      expect(
        messages,
        contains(
          '✓ Background runtime is managed. '
          'Use "sanad-dev status" or bounded "sanad-dev logs" commands.',
        ),
      );
      expect(errors, isEmpty);
      expect(exitCodes, isEmpty);
    },
  );

  test(
    'propagates failed startup attempt immediately without declaring managed',
    () async {
      final messages = <String>[];
      final errors = <String>[];
      final exitCodes = <int>[];
      var attemptReadCount = 0;

      final attempt = SanadDevStartupAttempt(
        attemptId: 'attempt-failed-1',
        workspaceHash: testWorkspaceHash,
        agentPort: 58092,
        requestedHome: 'worktree-default',
        resolvedHome: testHome.path,
        stage: SanadDevStartupStage.readiness,
        outcome: SanadDevStartupOutcome.failed,
        failureReason: 'agent readiness probe failed',
        exitStatus: 64,
        updatedAt: DateTime.utc(2026, 9, 21),
      );

      await sanad_dev.handleBackgroundRun(
        originalArguments: const ['run', 'agent', '--background'],
        target: SanadDevComponentTarget.agent,
        device: 'macos',
        clientInstanceSlot: null,
        sanadHomePath: testHome.path,
        timeout: const Duration(seconds: 1),
        pollInterval: const Duration(milliseconds: 10),
        startChild: ({
          required executable,
          required arguments,
          required workingDirectory,
          required callerDirectory,
        }) async => 5678,
        readAttempt: ({
          required runtimeDirectory,
          required workspaceHash,
        }) async {
          attemptReadCount++;
          return attemptReadCount == 1 ? null : attempt;
        },
        componentsManagedChecker: ({
          required runtime,
          required target,
          required device,
          required clientInstanceSlot,
        }) async => false,
        processRunning: (pid) async => true,
        printMessage: messages.add,
        printError: errors.add,
        setExitCode: exitCodes.add,
      );

      expect(
        messages.any((m) => m.contains('✓ Background runtime is managed')),
        isFalse,
      );
      expect(
        errors,
        contains(
          'Background startup failed at readiness: '
          'agent readiness probe failed (exit 64).',
        ),
      );
      expect(exitCodes, [64]);
    },
  );

  test(
    'idempotent run succeeds when components are already managed without new attempt',
    () async {
      final messages = <String>[];
      final errors = <String>[];
      final exitCodes = <int>[];

      final oldAttempt = SanadDevStartupAttempt(
        attemptId: 'attempt-old',
        workspaceHash: testWorkspaceHash,
        agentPort: 58092,
        requestedHome: 'worktree-default',
        resolvedHome: testHome.path,
        stage: SanadDevStartupStage.managed,
        outcome: SanadDevStartupOutcome.managed,
        updatedAt: DateTime.utc(2026, 9, 20),
      );

      await sanad_dev.handleBackgroundRun(
        originalArguments: const ['run', 'agent', '--background'],
        target: SanadDevComponentTarget.agent,
        device: 'macos',
        clientInstanceSlot: null,
        sanadHomePath: testHome.path,
        timeout: const Duration(seconds: 1),
        pollInterval: const Duration(milliseconds: 10),
        startChild: ({
          required executable,
          required arguments,
          required workingDirectory,
          required callerDirectory,
        }) async => 9999,
        readAttempt: ({
          required runtimeDirectory,
          required workspaceHash,
        }) async => oldAttempt,
        componentsManagedChecker: ({
          required runtime,
          required target,
          required device,
          required clientInstanceSlot,
        }) async => true,
        processRunning: (pid) async => true,
        printMessage: messages.add,
        printError: errors.add,
        setExitCode: exitCodes.add,
      );

      expect(
        messages,
        contains(
          '✓ Background runtime is managed. '
          'Use "sanad-dev status" or bounded "sanad-dev logs" commands.',
        ),
      );
      expect(exitCodes, isEmpty);
    },
  );
}
