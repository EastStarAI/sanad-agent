import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_dev/sanad_dev_cli.dart' as sanad_dev;

/// The native runner layout is `native/<platform>-<architecture>/`, and the
/// acquisition tool is the single owner of download, build, and verification.
/// These tests prove the launcher's contract around it: it never repeats an
/// attempt that is already running, it keeps one bounded durable log, and a
/// failure is a typed diagnostic instead of a silent dead end.
void main() {
  late Directory temporaryDirectory;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp(
      'sanad-dev-native-probe-',
    );
  });

  tearDown(() async {
    if (!temporaryDirectory.existsSync()) return;
    // A detached attempt closes its own handle, so the deletion can race it.
    for (var attempt = 0; attempt < 5; attempt++) {
      try {
        await temporaryDirectory.delete(recursive: true);
        return;
      } on FileSystemException {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      }
    }
  });

  String shimName() {
    if (Platform.isMacOS) return 'libsanad_whisper.dylib';
    if (Platform.isWindows) return 'sanad_whisper.dll';
    return 'libsanad_whisper.so';
  }

  Directory nativeDirectory() =>
      Directory('${temporaryDirectory.path}/native');

  File preparingMarker() =>
      File('${nativeDirectory().path}/${sanad_dev.nativeSttPreparingMarkerName}');

  File preparationLog() =>
      File(sanad_dev.nativeSttLogPath(temporaryDirectory.path));

  /// A runner that records every request and answers with [run].
  ({List<sanad_dev.NativeSttPreparationRequest> requests, sanad_dev.NativeSttPreparationRunner runner})
  runnerReturning(sanad_dev.NativeSttPreparationRun run) {
    final requests = <sanad_dev.NativeSttPreparationRequest>[];
    return (
      requests: requests,
      runner: (request) async {
        requests.add(request);
        return run;
      },
    );
  }

  group('native runtime tag', () {
    test('every supported pair resolves to a qualified directory', () {
      for (final os in ['macos', 'linux', 'windows']) {
        for (final architecture in ['arm64', 'x64']) {
          expect(
            sanad_dev.nativeRuntimeTag(
              operatingSystem: os,
              architecture: architecture,
            ),
            '$os-$architecture',
          );
        }
      }
    });

    test('an unknown host pair stays unqualified instead of guessing', () {
      expect(
        sanad_dev.nativeRuntimeTag(
          operatingSystem: 'freebsd',
          architecture: 'arm64',
        ),
        isNull,
      );
      expect(
        sanad_dev.nativeRuntimeTag(
          operatingSystem: 'macos',
          architecture: 'mips',
        ),
        isNull,
      );
    });
  });

  group('prepare probe', () {
    test('a qualified runtime means nothing is started', () async {
      final tag = sanad_dev.nativeRuntimeTag()!;
      final directory = Directory('${nativeDirectory().path}/$tag');
      await directory.create(recursive: true);
      await File('${directory.path}/${shimName()}').writeAsString('stub');

      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(exitCode: 0),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );

      expect(preparation.state, sanad_dev.NativeSttPreparationState.ready);
      expect(preparation.completion, isNull);
      expect(fake.requests, isEmpty);
    });

    test('a missing runtime starts one attempt against the durable log',
        () async {
      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(exitCode: 0),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );
      await preparation.completion;

      expect(preparation.state, sanad_dev.NativeSttPreparationState.started);
      expect(preparation.tag, sanad_dev.nativeRuntimeTag());
      expect(fake.requests, hasLength(1));
      // The attempt writes a file, never `NUL`: the log is the only record a
      // failed Windows preparation can leave behind.
      expect(
        fake.requests.single.logPath,
        endsWith('native/${sanad_dev.nativeSttLogFileName}'),
      );
      expect(
        fake.requests.single.agentDirectory,
        temporaryDirectory.path,
      );
      expect(
        sanad_dev.nativeSttLogDisplayPath(),
        'agent/native/${sanad_dev.nativeSttLogFileName}',
      );
    });

    test('an attempt already running is never repeated', () async {
      // The marker is what `tool/ensure_native_stt.dart` writes, and the daemon
      // reads it for `native_runtime_preparing`. A `run` while it is fresh must
      // start nothing: two attempts staging the same directory corrupt both.
      await nativeDirectory().create(recursive: true);
      await preparingMarker().writeAsString('2026-01-01T00:00:00Z');

      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(exitCode: 0),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );

      expect(preparation.state, sanad_dev.NativeSttPreparationState.inProgress);
      expect(preparation.completion, isNull);
      expect(fake.requests, isEmpty);
    });

    test('a stale marker expires instead of blocking a new attempt', () async {
      await nativeDirectory().create(recursive: true);
      await preparingMarker().writeAsString('2026-01-01T00:00:00Z');

      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(exitCode: 0),
      );
      final stale = DateTime.now().add(
        sanad_dev.nativeSttAttemptMaxAge + const Duration(minutes: 1),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
        now: stale,
      );
      await preparation.completion;

      expect(preparation.state, sanad_dev.NativeSttPreparationState.started);
      expect(fake.requests, hasLength(1));
    });

    test('a typed failure is reported once and kept in the log', () async {
      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(
          exitCode: 2,
          tail: [
            'native stt missing for windows-x64 in native/windows-x64: '
                'sanad_whisper.dll',
            'cmake is not installed',
            'native_stt_stage=build',
            'native_stt_result=failed',
            'native_stt_failure=prerequisite_missing',
          ],
        ),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );
      await preparation.completion;

      final log = await preparationLog().readAsString();
      expect(
        log,
        contains(
          'native dictation preparation failed at build '
          '(prerequisite_missing)',
        ),
      );
      expect(log, contains('retry: sanad-dev setup'));
    });

    test('a ready attempt is recorded as ready', () async {
      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(
          exitCode: 0,
          tail: ['native_stt_stage=ready', 'native_stt_result=ready'],
        ),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );
      await preparation.completion;

      final log = await preparationLog().readAsString();
      expect(log, contains('native dictation runtime is ready'));
    });

    test('a failing runner never throws at the caller', () async {
      // Dictation is the only thing a missing runtime takes away: the launcher
      // still starts the daemon and the Client, and readiness reports why.
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: (request) async => throw const ProcessException('fvm', ['dart']),
      );

      expect(preparation.state, sanad_dev.NativeSttPreparationState.started);
      await preparation.completion;
    });

    test('a busy attempt is reported as busy, never as ready', () async {
      // `sanad-dev setup` reaching a claim held by another attempt must not say
      // "ready": nothing was prepared and the runtime may still be missing.
      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(
          exitCode: 0,
          tail: ['native_stt_result=busy', 'native_stt_stage=inspect'],
        ),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );
      await preparation.completion;

      final log = await preparationLog().readAsString();
      expect(log, contains('another attempt was already running'));
      expect(log, isNot(contains('is ready')));
    });

    test('an abandoned claim is cleared instead of blocking the next run',
        () async {
      // A killed launcher leaves a fresh marker whose owner is gone. Reporting
      // "already running" for the full window would be a lie, and the tool that
      // could repair it would never be started.
      await nativeDirectory().create(recursive: true);
      await preparingMarker().writeAsString('2147483647');

      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(exitCode: 0),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );
      await preparation.completion;

      expect(preparation.state, sanad_dev.NativeSttPreparationState.started);
      expect(fake.requests, hasLength(1));
      expect(preparingMarker().existsSync(), isFalse);
    });

    test('a claim whose owner is alive still blocks a second attempt', () async {
      // The marker body is the owner's pid, so a live owner is never mistaken
      // for a killed attempt.
      await nativeDirectory().create(recursive: true);
      await preparingMarker().writeAsString('$pid');

      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(exitCode: 0),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );

      expect(preparation.state, sanad_dev.NativeSttPreparationState.inProgress);
      expect(fake.requests, isEmpty);
    });

    test('an oversized log is bounded before the next attempt', () async {
      await nativeDirectory().create(recursive: true);
      await preparationLog().writeAsString('build noise\n' * 120000);
      expect(await preparationLog().length(), greaterThan(
        sanad_dev.nativeSttLogLimitBytes,
      ));

      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(exitCode: 0),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );
      await preparation.completion;

      final log = await preparationLog().readAsString();
      expect(log, contains('log reset'));
      expect(log, isNot(contains('build noise')));
      expect(await preparationLog().length(), lessThan(
        sanad_dev.nativeSttLogLimitBytes,
      ));
    });

    test('the unqualified macOS directory is only a bounded legacy alias',
        () async {
      // A foreign architecture's unqualified slice must never be treated as this
      // host's runtime: only Apple Silicon ever shipped one.
      final tag = sanad_dev.nativeRuntimeTag()!;
      final legacy = Directory('${nativeDirectory().path}/macos');
      await legacy.create(recursive: true);
      await File('${legacy.path}/${shimName()}').writeAsString('stub');

      final fake = runnerReturning(
        const sanad_dev.NativeSttPreparationRun(exitCode: 0),
      );
      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        runner: fake.runner,
      );
      await preparation.completion;

      if (tag == 'macos-arm64') {
        expect(fake.requests, isEmpty);
      } else {
        expect(fake.requests, hasLength(1));
      }
    });
  });

  // The real spawn path: a fake `fvm` stands in for the tool, so these tests
  // cover the code a launcher actually runs instead of only the injected seam.
  group('detached attempt', () {
    late Directory fakeBin;

    setUp(() async {
      fakeBin = Directory('${temporaryDirectory.path}/fake-bin');
      await fakeBin.create(recursive: true);
    });

    /// A fake FVM that behaves like the acquisition tool.
    Future<String> fakeFvm({String body = ''}) async {
      if (Platform.isWindows) {
        final file = File('${fakeBin.path}/fvm.cmd');
        await file.writeAsString('@echo off\r\n$body\r\n');
        return file.path;
      }
      final file = File('${fakeBin.path}/fvm');
      await file.writeAsString('#!/bin/sh\n$body\n');
      await Process.run('chmod', ['+x', file.path]);
      return file.path;
    }

    test('the attempt is detached and streams into the durable log', () async {
      // Detached ownership is the whole point: an attached child either dies
      // with the launcher or holds it open for the length of a build. The shell
      // owns the log, so the output survives this process.
      final fvm = await fakeFvm(
        body: 'echo native_stt_stage=ready\n'
            'echo native_stt_result=ready\n',
      );

      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        fvmExecutable: fvm,
      );
      await preparation.completion;

      expect(preparation.state, sanad_dev.NativeSttPreparationState.started);
      // The launcher reports that it started the attempt, not a verdict it
      // cannot observe.
      final log = await waitForLog(preparation.logPath, 'native_stt_result=');
      expect(log, contains('native_stt_result=ready'));
      expect(log, contains('attempt started detached'));
      expect(log, isNot(contains('✓ Native dictation runtime is ready')));
    });

    test('a fake tool that only exits is reported as a failed attempt',
        () async {
      // No machine keys means no verdict: the launcher must not guess success
      // from a zero exit status it never saw.
      final fvm = await fakeFvm(body: 'exit 0');

      final preparation = await sanad_dev.prepareNativeDictation(
        temporaryDirectory.path,
        fvmExecutable: fvm,
      );
      await preparation.completion;

      final log = await preparationLog().readAsString();
      expect(log, contains('preparing ${sanad_dev.nativeRuntimeTag()}'));
      expect(log, isNot(contains('is ready')));
    });
  });
}

/// Waits until [needle] appears in the file at [path], then returns the content.
///
/// A detached attempt writes through the shell, so the only way to observe it is
/// to watch the same durable log a developer would read.
Future<String> waitForLog(
  String path,
  String needle, {
  int attempts = 100,
}) async {
  for (var attempt = 0; attempt < attempts; attempt++) {
    final file = File(path);
    if (file.existsSync()) {
      final content = await file.readAsString();
      if (content.contains(needle)) return content;
    }
    await Future<void>.delayed(const Duration(milliseconds: 100));
  }
  throw StateError('"$needle" never appeared in $path');
}
