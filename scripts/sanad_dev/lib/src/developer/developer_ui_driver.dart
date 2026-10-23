part of '../../sanad_dev_cli.dart';

/// Time a `sanad-dev ui` action may spend after the driver's own deadline
/// before the child process is killed.
const int uiDriverChildGraceSeconds = 10;

/// Default per-action deadline forwarded to the driver CLI, in seconds.
const int uiDriverDefaultActionTimeoutSeconds = 30;

/// Default post-action delay the driver applies before verifying, in ms.
const int uiDriverDefaultDelayMs = 300;

/// Default post-condition window the driver observes, in ms.
const int uiDriverDefaultVerifyMs = 2000;

/// Default sleep applied by a batch `sleep` step without an explicit value.
const int uiDriverDefaultSleepMs = 1000;

/// Default wall-clock cap for a batch recipe that cannot be read.
const int uiDriverBatchDefaultWallSeconds = 300;

/// Exit status reported when the driver child had to be killed.
const int uiDriverTimeoutExitCode = 124;

/// Upper bound for one driver CLI compilation.
const Duration uiDriverCompileTimeout = Duration(minutes: 3);

/// Driver commands that change the Client UI and may therefore bring the
/// owning window to the front. Read-only commands never take focus.
const Set<String> uiDriverActivatingCommands = {
  'tap',
  'enter-text',
  'entertext',
  'type',
  'scroll',
  'batch',
  'run',
};

/// Driver commands whose wall clock must also cover a post-delay and a
/// post-condition window.
const Set<String> uiDriverVerifyingCommands = {
  'tap',
  'enter-text',
  'entertext',
  'type',
};

/// Driver options that consume the following argument as their value.
///
/// The launcher only strips its own flags from value positions that cannot be a
/// driver value, so `enter-text --text --home` keeps `--home` as input text.
const Set<String> _uiDriverValueFlags = {
  '--key',
  '-k',
  '--text',
  '-t',
  '--type',
  '--within',
  '-w',
  '--index',
  '-i',
  '-x',
  '-y',
  '--coords',
  '--timeout',
  '--delay',
  '--verify-timeout',
  '--expect',
  '--expect-key',
  '--expect-absent',
  '--expect-gone',
  '--vm-url',
  '-u',
  '--file',
  '-f',
  '--json-steps',
  '--report-file',
  '--out',
  '-o',
  '--filter',
  '--query',
  '-q',
  '--direction',
  '--dx',
  '--dy',
  '--to',
  '--until-visible',
};

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

  /// The driver sub-command, lower-cased, or an empty string for help.
  String get command {
    if (driverArguments.isEmpty || driverArguments.first.startsWith('-')) {
      return '';
    }
    return driverArguments.first.toLowerCase();
  }

  bool get isBatch => command == 'batch' || command == 'run';

  /// Only UI-changing actions may take focus from the user.
  bool get activatesUi =>
      activateWindow && uiDriverActivatingCommands.contains(command);

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

/// One declarative batch step, reduced to the fields that bound its duration.
class UiDriverBatchStepBudget {
  const UiDriverBatchStepBudget({
    required this.action,
    this.timeoutSeconds,
    this.delayMs,
    this.sleepMs,
  });

  final String action;
  final int? timeoutSeconds;
  final int? delayMs;
  final int? sleepMs;

  bool get _verifies =>
      action == 'tap' ||
      action == 'enter_text' ||
      action == 'entertext' ||
      action == 'type';
  bool get _sleeps => action == 'sleep' || action == 'delay';
}

