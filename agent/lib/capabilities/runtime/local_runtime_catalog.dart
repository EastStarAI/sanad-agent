import 'dart:convert';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/capabilities/tools/system/host_capability_discovery_tool.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/capabilities/tools/system/screenshot_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/mouse_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/keyboard_tool.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

import 'interactive_user_input.dart';
import 'tool_builders/ask_user_tool.dart';
import 'tool_builders/platform_tool_specs.dart';
import 'tool_builders/secret_tools.dart';
import 'tool_builders/view_image_tool.dart';
import 'tool_builders/web_tools.dart';
import 'tool_builders/workspace_file_tools.dart';

import 'web_search/web_fetch_service.dart';
import 'web_search/web_search_service.dart';
import 'workspace_path_resolver.dart';

typedef AdmittedAttachmentPathsResolver =
    Future<List<String>> Function(String sessionId);

class LocalRuntimeCatalog {
  LocalRuntimeCatalog({
    required LocalWorkspaceRuntimeService workspaceRuntimeService,
    WebSearchService? webSearchService,
    WebFetchService? webFetchService,
    McpRuntimeManager? mcpRuntimeManager,
    PermissionManager? permissionManager,
    PlatformRuntimeBridge? platformRuntimeBridge,
    WorkspacePathResolver? pathResolver,
    AdmittedAttachmentPathsResolver? admittedAttachmentPathsResolver,
    WorkspacePolicyStore? workspacePolicyStore,
    Map<String, String>? hostEnvironment,
    UserSecretVault? userSecrets,
  }) : _workspaceRuntimeService = workspaceRuntimeService,
       _workspacePolicyStore = workspacePolicyStore ?? WorkspacePolicyStore(),
       _hostEnvironment = hostEnvironment,
       _webSearchService = webSearchService ?? WebSearchService(),
       _webFetchService = webFetchService ?? WebFetchService(),
       _mcpRuntimeManager = mcpRuntimeManager ?? McpRuntimeManager(),
       _permissionManager = permissionManager ?? PermissionManager(),
       _platformRuntimeBridge =
           platformRuntimeBridge ?? PlatformRuntimeBridge(),
       _pathResolver = pathResolver ?? const WorkspacePathResolver(),
       _admittedAttachmentPathsResolver =
           admittedAttachmentPathsResolver ?? _noAdmittedAttachmentPaths,
       _userSecrets = userSecrets;

  final LocalWorkspaceRuntimeService _workspaceRuntimeService;
  final WorkspacePathResolver _pathResolver;
  final WebSearchService _webSearchService;
  final WebFetchService _webFetchService;
  final McpRuntimeManager _mcpRuntimeManager;
  final PermissionManager _permissionManager;
  final PlatformRuntimeBridge _platformRuntimeBridge;
  final AdmittedAttachmentPathsResolver _admittedAttachmentPathsResolver;
  final WorkspacePolicyStore _workspacePolicyStore;
  final Map<String, String>? _hostEnvironment;
  final UserSecretVault? _userSecrets;

  late final InteractiveUserInput _userInput = InteractiveUserInput(
    bridge: _platformRuntimeBridge,
  );

  static Future<List<String>> _noAdmittedAttachmentPaths(
    String sessionId,
  ) async => const [];

