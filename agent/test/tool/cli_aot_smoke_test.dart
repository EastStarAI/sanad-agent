import 'dart:io';

import 'package:test/test.dart';

import '../../tool/cli_aot_smoke.dart';

void main() {
  late Directory root;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sanad-aot-cleanup-test-');
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  test(
    'retries transient filesystem access failures before deleting',
    () async {
      var attempts = 0;
      var waits = 0;

      await deleteDirectoryWithRetry(
        root,
        maxAttempts: 3,
        retryDelay: Duration.zero,
        delete: () async {
          attempts += 1;
          if (attempts < 3) {
            throw FileSystemException('temporary executable lock', root.path);
          }
          await root.delete(recursive: true);
        },
        wait: (_) async {
          waits += 1;
        },
      );

      expect(attempts, 3);
      expect(waits, 2);
      expect(await root.exists(), isFalse);
    },
  );

  test(
    'preserves a persistent cleanup failure after the retry bound',
    () async {
      var attempts = 0;
      var waits = 0;

      await expectLater(
        deleteDirectoryWithRetry(
          root,
          maxAttempts: 3,
          retryDelay: Duration.zero,
          delete: () {
            attempts += 1;
            throw FileSystemException('persistent executable lock', root.path);
          },
          wait: (_) async {
            waits += 1;
          },
        ),
        throwsA(isA<FileSystemException>()),
      );

      expect(attempts, 3);
      expect(waits, 2);
      expect(await root.exists(), isTrue);
    },
  );
}
