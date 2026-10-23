import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'file_lock.dart';

/// Cache root name owned by `sanad-dev` inside the invoking worktree.
const compiledCliCacheDirectoryName = '.sanad-dev';

/// How many historical commits stay cached beside the current one.
///
/// Each entry is a native build, so retaining a small window keeps a checkout
/// switch or a rebase from paying a full rebuild while never growing without
/// bound.
const compiledCliRetainedCommits = 3;

/// How long a builder or reader waits for another process to release the
/// component build lock before giving up.
const compiledCliLockTimeout = Duration(minutes: 15);

/// File name of the per-component build lock below a cache key directory.
///
/// A builder takes the lock exclusively and a runner takes it shared, so a
/// process never starts an artifact while it is being replaced.
String compiledCliLockFileName(CompiledCliComponent component) =>
    '${component.name}.build.lock';

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

/// Reads the effective Dart SDK version when the repository has no FVM pin.
typedef DartSdkVersionReader = Future<String> Function();

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
///
/// Publishing is serialized per component by an exclusive file lock, and every
/// reader takes the same lock shared before it starts the artifact, so a binary
/// is never executed while it is being replaced.
class CompiledCliCache {
  CompiledCliCache({
    required this.workspaceRoot,
    required this.repositoryRoot,
    CompiledCliBuilder? builder,
    CompiledCliCommitReader? sourceCommit,
    DartSdkVersionReader? dartSdkVersion,
    Map<String, String>? environment,
  }) : _environment = environment ?? Platform.environment,
       _sourceCommit = sourceCommit ?? (() => _gitHead(repositoryRoot)),
       _dartSdkVersion = dartSdkVersion ?? _readDartSdkVersion {
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
  final DartSdkVersionReader _dartSdkVersion;
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
    final directory = p.join(cacheRoot, cacheKey);
    await Directory(directory).create(recursive: true);
    final lockFile = File(_lockPath(component, directory));
    // The exclusive lock covers the stamp check, the build, the publish, and the
    // prune, so two `sanad-dev cli` calls for the same component never publish
    // over each other. POSIX record locks belong to the process, so an in-process
    // mutex is layered on top for two callers inside one isolate.
    return sanadDevWithProcessLock(_lockKey(component, cacheKey), () {
      return sanadDevWithFileLock(
        lockFile,
        FileLock.exclusive,
        () async {
      final fingerprint = await computeFingerprint(component);
      final executable = File(_executablePath(component, directory));
      final stamp = File(_stampPath(component, directory));
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
      await _build(component, directory);
      stopwatch.stop();
      if (!File(_executablePath(component, directory)).existsSync()) {
        throw StateError(
          'The ${component.name} CLI build did not produce '
          '${_executablePath(component, directory)}.',
        );
      }
      await stamp.writeAsString('$fingerprint\n', flush: true);
      await prune(keepCacheKey: cacheKey);
      return CompiledCliArtifact(
        component: component,
        executablePath: _executablePath(component, directory),
        fingerprint: fingerprint,
        cacheKey: cacheKey,
        rebuilt: true,
        buildDuration: stopwatch.elapsed,
      );
        },
        timeout: compiledCliLockTimeout,
        timeoutMessage:
            'Timed out after ${compiledCliLockTimeout.inMinutes} minutes '
            'waiting for the compiled CLI build lock.',
      );
    });
  }

  /// Runs [action] under the shared half of the component build lock.
  ///
  /// A concurrent builder waits until the started reader has resolved and
  /// launched the artifact, so a reader never executes a binary that is being
  /// replaced.
  Future<T> withReadLock<T>(
    CompiledCliComponent component,
    Future<T> Function() action,
  ) async {
    final cacheKey = await resolveCacheKey();
    final lockFile = File(_lockPath(component, p.join(cacheRoot, cacheKey)));
    if (!lockFile.existsSync()) return action();
    return sanadDevWithProcessLock(
      _lockKey(component, cacheKey),
      () => sanadDevWithFileLock(
        lockFile,
        FileLock.shared,
        action,
        timeout: compiledCliLockTimeout,
        timeoutMessage:
            'Timed out after ${compiledCliLockTimeout.inMinutes} minutes '
            'waiting for the compiled CLI build lock.',
      ),
    );
  }

  String _lockKey(CompiledCliComponent component, String cacheKey) =>
      '$cacheRoot|$cacheKey|${component.name}';

