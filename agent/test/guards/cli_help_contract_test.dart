import 'dart:io';
import 'dart:isolate';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

/// These guards prove real CLI startup behavior, so they must spawn the real
/// entrypoint. Compilation is the expensive part of that: it happens once for
/// the whole file, and every case runs the same kernel artifact instead of
/// paying `dart run` compilation again on slow runners. The compilation is
/// awaited inside the first case because `setUpAll` inherits the default test
/// timeout and cannot declare a generous one.
const _compileBudget = Duration(seconds: 60);

/// Upper bound for one compiled-artifact invocation.
const _artifactRunBudget = Duration(seconds: 45);

/// Stays above [_compileBudget] plus [_artifactRunBudget] so a slow compile or
/// a hung artifact reports its own bounded failure instead of an opaque
/// test-runner timeout.
const _testTimeout = Timeout(Duration(seconds: 150));

void main() {
  late Directory home;
  late Directory artifactDirectory;
  Future<File>? compiledKernel;

  setUpAll(() async {
    artifactDirectory = await Directory.systemTemp.createTemp(
      'sanad-cli-help-artifact-',
    );
  });

  tearDownAll(() async {
    try {
      await artifactDirectory.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-cli-help-');
  });

  tearDown(() async {
    try {
      await home.delete(recursive: true);
    } catch (_) {}
  });

  Future<File> kernel() => compiledKernel ??= _compileAgent(artifactDirectory);

  test('daemon help exits before bootstrap or supervisor startup', () async {
    final result = await _run(['daemon', '--help'], home, await kernel());

    expect(result.exitCode, 0);
    expect(result.stdout.toString(), contains('Usage: sanad daemon'));
    expect(result.stdout.toString(), isNot(contains('Daemon is running')));
    expect(File(p.join(home.path, '.env')).existsSync(), isFalse);
  }, timeout: _testTimeout);

  test(
    'unknown daemon arguments are rejected before supervisor startup',
    () async {
      final result = await _run(['daemon', '--unknown'], home, await kernel());

      expect(result.exitCode, 64);
      expect(result.stderr.toString(), contains('Unknown daemon argument'));
      expect(result.stdout.toString(), isNot(contains('Daemon is running')));
      expect(File(p.join(home.path, '.env')).existsSync(), isFalse);
    },
    timeout: _testTimeout,
  );

  test('service help prints usage without starting a daemon', () async {
    final result = await _run(['service', '--help'], home, await kernel());

    expect(result.exitCode, 0);
    expect(result.stdout.toString(), contains('Usage: sanad service'));
    expect(result.stdout.toString(), isNot(contains('Daemon is running')));
  }, timeout: _testTimeout);
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
  ], workingDirectory: packageRoot.path).timeout(_compileBudget);

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

Future<ProcessResult> _run(
  List<String> arguments,
  Directory home,
  File kernel,
) => Process.run(
  Platform.resolvedExecutable,
  [kernel.path, ...arguments],
  environment: {
    ...Platform.environment,
    'SANAD_HOME': home.path,
    'SANAD_STATE_HOME': home.path,
  },
).timeout(_artifactRunBudget);
