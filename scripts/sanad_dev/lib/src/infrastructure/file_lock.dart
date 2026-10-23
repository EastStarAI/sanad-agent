import 'dart:async';
import 'dart:io';

/// How long a caller waits for a contended Sanad development lock by default.
///
/// The wait is bounded so a leaked lock never hangs a command forever, and it is
/// generous because the holder can be a native compile or a full Home swap.
const sanadDevFileLockTimeout = Duration(minutes: 15);

/// Runs [action] while holding [mode] on [lockFile].
///
/// The lock is an OS advisory lock, so two *processes* cooperate. POSIX record
/// locks belong to the process rather than to an open file description, so two
/// callers inside one isolate would both "acquire" it; pair this with
/// [sanadDevWithProcessLock] whenever in-process concurrency is possible.
Future<T> sanadDevWithFileLock<T>(
  File lockFile,
  FileLock mode,
  Future<T> Function() action, {
  Duration timeout = sanadDevFileLockTimeout,
  String timeoutMessage =
      'Timed out waiting for the Sanad development file lock.',
}) async {
  await lockFile.create(recursive: true);
  final randomAccess = await lockFile.open(
    mode: mode == FileLock.shared ? FileMode.read : FileMode.append,
  );
  try {
    await _acquireLock(randomAccess, mode, timeout, timeoutMessage);
    return await action();
  } finally {
    try {
      await randomAccess.unlock();
    } on Object {
      // The lock is released by closing the handle even if unlock fails.
    }
    await randomAccess.close();
  }
}

/// Acquires [mode] without blocking the event loop.
///
/// The lock is retried instead of taken blocking, so a second waiter in the same
/// isolate keeps the event loop alive for the holder's own asynchronous work.
Future<void> _acquireLock(
  RandomAccessFile handle,
  FileLock mode,
  Duration timeout,
  String timeoutMessage,
) async {
  final deadline = DateTime.now().add(timeout);
  while (true) {
    try {
      await handle.lock(mode);
      return;
    } on FileSystemException {
      if (!DateTime.now().isBefore(deadline)) {
        throw StateError(timeoutMessage);
      }
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  }
}

final Map<String, Future<void>> _processLocks = {};

/// Serializes callers inside this process before they touch an OS file lock.
///
/// Chaining futures keeps two in-process callers ordered without blocking the
/// isolate that the first holder's own asynchronous work depends on.
Future<T> sanadDevWithProcessLock<T>(
  String key,
  Future<T> Function() action,
) {
  final previous = _processLocks[key] ?? Future<void>.value();
  final gate = Completer<void>();
  _processLocks[key] = gate.future;
  return previous
      .then((_) => action())
      .whenComplete(() {
        gate.complete();
        if (identical(_processLocks[key], gate.future)) {
          _processLocks.remove(key);
        }
      });
}