  /// Deletes cached commits beyond [compiledCliRetainedCommits] and the current
  /// cache key. Returns the removed directory names.
  Future<List<String>> prune({required String keepCacheKey}) async {
    final root = Directory(cacheRoot);
    if (!root.existsSync()) return const [];
    final directories =
        root
            .listSync(followLinks: false)
            .whereType<Directory>()
            .where((entry) => !p.basename(entry.path).startsWith('.'))
            .toList()
          ..sort(
            (left, right) => right.statSync().modified.compareTo(
              left.statSync().modified,
            ),
          );
    final keep = <String>{keepCacheKey};
    for (final directory in directories) {
      if (keep.length >= compiledCliRetainedCommits + 1) break;
      keep.add(p.basename(directory.path));
    }
    final removed = <String>[];
    for (final directory in directories) {
      final name = p.basename(directory.path);
      if (keep.contains(name)) continue;
      try {
        directory.deleteSync(recursive: true);
        removed.add(name);
      } on FileSystemException {
        // A directory held open by another process is retried on the next build.
      }
    }
    return removed;
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
  ///
  /// The fingerprint covers the package `lib/`, `bin/`, and `hook/` trees, the
  /// pubspecs, the whole transitive closure of path dependencies, and either the
  /// FVM pin or the effective `dart --version`, so a build-script or SDK change
  /// can never reuse a stale artifact.
  Future<String> computeFingerprint(CompiledCliComponent component) async {
    final inputs = <_FingerprintInput>[];
    final packageRoot = p.join(repositoryRoot, component.packageDirectory);
    inputs.addAll(_packageInputs(packageRoot));
    for (final dependency in _pathDependencyClosure(packageRoot)) {
      inputs.addAll(_packageInputs(dependency));
    }
    final fvmPin = File(p.join(repositoryRoot, '.fvmrc'));
    if (fvmPin.existsSync()) {
      inputs.add(_FingerprintInput('fvm-pin', fvmPin.readAsBytesSync()));
    } else {
      inputs.add(
        _FingerprintInput('dart-sdk', utf8.encode(await _dartSdkVersion())),
      );
    }
    final byPath = <String, _FingerprintInput>{};
    for (final input in inputs) {
      byPath[input.path] = input;
    }
    final ordered = byPath.values.toList()
      ..sort((left, right) => left.path.compareTo(right.path));
    final digest = _DigestSink();
    final sink = sha256.startChunkedConversion(digest);
    for (final input in ordered) {
      sink.add(utf8.encode('${input.path}:'));
      sink.add(sha256.convert(input.bytes).bytes);
      sink.add(const [0x0a]);
    }
    sink.close();
    return digest.value.toString();
  }

  /// Every file under `lib/`, `bin/`, and `hook/` plus the package pubspecs.
  List<_FingerprintInput> _packageInputs(String packageRoot) {
    final inputs = <_FingerprintInput>[];
    for (final name in const ['pubspec.yaml', 'pubspec.lock']) {
      final file = File(p.join(packageRoot, name));
      if (file.existsSync()) {
        inputs.add(_FingerprintInput(file.path, file.readAsBytesSync()));
      }
    }
    for (final name in const ['lib', 'bin']) {
      final directory = Directory(p.join(packageRoot, name));
      if (!directory.existsSync()) continue;
      for (final entity in directory.listSync(recursive: true)) {
        if (entity is File && entity.path.endsWith('.dart')) {
          inputs.add(_FingerprintInput(entity.path, entity.readAsBytesSync()));
        }
      }
    }
    // Native build hooks change the produced artifact even when no Dart source
    // changes, so every hook file is an input regardless of extension.
    final hookDirectory = Directory(p.join(packageRoot, 'hook'));
    if (hookDirectory.existsSync()) {
      for (final entity in hookDirectory.listSync(
        recursive: true,
        followLinks: false,
      )) {
        if (entity is! File) continue;
        inputs.add(_FingerprintInput(entity.path, entity.readAsBytesSync()));
      }
    }
    return inputs;
  }

  /// Absolute paths of every transitive `path:` dependency package.
  ///
  /// A path dependency can itself depend on another path package, so a single
  /// level would miss shared primitives such as the release contract.
  List<String> _pathDependencyClosure(String packageRoot) {
    final collected = <String>[];
    final visited = <String>{p.normalize(packageRoot)};
    final queue = <String>[p.normalize(packageRoot)];
    while (queue.isNotEmpty) {
      final current = queue.removeLast();
      final pubspec = File(p.join(current, 'pubspec.yaml'));
      if (!pubspec.existsSync()) continue;
      for (final dependency in _pathDependencies(pubspec)) {
        final resolved = p.normalize(p.join(current, dependency));
        if (!visited.add(resolved)) continue;
        if (!Directory(resolved).existsSync()) continue;
        collected.add(resolved);
        queue.add(resolved);
      }
    }
    collected.sort();
    return collected;
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

  String _lockPath(CompiledCliComponent component, String directory) =>
      p.join(directory, compiledCliLockFileName(component));

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
        // One rename publishes the new artifact: POSIX replaces the destination
        // atomically, and on Windows the exclusive lock already excludes every
        // reader, so the short delete window is invisible to them.
        if (Platform.isWindows) _deletePathSync(target);
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
        final previous = p.join(directory, '.client-bundle-previous');
        _deletePathSync(previous);
        if (Directory(destination).existsSync()) {
          Directory(destination).renameSync(previous);
        }
        Directory(produced).renameSync(destination);
        _deletePathSync(staging);
        _deletePathSync(previous);
    }
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

  static Future<String> _readDartSdkVersion() async {
    try {
      final result = await Process.run('dart', ['--version']);
      return '${result.stdout}${result.stderr}'.trim();
    } on Object {
      return 'unknown';
    }
  }
}

/// One fingerprint input: a stable label and its bytes.
class _FingerprintInput {
  const _FingerprintInput(this.path, this.bytes);

  final String path;
  final List<int> bytes;
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
    try {
      Directory(path).deleteSync(recursive: true);
    } on FileSystemException {
      // A running Windows artifact cannot be removed yet; the next build retries.
    }
  } else {
    try {
      File(path).deleteSync();
    } on FileSystemException {
      // Same as above.
    }
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
