import 'dart:convert';
import 'dart:io';

/// One build or test process found inside the invoking worktree.
class ForeignWorktreeActivity {
  const ForeignWorktreeActivity({required this.pid, required this.command});

  final int pid;
  final String command;

  /// Redacted one-line summary safe to print and to quote in a report.
  String get summary => 'PID $pid: ${redactCommandLine(command).trim()}';
}

/// Placeholder that replaces a redacted command-line value.
const redactedCommandLineValue = '<redacted>';

/// Name fragments that make a command-line flag or variable value secret-like.
///
/// Guard output is printed and often pasted into a report, so a value carried by
/// a token-like flag must never appear verbatim.
const secretLikeArgumentNameFragments = <String>[
  'token',
  'secret',
  'key',
  'password',
  'passwd',
  'pwd',
  'credential',
  'auth',
  'bearer',
  'session',
  'cookie',
];

final RegExp _tokenPattern = RegExp(r'\S+');
final RegExp _flagValuePattern = RegExp(
  r'(--?[A-Za-z0-9_.-]+)(\s+)(?!-)(?:"[^"]*"|[^\s]+)',
);

/// Matches one header flag and its value.
///
/// The value may be double-quoted, single-quoted, or an unquoted `Name: value`
/// pair; a bare `Name:` name is also matched so a shell-split header still loses
/// its value.
final RegExp _headerPattern = RegExp(
  r'''(-{1,2}(?:header|Header|HEADER|[Hh]|cookie|COOKIE|[Bb]))(\s+)("[^"]*"|'[^']*'|[A-Za-z0-9_-]+:(?:\s+[^\s]+)?|\S+)''',
);

bool _isSecretLikeArgumentName(String name) {
  final lower = name.replaceFirst(RegExp(r'^--?'), '').toLowerCase();
  return secretLikeArgumentNameFragments.any(lower.contains);
}

/// The secret-bearing header name in [value], or null when it is not one.
///
/// `-H "Authorization: Bearer …"` names no secret-like flag, so the flag-value
/// rule alone would print the token: the header name before the first `:` has to
/// decide instead.
String? _secretHeaderName(String value) {
  final unquoted = value.replaceAll(RegExp(r'''^["']|["']$'''), '');
  final separator = unquoted.indexOf(':');
  if (separator <= 0) return null;
  final name = unquoted.substring(0, separator).trim();
  return _isSecretLikeArgumentName(name) ? name : null;
}

/// Redacts the value of every header flag that carries a secret-like name.
String _redactHeaderValues(String command) => command.replaceAllMapped(
  _headerPattern,
  (match) => _secretHeaderName(match.group(3)!) == null
      ? match.group(0)!
      : '${match.group(1)}${match.group(2)}$redactedCommandLineValue',
);

/// Redacts secret-like values from a foreign command line before printing.
///
/// Handles `NAME=value` (including nested forms such as
/// `--dart-define=SANAD_TOKEN=abc`), the separated `--flag value` form, and a
/// header value such as `-H "Authorization: …"`, and leaves every other token
/// untouched.
String redactCommandLine(String command) {
  final assignments = command.replaceAllMapped(
    _tokenPattern,
    (match) => _redactAssignments(match.group(0)!),
  );
  final headers = _redactHeaderValues(assignments);
  return headers.replaceAllMapped(_flagValuePattern, (match) {
    final flag = match.group(1)!;
    if (!_isSecretLikeArgumentName(flag)) return match.group(0)!;
    return '$flag${match.group(2)}$redactedCommandLineValue';
  });
}

/// Redacts every `name=value` segment of one whitespace-free token.
///
/// Walking the `=` segments reaches a value nested inside another assignment,
/// which a single left-to-right match would skip.
String _redactAssignments(String token) {
  if (!token.contains('=')) return token;
  final segments = token.split('=');
  final result = <String>[segments.first];
  for (var index = 1; index < segments.length; index++) {
    final name = segments[index - 1];
    result.add(
      _isSecretLikeArgumentName(name)
          ? redactedCommandLineValue
          : segments[index],
    );
  }
  return result.join('=');
}

/// Command-line fragments that make a process a build or test workload.
///
/// A restart issued while one of these runs in the same worktree competes for
/// the same build outputs and produces a misleading result, so sanad-dev
/// reports it instead of waiting for an unbounded rebuild.
const foreignWorktreeActivityFragments = <String>[
  'flutter test',
  'dart test',
  'flutter build',
  'dart build',
  'dart compile',
  'flutter assemble',
  'xcodebuild',
  'cargokit',
  'flutter pub get',
  'dart pub get',
];

