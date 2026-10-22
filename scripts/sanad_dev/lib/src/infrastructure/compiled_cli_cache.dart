import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Cache root name owned by `sanad-dev` inside the invoking worktree.
const compiledCliCacheDirectoryName = '.sanad-dev';

/// The two command-line entry points `sanad-dev` compiles and caches.
///
/// Every call to `fvm dart run` pays the SDK resolution plus kernel compile
/// cost (measured at 6.5 s for the Agent CLI). A cached native artifact keeps
/// repeated `sanad`/`sanad-client` calls in the hundreds of milliseconds.
enum CompiledCliComponent {
  agent,
  client;

  String get name => switch (this) {
    CompiledCliComponent.agent => 'agent',
    CompiledCliComponent.client => 'client',
  };

  String get packageDirectory => switch (this) {
    CompiledCliComponent.agent => 'agent',
    _ => 'client',
  };

  String get entryPoint => switch (this) {
    CompiledCliComponent.agent => 'agent/bin/sanad_agent.dart',
    _ => 'client/bin/sanad_client.dart',
  };

  static CompiledCliComponent? parse(String value) =>
      switch (value.trim().toLowerCase()) {
        'agent' => CompiledCliComponent.agent,
        'client' => CompiledCliComponent.client,
        _ => null,
      };
}

/// Builds one cached artifact and returns the child exit status.
///
/// The production implementation runs `fvm dart compile exe` for the Agent CLI
/// and `fvm dart build cli` for the Client CLI (the Client package carries
/// native build hooks, so `dart compile exe` refuses it).
typedef CompiledCliBuilder =
    Future<int> Function({
      required String workingDirectory,
      required List<String> arguments,
    });

/// Reads the current source commit of the runtime repository.
typedef CompiledCliCommitReader = Future<String> Function();

class CompiledCliArtifact {
  const CompiledCliArtifact({
    required this.component,
    required this.executablePath,
    required this.fingerprint,
    required this.cacheKey,
    required this.rebuilt,
    this.buildDuration,
  });

  final CompiledCliComponent component;
  final String executablePath;
  final String fingerprint;
  final String cacheKey;
  final bool rebuilt;
  final Duration? buildDuration;

  /// Human label that distinguishes a fresh build from a reused artifact.
  String get buildLabel {
    final duration = buildDuration;
    if (!rebuilt || duration == null) return 'reused';
    return 'built in ${formatCompiledCliDuration(duration)}';
  }
}

String formatCompiledCliDuration(Duration duration) {
  final milliseconds = duration.inMilliseconds;
  if (milliseconds < 1000) return '${milliseconds}ms';
  return '${(milliseconds / 1000).toStringAsFixed(1)}s';
}

/// Per-SHA native artifact cache below `<worktree>/.sanad-dev/bin/<sha>/`.
///
/// The directory name is the runtime source commit so concurrent worktrees and
/// older runtimes never share an artifact. Inside that directory a fingerprint
/// stamp decides whether the artifact still matches the component sources, so a
/// dirty tree or a changed path dependency rebuilds in place instead of being
/// silently reused.
class CompiledCliCache {
  CompiledCliCache({
    required this.workspaceRoot,
    required this.repositoryRoot,
    CompiledCliBuilder? builder,
    CompiledCliCommitReader? sourceCommit,
    Map<String, String>? environment,
  }) : _environment = environment ?? Platform.environment,
       _sourceCommit = sourceCommit ?? (() => _gitHead(repositoryRoot)) {
    _builder =
        builder ??
        ({required String workingDirectory, required List<String> arguments}) =>
            _fvmBuildRunner(
              workingDirectory: workingDirectory,
              arguments: arguments,
              environment: _environment,
            );
  }

  final String workspaceRoot;
  final String repositoryRoot;
  final Map<String, String> _environment;
  final CompiledCliCommitReader _sourceCommit;
  late final CompiledCliBuilder _builder;

  String get cacheRoot =>
      p.join(workspaceRoot, compiledCliCacheDirectoryName, 'bin');