/// Splits `sanad-dev ui` arguments into forwarded driver arguments and the
/// launcher-owned flags that never reach the driver.
///
/// Launcher flags are stripped wherever they cannot be a driver value: outside a
/// value-taking driver option, and never after a `--` terminator. A positional
/// or option value that happens to equal `--home` or `--activate` therefore
/// reaches the driver unchanged.
UiDriverRunPlan planUiDriverRun(
  List<String> args, {
  List<UiDriverBatchStepBudget>? batchSteps,
}) {
  final driverArgs = <String>[];
  var activate = true;
  int? wallTimeoutSeconds;
  var index = 0;
  var endOfLauncherFlags = false;

  while (index < args.length) {
    final arg = args[index];
    if (endOfLauncherFlags) {
      driverArgs.add(arg);
      index++;
      continue;
    }
    if (arg == '--') {
      endOfLauncherFlags = true;
      index++;
      continue;
    }
    final valueFollows = index + 1 < args.length ? args[index + 1] : null;
    // A driver option value is preserved even when it matches a launcher flag.
    final isDriverValue =
        driverArgs.isNotEmpty &&
        driverArgs.last.startsWith('-') &&
        _uiDriverValueFlags.contains(driverArgs.last);
    if (!isDriverValue) {
      if (arg == '--home') {
        index += 2;
        continue;
      }
      if (arg.startsWith('--home=')) {
        index++;
        continue;
      }
      if (arg == '--activate') {
        activate = true;
        index++;
        continue;
      }
      if (arg == '--no-activate') {
        activate = false;
        index++;
        continue;
      }
      if (arg == '--wall-timeout' && valueFollows != null) {
        wallTimeoutSeconds = int.tryParse(valueFollows);
        index += 2;
        continue;
      }
      if (arg.startsWith('--wall-timeout=')) {
        wallTimeoutSeconds = int.tryParse(
          arg.substring('--wall-timeout='.length),
        );
        index++;
        continue;
      }
    }
    driverArgs.add(arg);
    index++;
  }

  final command = driverArgs.isEmpty || driverArgs.first.startsWith('-')
      ? ''
      : driverArgs.first.toLowerCase();
  final explicitSeconds = int.tryParse(
    _uiDriverOptionValue(driverArgs, '--timeout') ?? '',
  );
  final Duration wallTimeout;
  if (wallTimeoutSeconds != null && wallTimeoutSeconds > 0) {
    wallTimeout = Duration(seconds: wallTimeoutSeconds);
  } else if (command == 'batch' || command == 'run') {
    final stepBudget = batchSteps ?? readUiDriverBatchSteps(driverArgs);
    final budget = stepBudget == null
        ? null
        : uiDriverBatchBudgetSeconds(
            stepBudget,
            fallbackStepTimeout: explicitSeconds,
          );
    wallTimeout = budget == null
        ? const Duration(seconds: uiDriverBatchDefaultWallSeconds)
        : Duration(seconds: budget + uiDriverChildGraceSeconds);
  } else {
    final actionSeconds =
        explicitSeconds ?? uiDriverDefaultActionTimeoutSeconds;
    final verifies = uiDriverVerifyingCommands.contains(command);
    final delayMs = int.tryParse(
      _uiDriverOptionValue(driverArgs, '--delay') ?? '',
    );
    final verifyMs = int.tryParse(
      _uiDriverOptionValue(driverArgs, '--verify-timeout') ?? '',
    );
    wallTimeout = Duration(
      seconds: actionSeconds + uiDriverChildGraceSeconds,
      milliseconds:
          (delayMs ?? (verifies ? uiDriverDefaultDelayMs : 0)) +
          (verifyMs ?? (verifies ? uiDriverDefaultVerifyMs : 0)),
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

/// Total seconds a batch recipe may consume.
///
/// Every step contributes its own `timeout_seconds`, `delay_ms`, `sleep_ms`, and
/// verify window, so a recipe of slow steps is not capped by a single action
/// deadline times the step count.
int uiDriverBatchBudgetSeconds(
  List<UiDriverBatchStepBudget> steps, {
  int? fallbackStepTimeout,
}) {
  var total = 0;
  for (final step in steps) {
    final stepTimeout =
        step.timeoutSeconds ??
        fallbackStepTimeout ??
        uiDriverDefaultActionTimeoutSeconds;
    if (step._sleeps) {
      total += ((step.sleepMs ?? uiDriverDefaultSleepMs) / 1000).ceil();
      continue;
    }
    total += stepTimeout;
    if (step._verifies) {
      total += ((step.delayMs ?? uiDriverDefaultDelayMs) / 1000).ceil();
      total += ((stepVerifyWindowMs(stepTimeout)) / 1000).ceil();
    }
  }
  return total == 0 ? 0 : total;
}

/// Verify window the driver applies to a step with [stepTimeoutSeconds].
int stepVerifyWindowMs(int stepTimeoutSeconds) {
  final stepMs = stepTimeoutSeconds * 1000;
  return stepMs < uiDriverDefaultVerifyMs ? stepMs : uiDriverDefaultVerifyMs;
}

/// Parses the declarative batch steps of a recipe so the wall clock can cover
/// them. Returns null when the recipe cannot be read cheaply.
List<UiDriverBatchStepBudget>? readUiDriverBatchSteps(List<String> driverArgs) {
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
    if (steps == null || steps.isEmpty) return null;
    return steps
        .map((step) {
          final map = Map<String, dynamic>.from(step as Map);
          return UiDriverBatchStepBudget(
            action: (map['action'] as String? ?? '').toLowerCase(),
            timeoutSeconds:
                map['timeout_seconds'] as int? ?? map['timeout'] as int?,
            delayMs: map['delay_ms'] as int? ?? map['delay'] as int?,
            sleepMs:
                map['sleep_ms'] as int? ??
                map['sleep'] as int? ??
                map['ms'] as int?,
          );
        })
        .toList(growable: false);
  } catch (_) {
    return null;
  }
}

/// Counts declarative batch steps. Kept for callers that only need the count.
int? uiDriverBatchStepCount(List<String> driverArgs) =>
    readUiDriverBatchSteps(driverArgs)?.length;

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

/// Temporary report path that carries per-step batch evidence.
String uiDriverBatchReportPath() {
  final stamp = DateTime.now().microsecondsSinceEpoch;
  return '${Directory.systemTemp.path}/sanad-dev-ui/batch-$pid-$stamp.json';
}

/// Reproduces the completed steps of a killed batch from its report file.
///
/// Returns null when no step completed, so the caller can fall back to the
/// generic timeout diagnostic.
String? uiDriverPartialBatchReport(String reportPath) {
  try {
    final file = File(reportPath);
    if (!file.existsSync()) return null;
    final decoded = json.decode(file.readAsStringSync());
    if (decoded is! Map) return null;
    final results = decoded['results'];
    if (results is! List || results.isEmpty) return null;
    final passed = results.where((result) {
      return result is Map && result['success'] == true;
    }).length;
    return json.encode({
      'status': 'failed',
      'timed_out': true,
      'partial': true,
      'steps_total': decoded['steps_total'],
      'total': results.length,
      'completed': decoded['completed'] ?? results.length,
      'passed': passed,
      'results': results,
    });
  } catch (_) {
    return null;
  }
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
    if (plan.activatesUi) {
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

  String? reportPath;
  if (plan.isBatch) {
    reportPath = uiDriverBatchReportPath();
    extraArgs.addAll(['--report-file', reportPath]);
  }

  Duration? artifactBuild;
  final artifact = await ensureUiDriverArtifact(
    repositoryRoot: repoRoot,
    allowCompile: !plan.isHelpRequest,
    compile: (outputPath) async {
      final compileTimer = Stopwatch()..start();
      final result = await compileUiDriverArtifact(
        packageConfig: packageConfig,
        toolScript: toolScript,
        workingDirectory: clientDir.path,
        outputPath: outputPath,
      );
      if (!result.compiled) {
        stderr.writeln(
          result.timedOut
              ? 'Driver CLI precompilation exceeded '
                    '${uiDriverCompileTimeout.inMinutes} minutes; falling back '
                    'to the slower JIT path.'
              : 'Driver CLI precompilation failed; falling back to the slower '
                    'JIT path.',
        );
        return false;
      }
      artifactBuild = compileTimer.elapsed;
      stderr.writeln(
        'Prepared driver CLI artifact in '
        '${artifactBuild!.inMilliseconds}ms.',
      );
      return true;
    },
  );

  // The artifact can vanish between the existence check and the spawn (a
  // concurrent prune, a cleaned checkout); fall back to the JIT path instead of
  // failing the action.
  final invocation = planUiDriverInvocation(
    artifactPath: artifact,
    artifactExists: artifact != null && File(artifact).existsSync(),
    packageConfig: packageConfig,
    toolScript: toolScript,
    driverArguments: driverArgs,
    extraArguments: extraArgs,
  );
  var usedJit = invocation.usesJit;

  Process? process;
  try {
    process = await Process.start(
      invocation.executable,
      invocation.arguments,
      workingDirectory: clientDir.path,
      mode: ProcessStartMode.inheritStdio,
      runInShell: usedJit && Platform.isWindows,
      environment: uiDriverChildEnvironment(
        callerDir: callerDir,
        artifactBuild: artifactBuild,
        base: Platform.environment,
      ),
    );
  } on ProcessException catch (error) {
    if (usedJit) rethrow;
    // A missing or non-executable artifact retries through the JIT path.
    stderr.writeln(
      'Driver CLI artifact was not executable '
      '(${error.message}); retrying through the JIT path.',
    );
    usedJit = true;
    final fallback = planUiDriverInvocation(
      artifactPath: null,
      artifactExists: false,
      packageConfig: packageConfig,
      toolScript: toolScript,
      driverArguments: driverArgs,
      extraArguments: extraArgs,
    );
    process = await Process.start(
      fallback.executable,
      fallback.arguments,
      workingDirectory: clientDir.path,
      mode: ProcessStartMode.inheritStdio,
      runInShell: Platform.isWindows,
      environment: uiDriverChildEnvironment(
        callerDir: callerDir,
        artifactBuild: artifactBuild,
        base: Platform.environment,
      ),
    );
  }

  final code = await awaitUiDriverChild(
    UiDriverSpawnedProcess(process),
    wallTimeout: plan.wallTimeout,
  );
  if (code == uiDriverTimeoutExitCode) {
    final partial = reportPath == null
        ? null
        : uiDriverPartialBatchReport(reportPath);
    if (partial != null) {
      if (plan.driverArguments.contains('--json')) {
        stdout.writeln(partial);
      } else {
        _printUiDriverPartialBatch(partial);
      }
      stderr.writeln(
        'Batch recipe was killed after ${plan.wallTimeout.inSeconds}s; the '
        'report above contains only the steps that completed.',
      );
    } else {
      stderr.writeln(
        'Driver action exceeded ${plan.wallTimeout.inSeconds}s and was killed'
        '${usedJit ? ' (JIT fallback)' : ''}. '
        'Retry with a longer --timeout, or navigate to the target first.',
      );
    }
  }
  if (reportPath != null) {
    try {
      final report = File(reportPath);
      if (report.existsSync()) report.deleteSync();
    } catch (_) {}
  }
  exit(code);
}

/// Prints the completed steps of a killed batch in human-readable form.
void _printUiDriverPartialBatch(String partialJson) {
  try {
    final payload = json.decode(partialJson);
    final results = payload['results'];
    if (results is List) {
      for (var index = 0; index < results.length; index++) {
        final result = results[index];
        final message = result is Map ? result['message'] : result;
        stdout.writeln('${index + 1}. $message');
      }
    }
    stdout.writeln(
      'Completed ${payload['total']} of ${payload['steps_total']} steps before '
      'the kill.',
    );
  } catch (_) {
    stdout.writeln(partialJson);
  }
}
