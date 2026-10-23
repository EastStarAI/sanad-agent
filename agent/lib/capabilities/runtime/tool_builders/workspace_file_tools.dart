import 'package:sanad_agent/capabilities/execution/execution_backend_resolver.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';

import '../workspace_path_resolver.dart';
import '../workspace_tools/file_edit_handler.dart';
import '../workspace_tools/file_read_handler.dart';
import '../workspace_tools/file_write_handler.dart';
import '../workspace_tools/search_glob_handler.dart';
import '../workspace_tools/search_grep_handler.dart';

/// Workspace-bound tool builders for `LocalRuntimeCatalog`.
///
/// [buildWorkspaceFileTools] owns the terminal and file/search tool set for one
/// turn, and [authorizeExternalWorkspacePath] is the single external-path
/// approval gate shared by every workspace- and attachment-scoped tool that can
/// reach a canonical path outside the selected workspace. The catalog still
/// assembles the catalog; these functions never register themselves.
List<BaseTool> buildWorkspaceFileTools({
  required String workspacePath,
  required AgentTurnRequest request,
  required WorkspacePathResolver pathResolver,
  required PermissionManager permissionManager,
  required WorkspacePolicyStore workspacePolicyStore,
  required UserSecretVault? userSecrets,
}) {
  return [
    ShellExecuteTool(
      workspacePath: workspacePath,
      permissionManager: permissionManager,
      userSecrets: userSecrets,
      backendResolver: ExecutionBackendResolver(
        policyStore: workspacePolicyStore,
      ),
    ),
    CallbackTool(
      toolSpec: _workspaceSpec(
        name: 'file_read',
        displayName: 'Read File',
        description:
            'Read a file or list a directory. Paths inside the workspace execute directly; external paths require full access or user approval. Files return up to 2000 lines, with offset for later sections, and directories return paginated entries.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'offset': {'type': 'integer', 'minimum': 0},
            'limit': {'type': 'integer', 'minimum': 1, 'maximum': 2000},
          },
          'required': ['path'],
          'additionalProperties': false,
        },
        category: 'workspace_io',
        restartReplaySafe: true,
      ),
      onExecute: (args, {context}) async {
        final authorizedExternalRoot = await authorizeExternalWorkspacePath(
          pathResolver: pathResolver,
          permissionManager: permissionManager,
          toolName: 'file_read',
          arguments: args,
          context: context,
          request: request,
          workspacePath: workspacePath,
        );
        return FileReadHandler(pathResolver).execute(
          args,
          workspacePath,
          authorizedExternalRoot: authorizedExternalRoot,
        );
      },
    ),
    CallbackTool(
      toolSpec: _workspaceSpec(
        name: 'file_write',
        displayName: 'Write File',
        description:
            'Create or replace a text file inside the workspace or at an authorized external path.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'content': {'type': 'string'},
          },
          'required': ['path', 'content'],
          'additionalProperties': false,
        },
        category: 'workspace_io',
      ),
      onExecute: (args, {context}) async {
        final authorizedExternalRoot = await authorizeExternalWorkspacePath(
          pathResolver: pathResolver,
          permissionManager: permissionManager,
          toolName: 'file_write',
          arguments: args,
          context: context,
          request: request,
          workspacePath: workspacePath,
          allowMissing: true,
        );
        return FileWriteHandler(pathResolver).execute(
          args,
          workspacePath,
          authorizedExternalRoot: authorizedExternalRoot,
        );
      },
    ),
    CallbackTool(
      toolSpec: _workspaceSpec(
        name: 'file_edit',
        displayName: 'Edit File',
        description:
            'Perform exact string replacements inside the workspace or in an authorized external file. Provide either old_string and new_string for a single replacement, or edits for multiple non-contiguous replacements in the same file. Each old_string must preserve indentation and must not include file_read line-number prefixes. Fails atomically if any match is missing or ambiguous unless replace_all is true, or if edits overlap.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
            'old_string': {'type': 'string'},
            'new_string': {'type': 'string'},
            'replace_all': {'type': 'boolean'},
            'edits': {
              'type': 'array',
              'description':
                  'Optional list of edits to apply in one call. Each edit requires old_string and new_string.',
              'items': {
                'type': 'object',
                'properties': {
                  'old_string': {'type': 'string'},
                  'new_string': {'type': 'string'},
                  'replace_all': {'type': 'boolean'},
                },
                'required': ['old_string', 'new_string'],
                'additionalProperties': false,
              },
            },
          },
          'required': ['path'],
          'additionalProperties': false,
        },
        category: 'workspace_io',
      ),
      onExecute: (args, {context}) async {
        final authorizedExternalRoot = await authorizeExternalWorkspacePath(
          pathResolver: pathResolver,
          permissionManager: permissionManager,
          toolName: 'file_edit',
          arguments: args,
          context: context,
          request: request,
          workspacePath: workspacePath,
        );
        return FileEditHandler(pathResolver).execute(
          args,
          workspacePath,
          authorizedExternalRoot: authorizedExternalRoot,
        );
      },
    ),
    CallbackTool(
      toolSpec: _workspaceSpec(
        name: 'search_glob',
        displayName: 'Glob Search',
        description:
            'Match file patterns in the workspace or an authorized external directory. Supports patterns like "**/*.dart" and returns matches sorted by modification time.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'pattern': {'type': 'string'},
            'path': {'type': 'string'},
          },
          'required': ['pattern'],
          'additionalProperties': false,
        },
        category: 'workspace_search',
        restartReplaySafe: true,
      ),
      onExecute: (args, {context}) async {
        final authorizedExternalRoot = await authorizeExternalWorkspacePath(
          pathResolver: pathResolver,
          permissionManager: permissionManager,
          toolName: 'search_glob',
          arguments: args,
          context: context,
          request: request,
          workspacePath: workspacePath,
        );
        return SearchGlobHandler(pathResolver).execute(
          args,
          workspacePath,
          authorizedExternalRoot: authorizedExternalRoot,
        );
      },
    ),
    CallbackTool(
      toolSpec: _workspaceSpec(
        name: 'search_grep',
        displayName: 'Grep Search',
        description:
            'Search file contents in the workspace or an authorized external path using regular expressions, with optional glob filtering and line-numbered matches.',
        inputSchema: const {
          'type': 'object',
          'properties': {
            'pattern': {'type': 'string'},
            'path': {'type': 'string'},
            'glob': {'type': 'string'},
            'line_numbers': {'type': 'boolean'},
            'case_insensitive': {'type': 'boolean'},
            'head_limit': {'type': 'integer', 'minimum': 1, 'maximum': 100},
            'offset': {'type': 'integer', 'minimum': 0},
            'before': {'type': 'integer', 'minimum': 0, 'maximum': 20},
            'after': {'type': 'integer', 'minimum': 0, 'maximum': 20},
            'context': {'type': 'integer', 'minimum': 0, 'maximum': 20},
          },
          'required': ['pattern'],
          'additionalProperties': false,
        },
        category: 'workspace_search',
        restartReplaySafe: true,
      ),
      onExecute: (args, {context}) async {
        final authorizedExternalRoot = await authorizeExternalWorkspacePath(
          pathResolver: pathResolver,
          permissionManager: permissionManager,
          toolName: 'search_grep',
          arguments: args,
          context: context,
          request: request,
          workspacePath: workspacePath,
        );
        return SearchGrepHandler(pathResolver).execute(
          args,
          workspacePath,
          authorizedExternalRoot: authorizedExternalRoot,
        );
      },
    ),
  ];
}

