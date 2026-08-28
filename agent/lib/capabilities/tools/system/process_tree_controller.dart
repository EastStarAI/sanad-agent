import 'dart:async';
import 'dart:io';

import '../tool_execution_outcome.dart';

/// Identity captured at spawn for safe late cleanup.
class ProcessFingerprint {
  final int pid;
  final DateTime capturedAt;
  final int? processGroupId;
  final bool usesProcessGroup;

  const ProcessFingerprint({
    required this.pid,
    required this.capturedAt,
    required this.processGroupId,
    required this.usesProcessGroup,
  });
}

/// Owns one spawned process tree and performs bounded TERM → grace → KILL cleanup.
class ProcessTreeHandle {
  final Process _process;
  final ProcessFingerprint fingerprint;
  bool _released = false;
  bool _terminateInFlight = false;
  ToolProcessCleanupReport? _lastReport;

  ProcessTreeHandle._(this._process, this.fingerprint);

  int get pid => _process.pid;

  /// Marks natural completion so late Stop cleanup does not target this PID.
  void release() {
    _released = true;
  }

  Future<ToolProcessCleanupReport> terminate({
    Duration gracePeriod = const Duration(milliseconds: 500),
  }) async {
    if (_released) {
      return ToolProcessCleanupReport(
        outcome: ToolProcessCleanupOutcome.exited,
        pid: fingerprint.pid,
        diagnostics: 'already_released',
      );
    }
    final existing = _lastReport;
    if (existing != null) {
      return existing;
    }
    if (_terminateInFlight) {
      while (_lastReport == null) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      return _lastReport!;
    }
    _terminateInFlight = true;

    if (!await _verifyFingerprint()) {
      _lastReport = ToolProcessCleanupReport(
        outcome: ToolProcessCleanupOutcome.ownershipLost,
        pid: fingerprint.pid,
        diagnostics: 'fingerprint_mismatch',
      );
      return _lastReport!;
    }

    try {
      await _signalTerm();
      final exitedAfterTerm = await _waitForExit(gracePeriod);
      if (exitedAfterTerm) {
        _lastReport = ToolProcessCleanupReport(
          outcome: ToolProcessCleanupOutcome.exited,
          pid: fingerprint.pid,
        );
        return _lastReport!;
      }

      await _signalKill();
      final exitedAfterKill = await _waitForExit(const Duration(seconds: 2));
      _lastReport = ToolProcessCleanupReport(
        outcome: exitedAfterKill
            ? ToolProcessCleanupOutcome.escalated
            : ToolProcessCleanupOutcome.failed,
        pid: fingerprint.pid,
        diagnostics: exitedAfterKill ? null : 'kill_unverified',
      );
      return _lastReport!;
    } catch (error) {
      _lastReport = ToolProcessCleanupReport(
        outcome: ToolProcessCleanupOutcome.failed,
        pid: fingerprint.pid,
        diagnostics: error.toString(),
      );
      return _lastReport!;
    } finally {
      _terminateInFlight = false;
    }
  }

  Future<bool> _verifyFingerprint() async {
    if (_process.pid != fingerprint.pid) {
      return false;
    }
    if (Platform.isWindows) {
      final result = await Process.run(
        'tasklist',
        ['/FI', 'PID eq ${fingerprint.pid}', '/NH'],
        runInShell: true,
      );
      return result.stdout.toString().contains('${fingerprint.pid}');
    }
    final result = await Process.run('kill', ['-0', '${fingerprint.pid}']);
    return result.exitCode == 0;
  }

  Future<void> _signalTerm() async {
    if (Platform.isWindows) {
      await Process.run(
        'taskkill',
        ['/PID', '${fingerprint.pid}', '/T'],
        runInShell: true,
      );
      return;
    }
    if (fingerprint.usesProcessGroup && fingerprint.processGroupId != null) {
      await Process.run('sh', [
        '-c',
        'kill -TERM -${fingerprint.processGroupId} 2>/dev/null || true',
      ]);
    }
    try {
      _process.kill(ProcessSignal.sigterm);
    } catch (_) {}
  }

  Future<void> _signalKill() async {
    if (Platform.isWindows) {
      await Process.run(
        'taskkill',
        ['/PID', '${fingerprint.pid}', '/T', '/F'],
        runInShell: true,
      );
      return;
    }
    if (fingerprint.usesProcessGroup && fingerprint.processGroupId != null) {
      await Process.run('sh', [
        '-c',
        'kill -KILL -${fingerprint.processGroupId} 2>/dev/null || true',
      ]);
    }
    try {
      _process.kill(ProcessSignal.sigkill);
    } catch (_) {}
  }

  Future<bool> _waitForExit(Duration timeout) async {
    try {
      await _process.exitCode.timeout(timeout);
      return true;
    } on TimeoutException {
      return false;
    }
  }
}

/// Factory for run-owned process trees started by shell tools.
class ProcessTreeController {
  const ProcessTreeController._();

  static ProcessTreeHandle attach(
    Process process, {
    required bool usesProcessGroup,
  }) {
    final pgid = usesProcessGroup ? process.pid : null;
    return ProcessTreeHandle._(
      process,
      ProcessFingerprint(
        pid: process.pid,
        capturedAt: DateTime.now(),
        processGroupId: pgid,
        usesProcessGroup: usesProcessGroup,
      ),
    );
  }
}