  /// Compiles or reuses the cached artifact for [component].
  Future<CompiledCliArtifact> ensure(
    CompiledCliComponent component, {
    bool force = false,
    void Function(String message)? log,
  }) async {
    final cacheKey = await resolveCacheKey();
    final directory = Directory(p.join(cacheRoot, cacheKey));
    final fingerprint = await computeFingerprint(component);
    final executable = File(_executablePath(component, directory.path));
    final stamp = File(_stampPath(component, directory.path));
    if (!force &&
        executable.existsSync() &&
        stamp.existsSync() &&
        stamp.readAsStringSync().trim() == fingerprint) {
      return CompiledCliArtifact(
        component: component,
        executablePath: executable.path,
        fingerprint: fingerprint,
        cacheKey: cacheKey,
        rebuilt: false,
      );
    }
    log?.call(
      'Building ${component.name} CLI for $cacheKey '
      '(${force ? 'forced' : 'source changed'})...',
    );
    final stopwatch = Stopwatch()..start();
    await directory.create(recursive: true);
    await _build(component, directory.path);
    stopwatch.stop();
    if (!File(_executablePath(component, directory.path)).existsSync()) {
      throw StateError(
        'The ${component.name} CLI build did not produce '
        '${_executablePath(component, directory.path)}.',
      );
    }
    await stamp.writeAsString('$fingerprint\n', flush: true);
    return CompiledCliArtifact(
      component: component,
      executablePath: _executablePath(component, directory.path),
      fingerprint: fingerprint,
      cacheKey: cacheKey,
      rebuilt: true,
      buildDuration: stopwatch.elapsed,
    );
  }

  /// Cache directory name: the runtime source commit, or `nogit` outside Git.
  Future<String> resolveCacheKey() async {
    try {
      final commit = (await _sourceCommit()).trim();
      if (commit.isEmpty) return 'nogit';
      return commit.length > 12 ? commit.substring(0, 12) : commit;
    } on Object {
      return 'nogit';
    }
  }

  /// SHA-256 over every relevant source file of [component].
  Future<String> computeFingerprint(CompiledCliComponent component) async {
    final inputs = <String>[];
    final packageRoot = p.join(repositoryRoot, component.packageDirectory);
    inputs.addAll(_packageInputs(packageRoot));
    for (final dependency in _pathDependencies(
      File(p.join(packageRoot, 'pubspec.yaml')),
    )) {
      // Path dependencies are relative to the package directory.
      inputs.addAll(
        _packageInputs(p.normalize(p.join(packageRoot, dependency))),
      );
    }
    final fvmPin = File(p.join(repositoryRoot, '.fvmrc'));
    if (fvmPin.existsSync()) inputs.add(fvmPin.path);
    inputs.sort();
    final digest = _DigestSink();
    final input = sha256.startChunkedConversion(digest);
    for (final path in inputs) {
      final relative = p.relative(path, from: repositoryRoot);
      input.add(utf8.encode('$relative:'));
      input.add(sha256.convert(File(path).readAsBytesSync()).bytes);
      input.add(const [0x0a]);
    }
    input.close();
    return digest.value.toString();
  }

  String _executablePath(CompiledCliComponent component, String directory) =>
      switch (component) {
        CompiledCliComponent.agent => p.join(
          directory,
          Platform.isWindows ? 'agent.exe' : 'agent',
        ),
        CompiledCliComponent.client => p.join(
          directory,
          'client-bundle',
          'bin',
          Platform.isWindows ? 'sanad_client.exe' : 'sanad_client',
        ),
      };

  String _stampPath(CompiledCliComponent component, String directory) =>
      p.join(directory, '${component.name}.stamp');

