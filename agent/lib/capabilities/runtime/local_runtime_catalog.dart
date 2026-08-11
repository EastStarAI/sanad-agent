import 'dart:convert';

import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/capabilities/tools/system/shell_execute_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/screenshot_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/mouse_tool.dart';
import 'package:sanad_agent/capabilities/tools/system/keyboard_tool.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';

import 'web_search/web_fetch_service.dart';
import 'web_search/web_search_service.dart';
import 'workspace_path_resolver.dart';
import 'workspace_tools/file_edit_handler.dart';
import 'workspace_tools/file_read_handler.dart';
import 'workspace_tools/file_write_handler.dart';
import 'workspace_tools/search_glob_handler.dart';
import 'workspace_tools/search_grep_handler.dart';

class LocalRuntimeCatalog {
  LocalRuntimeCatalog({
    required LocalWorkspaceRuntimeService workspaceRuntimeService,
    WebSearchService? webSearchService,
    WebFetchService? webFetchService,
    McpRuntimeManager? mcpRuntimeManager,
    PermissionManager? permissionManager,
    PlatformRuntimeBridge? platformRuntimeBridge,
    WorkspacePathResolver? pathResolver,
  }) : _workspaceRuntimeService = workspaceRuntimeService,
       _webSearchService = webSearchService ?? WebSearchService(),
       _webFetchService = webFetchService ?? WebFetchService(),
       _mcpRuntimeManager = mcpRuntimeManager ?? McpRuntimeManager(),
       _permissionManager = permissionManager ?? PermissionManager(),
       _platformRuntimeBridge =
           platformRuntimeBridge ?? PlatformRuntimeBridge(),
       _pathResolver = pathResolver ?? const WorkspacePathResolver();

  final LocalWorkspaceRuntimeService _workspaceRuntimeService;
  final WorkspacePathResolver _pathResolver;
  final WebSearchService _webSearchService;
  final WebFetchService _webFetchService;
  final McpRuntimeManager _mcpRuntimeManager;
  final PermissionManager _permissionManager;
  final PlatformRuntimeBridge _platformRuntimeBridge;

