part of '../../sanad_dev_cli.dart';

/// Minimal child-process boundary so the wall-clock guard stays testable.
abstract class UiDriverChildProcess {
  Future<int> get exitCode;

  void kill();
}

class UiDriverSpawnedProcess implements UiDriverChildProcess {
  UiDriverSpawnedProcess(this._process);

  final Process _process;

  @override
  Future<int> get exitCode => _process.exitCode;

  /// Kills the whole process tree: `fvm` exits on its own signal, but the
  /// `dart` grandchild keeps running unless the tree is taken down.
  @override
  void kill() => killUiDriverProcessTree(_process.pid);
}

/// Environment variable that carries the cold artifact build cost to the
/// driver CLI, so the first JSON result can report `build_ms`.
const String uiDriverBuildMsEnvVar = 'SANAD_DEV_UI_BUILD_MS';

/// Environment for the driver child process.
///
/// The caller directory lets a batch `--file` resolve against the invoking
/// worktree, and [artifactBuild] carries the compile cost of a cold artifact so
/// the driver can report it as `build_ms` in that one JSON result. The value is
/// always replaced or removed: a stale cost inherited from a parent process must
/// never be reported for a cached artifact.
Map<String, String> uiDriverChildEnvironment({
  required String callerDir,
  Duration? artifactBuild,
  Map<String, String>? base,
}) {
  final environment = {...?base, 'SANAD_DEV_CALLER_DIR': callerDir};
  final buildMs = artifactBuild?.inMilliseconds ?? 0;
  if (buildMs > 0) {
    environment[uiDriverBuildMsEnvVar] = '$buildMs';
  } else {
    environment.remove(uiDriverBuildMsEnvVar);
  }
  return environment;
}

/// Kills [rootPid] together with every descendant process.
///
/// POSIX has no portable way to put a Dart child into its own process group, so
/// the tree is resolved from the process table and killed deepest first; Windows
/// uses `taskkill /T /F`, which is the native equivalent.
void killUiDriverProcessTree(
  int rootPid, {
  bool? isWindows,
  Map<int, int>? processTree,
}) {
  if (rootPid <= 0) return;
  if (isWindows ?? Platform.isWindows) {
    try {
      Process.runSync('taskkill', ['/PID', '$rootPid', '/T', '/F']);
    } catch (_) {}
    return;
  }
  final tree = processTree ?? readUiDriverProcessTree();
  final descendants = uiDriverDescendantPids(tree, rootPid).toList().reversed;
  for (final pid in descendants) {
    try {
      Process.killPid(pid, ProcessSignal.sigkill);
    } catch (_) {}
  }
  try {
    Process.killPid(rootPid, ProcessSignal.sigkill);
  } catch (_) {}
}

/// Snapshot of the host process table as `child pid -> parent pid`.
Map<int, int> readUiDriverProcessTree() {
  try {
    final result = Process.runSync('ps', ['-A', '-o', 'pid=,ppid=']);
    if (result.exitCode != 0) return const {};
    return parseUiDriverProcessTree(result.stdout.toString());
  } catch (_) {
    return const {};
  }
}

/// Parses `pid ppid` lines. Pure so the tree walk is testable without a host.
Map<int, int> parseUiDriverProcessTree(String psOutput) {
  final tree = <int, int>{};
  for (final line in psOutput.split('\n')) {
    final parts = line.trim().split(RegExp(r'\s+'));
    if (parts.length < 2) continue;
    final pid = int.tryParse(parts[0]);
    final parent = int.tryParse(parts[1]);
    if (pid == null || parent == null) continue;
    tree[pid] = parent;
  }
  return tree;
}

/// Every live descendant of [rootPid], deepest last.
List<int> uiDriverDescendantPids(Map<int, int> tree, int rootPid) {
  final childrenByParent = <int, List<int>>{};
  tree.forEach((pid, parent) {
    childrenByParent.putIfAbsent(parent, () => []).add(pid);
  });
  final ordered = <int>[];
  void walk(int pid) {
    for (final child in childrenByParent[pid] ?? const <int>[]) {
      walk(child);
      ordered.add(child);
    }
  }

  walk(rootPid);
  return ordered;
}

/// Runs the driver CLI compilation with its own deadline.
Future<({bool compiled, bool timedOut})> compileUiDriverArtifact({
  required String packageConfig,
  required String toolScript,
  required String workingDirectory,
  required String outputPath,
  Duration timeout = uiDriverCompileTimeout,
  bool? isWindows,
  Future<Process> Function(String executable, List<String> arguments)? spawn,
}) async {
  final windows = isWindows ?? Platform.isWindows;
  final Process process;
  try {
    process = await (spawn ??
        (String executable, List<String> arguments) => Process.start(
          executable,
          arguments,
          workingDirectory: workingDirectory,
          runInShell: windows,
        ))('fvm', [
      'dart',
      'compile',
      'exe',
      '--packages=$packageConfig',
      toolScript,
      '-o',
      outputPath,
    ]);
  } catch (_) {
    return (compiled: false, timedOut: false);
  }
  // Drain both streams so a chatty compiler can never block on a full pipe.
  final drain = [
    process.stdout.drain<void>().catchError((Object _) {}),
    process.stderr.drain<void>().catchError((Object _) {}),
  ];
  var timedOut = false;
  final code = await process.exitCode.timeout(
    timeout,
    onTimeout: () {
      timedOut = true;
      killUiDriverProcessTree(process.pid, isWindows: windows);
      return uiDriverTimeoutExitCode;
    },
  );
  await Future.wait(drain);
  return (compiled: code == 0, timedOut: timedOut);
}

