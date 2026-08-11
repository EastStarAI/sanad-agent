import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';

class FakeMcpRuntimeManager extends McpRuntimeManager {
  FakeMcpRuntimeManager()
    : super(settingsStore: const SanadSettingsStore(homeDirectoryPath: '/tmp'));

  String? lastToolName;
  Map<String, dynamic>? lastArguments;

  @override
  Future<List<LocalToolSpec>> listToolSpecs({String? workspacePath}) async {
    return const [
      LocalToolSpec(
        name: 'mcp__filesystem__read_file',
        displayName: 'read_file',
        description: 'Read a file through MCP.',
        inputSchema: {
          'type': 'object',
          'properties': {
            'path': {'type': 'string'},
          },
          'required': ['path'],
        },
        source: {
          'type': 'mcp_server',
          'id': 'filesystem',
          'original_name': 'read_file',
        },
        category: 'mcp',
        workspaceRequired: false,
        approval: {'mode': 'default', 'sensitive': true},
        execution: {'target': 'local_runtime', 'timeout_ms': 60000},
        serverName: 'filesystem',
      ),
    ];
  }

  @override
  Future<String> executeTool(
    String namespacedToolName,
    Map<String, dynamic> arguments, {
    String? workspacePath,
  }) async {
    lastToolName = namespacedToolName;
    lastArguments = arguments;
    return jsonEncode({
      'tool': namespacedToolName,
      'workspace_path': workspacePath,
      'arguments': arguments,
    });
  }
}

class FakePlatformRuntimeBridge extends PlatformRuntimeBridge {
  Map<String, dynamic>? lastPermissionPayload;
  Map<String, dynamic>? lastExecutionPayload;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    lastPermissionPayload = payload;
    return const {'allowed': true, 'scope': 'session'};
  }

  @override
  Future<String> executePlatformTool({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    lastExecutionPayload = payload;
    return jsonEncode({
      'tool_name': payload['tool_name'],
      'session_id': sessionId,
      'tool_input': payload['tool_input'],
    });
  }
}

class NoopCheckpointStore extends SuspendedCheckpointStore {
  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async {}

  @override
  Future<SuspendedCheckpoint?> getByRequestId(String requestId) async {
    return null;
  }

  @override
  Future<void> updateStatus({
    required String requestId,
    required String status,
  }) async {}

  @override
  Future<void> deleteByRequestId(String requestId) async {}
}

