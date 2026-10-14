import 'dart:convert';
import 'dart:io';

import 'package:sanad_windows_path/windows_path.dart';

import '../../models/local_tool_spec.dart';
import '../base_tool.dart';
import '../runtime/spec_backed_tool.dart';

/// Tool allowing safe, typed discovery of host executables from inherited PATH.
///
/// Under Plan 83 (Task 83f):
/// - Discovers executables strictly from inherited PATH.
/// - Does not execute any binary, run `--version`, or inspect file content.
/// - Rejects path separators, directory traversal, and raw environment dumps.
/// - Returns bounded metadata (name, availability, and canonical path).
class HostCapabilityDiscoveryTool extends SpecBackedTool {
  HostCapabilityDiscoveryTool({
    Map<String, String>? environment,
    WindowsSystemPath? windowsSystemPath,
  }) : _environment = environment ?? Platform.environment,
       _windowsSystemPath =
           windowsSystemPath ?? sharedWindowsSystemPathResolver;

  final Map<String, String> _environment;
  final WindowsSystemPath _windowsSystemPath;

  static const List<String> standardCommonTools = [
    'git',
    'flutter',
    'dart',
    'node',
    'npm',
    'python3',
    'cargo',
    'go',
    'docker',
  ];

  static const toolSpecification = LocalToolSpec(
    name: 'host_capability_discovery',
    displayName: 'Host Capability Discovery',
    description:
        'Discover availability and canonical paths of host executables from inherited PATH without executing them.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'executable_name': {
          'type': 'string',
          'description':
              'Exact executable name to query in host PATH (e.g. "flutter", "git", "node"). Traversal and path separators are prohibited.',
        },
        'common_tools': {
          'type': 'boolean',
          'description':
              'If true, checks availability for common developer toolchains.',
        },
      },
      'additionalProperties': false,
    },
    source: {'type': 'builtin_local', 'id': 'sanad-agent.system'},
    category: 'system_discovery',
    workspaceRequired: false,
    approval: {
      'mode': 'default',
      'sensitive': false,
      'permission_class': 'host_discovery',
    },
    execution: {'target': 'local_runtime', 'timeout_ms': 10000},
    serverName: 'system',
  );

  @override
  LocalToolSpec get toolSpec => toolSpecification;

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    final executableName = args['executable_name']?.toString().trim();
    final checkCommon = args['common_tools'] == true;

    if ((executableName == null || executableName.isEmpty) && !checkCommon) {
      return jsonEncode({
        'isError': true,
        'error':
            'Provide executable_name or specify common_tools: true for host capability discovery.',
      });
    }

    final pathEntries = await _resolvePathEntries();

    if (executableName != null && executableName.isNotEmpty) {
      if (_isInvalidExecutableName(executableName)) {
        return jsonEncode({
          'isError': true,
          'error':
              'Invalid executable name. Path separators, traversal characters, and whitespace are prohibited.',
        });
      }

      final result = _lookupExecutable(executableName, pathEntries);
      return jsonEncode(result);
    }

    // Common tools check
    final results = <Map<String, dynamic>>[];
    for (final tool in standardCommonTools) {
      results.add(_lookupExecutable(tool, pathEntries));
    }

    return jsonEncode({'tools': results});
  }

  bool _isInvalidExecutableName(String name) {
    if (name.contains('/') ||
        name.contains('\\') ||
        name.contains('..') ||
        name.contains('\x00') ||
        name.contains(' ') ||
        name.contains('\t')) {
      return true;
    }
    return false;
  }

  Future<List<String>> _resolvePathEntries() async {
    String rawPath = inheritedPathFromEnvironment(_environment);
    if (_windowsSystemPath.isWindows) {
      rawPath = await _windowsSystemPath.resolve(rawPath);
    }

    final delimiter = Platform.isWindows ? ';' : ':';
    return rawPath
        .split(delimiter)
        .map((p) => p.trim())
        .where((p) => p.isNotEmpty)
        .toList(growable: false);
  }

  Map<String, dynamic> _lookupExecutable(
    String name,
    List<String> pathEntries,
  ) {
    final extensions = _windowsSystemPath.isWindows
        ? const ['.exe', '.cmd', '.bat', '.ps1', '']
        : const [''];

    for (final dirPath in pathEntries) {
      final dir = Directory(dirPath);
      if (!dir.existsSync()) continue;

      for (final ext in extensions) {
        final candidateName = _windowsSystemPath.isWindows && ext.isNotEmpty
            ? (name.toLowerCase().endsWith(ext) ? name : '$name$ext')
            : name;

        final candidate = File(
          Platform.isWindows
              ? '$dirPath\\$candidateName'
              : '$dirPath/$candidateName',
        );

        if (candidate.existsSync()) {
          try {
            final canonical = candidate.resolveSymbolicLinksSync();
            return {
              'name': name,
              'found': true,
              'canonical_path': canonical,
            };
          } catch (_) {
            return {
              'name': name,
              'found': true,
              'canonical_path': candidate.path,
            };
          }
        }
      }
    }

    return {
      'name': name,
      'found': false,
    };
  }
}
