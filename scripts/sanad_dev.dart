import 'dart:io';

/// Compatibility entry point for callers that still invoke this historical
/// script directly. The platform wrappers execute the package-owned CLI
/// library without this extra process.
Future<void> main(List<String> arguments) async {
  final scriptsDirectory = File.fromUri(Platform.script).parent;
  final packageDirectory = Directory(
    '${scriptsDirectory.path}${Platform.pathSeparator}sanad_dev',
  );
  final packageConfig = File(
    '${packageDirectory.path}${Platform.pathSeparator}.dart_tool'
    '${Platform.pathSeparator}package_config.json',
  );
  if (!packageConfig.existsSync()) {
    stderr.writeln(
      'sanad-dev package is not ready. Run: '
      'fvm dart pub get --directory scripts/sanad_dev',
    );
    exitCode = 1;
    return;
  }
  final cli = File(
    '${packageDirectory.path}${Platform.pathSeparator}lib'
    '${Platform.pathSeparator}sanad_dev_cli.dart',
  );
  final process = await Process.start(
    Platform.resolvedExecutable,
    ['--packages=${packageConfig.path}', cli.path, ...arguments],
    workingDirectory: Directory.current.path,
    environment: Platform.environment,
    mode: ProcessStartMode.inheritStdio,
  );
  exitCode = await process.exitCode;
}
