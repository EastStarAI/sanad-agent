import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/runtime_ownership.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad-runtime-owner-');
    setSanadHomeOverride(home.path);
    setSanadStateHomeOverride(home.path);
    await SanadHomeBootstrap.prepareAll();
  });

  tearDown(() async {
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    if (await home.exists()) {
      await home.delete(recursive: true);
    }
  });

  test(
    'rejects a second process and releases ownership deterministically',
    () async {
      final packageLibrary = await Isolate.resolvePackageUri(
        Uri.parse('package:sanad_agent/core/constants.dart'),
      );
      if (packageLibrary == null) {
        fail('Could not resolve the sanad_agent package root.');
      }
      final packageRoot = File.fromUri(packageLibrary).parent.parent.parent;
      final helperPath = packageRoot.uri
          .resolve('test/core/sanad_home/runtime_lock_holder.dart')
          .toFilePath();
      final holder = await Process.start(
        Platform.resolvedExecutable,
        [helperPath, home.path],
        workingDirectory: packageRoot.path,
        environment: <String, String>{
          ...Platform.environment,
          'SANAD_HOME': home.path,
          'SANAD_STATE_HOME': home.path,
        },
      );
      final helperStderr = StringBuffer();
      final stderrSubscription = holder.stderr
          .transform(utf8.decoder)
          .listen(helperStderr.write);

      try {
        late final String ready;
        try {
          ready = await holder.stdout
              .transform(utf8.decoder)
              .transform(const LineSplitter())
              .first
              .timeout(const Duration(seconds: 10));
        } on StateError {
          final exitCode = await holder.exitCode.timeout(
            const Duration(seconds: 10),
          );
          fail(
            'Runtime lock helper exited before readiness '
            '(exit $exitCode): ${helperStderr.toString().trim()}',
          );
        }
        expect(ready, 'locked');

        await expectLater(
          SanadRuntimeOwnership.acquire(
            timeout: const Duration(milliseconds: 50),
          ),
          throwsA(isA<SanadRuntimeOwnershipConflict>()),
        );

        holder.stdin.writeln('release');
        await holder.stdin.flush();
        expect(await holder.exitCode.timeout(const Duration(seconds: 10)), 0);

        final lease = await SanadRuntimeOwnership.acquire();
        expect(lease.isReleased, isFalse);
        await lease.release();
        expect(lease.isReleased, isTrue);
      } finally {
        holder.kill();
        await stderrSubscription.cancel();
      }
    },
  );
}
