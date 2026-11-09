import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// Real-CLI guards must spawn the real entrypoint, so compilation is the
/// expensive part of such a test. It happens once per suite and every case runs
/// the same kernel artifact instead of paying `dart run` compilation again on
/// slow runners (issue 339 review 2 extracted this owner from the help guard).
const cliCompileBudget = Duration(seconds: 60);

/// Upper bound for one compiled-artifact invocation.
const cliArtifactRunBudget = Duration(seconds: 45);

/// Stays above [cliCompileBudget] plus [cliArtifactRunBudget] so a slow compile
/// or a hung artifact reports its own bounded failure instead of an opaque
/// test-runner timeout.
final cliTestTimeout = Timeout(
  const Duration(seconds: 150),
);

/// The composition entry point every real-CLI suite spawns.
const String agentCliEntrypoint = 'bin/sanad_agent.dart';

/// The compiled entry point plus its invocation helpers.
///
/// [kernel] is lazy on purpose: awaiting it inside the first case keeps
/// [cliTestTimeout], while `setUpAll` inherits the default test timeout and
/// cannot declare a generous one.
class CompiledAgentCli {
  CompiledAgentCli(
    this.artifactDirectory, {
    this.entrypoint = agentCliEntrypoint,
  });

  final Directory artifactDirectory;

  /// Entry point compiled for this suite, relative to the package root.
  ///
  /// A suite that proves a different composition entry point names it here
  /// (for example the daemon), so it still compiles once per suite instead of
  /// paying `dart run` compilation per case.
  final String entrypoint;

  Future<File>? _compiled;

  Future<File> kernel() =>
      _compiled ??= _compileEntrypoint(artifactDirectory, entrypoint);

  /// Runs the compiled artifact against an isolated Sanad Home.
  ///
  /// The child inherits the suite's environment and receives both runtime roots
  /// explicitly, so it can never read or write the caller's user state. Pass
  /// [extraEnvironment] for the seams a case needs (for example the E2E mode
  /// switch), and [budget] only when the case owns a longer measured budget.
  Future<ProcessResult> run(
    List<String> arguments, {
    required Directory home,
    Directory? stateHome,
    Map<String, String> extraEnvironment = const <String, String>{},
    Duration budget = cliArtifactRunBudget,
  }) async {
    final compiled = await kernel();
    return Process.run(
      Platform.resolvedExecutable,
      [compiled.path, ...arguments],
      environment: <String, String>{
        ...Platform.environment,
        ...sanadRootsEnvironment(home, stateHome),
        ...extraEnvironment,
      },
    ).timeout(budget);
  }

  /// Runs the compiled artifact with exactly [environment] and no inherited
  /// variables, so a suite can prove what the CLI does *without* a Home.
  Future<ProcessResult> runWithEnvironment(
    List<String> arguments, {
    required Map<String, String> environment,
    Duration budget = cliArtifactRunBudget,
  }) async {
    final compiled = await kernel();
    return Process.run(
      Platform.resolvedExecutable,
      [compiled.path, ...arguments],
      environment: environment,
      includeParentEnvironment: false,
    ).timeout(budget);
  }

  /// Starts the compiled artifact like [run], streaming its output instead of
  /// collecting it, for a case that observes a process it owns.
  Future<Process> start(
    List<String> arguments, {
    required Directory home,
    Directory? stateHome,
    Map<String, String> extraEnvironment = const <String, String>{},
  }) async {
    final compiled = await kernel();
    return Process.start(
      Platform.resolvedExecutable,
      [compiled.path, ...arguments],
      environment: <String, String>{
        ...Platform.environment,
        ...sanadRootsEnvironment(home, stateHome),
        ...extraEnvironment,
      },
    );
  }
}

/// The two runtime roots a spawned Agent must be given, never inherit.
Map<String, String> sanadRootsEnvironment(
  Directory home,
  Directory? stateHome,
) {
  return <String, String>{
    'SANAD_HOME': home.path,
    'SANAD_STATE_HOME': (stateHome ?? home).path,
  };
}

Future<File> _compileEntrypoint(
  Directory artifactDirectory,
  String entrypoint,
) async {
  final kernel = File(
    p.join(
      artifactDirectory.path,
      '${p.basenameWithoutExtension(entrypoint)}.dill',
    ),
  );
  final packageRoot = await _resolvePackageRoot();
  final compilation = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'kernel',
    p.join(packageRoot.path, entrypoint),
    '-o',
    kernel.path,
  ], workingDirectory: packageRoot.path).timeout(cliCompileBudget);

  expect(
    compilation.exitCode,
    0,
    reason:
        'dart compile kernel failed:\n${compilation.stdout}\n'
        '${compilation.stderr}',
  );
  expect(kernel.existsSync(), isTrue);
  return kernel;
}

Future<Directory> _resolvePackageRoot() async {
  final configUri = await Isolate.resolvePackageUri(
    Uri.parse('package:sanad_agent/core/config.dart'),
  );
  if (configUri == null) {
    throw StateError('Unable to resolve the sanad_agent package root.');
  }
  // lib/core/config.dart -> lib -> package root.
  return File.fromUri(configUri).parent.parent.parent;
}
