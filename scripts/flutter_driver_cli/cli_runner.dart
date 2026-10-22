import 'dart:convert';
import 'dart:io';

import 'flutter_vm_controller.dart';
import 'models.dart';
import 'tree_state.dart';

/// Default hard deadline for one driver action, in seconds.
const int defaultActionTimeoutSeconds = 30;

/// Launcher-provided artifact build cost, in milliseconds.
///
/// `sanad-dev ui` sets this only on an invocation that had to compile the
/// driver artifact; a cached artifact, a standalone CLI run, or the JIT path
/// leaves it unset, so `build_ms` is reported exactly once per cold start
/// instead of being charged to every call.
const String driverBuildMsEnvVar = 'SANAD_DEV_UI_BUILD_MS';

class CliRunner {
  final List<String> args;

  /// Overrides the snapshot generation store; tests inject a temp location.
  final UiTreeGenerationStore? generationStore;

  /// Root directory for the default generation store; tests inject a temp dir.
  final Directory? generationRoot;

  /// Artifact build cost to report, when this process was told about one.
  final int? buildMs;

  CliRunner(this.args, {this.generationStore, this.generationRoot, int? buildMs})
    : buildMs =
          buildMs ?? _parseBuildMs(Platform.environment[driverBuildMsEnvVar]);

  static int? _parseBuildMs(String? raw) {
    final value = int.tryParse(raw ?? '');
    return value != null && value > 0 ? value : null;
  }

  /// Emits one JSON result, adding the cold artifact cost when it applies.
  void _printJson(Map<String, dynamic> payload) {
    final cost = buildMs;
    print(
      json.encode(
        cost == null ? payload : {...payload, 'build_ms': cost},
      ),
    );
  }

  Future<int> run() async {
    if (args.isEmpty ||
        args.contains('-h') ||
        args.contains('--help') ||
        args.first == 'help') {
      _printUsage();
      return 0;
    }

    final command = args.first.toLowerCase();
    final commandArgs = args.sublist(1);
    final isJson = _hasFlag(commandArgs, '--json');
    final explicitUrl =
        _getOption(commandArgs, '--vm-url') ?? _getOption(commandArgs, '-u');

    try {
      switch (command) {
        case 'snapshot':
        case 'inspect':
          return await _handleSnapshot(commandArgs, explicitUrl, isJson);

        case 'find':
          return await _handleFind(commandArgs, explicitUrl, isJson);

        case 'auth-url':
          return await _handleAuthUrl(explicitUrl, isJson);

        case 'tap':
          return await _handleTap(commandArgs, explicitUrl, isJson);

        case 'enter-text':
        case 'entertext':
        case 'type':
          return await _handleEnterText(commandArgs, explicitUrl, isJson);

        case 'scroll':
          return await _handleScroll(commandArgs, explicitUrl, isJson);

        case 'wait-for':
        case 'waitfor':
        case 'wait':
          return await _handleWaitFor(commandArgs, explicitUrl, isJson);

        case 'screenshot':
        case 'capture':
          return await _handleScreenshot(commandArgs, explicitUrl, isJson);

        case 'batch':
        case 'run':
          return await _handleBatch(commandArgs, explicitUrl, isJson);

        default:
          print('❌ Unknown command: "$command"');
          _printUsage();
          return 1;
      }
    } catch (e) {
      if (isJson) {
        print(json.encode({'status': 'error', 'error': e.toString()}));
      } else if (command == 'auth-url') {
        stderr.writeln('Authentication URL unavailable: $e');
      } else {
        print('❌ Error executing command "$command": $e');
      }
      return 1;
    }
  }

  Future<FlutterVmController> _connect({
    required String? explicitUrl,
    required Duration rpcTimeout,
    bool connectDriver = false,
  }) async {
    final controller = await FlutterVmController.connect(
      explicitUrl: explicitUrl,
      connectDriver: connectDriver,
    );
    controller.rpcTimeout = rpcTimeout;
    // Key the counter by the *resolved* endpoint so an invocation without an
    // explicit --vm-url still uses its own Client's counter.
    controller.generationStore =
        generationStore ??
        UiTreeGenerationStore.forVmServiceUrl(
          controller.serviceUrl,
          root: generationRoot,
        );
    return controller;
  }

