import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';
import 'package:sanad_agent/core/models/tool_execution_result.dart';

import '../workspace_path_resolver.dart';
import '../workspace_tools/view_image_handler.dart';

/// `view_image` builder for `LocalRuntimeCatalog`.
///
/// The tool is registered only when the turn has a workspace or admitted
/// attachment scope. External-path approval is supplied by the host through the
/// single workspace approval gate, so this builder never mints its own
/// permission path.
BaseTool buildViewImageTool({
  required WorkspacePathResolver pathResolver,
  required String? workspacePath,
  required List<String> admittedAttachmentPaths,
  required ExternalImagePathAuthorizer authorizeExternal,
}) {
  final hasWorkspace = workspacePath != null && workspacePath.isNotEmpty;
  final spec = LocalToolSpec(
    name: 'view_image',
    displayName: 'View Image',
    description:
        'Inspect one local PNG, JPEG, or WebP image from the current workspace or admitted session attachments.',
    inputSchema: const {
      'type': 'object',
      'properties': {
        'path': {'type': 'string'},
        'detail': {
          'type': 'string',
          'enum': ['low', 'auto', 'high', 'original'],
          'default': 'auto',
        },
      },
      'required': ['path'],
      'additionalProperties': false,
    },
    source: hasWorkspace
        ? const {'type': 'builtin_workspace', 'id': 'sanad-agent.workspace'}
        : const {
            'type': 'builtin_attachment',
            'id': 'sanad-agent.attachments',
          },
    category: 'workspace_io',
    workspaceRequired: hasWorkspace,
    approval: const {'mode': 'workspace', 'sensitive': false},
    execution: const {
      'target': 'local_runtime',
      'timeout_ms': 30000,
      'restart_replay_safe': true,
    },
    serverName: hasWorkspace ? 'workspace' : 'attachments',
  );
  final handler = ViewImageHandler(pathResolver);
  return _ResultCallbackTool(
    toolSpec: spec,
    onExecuteResult: (args, {context}) => handler.executeResult(
      args,
      workspacePath: workspacePath,
      admittedAttachmentPaths: admittedAttachmentPaths,
      context: context,
      authorizeExternal: authorizeExternal,
    ),
  );
}

typedef _ResultExecutionCallback =
    Future<ToolExecutionResult> Function(
      Map<String, dynamic> args, {
      ToolContext? context,
    });

final class _ResultCallbackTool extends SpecBackedTool {
  _ResultCallbackTool({
    required this.toolSpec,
    required _ResultExecutionCallback onExecuteResult,
  }) : _onExecuteResult = onExecuteResult;

  @override
  final LocalToolSpec toolSpec;
  final _ResultExecutionCallback _onExecuteResult;

  @override
  Future<ToolExecutionResult> executeResult(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) => _onExecuteResult(args, context: context);

  @override
  Future<String> execute(
    Map<String, dynamic> args, {
    ToolContext? context,
  }) async => (await executeResult(args, context: context)).displayText;
}
