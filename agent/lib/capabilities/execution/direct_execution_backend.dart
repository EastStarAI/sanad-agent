import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/execution_mode.dart';
import 'package:sanad_agent/capabilities/permissions/process_environment_policy.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/capabilities/tools/system/process_tree_controller.dart';
import 'package:sanad_agent/capabilities/tools/tool_execution_outcome.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';
import 'package:sanad_windows_path/windows_path.dart';

import 'execution_backend.dart';
import 'windows_shell_wrapper.dart';

/// Direct Developer execution on the host.
///
/// Keeps host-native command semantics, process-group ownership, bounded
/// output, timeout and cancellation behaviour. The child environment comes
/// from [ProcessEnvironmentPolicy]: the inherited developer environment minus
/// Sanad-owned credentials, plus the user secrets explicitly requested for
/// the call and backend-generated values. Every reported output (progress
/// checkpoints, final and partial results) has those secret values redacted.
class DirectExecutionBackend implements ExecutionBackend {
  DirectExecutionBackend({
    ProcessEnvironmentPolicy? processEnvironmentPolicy,
    WindowsSystemPath? windowsSystemPath,
    Map<String, String> Function()? inheritedEnvironment,
  }) : _environmentPolicy =
           processEnvironmentPolicy ?? const ProcessEnvironmentPolicy(),
       _windowsSystemPath =
           windowsSystemPath ?? sharedWindowsSystemPathResolver,
       _inheritedEnvironment =
           inheritedEnvironment ?? (() => Platform.environment);

  static const int _maxOutputChars = 50000;
  static const int _maxStreamChars = _maxOutputChars ~/ 2;
  static const Duration _terminationGrace = Duration(milliseconds: 500);

  final ProcessEnvironmentPolicy _environmentPolicy;
  final WindowsSystemPath _windowsSystemPath;
  final Map<String, String> Function() _inheritedEnvironment;

  @override
  ExecutionMode get mode => ExecutionMode.direct;

  @override
  bool get runsCommands => true;

  Future<
    ({
      String executable,
      List<String> arguments,
      Directory? cleanupDirectory,
      File? startGate,
      bool usesProcessGroup,
    })
  >
  _shellCommand(String command) async {
    if (Platform.isWindows) {
      final directory = await Directory.systemTemp.createTemp('sanad-shell-');
      // cmd.exe decodes the command text with the console code page, so the
      // UTF-8 command is kept in its own payload file that the ASCII wrapper
      // hands over after it switched cmd to UTF-8.
      final files = await writeWindowsShellFiles(
        directoryPath: directory.path,
        command: command,
      );
      return (
        executable: Platform.environment['COMSPEC'] ?? 'cmd.exe',
        arguments: ['/d', '/q', '/c', files.wrapper.path],
        cleanupDirectory: directory,
        startGate: files.startGate,
        usesProcessGroup: false,
      );
    }
    if (Platform.isLinux) {
      return (
        executable: 'setsid',
        arguments: ['sh', '-c', command],
        cleanupDirectory: null,
        startGate: null,
        usesProcessGroup: true,
      );
    }
    if (Platform.isMacOS) {
      return (
        executable: 'perl',
        arguments: [
          '-e',
          r'setpgrp(0,0); exec @ARGV',
          '--',
          'sh',
          '-c',
          command,
        ],
        cleanupDirectory: null,
        startGate: null,
        usesProcessGroup: true,
      );
    }
    return (
      executable: 'sh',
      arguments: ['-c', command],
      cleanupDirectory: null,
      startGate: null,
      usesProcessGroup: false,
    );
  }