  Future<int> _handleAuthUrl(String? explicitUrl, bool isJson) async {
    final controller = await _connect(
      explicitUrl: explicitUrl,
      rpcTimeout: const Duration(seconds: defaultActionTimeoutSeconds),
    );
    try {
      final authUrl = await controller.authUrl();
      if (isJson) {
        _printJson({'status': 'ok', 'auth_url': authUrl});
      } else {
        print(authUrl);
      }
      return 0;
    } finally {
      await controller.close();
    }
  }

  Future<int> _handleSnapshot(
    List<String> cmdArgs,
    String? explicitUrl,
    bool isJson,
  ) async {
    final filter = _getOption(cmdArgs, '--filter') ?? _getOption(cmdArgs, '-f');
    final within = _getOption(cmdArgs, '--within') ?? _getOption(cmdArgs, '-w');
    final onlyWithKeys = _hasFlag(cmdArgs, '--only-keys');
    final interactive =
        _hasFlag(cmdArgs, '--interactive') || _hasFlag(cmdArgs, '-i');
    final compact = _hasFlag(cmdArgs, '--compact') || _hasFlag(cmdArgs, '-c');
    final noBounds = _hasFlag(cmdArgs, '--no-bounds') || compact;
    final fresh = _hasFlag(cmdArgs, '--fresh');
    final timeoutSec = _getIntOption(
      cmdArgs,
      '--timeout',
      defaultVal: defaultActionTimeoutSeconds,
    );

    final controller = await _connect(
      explicitUrl: explicitUrl,
      rpcTimeout: Duration(seconds: timeoutSec),
    );
    try {
      final capture = fresh
          ? await controller.captureSettledTree(
              filter: filter,
              within: within,
              includeBounds: !noBounds,
              onlyWithKeys: onlyWithKeys,
              interactiveOnly: interactive,
              timeout: Duration(seconds: timeoutSec),
            )
          : await controller.captureTree(
              filter: filter,
              within: within,
              includeBounds: !noBounds,
              onlyWithKeys: onlyWithKeys,
              interactiveOnly: interactive,
            );
      final elements = capture.elements;
      final generation = controller.generationStore?.next();

      if (isJson) {
        _printJson({
          'status': 'ok',
          'count': elements.length,
          'generation': generation,
          'signature': capture.signature,
          // `fresh` is true only on a `--fresh` capture; `settled` then reports
          // whether two consecutive trees actually agreed.
          'fresh': fresh,
          if (fresh) 'settled': capture.settled,
          'elements': elements.map((e) => e.toJson()).toList(),
        });
      } else {
        _printElementsFormatted(elements, compact: compact);
        print(
          'generation: $generation'
          '${fresh ? (capture.settled ? ' (fresh)' : ' (fresh, unsettled)') : ''}',
        );
      }
      return 0;
    } finally {
      await controller.close();
    }
  }

  Future<int> _handleFind(
    List<String> cmdArgs,
    String? explicitUrl,
    bool isJson,
  ) async {
    final key = _getOption(cmdArgs, '--key') ?? _getOption(cmdArgs, '-k');
    final text = _getOption(cmdArgs, '--text') ?? _getOption(cmdArgs, '-t');
    final type = _getOption(cmdArgs, '--type');
    final query = _getOption(cmdArgs, '--query') ?? _getOption(cmdArgs, '-q');
    final within = _getOption(cmdArgs, '--within') ?? _getOption(cmdArgs, '-w');
    final interactive =
        _hasFlag(cmdArgs, '--interactive') || _hasFlag(cmdArgs, '-i');
    final compact = _hasFlag(cmdArgs, '--compact') || _hasFlag(cmdArgs, '-c');
    final timeoutSec = _getIntOption(
      cmdArgs,
      '--timeout',
      defaultVal: defaultActionTimeoutSeconds,
    );

    if (key == null && text == null && type == null && query == null) {
      print(
        '❌ Must provide at least one filter: --key, --text, --type, or --query',
      );
      return 1;
    }

    final controller = await _connect(
      explicitUrl: explicitUrl,
      rpcTimeout: Duration(seconds: timeoutSec),
    );
    try {
      final matches = await controller.findElements(
        key: key,
        text: text,
        type: type,
        query: query,
        within: within,
        interactiveOnly: interactive,
      );
      final generation = controller.generationStore?.next();

      if (isJson) {
        _printJson({
          'status': 'ok',
          'found': matches.isNotEmpty,
          'count': matches.length,
          'generation': generation,
          'elements': matches.map((e) => e.toJson()).toList(),
        });
      } else {
        if (matches.isEmpty) {
          print(
            '⚠️ No matching elements found${within != null ? " within '$within'" : ""}.',
          );
        } else {
          print(
            '🔍 Found ${matches.length} matching element(s)${within != null ? " within '$within'" : ""}:',
          );
          _printElementsFormatted(matches, compact: compact);
        }
      }
      return matches.isNotEmpty ? 0 : 1;
    } finally {
      await controller.close();
    }
  }

