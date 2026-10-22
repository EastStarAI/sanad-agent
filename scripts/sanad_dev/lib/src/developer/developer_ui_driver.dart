part of '../../sanad_dev_cli.dart';

/// Time a `sanad-dev ui` action may spend after the driver's own deadline
/// before the child process is killed.
const int uiDriverChildGraceSeconds = 10;

/// Default per-action deadline forwarded to the driver CLI, in seconds.
const int uiDriverDefaultActionTimeoutSeconds = 30;

/// Default wall-clock cap for a batch recipe without explicit step timeouts.
const int uiDriverBatchDefaultWallSeconds = 300;

/// Exit status reported when the driver child had to be killed.
const int uiDriverTimeoutExitCode = 124;

List<ClientInstance> selectManagedUiDriverClients(
  RuntimeOwnershipAssessment ownership,
) {
  if (!ownership.isManaged) return const [];
  return ownership.state.ownedClients
      .where(
        (client) =>
            client.launchProfile?.target
                ?.replaceAll('\\\\', '/')
                .endsWith('lib/driver_main.dart') ==
            true,
      )
      .toList(growable: false);
}

/// Everything one `sanad-dev ui` invocation needs before a child is spawned.
class UiDriverRunPlan {
  const UiDriverRunPlan({
    required this.driverArguments,
    required this.wallTimeout,
    required this.activateWindow,
  });

  /// Arguments forwarded verbatim to the driver CLI.
  final List<String> driverArguments;

  /// Hard wall-clock cap for the child process.
  final Duration wallTimeout;

  /// Whether the owning Client window is brought to the front first.
  final bool activateWindow;

  bool get isHelpRequest =>
      driverArguments.isEmpty ||
      driverArguments.first == 'help' ||
      driverArguments.any((arg) => arg == '-h' || arg == '--help');

  bool get hasExplicitVmUrl => driverArguments.any(
    (arg) =>
        arg == '--vm-url' ||
        arg == '-u' ||
        arg.startsWith('--vm-url=') ||
        arg.startsWith('-u='),
  );
}

/// Splits `sanad-dev ui` arguments into forwarded driver arguments and the
/// launcher-owned flags that never reach the driver.
UiDriverRunPlan planUiDriverRun(
  List<String> args, {
  int? batchStepCount,
}) {
  final driverArgs = <String>[];
  var activate = true;
  int? wallTimeoutSeconds;
  for (var index = 0; index < args.length; index++) {
    final arg = args[index];
    if (arg == '--home') {
      index++;
      continue;
    }
    if (arg.startsWith('--home=')) continue;
    if (arg == '--activate') continue;
    if (arg == '--no-activate') {
      activate = false;
      continue;
    }
    if (arg == '--wall-timeout') {
      if (index + 1 < args.length) {
        wallTimeoutSeconds = int.tryParse(args[index + 1]);
        index++;
      }
      continue;
    }
    if (arg.startsWith('--wall-timeout=')) {
      wallTimeoutSeconds = int.tryParse(arg.substring('--wall-timeout='.length));
      continue;
    }
    driverArgs.add(arg);
  }

  final command = driverArgs.isEmpty ? '' : driverArgs.first.toLowerCase();
  final explicitSeconds = int.tryParse(
    _uiDriverOptionValue(driverArgs, '--timeout') ?? '',
  );
  final Duration wallTimeout;
  if (wallTimeoutSeconds != null && wallTimeoutSeconds > 0) {
    wallTimeout = Duration(seconds: wallTimeoutSeconds);
  } else if (command == 'batch' || command == 'run') {
    final stepBudget = explicitSeconds ?? uiDriverDefaultActionTimeoutSeconds;
    final steps = batchStepCount ?? uiDriverBatchStepCount(driverArgs);
    wallTimeout = steps == null
        ? const Duration(seconds: uiDriverBatchDefaultWallSeconds)
        : Duration(seconds: stepBudget * steps + uiDriverChildGraceSeconds);
  } else {
    wallTimeout = Duration(
      seconds:
          (explicitSeconds ?? uiDriverDefaultActionTimeoutSeconds) +
          uiDriverChildGraceSeconds,
    );
  }

  return UiDriverRunPlan(
    driverArguments: List.unmodifiable(driverArgs),
    wallTimeout: wallTimeout,
    activateWindow: activate,
  );
}

String? _uiDriverOptionValue(List<String> args, String flag) {
  for (var index = 0; index < args.length; index++) {
    if (args[index] == flag && index + 1 < args.length) {
      return args[index + 1];
    }
    if (args[index].startsWith('$flag=')) {
      return args[index].substring(flag.length + 1);
    }
  }
  return null;
}