  @override
  Future<ToolExecutionResult> execute(ShellCommandRequest request) async {
    final stopwatch = request.stopwatch;
    final context = request.context;
    final shell = await _shellCommand(request.command);
    final redactor = request.secretEnvironment.isEmpty
        ? const SecretOutputRedactor.none()
        : SecretOutputRedactor(request.secretEnvironment);
    String render(({String text, int totalChars, bool truncated}) result) =>
        redactor.redact(_renderBoundedOutput(result));
    Process? process;
    ProcessTreeHandle? tree;
    RunCancellationResourceHandle? cancellationHandle;
    Future<({String text, int totalChars, bool truncated})>? stdoutFuture;
    Future<({String text, int totalChars, bool truncated})>? stderrFuture;
    var stdoutSnapshot = (text: '', totalChars: 0, truncated: false);
    var stderrSnapshot = (text: '', totalChars: 0, truncated: false);
    DateTime? lastProgressWrite;
    var lastPersistedOutputChars = 0;
    var terminalSet = false;

    void persistProgress({bool force = false}) {
      final callback = context?.onExecutionProgress;
      final fingerprint = tree?.fingerprint;
      if (callback == null || fingerprint == null) return;
      final now = DateTime.now().toUtc();
      final outputChars = stdoutSnapshot.totalChars + stderrSnapshot.totalChars;
      if (!force &&
          lastPersistedOutputChars > 0 &&
          lastProgressWrite != null &&
          now.difference(lastProgressWrite!) <
              const Duration(milliseconds: 100)) {
        return;
      }
      lastProgressWrite = now;
      lastPersistedOutputChars = outputChars;
      callback({
        'tool_name': 'shell_execute',
        'status': 'running',
        'stdout': render(stdoutSnapshot),
        'stderr': render(stderrSnapshot),
        'stdout_total_chars': stdoutSnapshot.totalChars,
        'stderr_total_chars': stderrSnapshot.totalChars,
        'updated_at': now.toIso8601String(),
        'process': fingerprint.toJson(),
      });
    }

    bool trySetTerminal(ToolExecutionTerminalReason reason) {
      if (terminalSet) return false;
      terminalSet = true;
      return true;
    }

    ToolExecutionResult finishWith({
      required bool isError,
      required String output,
      ToolProcessCleanupReport? cleanup,
      String? terminalReason,
      ToolResultErrorCode? errorCode,
      // Reported only when the command exited on its own; a timeout,
      // cancellation or failed spawn has no observed exit status.
      int? exitCode,
    }) {
      final payload = <String, dynamic>{
        if (isError) 'isError': true,
        'output': redactor.redact(output),
        'duration_ms': stopwatch.elapsedMilliseconds,
        'exit_code': ?exitCode,
        'cleanup_outcome': ?cleanup?.outcome.name,
        'terminal_reason': ?terminalReason,
      };
      return ToolExecutionResult.text(
        const JsonEncoder.withIndent('  ').convert(payload),
        isError: isError,
        errorCode: isError
            ? errorCode ?? ToolResultErrorCode.executionFailed
            : null,
      );
    }

    try {
      var childEnvironment = _environmentPolicy.buildChildEnvironment(
        purpose: ChildProcessPurpose.directDeveloper,
        inheritedEnvironment: _inheritedEnvironment(),
        secretEnvironment: request.secretEnvironment,
      );
      if (_windowsSystemPath.isWindows) {
        final path = await _windowsSystemPath.resolve(
          inheritedPathFromEnvironment(childEnvironment),
        );
        childEnvironment = replaceEnvironmentPath(childEnvironment, path);
      }
      // Backend-generated values: never prompt interactively, and carry only
      // the session/tool-call identity a restart request needs.
      childEnvironment.addAll({
        'GIT_TERMINAL_PROMPT': '0',
        'GCM_INTERACTIVE': 'false',
        'SSH_ASKPASS_REQUIRE': 'never',
        if (context?.sessionId.isNotEmpty == true)
          'SANAD_REQUESTER_SESSION_ID': context!.sessionId,
        if (context?.toolCallId?.isNotEmpty == true)
          'SANAD_REQUESTER_TOOL_CALL_ID': context!.toolCallId!,
      });
      process = await Process.start(
        shell.executable,
        shell.arguments,
        workingDirectory: request.workingDirectory,
        runInShell: false,
        environment: childEnvironment,
        // The policy-built map is the whole environment; Dart would otherwise
        // merge the daemon's environment (and its credentials) back in.
        includeParentEnvironment: false,
      );
      tree = ProcessTreeController.attach(
        process,
        usesProcessGroup: shell.usesProcessGroup,
      );
      persistProgress(force: true);

      final scope = context?.cancellationScope;
      if (scope != null) {
        cancellationHandle = scope.register(
          'shell_execute:${context?.toolCallId ?? process.pid}',
          () async {
            await tree?.terminate(gracePeriod: _terminationGrace);
          },
        );
      }
      if (scope != null && !scope.isPublicationOpen) {
        final cleanup = await tree.terminate(gracePeriod: _terminationGrace);
        final cancellation = _cancellationResult(scope.reason);
        return finishWith(
          isError: true,
          output: cancellation.message,
          cleanup: cleanup,
          terminalReason: cancellation.reason,
        );
      }
      await shell.startGate?.writeAsString('owned');

      unawaited(process.stdin.close().catchError((_) {}));

      stdoutFuture = _collectBoundedOutput(
        process.stdout,
        _maxStreamChars,
        onSnapshot: (snapshot) {
          stdoutSnapshot = snapshot;
          persistProgress();
        },
      );
      stderrFuture = _collectBoundedOutput(
        process.stderr,
        _maxStreamChars,
        onSnapshot: (snapshot) {
          stderrSnapshot = snapshot;
          persistProgress();
        },
      );

      final waitOutcome = await _waitForOutcome(
        process: process,
        timeoutMs: request.timeoutMs,
        cancellationScope: scope,
        trySetTerminal: trySetTerminal,
      );

      switch (waitOutcome) {
        case _ShellWaitCompleted(:final exitCode):
          final naturalCleanup = await tree.completeNaturally(
            gracePeriod: _terminationGrace,
          );
          final stdoutResult = await stdoutFuture;
          final stderrResult = await stderrFuture;
          cancellationHandle?.release();
          final stdoutStr = render(stdoutResult);
          final stderrStr = render(stderrResult);
          var output = stdoutStr;
          if (stderrStr.isNotEmpty) {
            if (output.isNotEmpty) {
              output += '\n';
            }
            output += 'STDERR:\n$stderrStr';
          }
          if (output.isEmpty && exitCode == 0) {
            output = 'Command executed successfully (no output).';
          }
          final cleanupFailed =
              naturalCleanup.outcome == ToolProcessCleanupOutcome.failed ||
              naturalCleanup.outcome == ToolProcessCleanupOutcome.ownershipLost;
          if (cleanupFailed) {
            output = '$output\nOwned process cleanup failed.';
          }
          return finishWith(
            isError: exitCode != 0 || cleanupFailed,
            output: output,
            cleanup: cleanupFailed ? naturalCleanup : null,
            exitCode: exitCode,
          );
        case _ShellWaitTimedOut():
          final cleanup = await tree.terminate(gracePeriod: _terminationGrace);
          cancellationHandle?.release();
          final partialOutput = await _collectFinishedOutput(
            stdoutFuture,
            stderrFuture,
          );
          return finishWith(
            isError: true,
            output: _appendTerminalMessage(
              partialOutput,
              'Command timed out after ${request.timeoutMs} ms.',
            ),
            cleanup: cleanup,
            terminalReason: 'timed_out',
            errorCode: ToolResultErrorCode.timedOut,
          );
        case _ShellWaitCancelled():
          final cleanup = await tree.terminate(gracePeriod: _terminationGrace);
          cancellationHandle?.release();
          final partialOutput = await _collectFinishedOutput(
            stdoutFuture,
            stderrFuture,
          );
          final cancellation = _cancellationResult(scope?.reason);
          return finishWith(
            isError: true,
            output: _appendTerminalMessage(partialOutput, cancellation.message),
            cleanup: cleanup,
            terminalReason: cancellation.reason,
          );
      }
    } catch (e) {
      if (tree != null && !terminalSet) {
        await tree.terminate(gracePeriod: _terminationGrace);
      } else if (process != null && !terminalSet) {
        process.kill(ProcessSignal.sigkill);
      }
      return finishWith(isError: true, output: 'Failed to execute command: $e');
    } finally {
      final cleanupDirectory = shell.cleanupDirectory;
      if (cleanupDirectory != null) {
        try {
          await cleanupDirectory.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<String> _collectFinishedOutput(
    Future<({String text, int totalChars, bool truncated})>? stdoutFuture,
    Future<({String text, int totalChars, bool truncated})>? stderrFuture,
  ) async {
    if (stdoutFuture == null || stderrFuture == null) return '';
    try {
      final results = await Future.wait([
        stdoutFuture,
        stderrFuture,
      ]).timeout(const Duration(seconds: 2));
      final stdout = _renderBoundedOutput(results[0]);
      final stderr = _renderBoundedOutput(results[1]);
      if (stderr.isEmpty) return stdout;
      return stdout.isEmpty ? 'STDERR:\n$stderr' : '$stdout\nSTDERR:\n$stderr';
    } catch (_) {
      return '';
    }
  }

  String _appendTerminalMessage(String output, String message) =>
      output.trim().isEmpty ? message : '${output.trimRight()}\n$message';

  ({String reason, String message}) _cancellationResult(
    RunCancellationReason? reason,
  ) => switch (reason) {
    RunCancellationReason.userStop => (
      reason: 'cancelled_by_user',
      message: 'Command cancelled by user.',
    ),
    RunCancellationReason.timeout => (
      reason: 'timed_out',
      message: 'Command timed out.',
    ),
    RunCancellationReason.shutdown => (
      reason: 'agent_interrupted',
      message:
          'The command was interrupted because the agent stopped. Its final outcome is unknown.',
    ),
    RunCancellationReason.superseded => (
      reason: 'superseded',
      message: 'The command was interrupted by a newer execution owner.',
    ),
    null => (
      reason: 'agent_interrupted',
      message:
          'The command was interrupted because the agent stopped unexpectedly. Its final outcome is unknown.',
    ),
  };

  Future<_ShellWaitOutcome> _waitForOutcome({
    required Process process,
    required int timeoutMs,
    required RunCancellationScope? cancellationScope,
    required bool Function(ToolExecutionTerminalReason reason) trySetTerminal,
  }) async {
    final completer = Completer<_ShellWaitOutcome>();
    Timer? timeoutTimer;

    void complete(_ShellWaitOutcome outcome) {
      if (completer.isCompleted) return;
      timeoutTimer?.cancel();
      completer.complete(outcome);
    }

    timeoutTimer = Timer(Duration(milliseconds: timeoutMs), () {
      if (trySetTerminal(ToolExecutionTerminalReason.timedOut)) {
        complete(const _ShellWaitTimedOut());
      }
    });

    if (cancellationScope != null) {
      unawaited(
        cancellationScope.whenCancelled.then((_) {
          if (trySetTerminal(ToolExecutionTerminalReason.cancelled)) {
            complete(const _ShellWaitCancelled());
          }
        }),
      );
    }

    unawaited(
      process.exitCode.then((exitCode) {
        if (completer.isCompleted) return;
        final scope = cancellationScope;
        if (scope != null && !scope.isPublicationOpen) {
          if (!completer.isCompleted) {
            complete(const _ShellWaitCancelled());
          }
          return;
        }
        complete(_ShellWaitCompleted(exitCode));
      }),
    );

    return completer.future;
  }

  Future<({String text, int totalChars, bool truncated})> _collectBoundedOutput(
    Stream<List<int>> stream,
    int maxChars, {
    void Function(({String text, int totalChars, bool truncated}) snapshot)?
    onSnapshot,
  }) async {
    final headLimit = (maxChars * 0.4).floor();
    final tailLimit = maxChars - headLimit;
    final head = StringBuffer();
    var tail = '';
    var totalChars = 0;

    await for (final chunk in stream.transform(
      const Utf8Decoder(allowMalformed: true),
    )) {
      totalChars += chunk.length;
      var remainingChunk = chunk;
      final availableHead = headLimit - head.length;
      if (availableHead > 0) {
        final take = remainingChunk.length < availableHead
            ? remainingChunk.length
            : availableHead;
        head.write(remainingChunk.substring(0, take));
        remainingChunk = remainingChunk.substring(take);
      }
      if (remainingChunk.isNotEmpty && tailLimit > 0) {
        tail += remainingChunk;
        if (tail.length > tailLimit) {
          tail = tail.substring(tail.length - tailLimit);
        }
      }
      onSnapshot?.call((
        text: '${head.toString()}$tail',
        totalChars: totalChars,
        truncated: totalChars > maxChars,
      ));
    }

    return (
      text: '${head.toString()}$tail',
      totalChars: totalChars,
      truncated: totalChars > maxChars,
    );
  }

  String _renderBoundedOutput(
    ({String text, int totalChars, bool truncated}) result,
  ) {
    if (!result.truncated) {
      return result.text;
    }
    final headChars = (_maxStreamChars * 0.4).floor();
    final tailChars = _maxStreamChars - headChars;
    final head = result.text.substring(0, headChars);
    final tail = result.text.substring(result.text.length - tailChars);
    final omitted = result.totalChars - _maxStreamChars;
    return '$head\n\n... [OUTPUT TRUNCATED: $omitted of ${result.totalChars} characters omitted] ...\n\n$tail';
  }
}

sealed class _ShellWaitOutcome {
  const _ShellWaitOutcome();
}

final class _ShellWaitCompleted extends _ShellWaitOutcome {
  final int exitCode;
  const _ShellWaitCompleted(this.exitCode);
}

final class _ShellWaitTimedOut extends _ShellWaitOutcome {
  const _ShellWaitTimedOut();
}

final class _ShellWaitCancelled extends _ShellWaitOutcome {
  const _ShellWaitCancelled();
}