  Future<int> _handleTap(
    List<String> cmdArgs,
    String? explicitUrl,
    bool isJson,
  ) async {
    final key = _getOption(cmdArgs, '--key') ?? _getOption(cmdArgs, '-k');
    final text = _getOption(cmdArgs, '--text') ?? _getOption(cmdArgs, '-t');
    final type = _getOption(cmdArgs, '--type');
    final within = _getOption(cmdArgs, '--within') ?? _getOption(cmdArgs, '-w');
    final index = _getIntOption(
      cmdArgs,
      '--index',
      defaultVal: _getIntOption(cmdArgs, '-i', defaultVal: 0),
    );
    final xValue = _getOption(cmdArgs, '-x');
    final yValue = _getOption(cmdArgs, '-y');
    final coords = _getOption(cmdArgs, '--coords');
    double? targetX = xValue == null ? null : double.tryParse(xValue);
    double? targetY = yValue == null ? null : double.tryParse(yValue);
    if (coords != null && coords.contains(',')) {
      final parts = coords.split(',');
      targetX = double.tryParse(parts[0].trim());
      targetY = double.tryParse(parts[1].trim());
    }

    final timeoutSec = _getIntOption(
      cmdArgs,
      '--timeout',
      defaultVal: defaultActionTimeoutSeconds,
    );
    final delayMs = _getIntOption(cmdArgs, '--delay', defaultVal: 300);
    final verifyMs = _getIntOption(
      cmdArgs,
      '--verify-timeout',
      defaultVal: 2000,
    );
    final expect =
        _getOption(cmdArgs, '--expect') ?? _getOption(cmdArgs, '--expect-key');
    final expectAbsent =
        _getOption(cmdArgs, '--expect-absent') ??
        _getOption(cmdArgs, '--expect-gone');
    final noVerify = _hasFlag(cmdArgs, '--no-verify');
    // `--verify` opts into strict verification: the same unchanged tree that a
    // plain tap reports becomes a failure.
    final strictVerify =
        !noVerify &&
        (_hasFlag(cmdArgs, '--verify') ||
            _hasFlag(cmdArgs, '--strict-verify'));

    if (key == null &&
        text == null &&
        type == null &&
        (targetX == null || targetY == null)) {
      print(
        '❌ Must provide target identifier: --key, --text, --type, or --coords x,y',
      );
      return 1;
    }

    final controller = await _connect(
      explicitUrl: explicitUrl,
      rpcTimeout: Duration(seconds: timeoutSec),
    );
    try {
      final res = await controller.tap(
        key: key,
        text: text,
        type: type,
        within: within,
        index: index,
        x: targetX,
        y: targetY,
        timeout: Duration(seconds: timeoutSec),
        postDelay: Duration(milliseconds: delayMs),
        expect: expect,
        expectAbsent: expectAbsent,
        verify: !noVerify,
        strictVerify: strictVerify,
        verifyTimeout: Duration(milliseconds: verifyMs),
      );

      if (isJson) {
        _printJson(res.toJson());
      } else {
        print(res.toString());
      }
      return res.success ? 0 : 1;
    } finally {
      await controller.close();
    }
  }

