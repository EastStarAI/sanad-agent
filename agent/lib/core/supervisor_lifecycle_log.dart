import 'dart:io';

import 'package:path/path.dart' as p;

/// Byte cap of one supervisor lifecycle segment.
const int supervisorLifecycleLogMaxBytes = 256 * 1024;

/// Retained segments: the active file plus one rotated predecessor.
const int supervisorLifecycleLogSegmentCount = 2;

/// One lifecycle transition the supervisor records exactly once.
enum SupervisorLifecycleEvent {
  /// The supervisor took ownership of the Agent child.
  start,

  /// An automatic respawn of the Agent child.
  respawn,

  /// The child asked for a permanent stop (`123`).
  childStop,

  /// The crash-loop breaker ended the supervisor.
  breakerExit,

  /// The launcher lease no longer belongs to this supervisor.
  leaseMismatchExit,

  /// The launcher's stdin pipe closed, so its supervisor must not outlive it.
  launcherExit,

  /// A signal ended the supervisor.
  shutdown,
}

/// Bounded, rotated lifecycle log for the in-process Agent supervisor.
///
/// The supervisor's stdout belongs to whichever terminal or pipe launched it,
/// and the launcher-owned component journal dies with the launcher. A supervisor
/// that outlives its launcher therefore leaves no record at all — one incident
/// ran for two days with nothing on disk to find. This log is that record: one
/// line per transition, at most [segmentCount] × [maxBytes] bytes, under the
/// owning Home.
///
/// It is diagnostic only and never fails the supervisor: every write is best
/// effort, and a Home that does not exist yet is never created here (the daemon
/// child owns Home preparation and its owner-only permissions).
class SupervisorLifecycleLog {
  SupervisorLifecycleLog({
    required this.home,
    this.maxBytes = supervisorLifecycleLogMaxBytes,
    this.segmentCount = supervisorLifecycleLogSegmentCount,
    DateTime Function()? clock,
  }) : _clock = clock ?? DateTime.now;

  /// Sanad Home that owns the log directory.
  final String home;

  /// Rotate before a segment would exceed this many bytes.
  final int maxBytes;

  /// Active file plus rotated predecessors to retain.
  final int segmentCount;

  final DateTime Function() _clock;

  /// `logs/agent-supervisor.log` under [home].
  String get path => p.join(home, 'logs', 'agent-supervisor.log');

  /// Records one transition; returns the written line or null when skipped.
  String? record(
    SupervisorLifecycleEvent event, {
    int? pid,
    int? attempt,
    String detail = '',
  }) {
    try {
      final root = Directory(home);
      if (!root.existsSync()) return null;
      final directory = Directory(p.join(home, 'logs'));
      if (!directory.existsSync()) directory.createSync();
      _rotateIfNeeded();
      final name = event.name;
      final fields = <String>[
        'event=$name',
        if (pid != null) 'pid=$pid',
        if (attempt != null) 'attempt=$attempt',
        if (detail.trim().isNotEmpty) 'detail=${detail.trim()}',
      ];
      final line =
          '${_clock().toUtc().toIso8601String()} ${fields.join(' ')}\n';
      final file = File(path);
      file.writeAsStringSync(line, mode: FileMode.append, flush: true);
      return line.trimRight();
    } on Object {
      // A diagnostic log must never end a supervisor.
      return null;
    }
  }

  /// Keeps the active file under [maxBytes] by rotating whole segments.
  ///
  /// Rotation is size-based rather than time-based because the failure this
  /// file exists for is a tight restart loop: a wall-clock policy would either
  /// rotate constantly or let a loop fill the disk between two timestamps.
  void _rotateIfNeeded() {
    final active = File(path);
    if (!active.existsSync()) return;
    if (active.lengthSync() < maxBytes) return;
    for (var index = segmentCount - 1; index > 0; index--) {
      final source = File(_segmentPath(index));
      if (!source.existsSync()) continue;
      if (index == segmentCount - 1) {
        source.deleteSync();
        continue;
      }
      source.renameSync(_segmentPath(index + 1));
    }
    if (segmentCount > 1) {
      active.renameSync(_segmentPath(1));
    } else {
      active.deleteSync();
    }
  }

  String _segmentPath(int index) => '$path.$index';
}
