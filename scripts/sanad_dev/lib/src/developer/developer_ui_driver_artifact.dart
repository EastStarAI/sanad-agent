part of '../../sanad_dev_cli.dart';

/// Change-detection fingerprint of everything a compiled driver CLI depends on.
///
/// This is cache invalidation, not a security boundary: it only needs to change
/// whenever a compiled artifact could behave differently.
String uiDriverSourceFingerprint(Map<String, String> sources) {
  final entries = sources.keys.toList()..sort();
  final buffer = StringBuffer();
  for (final path in entries) {
    final content = sources[path] ?? '';
    buffer
      ..write(path)
      ..write(':')
      ..write(_uiDriverStableHash(content))
      ..write('\n');
  }
  return _uiDriverStableHash(buffer.toString());
}

String _uiDriverStableHash(String value) {
  var hash = 0x00000100000001b3;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}

/// Path of the compiled driver CLI artifact for [fingerprint].
String uiDriverArtifactPath({
  required String repositoryRoot,
  required String fingerprint,
  bool? isWindows,
}) {
  final suffix = (isWindows ?? Platform.isWindows) ? '.exe' : '';
  return '$repositoryRoot/.dart_tool/sanad-dev/flutter-driver-cli-$fingerprint$suffix';
}

/// Reads every input that participates in the artifact fingerprint.
///
/// Besides the CLI sources this covers the Client package resolution
/// (`client/.dart_tool/package_config.json`), the locked dependency graph
/// (`client/pubspec.lock`), the FVM pin, and the Dart SDK running this
/// launcher. A dependency or SDK change would otherwise execute a stale binary
/// against a new `flutter_driver`/Flutter API surface.
Map<String, String> readUiDriverSources(
  String repositoryRoot, {
  String? sdkVersion,
}) {
  final entry = File('$repositoryRoot/scripts/flutter_driver_cli.dart');
  if (!entry.existsSync()) return const {};
  final sources = <String, String>{
    'scripts/flutter_driver_cli.dart': entry.readAsStringSync(),
    'dart-sdk': sdkVersion ?? Platform.version,
  };
  for (final dependency in const [
    'client/.dart_tool/package_config.json',
    'client/pubspec.lock',
    '.fvmrc',
  ]) {
    final file = File('$repositoryRoot/$dependency');
    if (!file.existsSync()) continue;
    sources[dependency] = file.readAsStringSync();
  }
  final directory = Directory('$repositoryRoot/scripts/flutter_driver_cli');
  if (!directory.existsSync()) return sources;
  for (final entity in directory.listSync(recursive: true, followLinks: false)) {
    if (entity is! File || !entity.path.endsWith('.dart')) continue;
    final relative = entity.path
        .substring(repositoryRoot.length)
        .replaceAll('\\', '/')
        .replaceFirst(RegExp(r'^/+'), '');
    sources[relative] = entity.readAsStringSync();
  }
  return sources;
}

/// Ensures a source-matched native driver CLI artifact exists.
///
/// Returns the artifact path, or null when compilation is unavailable so the
/// caller can fall back to the JIT invocation path.
Future<String?> ensureUiDriverArtifact({
  required String repositoryRoot,
  required Future<bool> Function(String outputPath) compile,
  bool? isWindows,
  bool allowCompile = true,
  String? sdkVersion,
}) async {
  final sources = readUiDriverSources(repositoryRoot, sdkVersion: sdkVersion);
  if (sources.isEmpty) return null;
  final fingerprint = uiDriverSourceFingerprint(sources);
  final artifact = uiDriverArtifactPath(
    repositoryRoot: repositoryRoot,
    fingerprint: fingerprint,
    isWindows: isWindows,
  );
  final artifactFile = File(artifact);
  if (artifactFile.existsSync()) return artifact;
  if (!allowCompile) return null;

  try {
    artifactFile.parent.createSync(recursive: true);
  } catch (_) {
    return null;
  }
  final staging = '$artifact.$pid.tmp';
  final compiled = await compile(staging);
  if (!compiled) {
    try {
      final stagingFile = File(staging);
      if (stagingFile.existsSync()) stagingFile.deleteSync();
    } catch (_) {}
    return null;
  }
  try {
    final stagingFile = File(staging);
    if (!stagingFile.existsSync()) return null;
    await stagingFile.rename(artifact);
  } catch (_) {
    return null;
  }
  _pruneUiDriverArtifacts(
    artifactDirectory: File(artifact).parent,
    keep: artifact,
  );
  return artifact;
}

/// Age after which another invocation's staging file is considered abandoned.
const Duration uiDriverStaleStagingAge = Duration(minutes: 10);

void _pruneUiDriverArtifacts({
  required Directory artifactDirectory,
  required String keep,
}) {
  final cutoff = DateTime.now().subtract(uiDriverStaleStagingAge);
  try {
    for (final entity in artifactDirectory.listSync()) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('flutter-driver-cli-')) continue;
      if (entity.path == keep) continue;
      try {
        if (name.endsWith('.tmp')) {
          // Another invocation may still be compiling into this staging file.
          if (entity.lastModifiedSync().isAfter(cutoff)) continue;
        }
        entity.deleteSync();
      } catch (_) {}
    }
  } catch (_) {}
}

/// How one driver CLI invocation is executed.
class UiDriverInvocation {
  const UiDriverInvocation({
    required this.executable,
    required this.arguments,
    required this.usesJit,
  });

  final String executable;
  final List<String> arguments;

  /// True when the JIT path runs instead of a native artifact.
  final bool usesJit;
}

/// Chooses the native artifact when it is still present, otherwise the JIT path.
///
/// Existence is checked at spawn time because a concurrent prune or a cleaned
/// checkout can remove the artifact between the cache lookup and the spawn.
UiDriverInvocation planUiDriverInvocation({
  required String? artifactPath,
  required bool artifactExists,
  required String packageConfig,
  required String toolScript,
  required List<String> driverArguments,
  required List<String> extraArguments,
}) {
  if (artifactPath != null && artifactExists) {
    return UiDriverInvocation(
      executable: artifactPath,
      arguments: <String>[...driverArguments, ...extraArguments],
      usesJit: false,
    );
  }
  return UiDriverInvocation(
    executable: 'fvm',
    arguments: <String>[
      'dart',
      '--packages=$packageConfig',
      toolScript,
      ...driverArguments,
      ...extraArguments,
    ],
    usesJit: true,
  );
}

