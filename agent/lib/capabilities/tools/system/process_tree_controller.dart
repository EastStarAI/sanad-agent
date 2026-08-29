import 'dart:async';
import 'dart:ffi';
import 'dart:io';

import 'package:ffi/ffi.dart';

import '../tool_execution_outcome.dart';

typedef ProcessIdentityReader = String? Function(int pid);

/// Identity captured at spawn for safe late cleanup.
class ProcessFingerprint {
  final int pid;
  final DateTime capturedAt;
  final String startIdentity;
  final String containmentIdentity;
  final int? processGroupId;
  final bool usesProcessGroup;

  const ProcessFingerprint({
    required this.pid,
    required this.capturedAt,
    required this.startIdentity,
    required this.containmentIdentity,
    required this.processGroupId,
    required this.usesProcessGroup,
  });
}

/// Owns one spawned process tree and performs bounded TERM -> grace -> KILL
/// cleanup. The handle never uses a PPID snapshot as its ownership boundary.
class ProcessTreeHandle {
  final Process _process;
  final ProcessIdentityReader _identityReader;
  final _WindowsJobObject? _windowsJob;
  final ProcessFingerprint fingerprint;
  bool _released = false;
  bool _processExited = false;
  Future<ToolProcessCleanupReport>? _terminationFuture;

  ProcessTreeHandle._(
    this._process,
    this.fingerprint,
    this._identityReader,
    this._windowsJob,
  ) {
    unawaited(
      _process.exitCode.then((_) {
        _processExited = true;
      }),
    );
  }

  int get pid => _process.pid;

  /// Marks natural completion and releases native containment ownership.
  void release() {
    if (_released) return;
    _released = true;
    _windowsJob?.close();
  }

  /// Completes a naturally exited command without allowing descendants to
  /// escape foreground ownership.
  Future<ToolProcessCleanupReport> completeNaturally({
    Duration gracePeriod = const Duration(milliseconds: 500),
  }) async {
    _processExited = true;
    if (await _isContainmentAlive()) {
      return terminate(gracePeriod: gracePeriod);
    }
    release();
    return ToolProcessCleanupReport(
      outcome: ToolProcessCleanupOutcome.exited,
      pid: fingerprint.pid,
      diagnostics: 'natural_exit',
    );
  }

  Future<ToolProcessCleanupReport> terminate({
    Duration gracePeriod = const Duration(milliseconds: 500),
  }) {
    if (_released) {
      return Future.value(
        ToolProcessCleanupReport(
          outcome: ToolProcessCleanupOutcome.exited,
          pid: fingerprint.pid,
          diagnostics: 'already_released',
        ),
      );
    }
    return _terminationFuture ??= _terminate(gracePeriod);
  }

  Future<ToolProcessCleanupReport> _terminate(Duration gracePeriod) async {
    final containmentAlive = await _isContainmentAlive();
    if (!containmentAlive) {
      release();
      return ToolProcessCleanupReport(
        outcome: ToolProcessCleanupOutcome.exited,
        pid: fingerprint.pid,
        diagnostics: 'already_exited',
      );
    }
    if (!_processExited && !_verifyFingerprint()) {
      return ToolProcessCleanupReport(
        outcome: ToolProcessCleanupOutcome.ownershipLost,
        pid: fingerprint.pid,
        diagnostics: 'fingerprint_mismatch',
      );
    }

    try {
      await _signalTerm();
      if (await _waitForTreeExit(gracePeriod)) {
        release();
        return ToolProcessCleanupReport(
          outcome: ToolProcessCleanupOutcome.exited,
          pid: fingerprint.pid,
        );
      }

      await _signalKill();
      final exitedAfterKill = await _waitForTreeExit(
        const Duration(seconds: 2),
      );
      if (exitedAfterKill) release();
      return ToolProcessCleanupReport(
        outcome: exitedAfterKill
            ? ToolProcessCleanupOutcome.escalated
            : ToolProcessCleanupOutcome.failed,
        pid: fingerprint.pid,
        diagnostics: exitedAfterKill ? null : 'kill_unverified',
      );
    } catch (error) {
      return ToolProcessCleanupReport(
        outcome: ToolProcessCleanupOutcome.failed,
        pid: fingerprint.pid,
        diagnostics: error.toString(),
      );
    }
  }

  bool _verifyFingerprint() =>
      _process.pid == fingerprint.pid &&
      _identityReader(fingerprint.pid) == fingerprint.startIdentity;

