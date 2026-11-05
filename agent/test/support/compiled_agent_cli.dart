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

/// The compiled `bin/sanad_agent.dart` kernel plus its invocation helper.
///
/// [kernel] is lazy on purpose: awaiting it inside the first case keeps
/// [cliTestTimeout], while `setUpAll` inherits the default test timeout and
/// cannot declare a generous one.
class CompiledAgentCli {
  CompiledAgentCli(this.artifactDirectory);

  final Directory artifactDirectory;
  Future<File>? _compiled;

  Future<File> kernel() => _compiled ??= _compileAgent(artifactDirectory);

  /// Runs the compiled artifact against an isolated Sanad Home.
  Future<ProcessResult> run(
    List<String> arguments, {
    required Directory home,
    Directory? stateHome,
  }) async {
    final compiled = await kernel();
    return Process.run(
      Platform.resolvedExecutable,
      [compiled.path, ...arguments],
      environment: {
        ...Platform.environment,
        'SANAD_HOME': home.path,
        'SANAD_STATE_HOME': (stateHome ?? home).path,
      },
    ).timeout(cliArtifactRunBudget);
  }
}

Future<File> _compileAgent(Directory artifactDirectory) async {
  final kernel = File(p.join(artifactDirectory.path, 'sanad_agent.dill'));
  final packageRoot = await _resolvePackageRoot();
  final compilation = await Process.run(Platform.resolvedExecutable, [
    'compile',
    'kernel',
    p.join(packageRoot.path, 'bin', 'sanad_agent.dart'),
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
