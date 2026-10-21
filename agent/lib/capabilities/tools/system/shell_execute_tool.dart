import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/execution/direct_execution_backend.dart';
import 'package:sanad_agent/capabilities/execution/execution_backend.dart';
import 'package:sanad_agent/capabilities/execution/execution_backend_resolver.dart';
import 'package:sanad_agent/capabilities/permissions/process_environment_policy.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';
import 'package:sanad_windows_path/windows_path.dart';

import '../../models/local_tool_spec.dart';
import '../../permissions/permission_manager.dart';
import '../base_tool.dart';
import '../runtime/spec_backed_tool.dart';

/// Model-facing shell tool.
///
/// Owns the schema, the workspace boundary and the permission check, then
/// hands the validated command to the backend selected by daemon policy.
class ShellExecuteTool extends SpecBackedTool {
  final String workspacePath;
  final PermissionManager? _permissionManager;
  final ExecutionBackendResolver _backendResolver;

  ShellExecuteTool({
    required this.workspacePath,
    PermissionManager? permissionManager,
    WindowsSystemPath? windowsSystemPath,
    ProcessEnvironmentPolicy? processEnvironmentPolicy,
    ExecutionBackendResolver? backendResolver,
  }) : _permissionManager = permissionManager,
       _backendResolver =
           backendResolver ??
           ExecutionBackendResolver(
             directBackend: DirectExecutionBackend(
               processEnvironmentPolicy: processEnvironmentPolicy,
               windowsSystemPath: windowsSystemPath,
             ),
           );

  @override
  bool get isCooperativelyCancellable => true;

  @override
  LocalToolSpec get toolSpec => const LocalToolSpec(
    name: 'shell_execute',
    displayName: 'Shell Execute',
    description:
        'Execute a shell command. Starts inside the active workspace; do not "cd" to it.',
    inputSchema: {
      'type': 'object',
      'properties': {
        'command': {'type': 'string'},
        'cwd': {
          'type': 'string',
          'description':
              'Optional subdirectory relative to workspace root. Do not use for root.',
        },
        'timeout_ms': {'type': 'integer'},
        'description': {
          'type': 'string',
          'description':
              'A concise sentence of no more than seven words that explains to the user, in their own language, the purpose or goal of executing this command.',
        },
      },
      'required': ['command', 'description'],
      'additionalProperties': false,
    },
    source: {'type': 'builtin_local', 'id': 'sanad-agent.system'},
    category: 'shell_execution',
    workspaceRequired: true,
    approval: {
      'mode': 'default',
      'sensitive': true,
      'permission_class': 'shell_execution',
    },
    execution: {'target': 'local_runtime', 'timeout_ms': 60000},
    serverName: 'system',
  );

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    final result = await executeResult(args, context: context);
    return result.displayText;
  }

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async {
    final stopwatch = Stopwatch()..start();

    final String cmd = args['command']?.toString() ?? '';
    if (cmd.trim().isEmpty) {
      throw const FormatException('No command provided.');
    }

    final workingDir = _resolveWorkingDirectory(args['cwd']?.toString() ?? '');

    final int timeoutMs = args['timeout_ms'] is int
        ? args['timeout_ms'] as int
        : int.tryParse(args['timeout_ms']?.toString() ?? '') ?? 60000;

    final backend = await _backendResolver.resolve(
      context,
      root: Directory(workspacePath).resolveSymbolicLinksSync(),
    );
    // A refusing backend answers before approval: no prompt and no durable
    // grant for a command that will never run.
    if (backend.runsCommands && _permissionManager != null && context != null) {
      await _permissionManager.ensureAuthorized(
        tool: toolSpec,
        arguments: args,
        context: context,
      );
    }
    return backend.execute(
      ShellCommandRequest(
        command: cmd,
        workingDirectory: workingDir,
        timeoutMs: timeoutMs,
        stopwatch: stopwatch,
        context: context,
      ),
    );
  }

  /// Resolves `cwd` and rejects anything outside the canonical workspace
  /// root, including sibling roots that merely share a name prefix.
  String _resolveWorkingDirectory(String targetSubPath) {
    final root = Directory(workspacePath).resolveSymbolicLinksSync();
    if (targetSubPath.trim().isEmpty) return root;
    final candidate = Directory(targetSubPath).isAbsolute
        ? targetSubPath
        : p.join(workspacePath, targetSubPath);
    final resolved = Directory(candidate).resolveSymbolicLinksSync();
    if (resolved != root && !p.isWithin(root, resolved)) {
      throw FileSystemException(
        'Security violation: Target path is outside the workspace root.',
        resolved,
      );
    }
    return resolved;
  }
}
