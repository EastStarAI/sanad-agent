import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_windows_path/windows_path.dart';

import '../../models/local_tool_spec.dart';
import '../base_tool.dart';
import '../runtime/spec_backed_tool.dart';

/// Typed, side-effect-free lookup of host executables on the inherited
/// `PATH`.
///
/// It never runs a binary, never starts a shell, never lists directories and
/// never returns `PATH` itself or any other environment value: only the
/// queried name, whether it was found, and its canonical location. Presence
/// in a catalog is decided by owner policy, not by this tool.
class HostCapabilityDiscoveryTool extends SpecBackedTool {
  HostCapabilityDiscoveryTool({
    Map<String, String>? environment,
    bool? isWindows,
  }) : _environment = environment ?? Platform.environment,
       _isWindows = isWindows ?? Platform.isWindows;

  final Map<String, String> _environment;
  final bool _isWindows;

  static const toolName = 'host_capability_discovery';

  /// Bounded set checked by `common_tools`.
  static const commonTools = [
    'git',
    'flutter',
    'dart',
    'fvm',
    'node',
    'npm',
    'python3',
    'java',
    'docker',
    'cargo',
    'go',
  ];

  static final _validName = RegExp(r'^[A-Za-z0-9][A-Za-z0-9._+-]{0,127}$');

  static const toolSpecification = LocalToolSpec(
    name: toolName,
    displayName: 'Host Capability Discovery',
    description:
        'Check whether host executables are available on PATH without running them.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'executable_name': {
          'type': 'string',
          'description':
              'Exact executable name such as "flutter" or "git". No paths.',
        },
        'common_tools': {
          'type': 'boolean',
          'description': 'Check a fixed list of common developer tools.',
        },
      },
      'additionalProperties': false,
    },
    source: {'type': 'builtin_local', 'id': 'sanad-agent.system'},
    category: 'host_discovery',
    workspaceRequired: false,
    approval: {'mode': 'default', 'sensitive': false},
    execution: {'target': 'local_runtime', 'timeout_ms': 10000},
    serverName: 'system',
  );

  @override
  LocalToolSpec get toolSpec => toolSpecification;

  /// Read-only lookups are harmless to repeat after a crash boundary.
  @override
  bool get restartReplaySafe => true;

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => (await executeResult(args, context: context)).displayText;

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    final rawName = args['executable_name'];
    final name = rawName?.toString().trim() ?? '';
    final checkCommon = args['common_tools'] == true;
    if (name.isEmpty && !checkCommon) {
      return _error('Provide executable_name or common_tools: true.');
    }
    if (name.isNotEmpty && !_validName.hasMatch(name)) {
      return _error(
        'Invalid executable name. Use a bare name without paths, spaces or '
        'wildcards.',
      );
    }
    final directories = _pathDirectories();
    final names = name.isNotEmpty ? [name] : commonTools;
    return ToolExecutionResult.text(
      jsonEncode({
        'tools': [for (final tool in names) _lookup(tool, directories)],
      }),
    );
  }

  ToolExecutionResult _error(String message) => ToolExecutionResult.text(
    jsonEncode({'isError': true, 'error': message}),
    isError: true,
    errorCode: ToolResultErrorCode.invalidInput,
  );

  List<String> _pathDirectories() {
    final raw = inheritedPathFromEnvironment(_environment);
    return raw
        .split(_isWindows ? ';' : ':')
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty && p.isAbsolute(entry))
        .toList(growable: false);
  }

  List<String> _candidateNames(String name) {
    if (!_isWindows) return [name];
    final raw = _environmentValue('PATHEXT') ?? '.COM;.EXE;.BAT;.CMD';
    final extensions = raw
        .split(';')
        .map((ext) => ext.trim().toLowerCase())
        .where((ext) => ext.startsWith('.'));
    final lower = name.toLowerCase();
    if (extensions.any(lower.endsWith)) return [name];
    return [for (final ext in extensions) '$name$ext'];
  }

  String? _environmentValue(String key) {
    for (final entry in _environment.entries) {
      if (entry.key.toUpperCase() == key) return entry.value;
    }
    return null;
  }

  Map<String, dynamic> _lookup(String name, List<String> directories) {
    for (final directory in directories) {
      for (final candidateName in _candidateNames(name)) {
        final candidate = File(p.join(directory, candidateName));
        try {
          if (!candidate.existsSync()) continue;
          final canonical = candidate.resolveSymbolicLinksSync();
          if (!_isWindows && !_isExecutable(File(canonical))) continue;
          return {'name': name, 'found': true, 'canonical_path': canonical};
        } on FileSystemException {
          continue;
        }
      }
    }
    return {'name': name, 'found': false};
  }

  static bool _isExecutable(File file) {
    final stat = file.statSync();
    return stat.type == FileSystemEntityType.file && (stat.mode & 0x49) != 0;
  }
}