  Future<bool> _isContainmentAlive() async {
    if (Platform.isWindows) {
      final job = _windowsJob;
      return job?.hasActiveProcesses() ?? !_processExited;
    }
    final pgid = fingerprint.processGroupId;
    if (fingerprint.usesProcessGroup && pgid != null) {
      final result = await Process.run('ps', ['-eo', 'pgid=,stat=']);
      if (result.exitCode != 0) return !_processExited;
      for (final line in result.stdout.toString().split('\n')) {
        final match = RegExp(r'^\s*(\d+)\s+(\S+)').firstMatch(line);
        if (match == null || int.tryParse(match.group(1)!) != pgid) continue;
        if (!match.group(2)!.startsWith('Z')) return true;
      }
      return false;
    }
    return !_processExited;
  }

  Future<void> _signalTerm() async {
    if (Platform.isWindows) {
      // Windows has no cascading SIGTERM. Give taskkill's non-force path the
      // grace window while the Job Object remains the hard boundary.
      await Process.run('taskkill', ['/PID', '${fingerprint.pid}', '/T']);
      return;
    }
    if (fingerprint.usesProcessGroup && fingerprint.processGroupId != null) {
      await Process.run('sh', [
        '-c',
        'kill -TERM -${fingerprint.processGroupId} 2>/dev/null || true',
      ]);
      return;
    }
    _process.kill(ProcessSignal.sigterm);
  }

  Future<void> _signalKill() async {
    if (Platform.isWindows) {
      final job = _windowsJob;
      if (job != null && job.isOpen) {
        job.close();
      } else {
        await Process.run('taskkill', [
          '/PID',
          '${fingerprint.pid}',
          '/T',
          '/F',
        ]);
      }
      return;
    }
    if (fingerprint.usesProcessGroup && fingerprint.processGroupId != null) {
      await Process.run('sh', [
        '-c',
        'kill -KILL -${fingerprint.processGroupId} 2>/dev/null || true',
      ]);
      return;
    }
    _process.kill(ProcessSignal.sigkill);
  }

  Future<bool> _waitForTreeExit(Duration timeout) async {
    final deadline = DateTime.now().add(timeout);
    do {
      if (!await _isContainmentAlive()) return true;
      await Future<void>.delayed(const Duration(milliseconds: 25));
    } while (DateTime.now().isBefore(deadline));
    return !await _isContainmentAlive();
  }
}

/// Factory for run-owned process trees started by shell tools.
class ProcessTreeController {
  const ProcessTreeController._();

  static ProcessTreeHandle attach(
    Process process, {
    required bool usesProcessGroup,
    ProcessIdentityReader? identityReader,
  }) {
    final reader = identityReader ?? _readProcessIdentity;
    // Very short commands can exit before attach observes their OS identity.
    // The sentinel fails closed if cleanup later sees a live reused PID, while
    // natural completion can still release an already-empty containment.
    final identity = reader(process.pid) ?? 'unavailable-at-attach';
    final windowsJob = Platform.isWindows
        ? _WindowsJobObject.attach(process.pid)
        : null;
    return ProcessTreeHandle._(
      process,
      ProcessFingerprint(
        pid: process.pid,
        capturedAt: DateTime.now().toUtc(),
        startIdentity: identity,
        containmentIdentity: Platform.isWindows
            ? 'job:${windowsJob == null ? 'taskkill-fallback' : 'owned'}:${process.pid}'
            : usesProcessGroup
            ? 'pgid:${process.pid}'
            : 'pid:${process.pid}',
        processGroupId: usesProcessGroup ? process.pid : null,
        usesProcessGroup: usesProcessGroup,
      ),
      reader,
      windowsJob,
    );
  }

  static String? _readProcessIdentity(int pid) {
    if (Platform.isLinux) {
      try {
        final stat = File('/proc/$pid/stat').readAsStringSync();
        final fields = stat.substring(stat.lastIndexOf(')') + 2).split(' ');
        // The suffix starts at proc field 3; starttime is field 22.
        return fields.length > 19 ? fields[19] : null;
      } catch (_) {
        return null;
      }
    }
    if (Platform.isMacOS) {
      final result = Process.runSync('ps', ['-o', 'lstart=', '-p', '$pid']);
      if (result.exitCode != 0) return null;
      final value = result.stdout.toString().trim();
      return value.isEmpty ? null : value;
    }
    if (Platform.isWindows) {
      final result = Process.runSync('powershell.exe', [
        '-NoProfile',
        '-NonInteractive',
        '-Command',
        '(Get-Process -Id $pid).StartTime.ToUniversalTime().Ticks',
      ]);
      if (result.exitCode != 0) return null;
      final value = result.stdout.toString().trim();
      return value.isEmpty ? null : value;
    }
    return '$pid';
  }
}

typedef _CreateJobObjectNative =
    Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>);
