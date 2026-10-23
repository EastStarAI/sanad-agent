import 'dart:io';

/// One throwaway checkout that the sanad-dev wrapper can bootstrap inside.
///
/// The wrapper is copied from the real `scripts/sanad-dev`, and FVM is replaced
/// by a fake that records every invocation in [calls], so a test can assert
/// which bootstrap stages ran without touching the host toolchain.
class SanadBootstrapFixture {
  SanadBootstrapFixture({
    required this.root,
    required this.fakeBin,
    required this.userBin,
    required this.calls,
  });

  /// Repository root of the fixture checkout.
  final Directory root;

  /// Prepended to `PATH`; owns the fake `fvm`.
  final Directory fakeBin;

  /// `XDG_BIN_HOME` of the fixture, exposed as `HOME` to the wrapper.
  final Directory userBin;

  /// Every fake-FVM invocation, one `cwd|arguments` line each.
  final File calls;

  static Future<SanadBootstrapFixture> create() async {
    final fixture = await Directory.systemTemp.createTemp(
      'sanad-bootstrap-fixture-',
    );
    final fakeBin = Directory(
      '${fixture.path}${Platform.pathSeparator}fake-bin',
    );
    final userBin = Directory(
      '${fixture.path}${Platform.pathSeparator}user-bin',
    );
    await fakeBin.create();
    await userBin.create();
    final calls = File('${fixture.path}${Platform.pathSeparator}calls.log');

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

    return SanadBootstrapFixture(
      root: fixture,
      fakeBin: fakeBin,
      userBin: userBin,
      calls: calls,
    );
  }

  /// Files the fixture relies on a real checkout providing.
  String path(String relative) =>
      '${root.path}${Platform.pathSeparator}'
      '${relative.replaceAll('/', Platform.pathSeparator)}';

  Future<ProcessResult> run(
    List<String> arguments, {
    Map<String, String> environment = const {},
  }) => Process.run(
    path('scripts/sanad-dev'),
    arguments,
    workingDirectory: root.path,
    environment: {
      'PATH': '${fakeBin.path}:${Platform.environment['PATH']}',
      'HOME': root.path,
      'XDG_BIN_HOME': userBin.path,
      ...environment,
    },
  );

  Future<void> dispose() async {
    if (await root.exists()) {
      try {
        await root.delete(recursive: true);
      } on FileSystemException {
        // Windows file locking can delay folder deletion after process exit
        await Future<void>.delayed(const Duration(milliseconds: 500));
        try {
          if (await root.exists()) await root.delete(recursive: true);
        } catch (_) {}
      }
    }
  }
}
