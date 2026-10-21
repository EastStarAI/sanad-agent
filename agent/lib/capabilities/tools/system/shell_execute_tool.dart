import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/execution/direct_execution_backend.dart';
import 'package:sanad_agent/capabilities/execution/execution_backend.dart';
import 'package:sanad_agent/capabilities/execution/execution_backend_resolver.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/process_environment_policy.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
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
  final UserSecretVault _userSecrets;

  ShellExecuteTool({
    required this.workspacePath,
    PermissionManager? permissionManager,
    WindowsSystemPath? windowsSystemPath,
    ProcessEnvironmentPolicy? processEnvironmentPolicy,
    ExecutionBackendResolver? backendResolver,
    UserSecretVault? userSecrets,
  }) : _permissionManager = permissionManager,
       _userSecrets = userSecrets ?? UserSecretVault(),
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
        'secrets': {
          'type': 'array',
          'items': {'type': 'string'},
          'maxItems': maxRequestedSecrets,
          'description':
              'Names of stored user secrets to expose to this command as environment variables. Only these are injected; values never appear in the result.',
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

    final secretNames = requestedSecretNames(args);
    var secretEnvironment = const <String, String>{};
    if (secretNames.isNotEmpty) {
      final authority = CommandAuthority.fromStamped(
        context?.metadata[CommandAuthority.payloadKey],
      );
      if (!authority.isOwner) {
        return _refusal(
          stopwatch,
          'Stored secrets can be used only on a turn from the device owner.',
          terminalReason: 'secret_authority_required',
          errorCode: ToolResultErrorCode.permissionDenied,
        );
      }
      final resolved = _userSecrets.resolve(secretNames);
      if (resolved.missing.isNotEmpty) {
        return _refusal(
          stopwatch,
          'No stored secret named ${resolved.missing.join(', ')}. '
          'Ask the user with system_request_secret first.',
          terminalReason: 'secret_not_found',
          errorCode: ToolResultErrorCode.notFound,
        );
      }
      secretEnvironment = resolved.values;
    }
    // No `secrets` argument means no user secret: never all of them.

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
        secretEnvironment: secretEnvironment,
      ),
    );
  }

  /// Most secrets one command may request.
  static const maxRequestedSecrets = 16;

  /// The validated `secrets` argument: explicit names only, never a wildcard.
  /// A malformed, reserved or oversized list is rejected rather than trimmed.
  static List<String> requestedSecretNames(Map<String, dynamic> args) {
    final raw = args['secrets'];
    if (raw == null) return const [];
    if (raw is! List || raw.length > maxRequestedSecrets) {
      throw const FormatException(
        'secrets must be a list of at most $maxRequestedSecrets secret names.',
      );
    }
    final names = <String>[];
    for (final item in raw) {
      if (item is! String || UserSecretVault.nameRejection(item) != null) {
        throw FormatException('Invalid secret name: $item');
      }
      if (!names.contains(item)) names.add(item);
    }
    return names;
  }

  ToolExecutionResult _refusal(
    Stopwatch stopwatch,
    String message, {
    required String terminalReason,
    required ToolResultErrorCode errorCode,
  }) => ToolExecutionResult.text(
    const JsonEncoder.withIndent('  ').convert({
      'isError': true,
      'output': message,
      'duration_ms': stopwatch.elapsedMilliseconds,
      'terminal_reason': terminalReason,
    }),
    isError: true,
    errorCode: errorCode,
  );

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