typedef _CreateJobObjectDart =
    Pointer<Void> Function(Pointer<Void>, Pointer<Utf16>);
typedef _SetInformationJobObjectNative =
    Int32 Function(Pointer<Void>, Int32, Pointer<Void>, Uint32);
typedef _SetInformationJobObjectDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int);
typedef _OpenProcessNative = Pointer<Void> Function(Uint32, Int32, Uint32);
typedef _OpenProcessDart = Pointer<Void> Function(int, int, int);
typedef _AssignProcessToJobObjectNative =
    Int32 Function(Pointer<Void>, Pointer<Void>);
typedef _AssignProcessToJobObjectDart =
    int Function(Pointer<Void>, Pointer<Void>);
typedef _CloseHandleNative = Int32 Function(Pointer<Void>);
typedef _CloseHandleDart = int Function(Pointer<Void>);
typedef _QueryInformationJobObjectNative =
    Int32 Function(
      Pointer<Void>,
      Int32,
      Pointer<Void>,
      Uint32,
      Pointer<Uint32>,
    );
typedef _QueryInformationJobObjectDart =
    int Function(Pointer<Void>, int, Pointer<Void>, int, Pointer<Uint32>);

/// Minimal Windows Job Object wrapper. Kill-on-close makes the kernel-owned job
/// the primary containment boundary; taskkill is used only when setup fails.
class _WindowsJobObject {
  static const _jobObjectExtendedLimitInformation = 9;
  static const _jobObjectLimitKillOnJobClose = 0x00002000;
  static const _processTerminate = 0x0001;
  static const _processSetQuota = 0x0100;

  final Pointer<Void> _handle;
  final _CloseHandleDart _closeHandle;
  final _QueryInformationJobObjectDart _queryInformation;
  bool _closed = false;

  _WindowsJobObject._(this._handle, this._closeHandle, this._queryInformation);

  bool get isOpen => !_closed;

  static _WindowsJobObject? attach(int pid) {
    try {
      final kernel32 = DynamicLibrary.open('kernel32.dll');
      final createJob = kernel32
          .lookupFunction<_CreateJobObjectNative, _CreateJobObjectDart>(
            'CreateJobObjectW',
          );
      final setInformation = kernel32
          .lookupFunction<
            _SetInformationJobObjectNative,
            _SetInformationJobObjectDart
          >('SetInformationJobObject');
      final openProcess = kernel32
          .lookupFunction<_OpenProcessNative, _OpenProcessDart>('OpenProcess');
      final assignProcess = kernel32
          .lookupFunction<
            _AssignProcessToJobObjectNative,
            _AssignProcessToJobObjectDart
          >('AssignProcessToJobObject');
      final closeHandle = kernel32
          .lookupFunction<_CloseHandleNative, _CloseHandleDart>('CloseHandle');
      final queryInformation = kernel32
          .lookupFunction<
            _QueryInformationJobObjectNative,
            _QueryInformationJobObjectDart
          >('QueryInformationJobObject');

      final job = createJob(nullptr, nullptr.cast<Utf16>());
      if (job == nullptr) return null;
      final infoSize = sizeOf<IntPtr>() == 8 ? 144 : 112;
      final info = calloc<Uint8>(infoSize);
      try {
        (info + 16).cast<Uint32>().value = _jobObjectLimitKillOnJobClose;
        if (setInformation(
              job,
              _jobObjectExtendedLimitInformation,
              info.cast<Void>(),
              infoSize,
            ) ==
            0) {
          closeHandle(job);
          return null;
        }
      } finally {
        calloc.free(info);
      }

      final process = openProcess(_processTerminate | _processSetQuota, 0, pid);
      if (process == nullptr) {
        closeHandle(job);
        return null;
      }
      try {
        if (assignProcess(job, process) == 0) {
          closeHandle(job);
          return null;
        }
      } finally {
        closeHandle(process);
      }
      return _WindowsJobObject._(job, closeHandle, queryInformation);
    } catch (_) {
      return null;
    }
  }

  void close() {
    if (_closed) return;
    _closed = true;
    _closeHandle(_handle);
  }

  bool hasActiveProcesses() {
    if (_closed) return false;
    final info = calloc<Uint8>(64);
    try {
      // JOBOBJECT_BASIC_ACCOUNTING_INFORMATION.ActiveProcesses follows four
      // LARGE_INTEGER counters and two DWORD counters.
      if (_queryInformation(_handle, 1, info.cast<Void>(), 64, nullptr) == 0) {
        return true;
      }
      return (info + 40).cast<Uint32>().value > 0;
    } finally {
      calloc.free(info);
    }
  }
}
