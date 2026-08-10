import 'dart:async';
import 'dart:io';

import 'package:sanad_auth_lock/sanad_auth_lock.dart';
import 'package:test/test.dart';

void main() {
  late Directory home;

  setUp(() async {
    home = await Directory.systemTemp.createTemp('sanad_auth_lock_test_');
  });

  tearDown(() async {
    if (await home.exists()) await home.delete(recursive: true);
  });

  test('serializes concurrent work inside one isolate', () async {
    final firstEntered = Completer<void>();
    final releaseFirst = Completer<void>();
    var secondEntered = false;

    final first = NativeAuthFileLock(home.path).runExclusive(() async {
      firstEntered.complete();
      await releaseFirst.future;
    });
    await firstEntered.future;
    final second = NativeAuthFileLock(home.path).runExclusive(() async {
      secondEntered = true;
    });

    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(secondEntered, isFalse);
    releaseFirst.complete();
    await Future.wait([first, second]);
    expect(secondEntered, isTrue);
  });

  test('serializes independent native processes', () async {
    final ready = File('${home.path}${Platform.pathSeparator}holder.ready');
    final release = File('${home.path}${Platform.pathSeparator}holder.release');
    final holder = await Process.start(Platform.resolvedExecutable, [
      '--packages=.dart_tool/package_config.json',
      'tool/auth_lock_holder.dart',
      home.path,
      ready.path,
      release.path,
    ], workingDirectory: Directory.current.path);
    addTearDown(() async {
      if (await holder.exitCode.timeout(
            const Duration(milliseconds: 10),
            onTimeout: () => -1,
          ) ==
          -1) {
        holder.kill();
      }
    });

    for (var attempt = 0; attempt < 100 && !await ready.exists(); attempt++) {
      await Future<void>.delayed(const Duration(milliseconds: 10));
    }
    expect(await ready.exists(), isTrue);

    var secondEntered = false;
    final second = NativeAuthFileLock(home.path).runExclusive(() async {
      secondEntered = true;
    });
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(secondEntered, isFalse);

    await release.writeAsString('release', flush: true);
    await second;
    expect(await holder.exitCode, 0);
    expect(secondEntered, isTrue);
  });

  test('releases the operating-system lock after an exception', () async {
    final firstLock = NativeAuthFileLock(home.path);
    final secondLock = NativeAuthFileLock(home.path);

    await expectLater(
      firstLock.runExclusive<void>(() async => throw StateError('failure')),
      throwsStateError,
    );

    var entered = false;
    await secondLock.runExclusive(() async {
      entered = true;
    });
    expect(entered, isTrue);
  });

  test('creates a stable owner-only lock file on Unix', () async {
    final lock = NativeAuthFileLock(home.path);
    await lock.runExclusive(() async {});

    final file = File(
      '${home.path}${Platform.pathSeparator}${NativeAuthFileLock.fileName}',
    );
    expect(await file.exists(), isTrue);
    if (!Platform.isWindows) {
      final mode = (await file.stat()).mode & 0x1ff;
      expect(mode, 0x180); // 0600
    }
  });
}
