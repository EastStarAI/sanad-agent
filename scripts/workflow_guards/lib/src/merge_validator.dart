// Fail-closed validation for files resolved after a Git merge/rebase conflict.
//
// Rejects leftover conflict markers and corrupt JSON/JSONL syntax before a
// resolved file is allowed to be staged, so a corrupt merge output (for
// example from fragile Windows `cmd` quoting) never reaches the index.
library;

import 'dart:convert';
import 'dart:io';

/// Outcome of validating one file.
enum MergeVerdict { ok, conflictMarkers, corruptSyntax, missing }

/// Result details for one validated path.
class MergeValidation {
  MergeValidation({
    required this.path,
    required this.verdict,
    this.markerLines = const [],
    this.error,
  });

  final String path;
  final MergeVerdict verdict;
  final List<int> markerLines;

  /// Human-readable failure reason, when any.
  final String? error;

  /// Stable machine-readable exit code contribution
  /// (0 ok, 2 missing, 3 conflict markers, 4 corrupt syntax).
  int get exitCode => switch (verdict) {
    MergeVerdict.ok => 0,
    MergeVerdict.missing => 2,
    MergeVerdict.conflictMarkers => 3,
    MergeVerdict.corruptSyntax => 4,
  };
}

final _conflictRe = RegExp(
  r'^(<<<<<<<|>>>>>>>|\|\|\|\|\|\|\|)(?: .*)?$|^=======$',
);

/// Validates one resolved file. Returns [MergeVerdict.conflictMarkers] when
/// git conflict markers remain, [MergeVerdict.corruptSyntax] for invalid
/// JSON/JSONL, [MergeVerdict.missing] for absent paths, else ok.
MergeValidation validateResolvedFile(String path) {
  final file = File(path);
  if (!file.existsSync()) {
    return MergeValidation(
      path: path,
      verdict: MergeVerdict.missing,
      error: 'file does not exist',
    );
  }

  final markerLines = <int>[];
  final raw = file.readAsBytesSync();
  var text = utf8.decode(raw, allowMalformed: true);
  if (text.startsWith('\uFEFF')) text = text.substring(1);

  final lines = text.split('\n');
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].replaceAll('\r', '');
    if (_conflictRe.hasMatch(line.trim())) {
      markerLines.add(index + 1);
    }
  }
  if (markerLines.isNotEmpty) {
    return MergeValidation(
      path: path,
      verdict: MergeVerdict.conflictMarkers,
      markerLines: markerLines,
      error: 'unresolved conflict markers at line(s) ${markerLines.join(', ')}',
    );
  }

  final lower = path.toLowerCase();
  if (lower.endsWith('.json') || lower.endsWith('.jsonl')) {
    final error = _syntaxErrorText(lower, lines);
    if (error != null) {
      return MergeValidation(
        path: path,
        verdict: MergeVerdict.corruptSyntax,
        error: error,
      );
    }
  }

  return MergeValidation(path: path, verdict: MergeVerdict.ok);
}

String? _syntaxErrorText(String lower, List<String> lines) {
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].replaceAll('\r', '');
    if (line.trim().isEmpty) continue;
    try {
      if (lower.endsWith('.jsonl')) {
        jsonDecode(line);
      }
    } on FormatException catch (error) {
      return 'invalid JSON at line ${index + 1}: ${error.message}';
    }
  }
  if (lower.endsWith('.json')) {
    try {
      jsonDecode(lines.join('\n'));
    } on FormatException catch (error) {
      final offset = error.offset;
      final line = offset == null
          ? null
          : _lineForOffset(lines.join('\n'), offset);
      return 'invalid JSON${line == null ? '' : ' near line $line'}: ${error.message}';
    }
  }
  return null;
}

int? _lineForOffset(String text, int offset) {
  if (offset < 0 || offset > text.length) return null;
  var line = 1;
  for (var i = 0; i < offset && i < text.length; i++) {
    if (text.codeUnitAt(i) == 0x0A) line += 1;
  }
  return line;
}