  Future<void> _build(CompiledCliComponent component, String directory) async {
    final workingDirectory = p.join(repositoryRoot, component.packageDirectory);
    final target = _executablePath(component, directory);
    switch (component) {
      case CompiledCliComponent.agent:
        final staging = '$target.building';
        _deletePathSync(staging);
        final exitCode = await _builder(
          workingDirectory: workingDirectory,
          arguments: [
            'dart',
            'compile',
            'exe',
            // Keep `sanad --version` identical to the `fvm dart run` path; a
            // compiled binary cannot read the package pubspec.
            if (_agentVersionDefine() case final define?) define,
            'bin/sanad_agent.dart',
            '-o',
            staging,
          ],
        );
        if (exitCode != 0) {
          _deletePathSync(staging);
          throw StateError(
            'The Agent CLI build failed with exit code $exitCode.',
          );
        }
        _deletePathSync(target);
        File(staging).renameSync(target);
      case CompiledCliComponent.client:
        // `dart compile exe` refuses packages with native build hooks
        // (cnativeapi, objective_c), so the Client CLI is built as a CLI
        // bundle that carries its dynamic libraries beside the executable.
        final staging = p.join(directory, '.client-bundle-building');
        _deletePathSync(staging);
        final exitCode = await _builder(
          workingDirectory: workingDirectory,
          arguments: [
            'dart',
            'build',
            'cli',
            '-t',
            'bin/sanad_client.dart',
            '-o',
            staging,
          ],
        );
        final produced = p.join(staging, 'bundle');
        if (exitCode != 0 || !Directory(produced).existsSync()) {
          _deletePathSync(staging);
          throw StateError(
            'The Client CLI build failed with exit code $exitCode.',
          );
        }
        final destination = p.join(directory, 'client-bundle');
        _deletePathSync(destination);
        Directory(produced).renameSync(destination);
        _deletePathSync(staging);
    }
  }

  List<String> _packageInputs(String packageRoot) {
    final inputs = <String>[];
    for (final name in const ['pubspec.yaml', 'pubspec.lock']) {
      final file = File(p.join(packageRoot, name));
      if (file.existsSync()) inputs.add(file.path);
    }
    for (final name in const ['lib', 'bin']) {
      final directory = Directory(p.join(packageRoot, name));
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          inputs.add(entity.path);
        }
      }
    }
    return inputs;
  }

  List<String> _pathDependencies(File pubspec) {
    if (!pubspec.existsSync()) return const [];
    final dependencies = <String>[];
    final pattern = RegExp(r'^\s+path:\s*(\S+)\s*$', multiLine: true);
    for (final match in pattern.allMatches(pubspec.readAsStringSync())) {
      dependencies.add(p.normalize(match.group(1)!));
    }
    return dependencies;
  }

  /// `-DSANAD_AGENT_VERSION=<agent/pubspec.yaml version>` when readable.
  String? _agentVersionDefine() {
    final pubspec = File(p.join(repositoryRoot, 'agent', 'pubspec.yaml'));
    if (!pubspec.existsSync()) return null;
    final match = RegExp(
      r'^version:\s*([^\s#]+)',
      multiLine: true,
    ).firstMatch(pubspec.readAsStringSync());
    final version = match?.group(1);
    return version == null || version.isEmpty
        ? null
        : '-DSANAD_AGENT_VERSION=$version';
  }

  static Future<String> _gitHead(String repositoryRoot) async {
    final result = await Process.run('git', [
      '-C',
      repositoryRoot,
      'rev-parse',
      'HEAD',
    ]);
    if (result.exitCode != 0) return '';
    return result.stdout.toString().trim();
  }
}

/// Production builder: every Dart/Flutter child process runs through FVM.
Future<int> _fvmBuildRunner({
  required String workingDirectory,
  required List<String> arguments,
  Map<String, String>? environment,
}) async {
  final process = await Process.start(
    'fvm',
    arguments,
    workingDirectory: workingDirectory,
    environment: environment,
    runInShell: Platform.isWindows,
    mode: ProcessStartMode.inheritStdio,
  );
  return process.exitCode;
}

void _deletePathSync(String path) {
  final type = FileSystemEntity.typeSync(path, followLinks: false);
  if (type == FileSystemEntityType.notFound) return;
  if (type == FileSystemEntityType.directory) {
    Directory(path).deleteSync(recursive: true);
  } else {
    File(path).deleteSync();
  }
}

/// Captures the single digest produced by a chunked SHA-256 conversion.
class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