  Future<int> _handleEnterText(
    List<String> cmdArgs,
    String? explicitUrl,
    bool isJson,
  ) async {
    final key = _getOption(cmdArgs, '--key') ?? _getOption(cmdArgs, '-k');
    final textOption =
        _getOption(cmdArgs, '--text') ?? _getOption(cmdArgs, '-t');
    final positionalText = _getLeadingPositional(cmdArgs);
    if (textOption == null && positionalText == null) {
      print(
        '❌ Must provide text through --text or a leading positional value.',
      );
      return 1;
    }
    final text = textOption ?? positionalText!;
    final noTapFirst = _hasFlag(cmdArgs, '--no-tap-first');
    final timeoutSec = _getIntOption(
      cmdArgs,
      '--timeout',
      defaultVal: defaultActionTimeoutSeconds,
    );
    final delayMs = _getIntOption(cmdArgs, '--delay', defaultVal: 300);
    final verifyMs = _getIntOption(
      cmdArgs,
      '--verify-timeout',
      defaultVal: 2000,
    );
    final verify = !_hasFlag(cmdArgs, '--no-verify');

    final controller = await _connect(
      explicitUrl: explicitUrl,
      rpcTimeout: Duration(seconds: timeoutSec),
    );
    try {
      final res = await controller.enterText(
        text,
        key: key,
        tapFirst: !noTapFirst,
        timeout: Duration(seconds: timeoutSec),
        postDelay: Duration(milliseconds: delayMs),
        verify: verify,
        verifyTimeout: Duration(milliseconds: verifyMs),
      );

      if (isJson) {
        _printJson(res.toJson());
      } else {
        print(res.toString());
      }
      return res.success ? 0 : 1;
    } finally {
      await controller.close();
    }
  }

  Future<int> _handleScroll(
    List<String> cmdArgs,
    String? explicitUrl,
    bool isJson,
  ) async {
    final key = _getOption(cmdArgs, '--key') ?? _getOption(cmdArgs, '-k');
    final dx = _getDoubleOption(cmdArgs, '--dx', defaultVal: 0.0);
    var dy = _getDoubleOption(cmdArgs, '--dy', defaultVal: -300.0);
    final direction = _getOption(cmdArgs, '--direction')?.toLowerCase();
    final to = _getOption(cmdArgs, '--to')?.toLowerCase();
    final untilVisible = _getOption(cmdArgs, '--until-visible');
    final timeoutSec = _getIntOption(
      cmdArgs,
      '--timeout',
      defaultVal: defaultActionTimeoutSeconds,
    );

    if (direction != null && direction != 'down' && direction != 'up') {
      print('❌ --direction must be up or down.');
      return 1;
    }
    if (to != null && to != 'top' && to != 'bottom') {
      print('❌ --to must be top or bottom.');
      return 1;
    }
    if (to != null && untilVisible != null) {
      print('❌ --to and --until-visible cannot be combined.');
      return 1;
    }
    if (direction == 'down') dy = -300.0;
    if (direction == 'up') dy = 300.0;

    final controller = await _connect(
      explicitUrl: explicitUrl,
      rpcTimeout: Duration(seconds: timeoutSec),
    );
    try {
      final res = await controller.scroll(
        key: key,
        dx: dx,
        dy: dy,
        to: to,
        untilVisibleKey: untilVisible,
        timeout: Duration(seconds: timeoutSec),
      );

      if (isJson) {
        _printJson(res.toJson());
      } else {
        print(res.toString());
      }
      return res.success ? 0 : 1;
    } finally {
      await controller.close();
    }
  }