  Future<List<BaseTool>> buildTools({
    required ToolsRegistry registry,
    required AgentTurnRequest request,
    List<String> pendingAttachmentIds = const [],
  }) async {
    final workspacePath = await _resolveTargetWorkspacePath(request);
    final pendingAttachmentPaths =
        getIt.isRegistered<AttachmentStore>() &&
            pendingAttachmentIds.isNotEmpty &&
            request.requestId != null
        ? await getIt<AttachmentStore>().resolveAdmissionPaths(
            sessionId: request.sessionId,
            admissionId: request.requestId!,
            attachmentIds: pendingAttachmentIds,
          )
        : const <String>[];
    final injectedAttachmentPaths = await _admittedAttachmentPathsResolver(
      request.sessionId,
    );
    final persistedAttachmentPaths = injectedAttachmentPaths.isNotEmpty
        ? injectedAttachmentPaths
        : getIt.isRegistered<AttachmentStore>()
        ? await getIt<AttachmentStore>().resolveAttachedPaths(request.sessionId)
        : const <String>[];
    final admittedAttachmentPaths = {
      ...persistedAttachmentPaths,
      ...pendingAttachmentPaths,
    }.toList(growable: false);
    final tools = <BaseTool>[
      // TEMPORARILY DISABLED: tool_search — paused for review.
      // _buildSearchTool(registry),
      buildWebSearchTool(webSearchService: _webSearchService),
      buildWebFetchTool(webFetchService: _webFetchService),
      _buildSkillLoadTool(workspacePath),
      buildAskUserTool(userInput: _userInput),
      ...buildSecretTools(
        request: request,
        userInput: _userInput,
        userSecrets: _userSecrets,
        permissionManager: _permissionManager,
      ),
    ];

    if (workspacePath != null && workspacePath.isNotEmpty) {
      tools.addAll(
        buildWorkspaceFileTools(
          workspacePath: workspacePath,
          request: request,
          pathResolver: _pathResolver,
          permissionManager: _permissionManager,
          workspacePolicyStore: _workspacePolicyStore,
          userSecrets: _userSecrets,
        ),
      );
      final discovery = await _hostDiscoveryTool(request, workspacePath, tools);
      if (discovery != null) tools.add(discovery);
    }
    if ((workspacePath != null && workspacePath.isNotEmpty) ||
        admittedAttachmentPaths.isNotEmpty) {
      tools.add(
        buildViewImageTool(
          pathResolver: _pathResolver,
          workspacePath: workspacePath,
          admittedAttachmentPaths: admittedAttachmentPaths,
          authorizeExternal: (canonicalPath, originalArguments, toolContext) =>
              authorizeExternalWorkspacePath(
                pathResolver: _pathResolver,
                permissionManager: _permissionManager,
                toolName: 'view_image',
                arguments: {...originalArguments, 'path': canonicalPath},
                context: toolContext,
                request: request,
                workspacePath: workspacePath!,
              ),
        ),
      );
    }

    final hasConfig = getIt.isRegistered<Config>();
    final computerUse = hasConfig && getIt<Config>().computerUse;
    if (computerUse) {
      tools.addAll([ScreenshotTool(), MouseTool(), KeyboardTool()]);
    }

    tools.addAll(
      buildPlatformTools(
        request: request,
        platformRuntimeBridge: _platformRuntimeBridge,
        permissionManager: _permissionManager,
      ),
    );

    final mcpSpecs = await _mcpRuntimeManager.listToolSpecs(
      workspacePath: workspacePath,
    );
    for (final spec in mcpSpecs) {
      tools.add(
        CallbackTool(
          toolSpec: spec,
          onExecute: (args, {context}) async {
            final existingWorkspace = context?.metadata['workspace'] is Map
                ? Map<String, dynamic>.from(
                    context!.metadata['workspace'] as Map,
                  )
                : <String, dynamic>{};
            final toolContext = ToolContext(
              sessionId: context?.sessionId ?? request.sessionId,
              toolCallId: context?.toolCallId,
              metadata: {
                ...request.toMetadata(),
                ...?context?.metadata,
                if (workspacePath != null)
                  'workspace': {
                    ...existingWorkspace,
                    'id':
                        existingWorkspace['id'] ?? request.effectiveWorkspaceId,
                    'path': workspacePath,
                  },
              },
            );
            await _permissionManager.ensureAuthorized(
              tool: spec,
              arguments: args,
              context: toolContext,
            );
            return _mcpRuntimeManager.executeTool(
              spec.name,
              args,
              workspacePath: workspacePath,
            );
          },
        ),
      );
    }

    return tools;
  }

  Future<String?> _resolveTargetWorkspacePath(AgentTurnRequest request) async {
    final execRoot = request.executionRoot;
    if (execRoot != null && execRoot.isNotEmpty) {
      return _pathResolver.validateAndNormalizeExecutionRoot(execRoot);
    }

    final effectiveId = request.effectiveWorkspaceId;
    if (effectiveId != null && effectiveId.startsWith('exec_root:')) {
      final path = effectiveId.substring('exec_root:'.length);
      return _pathResolver.validateAndNormalizeExecutionRoot(path);
    }

    if (effectiveId != null && effectiveId.isNotEmpty) {
      final workspacePath = await _resolveWorkspacePath(effectiveId);
      if (workspacePath != null && workspacePath.isNotEmpty) {
        return workspacePath;
      }
    }

    if (getIt.isRegistered<SessionManager>()) {
      final sessionMeta = getIt<SessionManager>().getSessionMetadata(
        request.sessionId,
      );
      final sessionExecRoot = sessionMeta?['execution_root']?.toString();
      if (sessionExecRoot != null && sessionExecRoot.isNotEmpty) {
        return _pathResolver.validateAndNormalizeExecutionRoot(sessionExecRoot);
      }
      final sessionWorkspacePath = sessionMeta?['workspace_path']?.toString();
      if (sessionWorkspacePath != null && sessionWorkspacePath.isNotEmpty) {
        return sessionWorkspacePath;
      }
    }
    return null;
  }

