import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/mcp/sanad_settings_store.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
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
  Map<String, dynamic> nextDecision = const {
    'allowed': true,
    'scope': 'session',
  };
  int permissionRequestCount = 0;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(seconds: 60),
  }) async {
    permissionRequestCount++;
    lastPermissionPayload = payload;
    return nextDecision;
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
  SuspendedCheckpoint? lastSaved;

  @override
  Future<void> save(SuspendedCheckpoint checkpoint) async {
    lastSaved = checkpoint;
  }

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
    late WorkspacePolicyStore policyStore;
    late NoopCheckpointStore checkpointStore;
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
      policyStore = WorkspacePolicyStore(
        settingsStore: SanadSettingsStore(homeDirectoryPath: tempDir.path),
      );
      checkpointStore = NoopCheckpointStore();
      catalog = LocalRuntimeCatalog(
        workspaceRuntimeService: workspaceRuntimeService,
        mcpRuntimeManager: fakeMcpManager,
        permissionManager: PermissionManager(
          policyStore: policyStore,
          platformRuntimeBridge: fakePlatformBridge,
          checkpointStore: checkpointStore,
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
      expect(fakePlatformBridge.permissionRequestCount, equals(0));
    });

    test(
      'asks before each external workspace file capability and exposes only path details',
      () async {
        final externalDir = Directory('${tempDir.path}/external')
          ..createSync(recursive: true);
        final externalFile = File('${externalDir.path}/notes.txt')
          ..writeAsStringSync('external hello');
        final tools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'thread-external',
            message: 'Inspect an external path',
            workspaceId: workspaceDir.path,
          ),
        );
        registry.registerTools(tools);

        final readResult = await registry.getTool('file_read')!.execute({
          'path': externalFile.path,
        });
        expect(readResult, contains(externalFile.path));

        await registry.getTool('file_edit')!.execute({
          'path': externalFile.path,
          'old_string': 'hello',
          'new_string': 'updated',
        });
        expect(externalFile.readAsStringSync(), equals('external updated'));

        final globResult = await registry.getTool('search_glob')!.execute({
          'pattern': '**/*.txt',
          'path': externalDir.path,
        });
        expect(globResult, contains(externalFile.path));

        final grepResult = await registry.getTool('search_grep')!.execute({
          'pattern': 'updated',
          'path': externalDir.path,
        });
        expect(grepResult, contains(externalFile.path));

        final createdFile = '${externalDir.path}/created.txt';
        await registry.getTool('file_write')!.execute({
          'path': createdFile,
          'content': 'private content',
        });

        expect(fakePlatformBridge.permissionRequestCount, equals(5));
        expect(fakePlatformBridge.lastPermissionPayload?['tool_input'], {
          'action': 'file_write',
          'path': File(createdFile).resolveSymbolicLinksSync(),
        });
        expect(
          fakePlatformBridge.lastPermissionPayload.toString(),
          isNot(contains('private content')),
        );
        expect(
          checkpointStore.lastSaved?.toolArguments['content'],
          equals('private content'),
        );
        expect(File(createdFile).readAsStringSync(), equals('private content'));
      },
    );

    test('full_access executes an external path without prompting', () async {
      final externalFile = File('${tempDir.path}/full-access.txt')
        ..writeAsStringSync('allowed');
      await policyStore.savePolicy(
        workspaceDir.path,
        const WorkspacePolicy(
          permissionMode: WorkspacePermissionMode.fullAccess,
        ),
      );
      final tools = await catalog.buildTools(
        registry: registry,
        request: AgentTurnRequest(
          sessionId: 'thread-full-access',
          message: 'Read an external path',
          workspaceId: workspaceDir.path,
        ),
      );
      registry.registerTools(tools);

      final result = await registry.getTool('file_read')!.execute({
        'path': externalFile.path,
      });

      expect(result, contains('allowed'));
      expect(fakePlatformBridge.permissionRequestCount, equals(0));
    });

    test('denial prevents an external write', () async {
      fakePlatformBridge.nextDecision = const {
        'allowed': false,
        'scope': 'once',
      };
      final externalPath = '${tempDir.path}/denied.txt';
      final tools = await catalog.buildTools(
        registry: registry,
        request: AgentTurnRequest(
          sessionId: 'thread-denied',
          message: 'Write an external path',
          workspaceId: workspaceDir.path,
        ),
      );
      registry.registerTools(tools);

      await expectLater(
        registry.getTool('file_write')!.execute({
          'path': externalPath,
          'content': 'must not be written',
        }),
        throwsA(isA<Exception>()),
      );

      expect(File(externalPath).existsSync(), isFalse);
      expect(fakePlatformBridge.permissionRequestCount, equals(1));
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
