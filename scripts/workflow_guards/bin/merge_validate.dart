#!/usr/bin/env dart

// Fail-closed merge artifact validation CLI.
//
// Usage:
//   fvm dart run scripts/workflow_guards/bin/merge_validate.dart <file>... [--json]
//
// Exit codes: 0 all files valid, 2 missing file or usage error,
// 3 unresolved conflict markers, 4 corrupt JSON/JSONL syntax (worst wins).

import 'dart:convert';
import 'dart:io';

import 'package:sanad_workflow_guards/merge_validate.dart';

const _help = '''
merge_validate <file>... [options]

Rejects unresolved Git conflict markers and corrupt JSON/JSONL before staging.

Options:
  --json  Print one JSON envelope with per-file results.
  -h, --help  Show this help.

Exit codes:
  0    every file is clean (no markers; JSON/JSONL parses)
  3    at least one file still contains conflict markers
  4    at least one file has corrupt JSON/JSONL syntax
  2    missing file or usage error (reported, never staged)
''';

void main(List<String> args) {
  final files = <String>[];
  var jsonOutput = false;
  for (final arg in args) {
    switch (arg) {
      case '--json':
        jsonOutput = true;
      case '-h' || '--help':
        stdout.write(_help);
        return;
      default:
        if (arg.startsWith('--')) {
          stderr.writeln('merge_validate: unknown option $arg');
          stderr.write(_help);
          exit(2);
        }
        files.add(arg);
    }
  }
  if (files.isEmpty) {
    stderr.writeln('merge_validate: at least one file path is required');
    stderr.write(_help);
    exit(2);
  }

  final results = files.map(validateResolvedFile).toList();
  var worst = 0;
  for (final result in results) {
    if (result.exitCode > worst) worst = result.exitCode;
    if (result.verdict == MergeVerdict.ok) {
      if (!jsonOutput) stdout.writeln('${result.path}: ok');
    } else if (!jsonOutput) {
      stderr.writeln('${result.path}: ${result.verdict.name}: ${result.error ?? ''}');
    }
  }

  if (jsonOutput) {
    stdout.writeln(jsonEncode({
      'ok': worst == 0,
      'exitCode': worst,
      'files': results
          .map((r) => {
                'path': r.path,
                'verdict': r.verdict.name,
                'markerLines': r.markerLines,
                'error': r.error,
              })
          .toList(),
    }));
  }

  exit(worst);
}