  Future<int> _handleWaitFor(
    List<String> cmdArgs,
    String? explicitUrl,
    bool isJson,
  ) async {
    final key = _getOption(cmdArgs, '--key') ?? _getOption(cmdArgs, '-k');
    final text = _getOption(cmdArgs, '--text') ?? _getOption(cmdArgs, '-t');
    final type = _getOption(cmdArgs, '--type');
    final absent = _hasFlag(cmdArgs, '--absent');
    final noWait = _hasFlag(cmdArgs, '--no-wait');
    final timeoutSec = _getIntOption(
      cmdArgs,
      '--timeout',
      defaultVal: defaultActionTimeoutSeconds,
    );

    if (key == null && text == null && type == null) {
      print('❌ Must provide target identifier: --key, --text, or --type');
      return 1;
    }

    final controller = await _connect(
      explicitUrl: explicitUrl,
      rpcTimeout: Duration(seconds: timeoutSec),
    );
    try {
      final res = await controller.waitFor(
        key: key,
        text: text,
        type: type,
        absent: absent,
        timeout: Duration(seconds: timeoutSec),
        noWait: noWait,
      );

      if (isJson) {
        _printJson(res.toJson());
      } else {
        print(res.toString());
      }
      return res.success ? 0 : 1;
    } finally {
      await controller.close();
    }
  }

  Future<int> _handleScreenshot(
    List<String> cmdArgs,
    String? explicitUrl,
    bool isJson,
  ) async {
    final out = _getOption(cmdArgs, '--out') ?? _getOption(cmdArgs, '-o');
    final timeoutSec = _getIntOption(
      cmdArgs,
      '--timeout',
      defaultVal: defaultActionTimeoutSeconds,
    );

    final controller = await _connect(
      explicitUrl: explicitUrl,
      rpcTimeout: Duration(seconds: timeoutSec),
      connectDriver: true,
    );
    try {
      final file = await controller.screenshot(outputPath: out);

      if (isJson) {
        _printJson({
          'status': 'ok',
          'file_path': file.path,
          'absolute_path': file.absolute.path,
          'size_bytes': await file.length(),
        });
      } else {
        print('📸 Screenshot successfully saved to: ${file.path}');
      }
      return 0;
    } finally {
      await controller.close();
    }
  }

  Future<int> _handleBatch(
    List<String> cmdArgs,
    String? explicitUrl,
    bool isJson,
  ) async {
    final filePath = _getOption(cmdArgs, '--file') ?? _getOption(cmdArgs, '-f');
    final rawJson = _getOption(cmdArgs, '--json-steps');
    final timeoutSec = _getIntOption(
      cmdArgs,
      '--timeout',
      defaultVal: defaultActionTimeoutSeconds,
    );

    String content = '';
    if (filePath != null) {
      final callerDir = Platform.environment['SANAD_DEV_CALLER_DIR'];
      File file = File(filePath);
      if (!file.existsSync() && callerDir != null) {
        file = File('$callerDir/$filePath');
      }
      if (!file.existsSync() && filePath.startsWith('client/')) {
        file = File(filePath.substring(7));
      }
      if (!file.existsSync()) {
        file = File('../$filePath');
      }

      if (!file.existsSync()) {
        print('❌ Batch recipe file not found: $filePath');
        return 1;
      }
      content = await file.readAsString();
    } else if (rawJson != null) {
      content = rawJson;
    } else {
      // Read from stdin
      content = await utf8.decoder.bind(stdin).join();
    }

    if (content.trim().isEmpty) {
      print('❌ No batch steps provided.');
      return 1;
    }

    final decoded = json.decode(content);
    final List list = decoded is List
        ? decoded
        : (decoded['steps'] as List? ?? []);
    final steps = list
        .map((s) => BatchStep.fromJson(Map<String, dynamic>.from(s as Map)))
        .toList();

    if (!isJson) {
      print('🚀 Running batch with ${steps.length} steps...');
    }
    final reportFile = _getOption(cmdArgs, '--report-file');
    // One value drives both sides: the launcher budgets the wall clock with the
    // batch `--timeout`, and the driver applies the same value to every step
    // that declares no timeout of its own.
    final defaultStepTimeout = Duration(seconds: timeoutSec);
    final controller = await _connect(
      explicitUrl: explicitUrl,
      rpcTimeout: batchRpcTimeout(steps, defaultStepTimeout),
    );
    try {
      // Every completed step is persisted before the next one starts, so a
      // wall-clock kill still leaves the completed evidence on disk for the
      // launcher to report.
      void persist(List<DriverActionResult> soFar) {
        if (reportFile == null) return;
        try {
          final file = File(reportFile);
          if (!file.parent.existsSync()) {
            file.parent.createSync(recursive: true);
          }
          final staging = File('${file.path}.$pid.tmp');
          staging.writeAsStringSync(
            json.encode({
              'steps_total': steps.length,
              'completed': soFar.length,
              'results': soFar.map((r) => r.toJson()).toList(),
            }),
            flush: true,
          );
          staging.renameSync(file.path);
        } catch (_) {
          // Partial evidence is best effort; it never fails the batch.
        }
      }

      final results = await controller.runBatch(
        steps,
        defaultStepTimeout: defaultStepTimeout,
        onProgress: (soFar) {
          persist(soFar);
          if (!isJson) print('${soFar.length}. ${soFar.last}');
        },
      );
      persist(results);
      final allSuccess = results.every((r) => r.success);

      if (isJson) {
        _printJson({
          'status': allSuccess ? 'ok' : 'failed',
          'total': results.length,
          'steps_total': steps.length,
          'passed': results.where((r) => r.success).length,
          'generation': controller.generationStore?.peek(),
          'results': results.map((r) => r.toJson()).toList(),
        });
      } else {
        print('\n--- Batch Execution Summary ---');
        print(
          '${results.where((r) => r.success).length}/${results.length} '
          'completed steps succeeded out of ${steps.length} requested.',
        );
        print(
          allSuccess && results.length == steps.length
              ? '✅ All batch steps succeeded!'
              : '❌ Some batch steps did not run or failed.',
        );
      }
      return allSuccess ? 0 : 1;
    } finally {
      await controller.close();
    }
  }

