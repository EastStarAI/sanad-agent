import 'dart:io';

/// A throwaway project tree that the real `sanad-dev` bootstrap script runs in.
///
/// The script under test is the repository's own `scripts/sanad-dev` (or
/// `scripts/sanad-dev.ps1` on Windows), copied into a temporary project with a
/// fake `fvm` on `PATH`, so every stage is observed through the recorded
/// invocations instead of a mock. Two suites share this harness: the bootstrap
/// ordering suite and the prepared-runtime fingerprint suite.
class SanadDevBootstrapHarness {
  late Directory fixture;
  late Directory fakeBin;
  late Directory userBin;
  late File calls;

  File get sanadDevCliSource => File(
    [
      fixture.path,
      'scripts',
      'sanad_dev',
      'lib',
      'sanad_dev_cli.dart',
    ].join(Platform.pathSeparator),
  );

  String get runtimeArtifactRoot => [
    fixture.path,
    '.dart_tool',
    'sanad-dev',
  ].join(Platform.pathSeparator);

  File get runtimeStamp =>
      File('$runtimeArtifactRoot${Platform.pathSeparator}runtime-cli.stamp');

  /// Path of a file inside one of the fixture's `path:` dependency packages.
  File sharedFile(String package, List<String> segments) => File(
    [fixture.path, 'shared', package, ...segments].join(Platform.pathSeparator),
  );

  Future<void> setUp() async {
    fixture = await Directory.systemTemp.createTemp('sanad-bootstrap-fixture-');
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
    ).writeAsString('''
name: sanad_dev
dependencies:
  sanad_public_service_endpoints:
    path: ../../shared/public_service_endpoints
  sanad_windows_path:
    path: ../../shared/windows_path
''');
    // A `path:` dependency is compiled into the runtime CLI, so both shared
    // packages exist here with real inputs for the fingerprint to cover.
    for (final sharedPackage in const {
      'public_service_endpoints': 'sanad_public_service_endpoints',
      'windows_path': 'sanad_windows_path',
    }.entries) {
      final root = Directory(
        [
          fixture.path,
          'shared',
          sharedPackage.key,
        ].join(Platform.pathSeparator),
      );
      await Directory(
        '${root.path}${Platform.pathSeparator}lib${Platform.pathSeparator}src',
      ).create(recursive: true);
      await File(
        '${root.path}${Platform.pathSeparator}pubspec.yaml',
      ).writeAsString('name: ${sharedPackage.value}');
      await File(
        '${root.path}${Platform.pathSeparator}pubspec.lock',
      ).writeAsString('${sharedPackage.value}-lock');
      await File(
        '${root.path}${Platform.pathSeparator}lib${Platform.pathSeparator}${sharedPackage.value}.dart',
      ).writeAsString('const revision = 1;');
      await File(
        '${root.path}${Platform.pathSeparator}lib${Platform.pathSeparator}src${Platform.pathSeparator}impl.dart',
      ).writeAsString('const revision = 1;');
    }
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
    await File(
      '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev',
    ).writeAsString(await File('../sanad-dev').readAsString());

    if (Platform.isWindows) {
      await File(
        '${fakeBin.path}${Platform.pathSeparator}fvm.cmd',
      ).writeAsString('''@echo off
 if "%1"=="spawn" (
   if exist .fake-fvm-installed exit /b 0
   exit /b 1
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
      final powershellWrapper = (await File('../sanad-dev.ps1').readAsString())
          .replaceAll(
            r'Ensure-UserBinPath $binRoot',
            '# Test fixture suppresses user PATH persistence.',
          );
      await File(
        '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev.ps1',
      ).writeAsString(powershellWrapper);
    } else {
      final fakeFvm = File('${fakeBin.path}${Platform.pathSeparator}fvm');
      await fakeFvm.writeAsString('''#!/usr/bin/env bash
set -e
if [ "\${1:-}" = spawn ]; then
  [ -f .fake-fvm-installed ]
  exit
fi
printf '%s|%s\\n' "\$PWD" "\$*" >> '${calls.path}'
printf 'live:%s:%s\\n' "\$PWD" "\$*"
if [ "\${FAIL_STAGE:-}" = "\${1:-}-\${2:-}" ]; then exit 42; fi
if [ "\${1:-}" = install ]; then
  touch .fake-fvm-installed
elif [ "\${1:-}" = dart ] && [ "\${2:-}" = pub ]; then
  mkdir -p .dart_tool && printf '{}' > .dart_tool/package_config.json
elif [ "\${1:-}" = flutter ] && [ "\${2:-}" = pub ]; then
  mkdir -p .dart_tool && printf '{}' > .dart_tool/package_config.json
elif [ "\${1:-}" = dart ] && [ "\${2:-}" = compile ]; then
  output="\${6}"
  cat > "\$output" <<'RUNTIME'
#!/usr/bin/env bash
printf 'runtime|%s\\n' "\$*" >> '${calls.path}'
RUNTIME
  chmod +x "\$output"
fi
''');
      await Process.run('chmod', ['+x', fakeFvm.path]);
      await Process.run('chmod', [
        '+x',
        '${fixture.path}${Platform.pathSeparator}scripts${Platform.pathSeparator}sanad-dev',
      ]);
    }
  }

  Future<void> tearDown() async {
    if (await fixture.exists()) {
      try {
        await fixture.delete(recursive: true);
      } on FileSystemException {
        // Windows file locking can delay folder deletion after process exit
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          if (await fixture.exists()) await fixture.delete(recursive: true);
        } catch (_) {}
      }
    }
  }

  Future<ProcessResult> run(
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
}