void main() {
  group('LocalRuntimeCatalog', () {
    late Directory tempDir;
    late Directory workspaceDir;
    late LocalWorkspaceRuntimeService workspaceRuntimeService;
    late ToolsRegistry registry;
    late FakeMcpRuntimeManager fakeMcpManager;
    late FakePlatformRuntimeBridge fakePlatformBridge;
    late LocalRuntimeCatalog catalog;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('runtime-catalog-test');
      workspaceDir = Directory('${tempDir.path}/workspace')
        ..createSync(recursive: true);
      Directory(
        '${workspaceDir.path}/.sanad/skills/review',
      ).createSync(recursive: true);
      File(
        '${workspaceDir.path}/AGENTS.md',
      ).writeAsStringSync('Workspace instructions from AGENTS.');
      File(
        '${workspaceDir.path}/.sanad/skills/review/SKILL.md',
      ).writeAsStringSync('''---
name: review
description: Review the current workspace carefully.
---
Use the review skill.''');
      workspaceRuntimeService = LocalWorkspaceRuntimeService(
        sanadHomePath: tempDir.path,
        currentWorkingDirectory: workspaceDir.path,
      );
      registry = ToolsRegistry();
      fakeMcpManager = FakeMcpRuntimeManager();
      fakePlatformBridge = FakePlatformRuntimeBridge();
      catalog = LocalRuntimeCatalog(
        workspaceRuntimeService: workspaceRuntimeService,
        mcpRuntimeManager: fakeMcpManager,
        permissionManager: PermissionManager(
          policyStore: WorkspacePolicyStore(
            settingsStore: SanadSettingsStore(homeDirectoryPath: tempDir.path),
          ),
          platformRuntimeBridge: fakePlatformBridge,
          checkpointStore: NoopCheckpointStore(),
        ),
        platformRuntimeBridge: fakePlatformBridge,
      );
    });

    tearDown(() async {
      await tempDir.delete(recursive: true);
    });

    test(
      'builds workspace, web, discovery, and MCP tools for a turn',
      () async {
        final tools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'thread-1',
            message: 'Inspect the workspace',
            workspaceId: workspaceDir.path,
          ),
        );
        registry.registerTools(tools);

        // tool_search is temporarily disabled — see local_runtime_catalog.dart.
        expect(registry.getSpec('tool_search'), isNull);
        expect(registry.getSpec('file_read')?.workspaceRequired, isTrue);
        expect(registry.getSpec('web_search')?.category, equals('web'));
        final grepProperties =
            registry.getSpec('search_grep')!.inputSchema['properties']
                as Map<String, dynamic>;
        final readProperties =
            registry.getSpec('file_read')!.inputSchema['properties']
                as Map<String, dynamic>;
        final webProperties =
            registry.getSpec('web_search')!.inputSchema['properties']
                as Map<String, dynamic>;
        expect(grepProperties['head_limit']['maximum'], 100);
        expect(grepProperties['context']['maximum'], 20);
        expect(readProperties['limit']['maximum'], 2000);
        expect(webProperties['limit']['maximum'], 10);
        expect(
          registry.getSpec('mcp__filesystem__read_file')?.serverName,
          equals('filesystem'),
        );
      },
    );

    test(
      'builds and executes platform-provided tools through the bridge',
      () async {
        final tools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'thread-platform',
            message: 'Use the system screenshot tool',
            workspaceId: workspaceDir.path,
            metadata: {
              'platform_tools': [
                {
                  'name': 'system_screenshot',
                  'display_name': 'Screenshot',
                  'description': 'Capture the current screen.',
                  'category': 'system',
                  'input_schema': {
                    'type': 'object',
                    'properties': {
                      'monitor_number': {'type': 'integer'},
                    },
                  },
                  'approval': {
                    'mode': 'default',
                    'sensitive': true,
                    'scope': 'session',
                    'permission_class': 'screen_capture',
                  },
                  'availability': {'status': 'available'},
                },
              ],
            },
          ),
        );
        registry.registerTools(tools);

        final result = await registry.getTool('system_screenshot')!.execute({
          'monitor_number': 1,
        });

        expect(
          fakePlatformBridge.lastPermissionPayload?['tool_name'],
          equals('system_screenshot'),
        );
        expect(
          fakePlatformBridge.lastExecutionPayload?['tool_name'],
          equals('system_screenshot'),
        );
        expect(result, contains('system_screenshot'));
      },
    );

    test('executes workspace and MCP-backed tools locally', () async {
      final tools = await catalog.buildTools(
        registry: registry,
        request: AgentTurnRequest(
          sessionId: 'thread-2',
          message: 'Write then read',
          workspaceId: workspaceDir.path,
        ),
      );
      registry.registerTools(tools);

      final writeResult = await registry.getTool('file_write')!.execute({
        'path': 'notes.txt',
        'content': 'hello from runtime',
      });
      expect(writeResult, contains('"type": "create"'));

      final readResult = await registry.getTool('file_read')!.execute({
        'path': 'notes.txt',
      });
      expect(readResult, contains('hello from runtime'));

      final mcpResult = await registry
          .getTool('mcp__filesystem__read_file')!
          .execute({'path': 'notes.txt'});
      expect(mcpResult, contains('mcp__filesystem__read_file'));
      expect(fakeMcpManager.lastArguments?['path'], equals('notes.txt'));
    });

    test('tool search is temporarily disabled and not registered', () async {
      final tools = await catalog.buildTools(
        registry: registry,
        request: AgentTurnRequest(
          sessionId: 'thread-3',
          message: 'Search for tools',
          workspaceId: workspaceDir.path,
        ),
      );
      registry.registerTools(tools);

      // tool_search is temporarily disabled — see local_runtime_catalog.dart.
      expect(registry.getSpec('tool_search'), isNull);
      expect(registry.getTool('tool_search'), isNull);
    });

    test(
      'loads skills from the local runtime and exposes them to slash search',
      () async {
        final tools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'thread-4',
            message: 'Load the review skill',
            workspaceId: workspaceDir.path,
          ),
        );
        registry.registerTools(tools);

        final skillSpec = registry.getSpec('skill_load')!;
        final properties = Map<String, dynamic>.from(
          skillSpec.inputSchema['properties'] as Map,
        );
        expect(properties.keys, equals(['skill']));

        final payload = await registry.getTool('skill_load')!.execute({
          'skill': 'review',
        });

        expect(payload, startsWith('Skill source: '));
        expect(
          payload,
          contains('/workspace/.sanad/skills/review/SKILL.md\n\n'),
        );
        expect(payload, contains('Use the review skill.'));
        expect(payload, isNot(contains('"origin"')));
        expect(payload, isNot(contains('"metadata"')));

        final slashCommands = await workspaceRuntimeService.searchSlashCommands(
          query: 'review',
          workspaceId: workspaceDir.path,
        );
        expect(
          slashCommands.any((entry) => entry['command'] == 'review'),
          isTrue,
        );
      },
    );

    test(
      'builds runtime context from workspace instructions, skills, and tools',
      () async {
        final tools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'thread-5',
            message: 'Inspect runtime context',
            workspaceId: workspaceDir.path,
          ),
        );
        registry.registerTools(tools);

        final context = await RuntimeContextBuilder().build(
          workspacePath: workspaceDir.path,
          workspaceName: 'workspace',
          registry: registry,
        );

        expect(context, isNotNull);
        expect(
          context,
          contains('Workspace instruction contracts (hierarchy:'),
        );
        expect(context, contains('Workspace instructions from AGENTS.'));
        expect(context, contains('Available skills:'));
        expect(context, contains('name: review'));
        expect(context, contains('[Local Project Contract] AGENTS.md'));
        expect(context, isNot(contains('Available runtime tools:')));
        expect(context, isNot(contains('web_search')));
      },
    );

    test(
      'prioritizes the closest AGENTS contracts and uses head-tail truncation',
      () async {
        File('${tempDir.path}/AGENTS.md').writeAsStringSync(
          'PARENT_START\n${List.filled(25000, 'P').join()}\nPARENT_END',
        );
        File('${workspaceDir.path}/AGENTS.md').writeAsStringSync(
          'LOCAL_START\n${List.filled(25000, 'L').join()}\nLOCAL_END',
        );

        final context = await RuntimeContextBuilder().build(
          workspacePath: workspaceDir.path,
          workspaceName: 'workspace',
          registry: registry,
        );

        expect(context, isNotNull);
        final localPos = context!.indexOf('[Local Project Contract] AGENTS.md');
        final parentPos = context.indexOf('[Parent Contract]');
        expect(localPos, isNot(-1));
        expect(parentPos, isNot(-1));
        expect(localPos, lessThan(parentPos));
        expect(context, contains('LOCAL_START'));
        expect(context, contains('LOCAL_END'));
        expect(context, contains('PARENT_START'));
        expect(context, contains('PARENT_END'));
        expect(context, contains('[...truncated AGENTS.md: kept'));
      },
    );
  });
}
