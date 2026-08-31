import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/engine/runtime/run_cancellation_scope.dart';

import '../../models/local_tool_spec.dart';
import '../../permissions/permission_manager.dart';
import '../base_tool.dart';
import '../runtime/spec_backed_tool.dart';
import '../tool_execution_outcome.dart';
import 'process_tree_controller.dart';

class ShellExecuteTool extends SpecBackedTool {
  static const int _maxOutputChars = 50000;
  static const int _maxStreamChars = _maxOutputChars ~/ 2;
  static const Duration _terminationGrace = Duration(milliseconds: 500);

  final String workspacePath;
  final PermissionManager? _permissionManager;

  ShellExecuteTool({
    required this.workspacePath,
    PermissionManager? permissionManager,
  }) : _permissionManager = permissionManager;

  @override
  bool get isCooperativelyCancellable => true;

  @override
  LocalToolSpec get toolSpec => const LocalToolSpec(
    name: 'shell_execute',
    displayName: 'Shell Execute',
    description:
        'Execute a shell command. Starts inside the active workspace; do not "cd" to it.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': {'type': 'string'},
        'cwd': {
          'type': 'string',
          'description':
              'Optional subdirectory relative to workspace root. Do not use for root.',
        },
        'timeout_ms': {'type': 'integer'},
      },
      'required': ['command'],
      'additionalProperties': false,
    },
    source: {'type': 'builtin_local', 'id': 'sanad-agent.system'},
    category: 'shell_execution',
    workspaceRequired: true,
    approval: {
      'mode': 'default',
      'sensitive': true,
      'permission_class': 'shell_execution',
    },
    execution: {'target': 'local_runtime', 'timeout_ms': 60000},
    serverName: 'system',
  );

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
      final script = File('${directory.path}\\command.cmd');
      final startGate = File('${directory.path}\\owned.ready');
      await script.writeAsString(
        '@echo off\r\n'
        ':wait_for_owner\r\n'
        'if not exist "${startGate.path}" (\r\n'
        '  >nul 2>&1 ping -n 2 127.0.0.1\r\n'
        '  goto wait_for_owner\r\n'
        ')\r\n'
        '$command\r\n',
      );
      return (
        executable: Platform.environment['COMSPEC'] ?? 'cmd.exe',
        arguments: ['/d', '/q', '/c', script.path],
        cleanupDirectory: directory,
        startGate: startGate,
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
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    if (_permissionManager != null && context != null) {
      await _permissionManager.ensureAuthorized(
        tool: toolSpec,
        arguments: args,
        context: context,
      );
    }

    final String cmd = args['command']?.toString() ?? '';
    if (cmd.trim().isEmpty) {
      throw const FormatException('No command provided.');
    }

    final String targetSubPath = args['cwd']?.toString() ?? '';

    String workingDir = workspacePath;
    if (targetSubPath.trim().isNotEmpty) {
      final subDir = Directory(targetSubPath);
      if (subDir.isAbsolute) {
        workingDir = subDir.resolveSymbolicLinksSync();
      } else {
        workingDir = Directory(
          '$workspacePath/$targetSubPath',
        ).resolveSymbolicLinksSync();
      }
    } else {
      workingDir = Directory(workspacePath).resolveSymbolicLinksSync();
    }

    final resolvedWorkspaceRoot = Directory(
      workspacePath,
    ).resolveSymbolicLinksSync();
    if (!workingDir.startsWith(resolvedWorkspaceRoot)) {
      throw FileSystemException(
        'Security violation: Target path is outside the workspace root.',
        workingDir,
      );
    }

    final int timeoutMs = args['timeout_ms'] is int
        ? args['timeout_ms'] as int
        : int.tryParse(args['timeout_ms']?.toString() ?? '') ?? 60000;

    final shell = await _shellCommand(cmd);
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
        'stdout': _renderBoundedOutput(stdoutSnapshot),
        'stderr': _renderBoundedOutput(stderrSnapshot),
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

    Future<String> finishWith({
      required bool isError,
      required String output,
      ToolProcessCleanupReport? cleanup,
      String? terminalReason,
    }) async {
      final payload = <String, dynamic>{
        'isError': isError,
        'output': output,
        'cleanup_outcome': ?cleanup?.outcome.name,
        'terminal_reason': ?terminalReason,
      };
      return const JsonEncoder.withIndent('  ').convert(payload);
    }

    try {
      process = await Process.start(
        shell.executable,
        shell.arguments,
        workingDirectory: workingDir,
        runInShell: false,
        environment: {
          ...Platform.environment,
          'GIT_TERMINAL_PROMPT': '0',
          'GCM_INTERACTIVE': 'false',
          'SSH_ASKPASS_REQUIRE': 'never',
          if (context?.sessionId.isNotEmpty == true)
            'SANAD_REQUESTER_SESSION_ID': context!.sessionId,
          if (context?.toolCallId?.isNotEmpty == true)
            'SANAD_REQUESTER_TOOL_CALL_ID': context!.toolCallId!,
        },
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
        return await finishWith(
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
        timeoutMs: timeoutMs,
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
          final stdoutStr = _renderBoundedOutput(stdoutResult);
          final stderrStr = _renderBoundedOutput(stderrResult);
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
          return await finishWith(
            isError: exitCode != 0 || cleanupFailed,
            output: output,
            cleanup: cleanupFailed ? naturalCleanup : null,
          );
        case _ShellWaitTimedOut():
          final cleanup = await tree.terminate(gracePeriod: _terminationGrace);
          cancellationHandle?.release();
          final partialOutput = await _collectFinishedOutput(
            stdoutFuture,
            stderrFuture,
          );
          return await finishWith(
            isError: true,
            output: _appendTerminalMessage(
              partialOutput,
              'Command timed out after $timeoutMs ms.',
            ),
            cleanup: cleanup,
            terminalReason: 'timed_out',
          );
        case _ShellWaitCancelled():
          final cleanup = await tree.terminate(gracePeriod: _terminationGrace);
          cancellationHandle?.release();
          final partialOutput = await _collectFinishedOutput(
            stdoutFuture,
            stderrFuture,
          );
          final cancellation = _cancellationResult(scope?.reason);
          return await finishWith(
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
      return await finishWith(
        isError: true,
        output: 'Failed to execute command: $e',
      );
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