typedef ProcessLister = Future<List<String>> Function();

/// Detects build/test processes whose command line references [workspaceRoot].
///
/// Uses one `ps` (POSIX) or one `Get-CimInstance` (Windows) call and filters in
/// process, so the probe never spawns a shell loop and never matches its own
/// command line.
Future<List<ForeignWorktreeActivity>> detectForeignWorktreeActivity({
  required String workspaceRoot,
  ProcessLister? listProcessCommandLines,
  int? currentPid,
}) async {
  if (workspaceRoot.trim().isEmpty) return const [];
  final lister = listProcessCommandLines ?? _defaultProcessLister;
  final normalizedRoot = _normalize(workspaceRoot);
  final ownPid = currentPid ?? pid;
  final activities = <ForeignWorktreeActivity>[];
  for (final line in await lister()) {
    final separator = line.indexOf('\u0000');
    if (separator <= 0) continue;
    final processId = int.tryParse(line.substring(0, separator).trim());
    final command = line.substring(separator + 1);
    if (processId == null || processId == ownPid) continue;
    if (!_referencesWorktree(command, normalizedRoot)) continue;
    if (!_invokesBuildOrTest(command.toLowerCase())) continue;
    activities.add(ForeignWorktreeActivity(pid: processId, command: command));
  }
  activities.sort((left, right) => left.pid.compareTo(right.pid));
  return activities;
}

/// True when [command] references [normalizedRoot] as a path, not as a prefix
/// of a longer sibling path such as `<worktree>-extra`.
bool _referencesWorktree(String command, String normalizedRoot) {
  final haystack = _normalize(command);
  var index = haystack.indexOf(normalizedRoot);
  while (index >= 0) {
    final next = index + normalizedRoot.length;
    if (next >= haystack.length ||
        const {'/', ' ', '\t', '\'', '"', ':', '='}.contains(haystack[next])) {
      return true;
    }
    index = haystack.indexOf(normalizedRoot, next);
  }
  return false;
}

/// True when the command line actually invokes a build or test workload.
///
/// A quoted occurrence (for example `rg "flutter test" <path>`) is a search
/// argument, not an invocation, and must not block a restart.
bool _invokesBuildOrTest(String lowerCommand) {
  for (final fragment in foreignWorktreeActivityFragments) {
    var index = lowerCommand.indexOf(fragment);
    while (index >= 0) {
      final preceding = index == 0 ? ' ' : lowerCommand[index - 1];
      if (preceding != '"' && preceding != '\'') return true;
      index = lowerCommand.indexOf(fragment, index + fragment.length);
    }
  }
  return false;
}

/// Clear, actionable message used instead of waiting for a foreign build.
String foreignWorktreeActivityMessage({
  required String worktreeId,
  required List<ForeignWorktreeActivity> activities,
}) {
  final buffer = StringBuffer()
    ..writeln(
      'Refusing to restart $worktreeId: another build or test is running in '
      'this worktree.',
    );
  for (final activity in activities) {
    buffer.writeln('  - ${activity.summary}');
  }
  buffer.write('Wait for it to finish, or pass --force to restart anyway.');
  return buffer.toString();
}

String _normalize(String value) => value.replaceAll('\\', '/').toLowerCase();

Future<List<String>> _defaultProcessLister() async {
  if (Platform.isWindows) {
    const command = r'''
Get-CimInstance Win32_Process |
  ForEach-Object {
    @{ pid = [int]$_.ProcessId; command = $_.CommandLine } |
      ConvertTo-Json -Compress
  }
''';
    final result = await Process.run('powershell', [
      '-NoProfile',
      '-NonInteractive',
      '-Command',
      command,
    ]);
    if (result.exitCode != 0) return const [];
    final entries = <String>[];
    for (final line in LineSplitter.split(result.stdout.toString())) {
      try {
        final value = jsonDecode(line);
        if (value is! Map) continue;
        final processId = value['pid'];
        final commandLine = value['command']?.toString() ?? '';
        if (processId is! int) continue;
        entries.add('$processId\u0000$commandLine');
      } on FormatException {
        // A malformed process record is incomplete discovery and is ignored.
      }
    }
    return entries;
  }
  final result = await Process.run('ps', ['-ww', '-axo', 'pid=,command=']);
  if (result.exitCode != 0) return const [];
  final lines = <String>[];
  for (final line in LineSplitter.split(result.stdout.toString())) {
    final match = RegExp(r'^\s*(\d+)\s+(.*)$').firstMatch(line);
    if (match == null) continue;
    lines.add('${match.group(1)}\u0000${match.group(2)}');
  }
  return lines;
}