  Future<String?> _resolveWorkspacePath(String? workspaceId) async {
    if (workspaceId == null || workspaceId.trim().isEmpty) {
      return null;
    }
    final workspace = await _workspaceRuntimeService.describeWorkspace(
      workspaceId,
    );
    return workspace?['path'] as String?;
  }

  // ignore: unused_element
  BaseTool _buildSearchTool(ToolsRegistry registry) {
    return CallbackTool(
      toolSpec: const LocalToolSpec(
        name: 'tool_search',
        displayName: 'Tool Search',
        description:
            'Search for specialized or non-core tools by exact name or keywords.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
            'max_results': {'type': 'integer', 'minimum': 1, 'maximum': 20},
          },
          'required': ['query'],
          'additionalProperties': false,
        },
        source: {'type': 'builtin_local', 'id': 'sanad-agent.discovery'},
        category: 'tool_discovery',
        workspaceRequired: false,
        approval: {'mode': 'default', 'sensitive': false},
        execution: {'target': 'local_runtime', 'timeout_ms': 10000},
        serverName: 'discovery',
      ),
      onExecute: (args, {context}) async {
        final query = args['query']?.toString() ?? '';
        final maxResults = args['max_results'] is int
            ? args['max_results'] as int
            : int.tryParse(args['max_results']?.toString() ?? '');
        return const JsonEncoder.withIndent(
          '  ',
        ).convert(registry.search(query, maxResults: maxResults ?? 5));
      },
    );
  }

  BaseTool _buildSkillLoadTool(String? workspacePath) {
    return CallbackTool(
      toolSpec: const LocalToolSpec(
        name: 'skill_load',
        displayName: 'Skill Loader',
        description:
            'Load a local skill definition from workspace or user skill directories.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'skill': {'type': 'string'},
          },
          'required': ['skill'],
          'additionalProperties': false,
        },
        source: {'type': 'builtin_local', 'id': 'sanad-agent.skills'},
        category: 'skills',
        workspaceRequired: false,
        approval: {'mode': 'default', 'sensitive': false},
        execution: {'target': 'local_runtime', 'timeout_ms': 15000},
        serverName: 'skill',
      ),
      onExecute: (args, {context}) async {
        final skill = args['skill']?.toString() ?? '';
        return _workspaceRuntimeService.loadSkill(
          skill: skill,
          workspacePath: workspacePath,
        );
      },
    );
  }

  /// Adds typed host discovery only where it adds a capability the turn
  /// lacks: the workspace policy allows it, the turn carries daemon-stamped
  /// owner authority, and no tool in the turn already reaches the host
  /// `PATH` (a Direct shell does). Otherwise the schema is omitted entirely.
  Future<BaseTool?> _hostDiscoveryTool(
    AgentTurnRequest request,
    String root,
    List<BaseTool> tools,
  ) async {
    final authority = CommandAuthority.fromStamped(
      request.metadata[CommandAuthority.payloadKey],
    );
    if (!authority.isOwner) return null;
    final effective = await _workspacePolicyStore.resolveForRoot(root);
    if (effective == null) return null;
    final policy = effective.policy;
    final hasHostShell = tools.any(
      (tool) =>
          tool is SpecBackedTool &&
          tool.toolSpec.category == 'shell_execution',
    );
    final present = HostDiscoveryPolicy.isToolPresent(
      policy: policy.hostDiscoveryPolicy,
      isOwner: authority.isOwner,
      hasHostPathAccess:
          hasHostShell && policy.executionMode == ExecutionMode.direct,
    );
    return present
        ? HostCapabilityDiscoveryTool(environment: _hostEnvironment)
        : null;
  }
}