  Future<List<BaseTool>> buildTools({
    required ToolsRegistry registry,
    required AgentTurnRequest request,
  }) async {
    final workspacePath = await _resolveWorkspacePath(request.workspaceId);
    final tools = <BaseTool>[
      // TEMPORARILY DISABLED: tool_search — paused for review.
      // _buildSearchTool(registry),
      _buildWebSearchTool(),
      _buildWebFetchTool(),
      _buildSkillLoadTool(workspacePath),
      _buildAskUserTool(),
    ];

    if (workspacePath != null && workspacePath.isNotEmpty) {
      tools.addAll(_buildWorkspaceTools(workspacePath));
    }

    final hasConfig = getIt.isRegistered<Config>();
    final computerUse = hasConfig && getIt<Config>().computerUse;
    if (computerUse) {
      tools.addAll([ScreenshotTool(), MouseTool(), KeyboardTool()]);
    }

    tools.addAll(_buildPlatformTools(request));

    final mcpSpecs = await _mcpRuntimeManager.listToolSpecs(
      workspacePath: workspacePath,
    );
    for (final spec in mcpSpecs) {
      tools.add(
        CallbackTool(
          toolSpec: spec,
          onExecute: (args, {context}) async {
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

  List<BaseTool> _buildPlatformTools(AgentTurnRequest request) {
    final hasConfig = getIt.isRegistered<Config>();
    final computerUse = hasConfig && getIt<Config>().computerUse;
    final excludedTools = {
      'shell_execute',
      if (computerUse) ...{
        'system_screenshot',
        'system_mouse',
        'system_keyboard',
      },
    };

    return request.platformTools
        .map(_platformSpecFromPayload)
        .whereType<LocalToolSpec>()
        .where((spec) => !excludedTools.contains(spec.name))
        .map(
          (spec) => CallbackTool(
            toolSpec: spec,
            onExecute: (args, {context}) async {
              final toolContext =
                  context ??
                  ToolContext(
                    sessionId: request.sessionId,
                    metadata: request.toMetadata(),
                  );
              await _permissionManager.ensureAuthorized(
                tool: spec,
                arguments: args,
                context: toolContext,
              );
              return _platformRuntimeBridge.executePlatformTool(
                sessionId: toolContext.sessionId,
                payload: {
                  'tool_name': spec.name,
                  'tool_input': args,
                  'tool': spec.toJson(),
                  'workspace_id': request.workspaceId,
                  'session_id': request.sessionId,
                },
              );
            },
          ),
        )
        .toList(growable: false);
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

  BaseTool _buildWebSearchTool() {
    return CallbackTool(
      toolSpec: const LocalToolSpec(
        name: 'web_search',
        displayName: 'Web Search',
        description:
            'Search the web from the local runtime with optional domain filtering and result limits.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'query': {'type': 'string'},
            'allowed_domains': {
              'type': 'array',
              'items': {'type': 'string'},
              'description':
                  'Optional list of domains to restrict search results to (e.g. ["wikipedia.org"]).',
            },
            'limit': {
              'type': 'integer',
              'minimum': 1,
              'maximum': 10,
              'description':
                  'Optional limit on the number of search hits returned.',
            },
          },
          'required': ['query'],
          'additionalProperties': false,
        },
        source: {'type': 'builtin_local', 'id': 'sanad-agent.web'},
        category: 'web',
        workspaceRequired: false,
        approval: {'mode': 'default', 'sensitive': false},
        execution: {'target': 'local_runtime', 'timeout_ms': 30000},
        serverName: 'web',
      ),
      onExecute: (args, {context}) async {
        final query = args['query']?.toString() ?? '';
        final limit = args['limit'] is int ? args['limit'] as int : null;

        final domainsRaw = args['allowed_domains'];
        List<String>? allowedDomains;
        if (domainsRaw is List) {
          allowedDomains = domainsRaw.map((d) => d.toString()).toList();
        }

        return _webSearchService.search(
          query,
          allowedDomains: allowedDomains,
          limit: limit,
        );
      },
    );
  }

  BaseTool _buildWebFetchTool() {
    return CallbackTool(
      toolSpec: const LocalToolSpec(
        name: 'web_fetch',
        displayName: 'Web Fetch',
        description:
            'Fetch the content of specific URLs concurrently and summarize them.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'urls': {
              'type': 'array',
              'items': {'type': 'string'},
              'description': 'List of URLs to fetch content from (max 5 URLs).',
            },
            'prompt': {'type': 'string'},
          },
          'required': ['urls'],
          'additionalProperties': false,
        },
        source: {'type': 'builtin_local', 'id': 'sanad-agent.web'},
        category: 'web',
        workspaceRequired: false,
        approval: {'mode': 'default', 'sensitive': false},
        execution: {'target': 'local_runtime', 'timeout_ms': 30000},
        serverName: 'web',
      ),
      onExecute: (args, {context}) async {
        final urlsRaw = args['urls'];
        List<String> urls = [];
        if (urlsRaw is List) {
          urls = urlsRaw.map((u) => u.toString()).toList();
        } else if (urlsRaw is String) {
          urls = [urlsRaw];
        }

        final results = await _webFetchService.fetch(
          urls,
          prompt: args['prompt']?.toString() ?? '',
        );
        final jsonList = results.map((r) => r.toJson()).toList();
        return const JsonEncoder.withIndent(
          '  ',
        ).convert({'results': jsonList});
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

  List<BaseTool> _buildWorkspaceTools(String workspacePath) {
    return [
      ShellExecuteTool(
        workspacePath: workspacePath,
        permissionManager: _permissionManager,
      ),
      CallbackTool(
        toolSpec: _workspaceSpec(
          name: 'file_read',
          displayName: 'Read File',
          description:
              'Read a file or list contents of a directory. For files, returns up to 2000 lines from the start. Use offset (1-indexed) to read later sections. Lines are prefixed with line numbers. Lines >2000 chars are truncated. For directories, returns paginated entries.',
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
          return FileReadHandler(_pathResolver).execute(args, workspacePath);
        },
      ),
      CallbackTool(
        toolSpec: _workspaceSpec(
          name: 'file_write',
          displayName: 'Write File',
          description:
              'Create or replace a text file inside the selected workspace.',
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
          return FileWriteHandler(_pathResolver).execute(args, workspacePath);
        },
      ),
      CallbackTool(
        toolSpec: _workspaceSpec(
          name: 'file_edit',
          displayName: 'Edit File',
          description:
              'Performs exact string replacements using an elastic matching algorithm. old_string must preserve exact indentation. Fails if not found or if multiple matches exist (unless replace_all is true). Do NOT include line number prefixes from file_read in old_string.',
          inputSchema: const {
            'type': 'object',
            'properties': {
              'path': {'type': 'string'},
              'old_string': {'type': 'string'},
              'new_string': {'type': 'string'},
              'replace_all': {'type': 'boolean'},
            },
            'required': ['path', 'old_string', 'new_string'],
            'additionalProperties': false,
          },
          category: 'workspace_io',
        ),
        onExecute: (args, {context}) async {
          return FileEditHandler(_pathResolver).execute(args, workspacePath);
        },
      ),
      CallbackTool(
        toolSpec: _workspaceSpec(
          name: 'search_glob',
          displayName: 'Glob Search',
          description:
              'Fast file pattern matching tool. Supports glob patterns like "**/*.dart". Returns matching file paths sorted by modification time.',
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
          return SearchGlobHandler(_pathResolver).execute(args, workspacePath);
        },
      ),
      CallbackTool(
        toolSpec: _workspaceSpec(
          name: 'search_grep',
          displayName: 'Grep Search',
          description:
              'Searches file contents using regular expressions. Filter files with the glob parameter. Returns file paths and line numbers with matches.',
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
          return SearchGrepHandler(_pathResolver).execute(args, workspacePath);
        },
      ),
    ];
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

  LocalToolSpec? _platformSpecFromPayload(Map<String, dynamic> payload) {
    final name = payload['name']?.toString().trim();
    if (name == null || name.isEmpty) {
      return null;
    }

    final displayName =
        payload['display_name']?.toString().trim().isNotEmpty == true
        ? payload['display_name'].toString().trim()
        : name;
    final description =
        payload['description']?.toString().trim().isNotEmpty == true
        ? payload['description'].toString().trim()
        : 'Platform-provided tool exposed by the connected client.';
    final inputSchema = payload['input_schema'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(
            payload['input_schema'] as Map<String, dynamic>,
          )
        : payload['input_schema'] is Map
        ? Map<String, dynamic>.from(payload['input_schema'] as Map)
        : const {
            'type': 'object',
            'properties': <String, dynamic>{},
            'additionalProperties': true,
          };
    final approval = payload['approval'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(payload['approval'] as Map<String, dynamic>)
        : payload['approval'] is Map
        ? Map<String, dynamic>.from(payload['approval'] as Map)
        : <String, dynamic>{};
    final availability = payload['availability'] is Map<String, dynamic>
        ? Map<String, dynamic>.from(
            payload['availability'] as Map<String, dynamic>,
          )
        : payload['availability'] is Map
        ? Map<String, dynamic>.from(payload['availability'] as Map)
        : const {'status': 'available'};

    return LocalToolSpec(
      name: name,
      displayName: displayName,
      description: description,
      inputSchema: inputSchema,
      source: {
        'type': 'platform',
        'owner': 'platform',
        'id': payload['platform_id']?.toString() ?? 'connected-client',
      },
      category: payload['category']?.toString() ?? 'platform',
      workspaceRequired: payload['workspace_required'] == true,
      approval: {
        'mode': approval['mode']?.toString() ?? 'default',
        'sensitive': approval['sensitive'] == true,
        'scope': approval['scope']?.toString() ?? 'session',
        'permission_class':
            approval['permission_class']?.toString() ??
            payload['permission_class']?.toString() ??
            'platform',
      },
      execution: {
        'target': 'platform',
        if (payload['execution'] is Map)
          ...Map<String, dynamic>.from(payload['execution'] as Map),
      },
      availability: availability,
      serverName: payload['server_name']?.toString(),
    );
  }

  BaseTool _buildAskUserTool() {
    return CallbackTool(
      toolSpec: const LocalToolSpec(
        name: 'system_ask_user',
        displayName: 'Ask Clarifying Questions',
        description:
            'Ask the user one or more clarifying questions (up to 5) to resolve design ambiguity, missing details, or decision-making. Halts session execution until the user responds. Each question must have exactly 3 options.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'questions': {
              'type': 'array',
              'minItems': 1,
              'maxItems': 5,
              'items': {
                'type': 'object',
                'properties': {
                  'question': {
                    'type': 'string',
                    'description': 'The clarifying question text.',
                  },
                  'options': {
                    'type': 'array',
                    'minItems': 3,
                    'maxItems': 3,
                    'items': {'type': 'string'},
                    'description':
                        'Exactly 3 predefined options for the user to choose from.',
                  },
                },
                'required': ['question', 'options'],
                'additionalProperties': false,
              },
            },
          },
          'required': ['questions'],
          'additionalProperties': false,
        },
        source: {'type': 'builtin_local', 'id': 'sanad-agent.system'},
        category: 'system',
        workspaceRequired: false,
        approval: {'mode': 'default', 'sensitive': false},
        execution: {'target': 'local_runtime', 'timeout_ms': 3600000},
        serverName: 'system',
      ),
      onExecute: (args, {context}) async {
        final toolContext =
            context ??
            ToolContext(
              sessionId: 'default',
              toolCallId: 'ask-call-${DateTime.now().millisecondsSinceEpoch}',
            );
        final requestId = DateTime.now().millisecondsSinceEpoch.toString();
        final toolCallId = toolContext.toolCallId ?? 'ask-call-$requestId';

        final rawQuestions = args['questions'];
        final List<Map<String, dynamic>> questionsList = [];

        if (rawQuestions is List) {
          for (final q in rawQuestions) {
            if (q is Map) {
              questionsList.add({
                'question': q['question']?.toString() ?? '',
                'options': List<String>.from(
                  (q['options'] as List? ?? []).map((o) => o.toString()),
                ),
              });
            }
          }
        } else {
          // Backward compatibility for single 'question' parameter
          final singleQuestion =
              args['question']?.toString() ??
              args['questions']?.toString() ??
              '';
          if (singleQuestion.isNotEmpty) {
            questionsList.add({
              'question': singleQuestion,
              'options': <String>[],
            });
          }
        }

        final permissionPayload = <String, dynamic>{
          'request_id': requestId,
          'tool_name': 'system_ask_user',
          'session_id': toolContext.sessionId,
          'questions': questionsList,
          'workspace_id': toolContext.metadata['workspace_id'],
        };

        final checkpointStore = getIt<SuspendedCheckpointStore>();
        await checkpointStore.save(
          SuspendedCheckpoint(
            checkpointId: 'ask-$requestId',
            sessionId: toolContext.sessionId,
            requestId: requestId,
            toolCallId: toolCallId,
            toolName: 'system_ask_user',
            status: 'awaiting_permission',
            toolArguments: Map<String, dynamic>.from(args),
            permissionPayload: permissionPayload,
            createdAt: DateTime.now(),
            updatedAt: DateTime.now(),
          ),
        );

        try {
          final decision = await _platformRuntimeBridge.requestToolPermission(
            sessionId: toolContext.sessionId,
            payload: permissionPayload,
            timeout: const Duration(hours: 24),
          );
          return decision['answer']?.toString() ?? '';
        } finally {
          await checkpointStore.deleteByRequestId(requestId);
        }
      },
    );
  }
}