/// The one external-path approval gate for the turn.
///
/// Returns the canonical external root once `PermissionManager` approved it, or
/// `null` when the path is inside the workspace and needs no approval. Every
/// caller must stay bound to this single owner so the approval key, permission
/// class, and display arguments cannot diverge between tools.
Future<String?> authorizeExternalWorkspacePath({
  required WorkspacePathResolver pathResolver,
  required PermissionManager permissionManager,
  required String toolName,
  required Map<String, dynamic> arguments,
  required ToolContext? context,
  required AgentTurnRequest request,
  required String workspacePath,
  bool allowMissing = false,
}) async {
  final inputPath = arguments['path']?.toString().trim();
  final effectivePath = inputPath == null || inputPath.isEmpty
      ? '.'
      : inputPath;
  final resolution = allowMissing
      ? await pathResolver.classifyPathAllowMissingAsync(
          workspaceRoot: workspacePath,
          inputPath: effectivePath,
        )
      : await pathResolver.classifyExistingPathAsync(
          workspaceRoot: workspacePath,
          inputPath: effectivePath,
        );
  if (!resolution.isExternal) {
    return null;
  }

  final existingWorkspace = context?.metadata['workspace'] is Map
      ? Map<String, dynamic>.from(context!.metadata['workspace'] as Map)
      : <String, dynamic>{};
  final toolContext = ToolContext(
    sessionId: context?.sessionId ?? request.sessionId,
    toolCallId: context?.toolCallId,
    metadata: {
      ...request.toMetadata(),
      ...?context?.metadata,
      'workspace': {
        ...existingWorkspace,
        'id': existingWorkspace['id'] ?? request.effectiveWorkspaceId,
        'path': workspacePath,
      },
    },
  );
  final approvalSpec = _externalWorkspaceAccessSpec(toolName);
  await permissionManager.ensureAuthorized(
    tool: approvalSpec,
    arguments: arguments,
    context: toolContext,
    approvalKeyOverride:
        'external_workspace_path::$toolName::${resolution.resolvedPath}',
    permissionDisplayArguments: {
      'action': toolName,
      'path': resolution.resolvedPath,
    },
  );
  return resolution.resolvedPath;
}

LocalToolSpec _externalWorkspaceAccessSpec(String toolName) {
  return LocalToolSpec(
    name: toolName,
    displayName: toolName,
    description: 'Access a canonical path outside the selected workspace.',
    inputSchema: const {'type': 'object', 'additionalProperties': true},
    source: const {
      'type': 'builtin_workspace',
      'id': 'sanad-agent.workspace',
    },
    category: 'workspace_io',
    workspaceRequired: true,
    approval: const {
      'mode': 'ask',
      'sensitive': true,
      'scope': 'once',
      'permission_class': 'external_workspace_path',
    },
    execution: const {'target': 'local_runtime', 'timeout_ms': 30000},
    serverName: 'workspace',
  );
}

LocalToolSpec _workspaceSpec({
  required String name,
  required String displayName,
  required String description,
  required Map<String, dynamic> inputSchema,
  required String category,
  bool restartReplaySafe = false,
}) {
  return LocalToolSpec(
    name: name,
    displayName: displayName,
    description: description,
    inputSchema: inputSchema,
    source: const {
      'type': 'builtin_workspace',
      'id': 'sanad-agent.workspace',
    },
    category: category,
    workspaceRequired: true,
    approval: const {'mode': 'workspace', 'sensitive': false},
    execution: {
      'target': 'local_runtime',
      'timeout_ms': 30000,
      'restart_replay_safe': restartReplaySafe,
    },
    serverName: 'workspace',
  );
}