  void _printElementsFormatted(
    List<UiElement> elements, {
    bool compact = false,
  }) {
    if (elements.isEmpty) {
      print('(No matching UI elements)');
      return;
    }
    print('Total Elements: ${elements.length}');
    for (final el in elements) {
      final keyStr = el.key != null ? ' [key: ${el.key}]' : '';
      final textStr = el.text != null ? ' text: "${el.text}"' : '';
      final hintStr = el.hint != null ? ' hint: "${el.hint}"' : '';
      final tipStr = el.tooltip != null ? ' tip: "${el.tooltip}"' : '';
      final stateStr = el.enabled == false ? ' (disabled)' : '';
      final boundsStr = (!compact && el.bounds != null)
          ? ' @ ${el.bounds}'
          : '';
      print('• ${el.type}$keyStr$textStr$hintStr$tipStr$stateStr$boundsStr');
    }
  }

  void _printUsage() {
    print('''
Flutter VM Driver CLI — Unified Interactive UI Control & Automation

Usage:
  sanad-dev ui <command> [arguments]
  fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart <command> [arguments]

Commands:
  snapshot       Inspect and dump visible UI widget tree
                 Options: --filter <query>, --within <scope>, --interactive, --compact, --only-keys, --no-bounds, --fresh, --timeout <sec>, --json
                 JSON includes a monotonic `generation`; --fresh waits for a quiesced tree.

  find           Find element by key, text, type, or query
                 Options: --key <k>, --text <t>, --type <type>, --query <q>, --within <scope>, --interactive, --compact, --json

  auth-url       Print the active browser authentication URL for the selected Client
                 Options: --json

  tap            Tap an element (auto-scroll, then tap) and report the evidence
                 Options: --key <k>, --text <t>, --type <type>, --within <scope>, --index <i>, --coords x,y,
                          --verify, --expect <key>, --expect-absent <key>, --no-verify, --verify-timeout <ms>,
                          --timeout <sec>, --delay <ms>, --json
                 A plain tap exits 0 and reports `verified: false` with
                 `verification: no_observable_change` when nothing changed.
                 --verify, --expect, or --expect-absent make that a failure; the
                 reported `verification` stays `no_observable_change`.

  enter-text     Enter text into an input field and verify the effect
                 Options: --key <k>, --text <t>, --no-tap-first, --no-verify, --verify-timeout <ms>, --timeout <sec>, --delay <ms>, --json
                 A field whose value is not exposed is verified by an observable tree change.

  scroll         Scroll inside a scrollable widget or scroll until item visible
                 Options: --key <k>, --direction <up|down>, --dx <x>, --dy <y>, --to <top|bottom>, --until-visible <target_key>, --timeout <sec>, --json

  wait-for       Wait for an element to appear or disappear, then report the elapsed time
                 Options: --key <k>, --text <t>, --type <type>, --absent, --no-wait, --timeout <sec>, --json
                 --type --absent is proven by the rendered type census, because the
                 inspected tree omits unkeyed widgets with no text or interaction.
                 While that census still contains the type it keeps polling, because
                 absence can arrive later; at the deadline it fails with
                 `is still rendered (proven by the rendered type census) after Nms;
                 absence not observed`. --no-wait judges the first census instead of
                 waiting out --timeout. A wait failure always names the target and
                 what was observed, never a bare timeout.

  screenshot     Capture visual PNG screenshot
                 Options: --out <path>, --json

  batch          Execute a sequence of actions from a JSON recipe file
                 Options: --file <path>, --json-steps '<json>', --report-file <path>, --json, --timeout <sec> (default per-step deadline)
                 Steps: tap, enter_text, scroll, wait_for, snapshot, screenshot, message_bodies, sleep.
                 A step's own timeout_seconds replaces the batch --timeout for that step.
                 --report-file receives each completed step before the next starts.

Global Options:
  --vm-url <url>     VM service endpoint (injected automatically by sanad-dev ui)
  --timeout <sec>    Hard per-action deadline, default $defaultActionTimeoutSeconds
  --json             Format output as JSON
  -h, --help         Show this help

Launcher Options (sanad-dev ui only; stripped before the driver runs):
  --wall-timeout <sec>  Hard wall-clock cap for the whole driver child process.
                        Defaults to the action deadline (--timeout, 30 s) plus
                        the post-delay, the verification window, and a 10 s
                        grace; for a batch recipe it defaults to the sum of
                        every step's deadline. The child is killed with its
                        process tree when the cap elapses and the command
                        exits 124. Use it to bound a command you expect to be
                        slow (or to prove one hangs) without changing the
                        driver's own deadline.
  --home <path>         Sanad Home whose runtime is being driven.
  --activate            Bring the owning Client window to the front (default
                        for tap, enter-text, scroll, and batch).
  --no-activate         Never take focus from the user.

JSON Contract:
  Action results (tap, enter-text, scroll, wait-for, and every batch step)
  always carry `verified` as a boolean and `verification` as one of:
    key, present, absent, text, tree     -> verified: true
    no_observable_change, none, type_census -> verified: false
  `no_observable_change` means the action was dispatched and nothing observable
  changed in the window, with or without --verify; `none` means no evidence
  channel produced a verdict (verification disabled, the action failed before
  observation, or the step makes no post-condition claim); `type_census` means
  the rendered type census proved the requested absence is unprovable right now.
  Observation commands (snapshot, find, auth-url) report `status` and no
  post-condition verdict. `snapshot --fresh` sets `fresh: true` and then reports
  `settled`, which is false when the quiescence window expired first; a default
  snapshot reports `fresh: false` with no `settled` field.
  `build_ms` appears only on a call that had to compile the driver artifact
  (first run after a source or dependency change).
''');
  }

  String? _getOption(List<String> args, String flag) {
    final idx = args.indexOf(flag);
    if (idx != -1 && idx + 1 < args.length) {
      return args[idx + 1];
    }
    for (final a in args) {
      if (a.startsWith('$flag=')) {
        return a.substring(flag.length + 1);
      }
    }
    return null;
  }

  int _getIntOption(List<String> args, String flag, {required int defaultVal}) {
    final val = _getOption(args, flag);
    if (val != null) {
      return int.tryParse(val) ?? defaultVal;
    }
    return defaultVal;
  }

  double _getDoubleOption(
    List<String> args,
    String flag, {
    required double defaultVal,
  }) {
    final val = _getOption(args, flag);
    if (val != null) {
      return double.tryParse(val) ?? defaultVal;
    }
    return defaultVal;
  }

  bool _hasFlag(List<String> args, String flag) => args.contains(flag);

  String? _getLeadingPositional(List<String> args) {
    if (args.isEmpty || args.first.startsWith('-')) return null;
    return args.first;
  }
}
