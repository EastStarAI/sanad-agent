import 'dart:convert';
import 'dart:io';

import 'flutter_vm_controller.dart';
import 'models.dart';

class CliRunner {
  final List<String> args;

  CliRunner(this.args);

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
      } else {
        print('❌ Error executing command "$command": $e');
      }
      return 1;
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

    final controller = await FlutterVmController.connect(
      explicitUrl: explicitUrl,
      connectDriver: false,
    );
    try {
      final elements = await controller.snapshot(
        filter: filter,
        within: within,
        includeBounds: !noBounds,
        onlyWithKeys: onlyWithKeys,
        interactiveOnly: interactive,
      );

      if (isJson) {
        print(
          json.encode({
            'status': 'ok',
            'count': elements.length,
            'elements': elements.map((e) => e.toJson()).toList(),
          }),
        );
      } else {
        _printElementsFormatted(elements, compact: compact);
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

    if (key == null && text == null && type == null && query == null) {
      print(
        '❌ Must provide at least one filter: --key, --text, --type, or --query',
      );
      return 1;
    }

    final controller = await FlutterVmController.connect(
      explicitUrl: explicitUrl,
      connectDriver: false,
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

      if (isJson) {
        print(
          json.encode({
            'status': 'ok',
            'found': matches.isNotEmpty,
            'count': matches.length,
            'elements': matches.map((e) => e.toJson()).toList(),
          }),
        );
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

    final timeoutSec = _getIntOption(cmdArgs, '--timeout', defaultVal: 10);
    final delayMs = _getIntOption(cmdArgs, '--delay', defaultVal: 300);

    if (key == null &&
        text == null &&
        type == null &&
        (targetX == null || targetY == null)) {
      print(
        '❌ Must provide target identifier: --key, --text, --type, or --coords x,y',
      );
      return 1;
    }

    final controller = await FlutterVmController.connect(
      explicitUrl: explicitUrl,
      connectDriver: false,
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
      );

      if (isJson) {
        print(json.encode(res.toJson()));
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
    final timeoutSec = _getIntOption(cmdArgs, '--timeout', defaultVal: 10);
    final delayMs = _getIntOption(cmdArgs, '--delay', defaultVal: 300);

    final controller = await FlutterVmController.connect(
      explicitUrl: explicitUrl,
    );
    try {
      final res = await controller.enterText(
        text,
        key: key,
        tapFirst: !noTapFirst,
        timeout: Duration(seconds: timeoutSec),
        postDelay: Duration(milliseconds: delayMs),
      );

      if (isJson) {
        print(json.encode(res.toJson()));
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
    final timeoutSec = _getIntOption(cmdArgs, '--timeout', defaultVal: 15);

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

    final controller = await FlutterVmController.connect(
      explicitUrl: explicitUrl,
      connectDriver: false,
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
        print(json.encode(res.toJson()));
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
    final timeoutSec = _getIntOption(cmdArgs, '--timeout', defaultVal: 15);

    if (key == null && text == null && type == null) {
      print('❌ Must provide target identifier: --key, --text, or --type');
      return 1;
    }

    final controller = await FlutterVmController.connect(
      explicitUrl: explicitUrl,
    );
    try {
      final res = await controller.waitFor(
        key: key,
        text: text,
        type: type,
        absent: absent,
        timeout: Duration(seconds: timeoutSec),
      );

      if (isJson) {
        print(json.encode(res.toJson()));
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

    final controller = await FlutterVmController.connect(
      explicitUrl: explicitUrl,
    );
    try {
      final file = await controller.screenshot(outputPath: out);

      if (isJson) {
        print(
          json.encode({
            'status': 'ok',
            'file_path': file.path,
            'absolute_path': file.absolute.path,
            'size_bytes': await file.length(),
          }),
        );
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
    final controller = await FlutterVmController.connect(
      explicitUrl: explicitUrl,
    );
    try {
      final results = await controller.runBatch(steps);
      final allSuccess = results.every((r) => r.success);

      if (isJson) {
        print(
          json.encode({
            'status': allSuccess ? 'ok' : 'failed',
            'total': results.length,
            'passed': results.where((r) => r.success).length,
            'results': results.map((r) => r.toJson()).toList(),
          }),
        );
      } else {
        print('\n--- Batch Execution Summary ---');
        for (int i = 0; i < results.length; i++) {
          print('${i + 1}. ${results[i]}');
        }
        print('------------------------------');
        print(
          allSuccess
              ? '✅ All batch steps succeeded!'
              : '❌ Some batch steps failed.',
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
      final boundsStr = (!compact && el.bounds != null)
          ? ' @ ${el.bounds}'
          : '';
      print('• ${el.type}$keyStr$textStr$hintStr$tipStr$boundsStr');
    }
  }

  void _printUsage() {
    print('''
Flutter VM Driver CLI — Unified Interactive UI Control & Automation

Usage:
  fvm dart --packages=client/.dart_tool/package_config.json scripts/flutter_driver_cli.dart <command> [arguments]
  OR: sanad-dev ui <command> [arguments]

Commands:
  snapshot       Inspect and dump visible UI widget tree
                 Options: --filter <query>, --within <scope>, --interactive, --compact, --only-keys, --no-bounds, --json

  find           Find element by key, text, type, or query
                 Options: --key <k>, --text <t>, --type <type>, --query <q>, --within <scope>, --interactive, --compact, --json

  tap            Tap an element (with auto-scroll into view)
                 Options: --key <k>, --text <t>, --type <type>, --within <scope>, --index <i>, --coords x,y, --timeout <sec>, --delay <ms>, --json

  enter-text     Enter text into an input field
                 Options: --key <k>, --text <t>, --no-tap-first, --timeout <sec>, --delay <ms>, --json

  scroll         Scroll inside a scrollable widget or scroll until item visible
                 Options: --key <k>, --direction <up|down>, --dx <x>, --dy <y>, --to <top|bottom>, --until-visible <target_key>, --json

  wait-for       Wait for an element to appear or disappear
                 Options: --key <k>, --text <t>, --type <type>, --absent, --timeout <sec>, --json

  screenshot     Capture visual PNG screenshot
                 Options: --out <path>, --json

  batch          Execute a sequence of actions from a JSON recipe file
                 Options: --file <path>, --json-steps '<json>', --json

Global Options:
  --vm-url <url> VM service endpoint (injected automatically by sanad-dev ui)
  --json         Format output as JSON
  -h, --help     Show this help
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
