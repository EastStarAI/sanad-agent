import 'dart:io';

import 'package:test/test.dart';

import '../support/sanad_dev_bootstrap_harness.dart';

/// The prepared-runtime fingerprint must cover the same transitive input closure
/// the component cache does.
///
/// `scripts/sanad_dev` depends on `shared/public_service_endpoints` and
/// `shared/windows_path` through `path:` dependencies, and both are compiled into
/// the runtime CLI. Hashing only the package itself keeps the recorded stamp
/// matching after a `shared/` edit, so `run`, `reset`, `switch`, and `apply`
/// silently execute code the developer no longer has.
void main() {
  final harness = SanadDevBootstrapHarness();
  late File calls;

  setUp(() async {
    await harness.setUp();
    calls = harness.calls;
  });

  tearDown(() => harness.tearDown());

  Future<ProcessResult> runBootstrap(List<String> arguments) =>
      harness.run(arguments);

  test(
    'a shared path dependency edit rebuilds the prepared runtime CLI',
    () async {
      expect(
        (await runBootstrap(['setup'])).exitCode,
        0,
        reason: 'the fixture must prepare the runtime first',
      );
      final stamp = harness.runtimeStamp;
      final before = await stamp.readAsString();
      expect(before, isNotEmpty);
      await harness.sharedFile('windows_path', [
        'lib',
        'src',
        'impl.dart',
      ]).writeAsString('const revision = 2;');
      await calls.writeAsString('');

      final result = await runBootstrap(['setup']);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(
        await stamp.readAsString(),
        isNot(before),
        reason: 'a shared/ edit must change the prepared-runtime fingerprint',
      );
      final compiles = (await calls.readAsLines())
          .where((line) => line.contains('dart compile exe'))
          .toList();
      expect(
        compiles,
        hasLength(1),
        reason: 'a shared/ edit must rebuild the prepared runtime CLI',
      );
    },
  );

  test('a shared path dependency edit fails a mutating command closed', () async {
    expect((await runBootstrap(['setup'])).exitCode, 0);
    await harness.sharedFile('public_service_endpoints', [
      'lib',
      'src',
      'impl.dart',
    ]).writeAsString('const revision = 2;');
    await calls.writeAsString('');

    final result = await runBootstrap(const ['apply']);

    expect(result.exitCode, isNot(0));
    expect(
      result.stderr,
      contains('Project runtime is stale. Run: sanad-dev setup'),
      reason: 'a shared/ edit must never be executed through a stale CLI',
    );
    expect(await calls.readAsLines(), isEmpty);
  });

  test('a shared dependency that only gains a file still moves the fingerprint', () async {
    expect((await runBootstrap(['setup'])).exitCode, 0);
    final stamp = harness.runtimeStamp;
    final before = await stamp.readAsString();

    await harness.sharedFile('windows_path', [
      'lib',
      'src',
      'added.dart',
    ]).writeAsString('const added = true;');
    expect((await runBootstrap(['setup'])).exitCode, 0);

    expect(
      await stamp.readAsString(),
      isNot(before),
      reason: 'a new file in a path dependency is a new compiled input',
    );
  });
}
