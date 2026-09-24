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
      expect(await calls.readAsString(), isEmpty);
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
