import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('Windows PowerShell bootstrap', () {
    late Directory fixture;
    late Directory fakeBin;
    late Directory userBin;
    late File calls;

    setUp(() async {
      fixture = await Directory.systemTemp.createTemp('sanad-win-bootstrap-');
      fakeBin = Directory('${fixture.path}${Platform.pathSeparator}fake-bin');
      userBin = Directory('${fixture.path}${Platform.pathSeparator}user-bin');
      await fakeBin.create();
      await userBin.create();
      calls = File('${fixture.path}${Platform.pathSeparator}calls.log');

      for (final path in [
        'scripts/sanad_dev/lib',
        'release/contract',
        'agent',
        'client',
      ]) {
        await Directory(
          '${fixture.path}${Platform.pathSeparator}$path',
        ).create(recursive: true);
      }
      await File(
        '${fixture.path}${Platform.pathSeparator}.fvmrc',
      ).writeAsString('{"flutter":"3.41.9"}');
      await File(
        '${fixture.path}${Platform.pathSeparator}release${Platform.pathSeparator}contract${Platform.pathSeparator}pubspec.lock',
      ).writeAsString('contract-lock');
      await File(
        '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad_dev${Platform.pathSeparator}pubspec.yaml',
      ).writeAsString('name: sanad_dev');
      await File(
        '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad_dev${Platform.pathSeparator}pubspec.lock',
      ).writeAsString('sanad-dev-lock');
      await File(
        '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad_dev${Platform.pathSeparator}lib${Platform.pathSeparator}sanad_dev_cli.dart',
      ).writeAsString('void main() {}');
      await File(
        '${fixture.path}${Platform.pathSeparator}agent${Platform.pathSeparator}pubspec.lock',
      ).writeAsString('agent-lock');
      await File(
        '${fixture.path}${Platform.pathSeparator}client${Platform.pathSeparator}pubspec.lock',
      ).writeAsString('client-lock');
      await File(
        '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad_dev.dart',
      ).writeAsString('');

      if (Platform.isWindows) {
        await File(
          '${fakeBin.path}${Platform.pathSeparator}fvm.cmd',
        ).writeAsString('''@echo off
if "%1"=="spawn" (
  if exist .fake-fvm-installed exit /b 0
  exit /b 1
)
if not "%FAIL_STAGE%"=="" (
  echo %CD% | findstr /i "%FAIL_STAGE%" >nul
  if not errorlevel 1 exit /b 42
)
echo %CD%^|%*>>"${calls.path}"
if "%1"=="dart" if "%2"=="run" if "%3"=="tool/ensure_native_stt.dart" (
  if "%FAIL_DICTATION%"=="busy" (
    echo native_stt_result=busy
    echo native_stt_stage=inspect
    exit /b 0
  )
  if not "%FAIL_DICTATION%"=="" (
    echo cmake is not installed
    echo native_stt_stage=build
    echo native_stt_result=failed
    echo native_stt_failure=prerequisite_missing
    exit /b 2
  )
  echo native_stt_stage=ready
  echo native_stt_result=ready
  exit /b 0
)
if "%1"=="install" type nul > .fake-fvm-installed
if "%1"=="dart" if "%2"=="pub" (
  mkdir .dart_tool 2>nul
  echo {}> .dart_tool\\package_config.json
)
if "%1"=="flutter" if "%2"=="pub" (
  mkdir .dart_tool 2>nul
  echo {}> .dart_tool\\package_config.json
)
if "%1"=="dart" if "%2"=="compile" type nul > "%6"
''');
        await File(
          '${fakeBin.path}${Platform.pathSeparator}Get-FileHash.ps1',
        ).writeAsString(r'''
param([string] $Algorithm, [string] $Path)
[pscustomobject]@{ Hash = 'fixture-hash' }
''');
        final powershellWrapper =
            (await File('../sanad-dev.ps1').readAsString()).replaceAll(
              r'Ensure-UserBinPath $binRoot',
              '# Test fixture suppresses user PATH persistence.',
            );
        await File(
          '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev.ps1',
        ).writeAsString(powershellWrapper);
      }
    });

    tearDown(() async {
      if (await fixture.exists()) await fixture.delete(recursive: true);
    });

    /// The durable preparation log of the fixture checkout.
    File preparationLog() => File(
      '${fixture.path}${Platform.pathSeparator}agent'
      '${Platform.pathSeparator}native'
      '${Platform.pathSeparator}.stt-prepare.log',
    );

    Future<ProcessResult> runBootstrap(
      List<String> arguments, {
      Map<String, String> environment = const {},
    }) {
      final executable = Platform.environment['SystemRoot'] == null
          ? 'powershell.exe'
          : '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
      return Process.run(
        executable,
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev.ps1',
          ...arguments,
        ],
        workingDirectory: fixture.path,
        environment: {
          ...Platform.environment,
          'PATH': '${fakeBin.path};${Platform.environment['PATH']}',
          'LOCALAPPDATA': fixture.path,
          ...environment,
        },
      );
    }

    test('no arguments shows help without mutation', () async {
      final result = await runBootstrap(const []);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('Official source run:'));
      expect(result.stdout, contains('sanad-dev run'));
      expect(await calls.exists(), isFalse);
      final shim = File(
        '${fixture.path}${Platform.pathSeparator}SanadDev${Platform.pathSeparator}bin${Platform.pathSeparator}sanad-dev.cmd',
      );
      expect(shim.existsSync(), isFalse);
    });

    test(
      'install prepares tools and shim without package setup or run',
      () async {
        final result = await runBootstrap(const ['install']);

        expect(
          result.exitCode,
          0,
          reason: '${result.stdout}\n${result.stderr}',
        );
        final invocations = await calls.exists()
            ? await calls.readAsLines()
            : const <String>[];
        expect(invocations, hasLength(1));
        expect(invocations.single, contains('install 3.41.9'));
        final shim = File(
          '${fixture.path}${Platform.pathSeparator}SanadDev${Platform.pathSeparator}bin${Platform.pathSeparator}sanad-dev.cmd',
        );
        expect(shim.existsSync(), isTrue);
      },
    );

    test('checkout collision fails unless force is explicit', () async {
      final binDir = Directory(
        '${fixture.path}${Platform.pathSeparator}SanadDev${Platform.pathSeparator}bin',
      );
      await binDir.create(recursive: true);
      final shim = File('${binDir.path}${Platform.pathSeparator}sanad-dev.cmd');
      await shim.writeAsString('@echo foreign checkout');

      final rejected = await runBootstrap(const ['install']);
      expect(rejected.exitCode, isNonZero);
      expect(rejected.stderr, contains('another checkout'));

      final forced = await runBootstrap(const ['install', '--force']);
      expect(forced.exitCode, 0, reason: '${forced.stdout}\n${forced.stderr}');
      expect(
        await shim.readAsString(),
        contains(
          '${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev.ps1',
        ),
      );
    });

    test('failed stage blocks dependent setup and runtime launch', () async {
      final result = await runBootstrap(
        const ['setup'],
        environment: const {'FAIL_STAGE': 'release'},
      );

      expect(result.exitCode, isNonZero);
      expect(result.stderr, contains('failed with exit code 42'));
      final invocations = await calls.exists()
          ? await calls.readAsLines()
          : const <String>[];
      expect(
        invocations.any((line) => line.contains('client|flutter pub get')),
        isFalse,
      );
      expect(
        invocations.any((line) => line.contains('dart compile exe')),
        isFalse,
      );
    });

    test(
      'non-run runtime command directs missing prepared state to setup',
      () async {
        final result = await runBootstrap(const ['status']);

        expect(result.exitCode, isNonZero);
        expect(result.stderr, contains('sanad-dev setup'));
        expect(await calls.exists(), isFalse);
      },
    );

    test('fresh setup prepares native dictation through the acquisition tool',
        () async {
      final result = await runBootstrap(const ['setup']);

      expect(result.exitCode, 0, reason: '${result.stdout}\\n${result.stderr}');
      final invocations = await calls.readAsLines();
      expect(
        invocations.last,
        contains(
          'agent|dart run tool/ensure_native_stt.dart',
        ),
      );
      expect(result.stdout, contains('Preparing native dictation'));
      // `setup` reads the tool's own machine keys, so a stage that prepared
      // nothing can never be reported as ready.
      expect(result.stdout, contains('ready ('));
      expect(
        await preparationLog().readAsString(),
        contains('native_stt_result=ready'),
      );
    });

    test('a busy preparation is reported as already running, not ready',
        () async {
      // Another attempt holds the claim: `setup` did not prepare anything, so
      // reporting ready would send the user back to a missing runtime.
      final result = await runBootstrap(
        const ['setup'],
        environment: const {'FAIL_DICTATION': 'busy'},
      );

      expect(result.exitCode, 0, reason: '${result.stdout}\\n${result.stderr}');
      expect(result.stdout, contains('already running'));
      expect(
        result.stdout,
        isNot(contains('Dictation is unavailable')),
        reason: 'a concurrent attempt is not a failure of this checkout',
      );
    });

    test('a failed dictation preparation never fails setup', () async {
      // Dictation is optional: the Agent must keep installing and starting even
      // when the native runtime cannot be acquired. On Windows that means the
      // failed stage is reported with its durable log, never discarded to NUL.
      final result = await runBootstrap(
        const ['setup'],
        environment: const {'FAIL_DICTATION': '1'},
      );

      expect(result.exitCode, 0, reason: '${result.stdout}\\n${result.stderr}');
      expect(result.stdout, contains('Preparing native dictation'));
      expect(
        result.stdout,
        contains('Dictation is unavailable; the Agent runs without it.'),
      );
      expect(result.stdout, contains('agent/native/.stt-prepare.log'));
      expect(result.stdout, contains('retry: sanad-dev setup'));
      // The log is the durable evidence, so the test reads what is in it rather
      // than only checking that the file was created.
      final log = await preparationLog().readAsString();
      expect(log, contains('cmake is not installed'));
      expect(log, contains('native_stt_stage=build'));
      expect(log, contains('native_stt_result=failed'));
      expect(log, contains('native_stt_failure=prerequisite_missing'));
      // The failing lines are echoed on the terminal, not buried in the log.
      expect(result.stdout, contains('cmake is not installed'));
    });

    test('a failed dictation preparation never fails setup', () async {
      // Dictation is optional: the Agent must keep installing and starting even
      // when the native runtime cannot be acquired. On Windows that means the
      // failed stage is reported with its durable log, never discarded to NUL.
      final result = await runBootstrap(
        const ['setup'],
        environment: const {'FAIL_DICTATION': '1'},
      );

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(result.stdout, contains('Preparing native dictation'));
      expect(
        result.stdout,
        contains('Dictation is unavailable; the Agent runs without it.'),
      );
      expect(result.stdout, contains('agent/native/.stt-prepare.log'));
      expect(result.stdout, contains('retry: sanad-dev setup'));
      expect(
        File(
          '${fixture.path}${Platform.pathSeparator}agent'
          '${Platform.pathSeparator}native'
          '${Platform.pathSeparator}.stt-prepare.log',
        ).existsSync(),
        isTrue,
        reason: 'the preparation log is written, never redirected to NUL',
      );
    });

    test('incremental setup skips ready tools and packages', () async {
      final first = await runBootstrap(const ['setup']);
      expect(first.exitCode, 0, reason: '${first.stdout}\n${first.stderr}');
      final invocations = await calls.readAsLines();
      expect(
        invocations.any((line) => line.contains('install 3.41.9')),
        isTrue,
      );
      expect(
        invocations.any(
          (line) =>
              line.contains('release/contract|dart pub get') ||
              line.contains('release\\contract|dart pub get'),
        ),
        isTrue,
      );

      await calls.writeAsString('');
      final second = await runBootstrap(const ['setup']);
      expect(second.exitCode, 0, reason: '${second.stdout}\n${second.stderr}');
      // Only the dictation stage runs again: install, dependency resolution,
      // and the runtime compile are idempotent and silent when current.
      final secondInvocations = await calls.readAsLines();
      expect(secondInvocations, hasLength(1));
      expect(
        secondInvocations.single,
        contains('tool/ensure_native_stt.dart'),
      );
    });

    test('foreign wrapper preserves existing checkout shim', () async {
      final binDir = Directory(
        '${fixture.path}${Platform.pathSeparator}SanadDev${Platform.pathSeparator}bin',
      );
      await binDir.create(recursive: true);
      final shim = File('${binDir.path}${Platform.pathSeparator}sanad-dev.cmd');
      final foreignCheckout = Directory(
        '${fixture.path}${Platform.pathSeparator}other-checkout',
      );
      await foreignCheckout.create();
      final foreignWrapper = File(
        '${foreignCheckout.path}${Platform.pathSeparator}sanad-dev.ps1',
      );
      await foreignWrapper.writeAsString("Write-Output 'foreign checkout'");
      final expected =
          '@echo off\r\npowershell -NoProfile -ExecutionPolicy Bypass -File "${foreignWrapper.path}" %*\r\n';
      await shim.writeAsString(expected);

      final result = await runBootstrap(const ['setup']);
      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(await shim.readAsString(), expected);
    });

    test(
      'content-addressed artifact reuse handles locked active artifact',
      () async {
        final setupResult = await runBootstrap(const ['setup']);
        expect(setupResult.exitCode, 0);

        final artifactDir = Directory(
          '${fixture.path}${Platform.pathSeparator}.dart_tool${Platform.pathSeparator}sanad-dev',
        );
        final runtimeArtifacts = artifactDir
            .listSync()
            .whereType<File>()
            .where(
              (f) =>
                  f.path.contains('sanad-dev-runtime-') &&
                  f.path.endsWith('.exe'),
            )
            .toList();
        expect(runtimeArtifacts, hasLength(1));

        final staleArtifact = File(
          '${artifactDir.path}${Platform.pathSeparator}sanad-dev-runtime-stale.exe',
        );
        await staleArtifact.writeAsString('stale-exe');
        final lockedArtifact = await staleArtifact.open(mode: FileMode.append);
        await lockedArtifact.lock(FileLock.exclusive);
        try {
          final secondSetup = await runBootstrap(const ['setup']);
          expect(
            secondSetup.exitCode,
            0,
            reason: '${secondSetup.stdout}\n${secondSetup.stderr}',
          );
          expect(staleArtifact.existsSync(), isTrue);
        } finally {
          await lockedArtifact.unlock();
          await lockedArtifact.close();
        }
      },
    );
  }, skip: !Platform.isWindows);
}
