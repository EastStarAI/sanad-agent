import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory fixture;
  late Directory fakeBin;
  late Directory userBin;
  late File calls;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('sanad-bootstrap-fixture-');
    fakeBin = Directory('${fixture.path}${Platform.pathSeparator}fake-bin');
    userBin = Directory('${fixture.path}${Platform.pathSeparator}user-bin');
    await fakeBin.create();
    await userBin.create();
    calls = File('${fixture.path}${Platform.pathSeparator}calls.log');

    for (final path in [
      'scripts',
      'release/contract',
      'agent',
      'client',
    ]) {
      await Directory(
        '${fixture.path}${Platform.pathSeparator}$path',
      ).create(recursive: true);
    }
    await File('${fixture.path}${Platform.pathSeparator}.fvmrc').writeAsString(
      '{"flutter":"3.41.9"}',
    );
    await File(
      '${fixture.path}${Platform.pathSeparator}release${Platform.pathSeparator}contract${Platform.pathSeparator}pubspec.lock',
    ).writeAsString('contract-lock');
    await File(
      '${fixture.path}${Platform.pathSeparator}agent${Platform.pathSeparator}pubspec.lock',
    ).writeAsString('agent-lock');
    await File(
      '${fixture.path}${Platform.pathSeparator}client${Platform.pathSeparator}pubspec.lock',
    ).writeAsString('client-lock');
    await File(
      '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad_dev.dart',
    ).writeAsString('');
    await File(
      '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev',
    ).writeAsString(await File('../scripts/sanad-dev').readAsString());

    if (Platform.isWindows) {
      await File('${fakeBin.path}${Platform.pathSeparator}fvm.cmd').writeAsString('''@echo off
 echo %CD%^|%*>>"${calls.path}"
 if "%1"=="install" (
   mkdir .fvm\\flutter_sdk\\bin 2>nul
   type nul > .fvm\\flutter_sdk\\bin\\flutter.bat
 )
 if "%1"=="dart" if "%2"=="pub" (
   mkdir .dart_tool 2>nul
   echo {}> .dart_tool\\package_config.json
 )
 if "%1"=="flutter" if "%2"=="pub" (
   mkdir .dart_tool 2>nul
   echo {}> .dart_tool\\package_config.json
 )
''');
      await File('${fakeBin.path}${Platform.pathSeparator}Get-FileHash.ps1').writeAsString(r'''
param([string] $Algorithm, [string] $Path)
[pscustomobject]@{ Hash = 'fixture-hash' }
''');
      await File(
        '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev.ps1',
      ).writeAsString(await File('../scripts/sanad-dev.ps1').readAsString());
    } else {
      final fakeFvm = File('${fakeBin.path}${Platform.pathSeparator}fvm');
      await fakeFvm.writeAsString('''#!/usr/bin/env bash
set -e
printf '%s|%s\\n' "\$PWD" "\$*" >> '${calls.path}'
printf 'live:%s:%s\\n' "\$PWD" "\$*"
if [ "\${FAIL_STAGE:-}" = "\${1:-}-\${2:-}" ]; then exit 42; fi
if [ "\${1:-}" = install ]; then
  mkdir -p .fvm/flutter_sdk/bin && printf '#!/bin/sh' > .fvm/flutter_sdk/bin/flutter && chmod +x .fvm/flutter_sdk/bin/flutter
elif [ "\${1:-}" = dart ] && [ "\${2:-}" = pub ]; then
  mkdir -p .dart_tool && printf '{}' > .dart_tool/package_config.json
elif [ "\${1:-}" = flutter ] && [ "\${2:-}" = pub ]; then
  mkdir -p .dart_tool && printf '{}' > .dart_tool/package_config.json
fi
''');
      await Process.run('chmod', ['+x', fakeFvm.path]);
      await Process.run('chmod', [
        '+x',
        '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev',
      ]);
    }
  });

  tearDown(() async {
    if (await fixture.exists()) await fixture.delete(recursive: true);
  });

  Future<ProcessResult> runBootstrap(
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) => Process.run(
    '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev',
    arguments,
    workingDirectory: fixture.path,
    environment: {
      'PATH': '${fakeBin.path}:${Platform.environment['PATH']}',
      'HOME': fixture.path,
      'XDG_BIN_HOME': userBin.path,
      ...environment,
    },
  );

  group('POSIX bootstrap', () {
    test('fresh setup resolves Contract before Agent and Client', () async {
      final result = await runBootstrap(['setup']);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final invocations = await calls.readAsLines();
      expect(invocations[0], contains('install 3.41.9'));
      expect(invocations[1], contains('release/contract|dart pub get'));
      expect(invocations[2], contains('agent|dart pub get'));
      expect(invocations[3], contains('client|flutter pub get'));
      expect(result.stdout, isNot(contains('Checking FVM')));
      expect(result.stdout, contains('live:'));
      expect(result.stdout, contains('ready ('));
      expect(
        invocations.any((line) => line.contains('sanad_dev.dart')),
        isFalse,
      );
      final shim = Link('${userBin.path}${Platform.pathSeparator}sanad-dev');
      expect(await shim.exists(), isTrue);
      expect(await shim.target(), contains(fixture.path));
      expect(result.stdout, contains('PATH configured for new terminals'));
    });

    test('second setup skips dependency resolution with a valid stamp', () async {
      expect((await runBootstrap(['setup'])).exitCode, 0);
      await calls.writeAsString('');

      final result = await runBootstrap(['setup']);

      expect(result.exitCode, 0);
      expect(result.stdout, isNot(contains('Resolving package dependencies')));
      final invocations = await calls.readAsLines();
      expect(invocations, isEmpty);
    });

    test('explicit run repairs package graphs before entering runtime CLI', () async {
      final result = await runBootstrap([
        'run',
        '--force',
        '--config',
        'config/dev.json',
      ]);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final invocations = await calls.readAsLines();
      expect(invocations[1], contains('release/contract|dart pub get'));
      expect(invocations[2], contains('agent|dart pub get'));
      expect(invocations[3], contains('client|flutter pub get'));
      expect(invocations[4], contains('sanad_dev.dart run --config config/dev.json'));
      expect(
        await Link('${userBin.path}${Platform.pathSeparator}sanad-dev').exists(),
        isTrue,
      );
    });

    test('run accepts an existing command shim owned by another checkout', () async {
      final shim = Link('${userBin.path}${Platform.pathSeparator}sanad-dev');
      final foreign = '${fixture.path}${Platform.pathSeparator}other-checkout';
      await shim.create(foreign);

      final result = await runBootstrap(const ['run']);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      expect(await shim.target(), foreign);
      expect((await calls.readAsLines()).last, contains('sanad_dev.dart run'));
    });

    test('checkout collision fails unless force is explicit', () async {
      final shim = Link('${userBin.path}${Platform.pathSeparator}sanad-dev');
      await shim.create('${fixture.path}${Platform.pathSeparator}other-checkout');

      final rejected = await runBootstrap(['setup']);
      expect(rejected.exitCode, isNonZero);
      expect(rejected.stderr, contains('another checkout'));

      final forced = await runBootstrap(['setup', '--force']);
      expect(forced.exitCode, 0);
      expect(await shim.target(), contains('${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev'));
    });

    test('failed stage blocks dependent setup and runtime launch', () async {
      final result = await runBootstrap(
        const ['run'],
        environment: const {'FAIL_STAGE': 'dart-pub'},
      );

      expect(result.exitCode, isNonZero);
      final invocations = await calls.readAsLines();
      expect(invocations, hasLength(2));
      expect(invocations.last, contains('release/contract|dart pub get'));
      expect(invocations.any((line) => line.contains('flutter pub get')), isFalse);
      expect(invocations.any((line) => line.contains('sanad_dev.dart')), isFalse);
    });

    test('install prepares tools and shim without package setup or run', () async {
      final result = await runBootstrap(const ['install']);

      expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
      final invocations = await calls.readAsLines();
      expect(invocations, hasLength(1));
      expect(invocations.single, contains('install 3.41.9'));
      expect(
        await Link('${userBin.path}${Platform.pathSeparator}sanad-dev').exists(),
        isTrue,
      );
    });

    test('non-run runtime command does not bootstrap missing prerequisites', () async {
      final result = await runBootstrap(const ['status']);

      expect(result.exitCode, isNonZero);
      expect(result.stderr, contains('sanad-dev install'));
      expect(await calls.exists(), isFalse);
    });

    test('no arguments shows help without mutation', () async {
      final result = await runBootstrap(const []);

      expect(result.exitCode, 0);
      expect(result.stdout, contains('Official source run:'));
      expect(result.stdout, contains('sanad-dev run'));
      expect(await calls.exists(), isFalse);
      expect(
        await Link('${userBin.path}${Platform.pathSeparator}sanad-dev').exists(),
        isFalse,
      );
    });
  }, skip: Platform.isWindows);

  test('Windows setup executes all stages with a user-scoped shim', () async {
    final executable = Platform.environment['SystemRoot'] == null
        ? 'powershell.exe'
        : '${Platform.environment['SystemRoot']}\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    final result = await Process.run(
      executable,
      [
        '-NoProfile',
        '-ExecutionPolicy',
        'Bypass',
        '-File',
        '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev.ps1',
        'setup',
      ],
      workingDirectory: fixture.path,
      environment: {
        ...Platform.environment,
        'PATH': '${fakeBin.path};${Platform.environment['PATH']}',
        'LOCALAPPDATA': fixture.path,
      },
    );

    expect(result.exitCode, 0, reason: '${result.stdout}\n${result.stderr}');
    final invocations = await calls.readAsLines();
    expect(invocations.any((line) => line.contains('install 3.41.9')), isTrue);
    expect(
      invocations.any((line) => line.contains('release${Platform.pathSeparator}contract|dart pub get')),
      isTrue,
    );
    expect(invocations.any((line) => line.contains('agent|dart pub get')), isTrue);
    expect(invocations.any((line) => line.contains('client|flutter pub get')), isTrue);
    expect(
      File(
        '${fixture.path}${Platform.pathSeparator}SanadDev${Platform.pathSeparator}bin${Platform.pathSeparator}sanad-dev.cmd',
      ).existsSync(),
      isTrue,
    );
  }, skip: !Platform.isWindows);

  test('PowerShell bootstrap pins verified user-scoped artifacts', () async {
    final source = await File('../scripts/sanad-dev.ps1').readAsString();

    expect(source, contains("\$FvmVersion = '4.1.2'"));
    expect(source, contains('Get-FileHash -Algorithm SHA256'));
    expect(source, contains("[Environment]::SetEnvironmentVariable('Path'"));
    expect(source, contains("'User')"));
    expect(source, isNot(contains('Start-Process -Verb RunAs')));
  });
}
