import 'dart:io';

import 'package:sanad_agent/capabilities/execution/direct_execution_backend.dart';
import 'package:sanad_agent/capabilities/execution/execution_backend_resolver.dart';
import 'package:sanad_agent/capabilities/permissions/process_environment_policy.dart';
import 'package:sanad_agent/core/auth/agent_secret_store_contract.dart';
import 'package:sanad_windows_path/windows_path.dart';

import '../../models/local_tool_spec.dart';
import '../../permissions/permission_manager.dart';
import '../base_tool.dart';
import '../runtime/spec_backed_tool.dart';

class ShellExecuteTool extends SpecBackedTool {
  final String workspacePath;
  final PermissionManager? _permissionManager;
  final ExecutionBackendResolver _backendResolver;

  ShellExecuteTool({
    required this.workspacePath,
    PermissionManager? permissionManager,
    WindowsSystemPath? windowsSystemPath,
    ProcessEnvironmentPolicy? processEnvironmentPolicy,
    AgentSecretStore? secretStore,
    ExecutionBackendResolver? backendResolver,
  }) : _permissionManager = permissionManager,
       _backendResolver = backendResolver ??
           ExecutionBackendResolver(
             directBackend: DirectExecutionBackend(
               processEnvironmentPolicy: processEnvironmentPolicy,
               windowsSystemPath: windowsSystemPath,
               secretStore: secretStore,
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
    final stopwatch = Stopwatch()..start();

    if (_permissionManager != null && context != null) {
      await _permissionManager.ensureAuthorized(
        tool: toolSpec,
        arguments: args,
        context: context,
      );
    }

    final String cmd = args['command']?.toString() ?? '';
    if (cmd.trim().isEmpty) {
      throw const FormatException('No command provided.');
    }

    final String targetSubPath = args['cwd']?.toString() ?? '';

    String workingDir = workspacePath;
    if (targetSubPath.trim().isNotEmpty) {
      final subDir = Directory(targetSubPath);
      if (subDir.isAbsolute) {
        workingDir = subDir.resolveSymbolicLinksSync();
      } else {
        workingDir = Directory(
          '$workspacePath/$targetSubPath',
        ).resolveSymbolicLinksSync();
      }
    } else {
      workingDir = Directory(workspacePath).resolveSymbolicLinksSync();
    }

    final resolvedWorkspaceRoot = Directory(
      workspacePath,
    ).resolveSymbolicLinksSync();
    if (!workingDir.startsWith(resolvedWorkspaceRoot)) {
      throw FileSystemException(
        'Security violation: Target path is outside the workspace root.',
        workingDir,
      );
    }

    final int timeoutMs = args['timeout_ms'] is int
        ? args['timeout_ms'] as int
        : int.tryParse(args['timeout_ms']?.toString() ?? '') ?? 60000;

    final workspaceId = context?.metadata['workspace_id']?.toString() ?? '';
    final backend = await _backendResolver.resolveBackend(
      workspaceId: workspaceId,
      canonicalPath: resolvedWorkspaceRoot,
    );

    return backend.executeCommand(
      command: cmd,
      workingDir: workingDir,
      timeoutMs: timeoutMs,
      stopwatch: stopwatch,
      context: context,
    );
  }
}