/// Counts declarative batch steps so the wall-clock cap covers the whole
/// recipe. Returns null when the recipe cannot be read cheaply.
int? uiDriverBatchStepCount(List<String> driverArgs) {
  String? content;
  final rawSteps = _uiDriverOptionValue(driverArgs, '--json-steps');
  final filePath =
      _uiDriverOptionValue(driverArgs, '--file') ??
      _uiDriverOptionValue(driverArgs, '-f');
  try {
    if (rawSteps != null) {
      content = rawSteps;
    } else if (filePath != null) {
      final callerDir = Platform.environment['SANAD_DEV_CALLER_DIR'];
      final candidates = <String>[
        filePath,
        if (callerDir != null) '$callerDir/$filePath',
        if (filePath.startsWith('client/')) filePath.substring(7),
        '../$filePath',
      ];
      for (final candidate in candidates) {
        final file = File(candidate);
        if (file.existsSync()) {
          content = file.readAsStringSync();
          break;
        }
      }
    }
  } catch (_) {
    return null;
  }
  if (content == null || content.trim().isEmpty) return null;
  try {
    final decoded = json.decode(content);
    final steps = decoded is List ? decoded : decoded['steps'] as List?;
    final count = steps?.length ?? 0;
    return count == 0 ? null : count;
  } catch (_) {
    return null;
  }
}

/// Change-detection fingerprint of the driver CLI sources.
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

/// Reads the driver CLI sources that participate in the artifact fingerprint.
Map<String, String> readUiDriverSources(String repositoryRoot) {
  final entry = File('$repositoryRoot/scripts/flutter_driver_cli.dart');
  if (!entry.existsSync()) return const {};
  final sources = <String, String>{
    'scripts/flutter_driver_cli.dart': entry.readAsStringSync(),
  };
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
}) async {
  final sources = readUiDriverSources(repositoryRoot);
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
  final staging = '$artifact.${pid}.tmp';
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

void _pruneUiDriverArtifacts({
  required Directory artifactDirectory,
  required String keep,
}) {
  try {
    for (final entity in artifactDirectory.listSync()) {
      if (entity is! File) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (!name.startsWith('flutter-driver-cli-')) continue;
      if (entity.path == keep) continue;
      try {
        entity.deleteSync();
      } catch (_) {}
    }
  } catch (_) {}
}

/// Minimal child-process boundary so the wall-clock guard stays testable.
abstract class UiDriverChildProcess {
  Future<int> get exitCode;

  void kill();
}

class UiDriverSpawnedProcess implements UiDriverChildProcess {
  UiDriverSpawnedProcess(this._process);

  final Process _process;

  @override
  Future<int> get exitCode => _process.exitCode;

  @override
  void kill() {
    _process.kill(ProcessSignal.sigkill);
  }
}

/// Waits for [child] and kills it once [wallTimeout] elapses.
Future<int> awaitUiDriverChild(
  UiDriverChildProcess child, {
  required Duration wallTimeout,
}) async {
  var killed = false;
  final code = await child.exitCode.timeout(
    wallTimeout,
    onTimeout: () {
      killed = true;
      child.kill();
      return uiDriverTimeoutExitCode;
    },
  );
  if (killed) return uiDriverTimeoutExitCode;
  return code;
}

Future<void> handleUiDriverCommand(
  List<String> args, {
  String? sanadHomePath,
}) async {
  final callerDir =
      Platform.environment['SANAD_DEV_CALLER_DIR'] ?? Directory.current.path;
  final runtime = await discoverSanadDevRuntime(
    callerDirectory: callerDir,
    sanadHomeOverride: sanadHomePath,
  );
  final plan = planUiDriverRun(args);
  final driverArgs = plan.driverArguments;
  final repoRoot = runtime.repositoryRoot;
  final clientDir = Directory('$repoRoot/client');
  final toolScript = '$repoRoot/scripts/flutter_driver_cli.dart';

  final extraArgs = <String>[];
  if (!plan.hasExplicitVmUrl && !plan.isHelpRequest) {
    final managed = await _resolveManagedUiDriverClient(runtime, sanadHomePath);
    if (managed.error != null) {
      stderr.writeln(managed.error);
      exitCode = 1;
      return;
    }
    final selectedClient = managed.client!;
    if (plan.activateWindow) {
      await activateUiDriverOwnerWindow(pid: selectedClient.pid);
    }
    final tokenPath = selectedClient.token.isEmpty
        ? ''
        : '${selectedClient.token}/';
    extraArgs.addAll([
      '--vm-url',
      'http://127.0.0.1:${selectedClient.port}/$tokenPath',
    ]);
  }

  final packageConfig = '${clientDir.path}/.dart_tool/package_config.json';
  if (!File(packageConfig).existsSync()) {
    stderr.writeln(
      'Client dependencies are not resolved for this checkout '
      '($packageConfig is missing). '
      'Run `sanad-dev setup` or `fvm flutter pub get` in client/ first.',
    );
    exitCode = 1;
    return;
  }

  final artifact = await ensureUiDriverArtifact(
    repositoryRoot: repoRoot,
    allowCompile: !plan.isHelpRequest,
    compile: (outputPath) async {
      final compileTimer = Stopwatch()..start();
      final result = await Process.run(
        'fvm',
        [
          'dart',
          'compile',
          'exe',
          '--packages=$packageConfig',
          toolScript,
          '-o',
          outputPath,
        ],
        workingDirectory: clientDir.path,
        runInShell: Platform.isWindows,
      );
      if (result.exitCode != 0) {
        stderr.writeln(
          'Driver CLI precompilation failed; falling back to the slower '
          'JIT path.',
        );
        return false;
      }
      stderr.writeln(
        'Prepared driver CLI artifact in ${compileTimer.elapsed.inMilliseconds}ms.',
      );
      return true;
    },
  );

  final executable = artifact ?? 'fvm';
  final executableArgs = artifact != null
      ? <String>[...driverArgs, ...extraArgs]
      : <String>[
          'dart',
          '--packages=$packageConfig',
          toolScript,
          ...driverArgs,
          ...extraArgs,
        ];

  final process = await Process.start(
    executable,
    executableArgs,
    workingDirectory: clientDir.path,
    mode: ProcessStartMode.inheritStdio,
    runInShell: artifact == null && Platform.isWindows,
    environment: {...Platform.environment, 'SANAD_DEV_CALLER_DIR': callerDir},
  );

  final code = await awaitUiDriverChild(
    UiDriverSpawnedProcess(process),
    wallTimeout: plan.wallTimeout,
  );
  if (code == uiDriverTimeoutExitCode) {
    stderr.writeln(
      'Driver action exceeded ${plan.wallTimeout.inSeconds}s and was killed. '
      'Retry with a longer --timeout, or navigate to the target first.',
    );
  }
  exit(code);
}

class _ManagedUiDriverClient {
  const _ManagedUiDriverClient(this.client, this.error);

  final ClientInstance? client;
  final String? error;
}

/// Resolves the single launcher-owned driver Client for this worktree.
///
/// A missing Client is retried once because discovery can race a Client that is
/// still finishing startup; the same condition reported by a live Client was
/// the most common transient `ui` failure.
Future<_ManagedUiDriverClient> _resolveManagedUiDriverClient(
  SanadDevRuntime runtime,
  String? sanadHomePath,
) async {
  for (var attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) {
      await Future<void>.delayed(const Duration(milliseconds: 400));
    }
    final activeClients = await discoverClientInstances();
    final processState = selectRuntimeProcessState(
      activeAgents: await discoverAgentInstances(
        sanadHomeOverride: sanadHomePath,
      ),
      activeClients: activeClients,
      runtime: runtime,
    );
    final activeHome = resolveActiveSanadHome(runtime, processState);
    final ownership = await assessRuntimeOwnership(
      runtime: runtime,
      state: processState,
      sanadHome: activeHome,
    );
    final managedClients = selectManagedUiDriverClients(ownership);
    if (managedClients.length == 1) {
      return _ManagedUiDriverClient(managedClients.single, null);
    }
    if (managedClients.length > 1) {
      return const _ManagedUiDriverClient(
        null,
        'Multiple managed clients are active for this worktree. '
        'Pass --vm-url explicitly to select one.',
      );
    }
  }
  return const _ManagedUiDriverClient(
    null,
    'No active driver-enabled client is managed for this worktree. '
    'Run `sanad-dev run --driver` first or pass --vm-url explicitly.',
  );
}

