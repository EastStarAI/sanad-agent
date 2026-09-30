#!/usr/bin/env dart

// Bounded PR-check monitor CLI.
//
// Usage:
//   fvm dart run scripts/workflow_guards/bin/pr_checks_watch.dart <pr> [--interval <sec>] [--timeout <sec>] [--gh <path>] [--json] [--quiet]
//
// Exit codes: 0 all checks passed (or none), 1 first failed check (fail-fast),
// 124 checks still pending after the timeout, 2 usage or tool error.

import 'dart:convert';
import 'dart:io';

import 'package:sanad_workflow_guards/pr_checks_watch.dart';

const _help = '''
pr_checks_watch <pr> [options]

Polls `gh pr checks <pr> --json` with a fixed interval and fails fast.

Options:
  --interval <sec>   Poll interval in seconds (default 5).
  --timeout <sec>    Maximum watch duration in seconds (default 420 = 7 minutes).
  --gh <path>        GitHub CLI executable override (default: gh on PATH).
  --json             Print one final JSON envelope instead of per-poll summaries.
  --quiet            Suppress per-poll summary lines.
  -h, --help         Show this help.

Exit codes:
  0    all checks passed (or no checks reported)
  1    first failed/cancelled check (fail-fast)
  124  checks still pending after the timeout
  2    usage error or gh unavailable/unparseable
''';

const _defaultInterval = Duration(seconds: 5);
const _defaultTimeout = Duration(minutes: 7);

Duration _seconds(String value) {
  final parsed = int.tryParse(value);
  if (parsed == null || parsed <= 0 || parsed > 86400) {
    stderr.writeln('pr_checks_watch: --interval/--timeout must be a positive number of seconds');
    exit(2);
  }
  return Duration(seconds: parsed);
}

void main(List<String> args) {
  final positional = <String>[];
  var interval = _defaultInterval;
  var timeout = _defaultTimeout;
  var gh = Platform.environment['SANAD_WORKFLOW_GH'] ?? 'gh';
  var jsonOutput = false;
  var quiet = false;

  for (var i = 0; i < args.length; i++) {
    final arg = args[i];
    String valueOf(String flag) {
      if (i + 1 >= args.length || args[i + 1].startsWith('--')) {
        stderr.writeln('pr_checks_watch: $flag requires a value');
        exit(2);
      }
      i += 1;
      return args[i];
    }

    switch (arg) {
      case '--interval':
        interval = _seconds(valueOf(arg));
      case '--timeout':
        timeout = _seconds(valueOf(arg));
      case '--gh':
        gh = valueOf(arg);
      case '--json':
        jsonOutput = true;
      case '--quiet':
        quiet = true;
      case '-h' || '--help':
        stdout.write(_help);
        return;
      default:
        if (arg.startsWith('--')) {
          stderr.writeln('pr_checks_watch: unknown option $arg');
          stderr.write(_help);
          exit(2);
        }
        positional.add(arg);
    }
  }

  if (positional.length != 1) {
    stderr.writeln('pr_checks_watch: exactly one PR number/url/branch is required');
    stderr.write(_help);
    exit(2);
  }
  final ref = positional.single;

  // Ensure the exit code propagates even for streams still flushing.
  final result = watchPrChecks(
    ref,
    options: PrChecksOptions(interval: interval, timeout: timeout, ghCommand: gh, quiet: quiet),
  );

  result.then((outcome) {
    if (jsonOutput) {
      stdout.writeln(jsonEncode({
        'verdict': outcome.verdict.name,
        'exitCode': outcome.exitCode,
        'pollCount': outcome.pollCount,
        'error': outcome.error,
        'checks': outcome.lastChecks
            .map((c) => {
                  'name': c.name,
                  'bucket': c.bucket,
                  'state': c.state,
                  'conclusion': c.conclusion,
                })
            .toList(),
      }));
    } else if (outcome.error != null) {
      stderr.writeln('pr_checks_watch: ${outcome.error}');
    } else {
      final passed = outcome.lastChecks.where((c) => !c.isFailed && !c.isPending).length;
      final failed = outcome.lastChecks.where((c) => c.isFailed).length;
      final pending = outcome.lastChecks.where((c) => c.isPending).length;
      stdout.writeln(
        'pr_checks_watch: ${outcome.verdict.name} after ${outcome.pollCount} poll(s) '
        '($passed passed, $pending pending, $failed failed)',
      );
    }
    exit(outcome.exitCode);
  }).catchError((Object error) {
    stderr.writeln('pr_checks_watch: ${error is Error ? error.toString() : error}');
    exit(2);
  });
}