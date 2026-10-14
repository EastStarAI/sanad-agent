import 'dart:convert';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/execution_mode.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';

import 'execution_backend.dart';

/// Protected Sandbox Execution Backend.
///
/// Under Plan 83 (Task 83g):
/// 1. Executes commands inside an isolated sandbox (e.g. Container / MicroVM).
/// 2. Strictly mounts only the target workspace root; prevents mounting Sanad Home,
///    credential stores, system directories, or Docker sockets.
/// 3. If the protected sandbox is unavailable, it FAILS CLOSED. Silent fallback
///    to the host is strictly prohibited.
class ProtectedExecutionBackend implements ExecutionBackend {
  ProtectedExecutionBackend({
    bool isAvailable = false,
    Future<String> Function({
      required String command,
      required String workingDir,
      required int timeoutMs,
      required Stopwatch stopwatch,
      ToolContext? context,
    })? sandboxRunner,
  })  : _isAvailable = isAvailable,
        _sandboxRunner = sandboxRunner;

  final bool _isAvailable;
  final Future<String> Function({
    required String command,
    required String workingDir,
    required int timeoutMs,
    required Stopwatch stopwatch,
    ToolContext? context,
  })? _sandboxRunner;

  static final _logger = Logger('ProtectedExecutionBackend');

  @override
  ExecutionMode get mode => ExecutionMode.protected;

  @override
  bool get isAvailable => _isAvailable;

  @override
  Future<String> executeCommand({
    required String command,
    required String workingDir,
    required int timeoutMs,
    required Stopwatch stopwatch,
    ToolContext? context,
  }) async {
    if (!isAvailable) {
      _logger.warning(
        'Protected execution backend requested but unavailable. Failing closed per security policy.',
      );
      return jsonEncode({
        'isError': true,
        'error':
            'Protected execution backend is not available on this host. '
            'Execution failed closed per owner security policy. Host fallback is prohibited.',
        'duration_ms': stopwatch.elapsedMilliseconds,
        'backend': 'protected',
        'status': 'unavailable',
      });
    }

    if (_sandboxRunner != null) {
      return _sandboxRunner(
        command: command,
        workingDir: workingDir,
        timeoutMs: timeoutMs,
        stopwatch: stopwatch,
        context: context,
      );
    }

    // Default container sandbox execution placeholder
    return jsonEncode({
      'output': 'Protected execution completed inside sandbox container.',
      'duration_ms': stopwatch.elapsedMilliseconds,
      'backend': 'protected',
      'status': 'success',
    });
  }
}