/// Bundle root of a running Client executable, or null when the executable is
/// not inside an application bundle.
String? uiDriverBundlePath(String? executable) {
  if (executable == null) return null;
  final marker = executable.indexOf('.app/Contents/MacOS/');
  if (marker < 0) return null;
  return executable.substring(0, marker + '.app'.length);
}

/// Brings the owning Client window to the front before an action is dispatched.
///
/// macOS activates only the bundle of the already-running Client whose process
/// id was discovered, so no Accessibility, Automation, or Keychain prompt is
/// ever triggered. Every failure is a silent no-op: the action still runs.
Future<bool> activateUiDriverOwnerWindow({
  required int? pid,
  bool? isMacOS,
  Future<ProcessResult> Function(String, List<String>)? openApplication,
}) async {
  if (!(isMacOS ?? Platform.isMacOS) || pid == null || pid <= 0) return false;
  String? bundlePath;
  try {
    final arguments = readMacOsProcessArguments(pid);
    bundlePath = uiDriverBundlePath(
      arguments.isEmpty ? null : arguments.first,
    );
  } catch (_) {
    return false;
  }
  if (bundlePath == null) return false;
  try {
    final run =
        openApplication ??
        (String executable, List<String> arguments) => Process.run(
          executable,
          arguments,
          stdoutEncoding: null,
          stderrEncoding: null,
        );
    await run('open', ['-a', bundlePath]).timeout(const Duration(seconds: 3));
    return true;
  } catch (_) {
    return false;
  }
}
