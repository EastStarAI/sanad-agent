part of '../../../sanad_dev_cli.dart';

/// `sanad-dev cli path agent|client` and
/// `sanad-dev cli agent|client -- <args>`.
///
/// Both forms use the per-SHA cached native artifact below
/// `<worktree>/.sanad-dev/bin/<sha>/` and rebuild it only when the component
/// sources changed. `path` prints the artifact path and the build result;
/// the run form forwards every argument after `--` and reports the call time.
Future<void> handleCompiledCliCommand(
  List<String> arguments, {
  String? sanadHomePath,
  void Function(String message)? printMessage,
  void Function(String message)? printError,
  Future<CompiledCliArtifact> Function(
    CompiledCliComponent component, {
    bool force,
    void Function(String message)? log,
  })?
  ensureArtifact,
  Future<int> Function(String executable, List<String> arguments)? runArtifact,
  void Function(int code)? setExitCode,
}) async {
  final log = printMessage ?? print;
  final logError = printError ?? stderr.writeln;
  // The exit status is injected so tests can assert it without touching
  // `dart:io`'s process-global [exitCode], which parallel suites share.
  final assignExitCode = setExitCode ?? _assignProcessExitCode;
  final runtime = await _currentRuntime(sanadHomePath: sanadHomePath);
  final cache = CompiledCliCache(
    workspaceRoot: runtime.workspaceRoot,
    repositoryRoot: runtime.repositoryRoot,
  );
  final ensure =
      ensureArtifact ??
      (component, {bool force = false, void Function(String)? log}) =>
          cache.ensure(component, force: force, log: log);
  final requested = arguments.isEmpty ? '' : arguments.first.toLowerCase();
  final isPathForm = requested == 'path';
  final componentName = isPathForm
      ? (arguments.length > 1 ? arguments[1].toLowerCase() : '')
      : requested;
  final component = CompiledCliComponent.parse(componentName);
  if (component == null) {
    logError(
      'Usage: sanad-dev cli path agent|client | '
      'sanad-dev cli agent|client -- <args>',
    );
    assignExitCode(64);
    return;
  }
  final separator = arguments.indexOf('--');  final forwarded = separator >= 0
      ? arguments.sublist(separator + 1)
      : (isPathForm ? const <String>[] : arguments.skip(1).toList());
  final artifact = await ensure(component, log: log);
  log(
    '${component.name} CLI: ${artifact.executablePath} '
    '(sha=${artifact.cacheKey}, ${artifact.buildLabel})',
  );
  if (isPathForm) return;
  if (forwarded.isEmpty) {
    logError(
      'Nothing to run: pass the arguments after "--", for example '
      'sanad-dev cli agent -- --version',
    );
    assignExitCode(64);
    return;
  }
  final runner = runArtifact ?? _runCompiledCliArtifact;
  final stopwatch = Stopwatch()..start();
  final int childExitCode;
  if (ensureArtifact == null && runArtifact == null) {
    // The shared cache lock only has to cover launching the artifact: a rebuild
    // publishes into a new `<sha>/` directory and never rewrites the binary this
    // child already started, so holding the lock for the whole child run would
    // block every rebuild for as long as the session lives.
    childExitCode = await runCompiledCliArtifactUnderCacheLock(
      cache,
      component,
      artifact.executablePath,
      forwarded,
    );
  } else {
    // Injected runners are in-process seams and take no lock.
    childExitCode = await runner(artifact.executablePath, forwarded);
  }
  stopwatch.stop();
  stderr.writeln(
    '[sanad-dev] cli ${component.name}: call '
    '${formatCompiledCliDuration(stopwatch.elapsed)}, '
    'artifact ${artifact.buildLabel}',
  );
  if (childExitCode != 0) assignExitCode(childExitCode);
}

/// Starts the cached artifact under the shared cache lock and reports its exit
/// status.
///
/// The lock is released the moment the process has started, so a long
/// `sanad-dev cli agent -- …` run does not block a rebuild for its whole
/// lifetime. A rebuild publishes into a new commit directory and prunes older
/// ones without touching the inode this child already exec'd.
Future<int> runCompiledCliArtifactUnderCacheLock(
  CompiledCliCache cache,
  CompiledCliComponent component,
  String executable,
  List<String> arguments, {
  Future<Process> Function(String executable, List<String> arguments)?
  startProcess,
}) async {
  final start = startProcess ?? _startCompiledCliArtifact;
  final started = await cache.withReadLock<Process>(
    component,
    () => start(executable, arguments),
  );
  return started.exitCode;
}

void _assignProcessExitCode(int code) => exitCode = code;

Future<Process> _startCompiledCliArtifact(
  String executable,
  List<String> arguments,
) => Process.start(
  executable,
  arguments,
  mode: ProcessStartMode.inheritStdio,
);

Future<int> _runCompiledCliArtifact(
  String executable,
  List<String> arguments,
) async {
  final process = await _startCompiledCliArtifact(executable, arguments);
  return process.exitCode;
}
