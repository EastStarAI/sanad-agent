#!/usr/bin/env dart

// Bounded verification runner CLI.
//
// Usage:
//   fvm dart run scripts/workflow_guards/bin/verify.dart [flags] [--] <command> [args...]
//
// Runs a command, measures elapsed wall time, captures the complete stdout and
// stderr into a unique temporary log, preserves the exact child exit code, and
// prints only the final few output lines plus elapsed time, exit status, and
// the log path. On failure the bounded stderr tail is included as the error
// section. Exit status: child exit code (0/child), 2 for tool/usage errors.

import 'dart:convert';
import 'dart:io';

import 'package:sanad_workflow_guards/bounded_verify.dart';

const _help = '''
verify [flags] [--] <command> [args...]

Runs one command with bounded console output and full, untracked log capture.

Flags:
  --tail <n>     Console-visible output lines for stdout/stderr (default 5).
  --log-dir <d>  Directory for the unique log (default: system temp dir).
  --json         Print one final JSON envelope instead of bounded text.
  -h, --help     Show this help.

Output contract:
  - elapsed wall time in milliseconds
  - exact child exit status (preserved as this process's exit code)
  - the complete stdout/stderr in a unique temporary log (never tracked)
  - only the final --tail stdout lines (+ final --tail stderr lines on
    nonzero exit) to the console

Exit codes:
  0        child succeeded (status 0)
  <child>  exact child exit status, including intentional nonzero failures
  2        usage error or the command could not be started
''';

Future<void> main(List<String> args) async {
  var tail = 5;
  String? logDir;
  var jsonOutput = false;
  var commandIndex = -1;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    if (arg == '--') {
      commandIndex = i + 1;
      break;
    }
    String valueOf(String flag) {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        stderr.writeln('verify: $flag requires a value');
        exit(2);
      }
      i += 1;
      return args[i];
    }

    switch (arg) {
      case '--tail':
        final parsed = int.tryParse(valueOf(arg));
        if (parsed == null || parsed < 1 || parsed > 200) {
          stderr.writeln('verify: --tail must be between 1 and 200');
          exit(2);
        }
        tail = parsed;
      case '--log-dir':
        logDir = valueOf(arg);
      case '--json':
        jsonOutput = true;
      case '-h' || '--help':
        stdout.write(_help);
        return;
      default:
        if (arg.startsWith('--')) {
          stderr.writeln('verify: unknown option $arg');
          stderr.write(_help);
          exit(2);
        }
        // First non-flag token starts the command even without `--`.
        commandIndex = i;
        break;
    }
    if (commandIndex != -1) break;
  }

  if (commandIndex == -1 || commandIndex >= args.length) {
    stderr.writeln('verify: a command is required');
    stderr.write(_help);
    exit(2);
  }
  final command = args[commandIndex];
  final commandArgs = args.sublist(commandIndex + 1);

  try {
    final result = await runBounded(
      command,
      commandArgs,
      options: VerifyOptions(tail: tail, logDir: logDir),
    );
    if (jsonOutput) {
      stdout.writeln(jsonEncode({
        'command': command,
        'args': commandArgs,
        'exitCode': result.exitCode,
        'elapsedMs': result.elapsedMs,
        'logPath': result.logPath,
        'error': result.error,
        'stdoutTail': result.stdoutTail,
        'stderrTail': result.stderrTail,
      }));
    } else if (result.error != null) {
      stderr.writeln('verify: ${result.error}');
    } else {
      if (result.stdoutTail.isNotEmpty) {
        stdout.writeln(result.stdoutTail.join('\n'));
      }
      if (result.exitCode != 0 && result.stderrTail.isNotEmpty) {
        stderr.writeln('--- stderr (last ${result.stderrTail.length}) ---');
        stderr.writeln(result.stderrTail.join('\n'));
      }
      stdout.writeln(
        'verify: elapsed ${result.elapsedMs}ms | exit ${result.exitCode} | log ${result.logPath}',
      );
    }
    exit(result.exitCode);
  } catch (error) {
    stderr.writeln('verify: ${error is Error ? error.toString() : error}');
    exit(2);
  }
}