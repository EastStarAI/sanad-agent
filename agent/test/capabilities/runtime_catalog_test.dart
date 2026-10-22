import 'dart:convert';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/tools/system/host_capability_discovery_tool.dart';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:image/image.dart' as img;
import 'package:path/path.dart' as p;
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:test/test.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_runtime_manager.dart';
import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/provider_runtime/route_capability_resolver.dart';
import 'package:sanad_agent/evolution/models/suspended_checkpoint.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import '../support/memory_workspace_policy_store.dart';
import '../support/isolated_sanad_test_home.dart';

class FakeMcpRuntimeManager extends McpRuntimeManager {
  FakeMcpRuntimeManager()
    : super();

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

class _FakeSessionManager implements SessionManager {
  final Map<String, Map<String, dynamic>> sessionMetas = {};

  @override
  Map<String, dynamic>? getSessionMetadata(String sessionId) =>
      sessionMetas[sessionId];

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  useIsolatedSanadStateRoot();
  group('LocalRuntimeCatalog', () {
    late Directory tempDir;
    late Directory workspaceDir;
    late LocalWorkspaceRuntimeService workspaceRuntimeService;
    late ToolsRegistry registry;
    late FakeMcpRuntimeManager fakeMcpManager;
    late FakePlatformRuntimeBridge fakePlatformBridge;
    late MemoryWorkspacePolicyStore policyStore;
    late NoopCheckpointStore checkpointStore;
    late List<String> admittedAttachmentPaths;
    late LocalRuntimeCatalog catalog;
    late _FakeSessionManager fakeSessionManager;

    setUp(() async {
      fakeSessionManager = _FakeSessionManager();
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
      GetIt.instance.registerSingleton<SessionManager>(fakeSessionManager);
      final rawTemp = await Directory.systemTemp.createTemp(
        'runtime-catalog-test',
      );
      tempDir = Directory(rawTemp.resolveSymbolicLinksSync());
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
      policyStore = MemoryWorkspacePolicyStore();
      checkpointStore = NoopCheckpointStore();
      admittedAttachmentPaths = [];
      catalog = LocalRuntimeCatalog(
        workspaceRuntimeService: workspaceRuntimeService,
        mcpRuntimeManager: fakeMcpManager,
        permissionManager: PermissionManager(
          policyStore: policyStore,
          platformRuntimeBridge: fakePlatformBridge,
          checkpointStore: checkpointStore,
        ),
        platformRuntimeBridge: fakePlatformBridge,
        admittedAttachmentPathsResolver: (sessionId) async =>
            admittedAttachmentPaths,
        workspacePolicyStore: policyStore,
      );
    });

    group('project env files', () {
      const secret = 'sk-test-project-value-000000000000';

      Future<ToolsRegistry> registryWithEnv() async {
        File('${workspaceDir.path}/.env').writeAsStringSync(
          '# local settings\nAPI_TOKEN=$secret\nexport DB_URL="postgres://u:$secret@db"\n'
          'MULTI="line one\n$secret"\n',
        );
        File('${workspaceDir.path}/.env.example').writeAsStringSync(
          'API_TOKEN=replace-me\n',
        );
        final tools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'thread-env',
            message: 'read env',
            workspaceId: workspaceDir.path,
          ),
        );
        registry.registerTools(tools);
        return registry;
      }

      test('file_read keeps names and comments but never values', () async {
        final tools = await registryWithEnv();
        final read = await tools.getTool('file_read')!.execute({
          'path': '.env',
        });
        expect(read, isNot(contains(secret)));
        expect(read, contains('API_TOKEN=<redacted>'));
        expect(read, contains('export DB_URL=<redacted>'));
        expect(read, contains('# local settings'));

        final template = await tools.getTool('file_read')!.execute({
          'path': '.env.example',
        });
        expect(template, contains('replace-me'));
      });

      test('search_grep cannot find or reveal a value', () async {
        final tools = await registryWithEnv();
        final byValue = await tools.getTool('search_grep')!.execute({
          'pattern': secret,
        });
        expect(byValue, isNot(contains(secret)));
        expect(byValue, isNot(contains('.env:')));
        final byName = await tools.getTool('search_grep')!.execute({
          'pattern': 'API_TOKEN',
        });
        expect(byName, contains('API_TOKEN=<redacted>'));
        expect(byName, isNot(contains(secret)));
      });
    });

    group('secret tools presence', () {
      Future<Set<String>> names(String authority) async => (await catalog
              .buildTools(
                registry: ToolsRegistry(),
                request: AgentTurnRequest(
                  sessionId: 'thread-secrets',
                  message: 'connect',
                  metadata: {CommandAuthority.payloadKey: authority},
                ),
              ))
          .map((tool) => tool.schema.name)
          .toSet();

      const secretTools = {
        'system_request_secret',
        'system_list_secrets',
        'system_delete_secret',
      };

      test('are offered on an owner turn', () async {
        expect(await names('owner'), containsAll(secretTools));
      });

      test('are absent on an unverified turn', () async {
        final present = await names('unverified');
        expect(present.intersection(secretTools), isEmpty);
        expect(present, contains('system_ask_user'));
      });
    });

    group('host capability discovery presence', () {
      Future<Set<String>> toolNames(String authority) async {
        final tools = await catalog.buildTools(
          registry: ToolsRegistry(),
          request: AgentTurnRequest(
            sessionId: 'thread-discovery',
            message: 'which tools exist',
            workspaceId: workspaceDir.path,
            metadata: {CommandAuthority.payloadKey: authority},
          ),
        );
        return tools.map((tool) => tool.schema.name).toSet();
      }

      const discovery = HostCapabilityDiscoveryTool.toolName;

      test('is redundant beside a Direct host shell', () async {
        final names = await toolNames('owner');
        expect(names, contains('shell_execute'));
        expect(names, isNot(contains(discovery)));
      });

      test('appears for a local owner in Protected execution', () async {
        await policyStore.seed(
          workspaceDir.path,
          const WorkspacePolicy(executionMode: ExecutionMode.protected),
        );
        expect(await toolNames('owner'), contains(discovery));
      });

      test('is absent for an unverified caller even in Protected', () async {
        await policyStore.seed(
          workspaceDir.path,
          const WorkspacePolicy(executionMode: ExecutionMode.protected),
        );
        expect(await toolNames('unverified'), isNot(contains(discovery)));
        expect(await toolNames('OWNER'), isNot(contains(discovery)));
      });

      test('is absent when the owner disabled it, even with Full Access', () async {
        await policyStore.seed(
          workspaceDir.path,
          const WorkspacePolicy(
            executionMode: ExecutionMode.protected,
            permissionMode: WorkspacePermissionMode.fullAccess,
            hostDiscoveryPolicy: HostDiscoveryPolicy.disabled,
          ),
        );
        expect(await toolNames('owner'), isNot(contains(discovery)));
      });

      test('follows a policy change on the next turn of the same session', () async {
        await policyStore.seed(
          workspaceDir.path,
          const WorkspacePolicy(executionMode: ExecutionMode.protected),
        );
        expect(await toolNames('owner'), contains(discovery));
        await policyStore.seed(workspaceDir.path, const WorkspacePolicy());
        expect(await toolNames('owner'), isNot(contains(discovery)));
      });
    });

    tearDown(() async {
      if (GetIt.instance.isRegistered<SessionManager>()) {
        GetIt.instance.unregister<SessionManager>();
      }
      try {
        await tempDir.delete(recursive: true);
      } catch (_) {}
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
        final viewImageSpec = registry.getSpec('view_image')!;
        expect(viewImageSpec.workspaceRequired, isTrue);
        expect(registry.getTool('view_image')!.restartReplaySafe, isTrue);
        expect(viewImageSpec.inputSchema, {
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
        });
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

    test('scopes view_image to workspace or admitted attachments', () async {
      final noScopeTools = await catalog.buildTools(
        registry: registry,
        request: const AgentTurnRequest(
          sessionId: 'thread-no-image-scope',
          message: 'No file scope',
        ),
      );
      registry.registerTools(noScopeTools);
      expect(registry.getTool('view_image'), isNull);

      final attachment = File('${tempDir.path}/attachment.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 3, height: 2)));
      admittedAttachmentPaths = [attachment.path];
      final attachmentRegistry = ToolsRegistry();
      final attachmentTools = await catalog.buildTools(
        registry: attachmentRegistry,
        request: AgentTurnRequest(
          sessionId: 'thread-attachment-image-scope',
          message: 'Inspect attachment',
        ),
      );
      attachmentRegistry.registerTools(attachmentTools);

      final tool = attachmentRegistry.getTool('view_image')!;
      final spec = attachmentRegistry.getSpec('view_image')!;
      expect(spec.workspaceRequired, isFalse);
      expect(spec.source['type'], 'builtin_attachment');
      expect(tool.restartReplaySafe, isTrue);
      final result = await tool.executeResult(
        {'path': attachment.path},
        context: ToolContext(
          sessionId: 'thread-attachment-image-scope',
          imageSupport: RouteImageSupport.supported,
        ),
      );
      expect(result.isError, isFalse);
      expect(result.blocks.length, 2);
      expect(fakePlatformBridge.permissionRequestCount, 0);
    });

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
      expect(fakePlatformBridge.permissionRequestCount, equals(1));
      expect(
        fakePlatformBridge.lastPermissionPayload?['tool_name'],
        equals('mcp__filesystem__read_file'),
      );
      expect(fakePlatformBridge.lastPermissionPayload?['tool_input'], {
        'path': 'notes.txt',
      });
      expect(
        fakePlatformBridge.lastPermissionPayload?['tool'],
        containsPair('server_name', 'filesystem'),
      );
    });

    test(
      'resolves executionRoot for tools and MCP without a workspace',
      () async {
        final execRootDir = Directory('${tempDir.path}/independent-exec-root')
          ..createSync(recursive: true);

        final tools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'thread-exec-root',
            message: 'Write to independent worktree',
            metadata: {'execution_root': execRootDir.path},
          ),
        );
        registry.registerTools(tools);

        final writeResult = await registry.getTool('file_write')!.execute({
          'path': 'sub_task.txt',
          'content': 'written to independent exec root',
        });
        expect(writeResult, contains('"type": "create"'));

        expect(File('${execRootDir.path}/sub_task.txt').existsSync(), isTrue);
        expect(File('${workspaceDir.path}/sub_task.txt').existsSync(), isFalse);
      },
    );

    test('MCP denial prevents execution', () async {
      fakePlatformBridge.nextDecision = const {
        'allowed': false,
        'scope': 'once',
      };
      final tools = await catalog.buildTools(
        registry: registry,
        request: AgentTurnRequest(
          sessionId: 'thread-mcp-denied',
          message: 'Read through MCP',
          workspaceId: workspaceDir.path,
        ),
      );
      registry.registerTools(tools);

      await expectLater(
        registry.getTool('mcp__filesystem__read_file')!.execute({
          'path': 'notes.txt',
        }),
        throwsA(isA<Exception>()),
      );

      expect(fakePlatformBridge.permissionRequestCount, equals(1));
      expect(fakeMcpManager.lastToolName, isNull);
      expect(fakeMcpManager.lastArguments, isNull);
    });

    test(
      'MCP session approval suppresses repeated prompts for exact input',
      () async {
        fakePlatformBridge.nextDecision = const {
          'allowed': true,
          'scope': 'session',
        };
        final tools = await catalog.buildTools(
          registry: registry,
          request: AgentTurnRequest(
            sessionId: 'thread-mcp-session',
            message: 'Read through MCP twice',
            workspaceId: workspaceDir.path,
          ),
        );
        registry.registerTools(tools);
        final tool = registry.getTool('mcp__filesystem__read_file')!;

        await tool.execute({'path': 'notes.txt'});
        await tool.execute({'path': 'notes.txt'});

        expect(fakePlatformBridge.permissionRequestCount, equals(1));
        expect(fakeMcpManager.lastArguments?['path'], equals('notes.txt'));
      },
    );

    test('MCP workspace approval persists through workspace policy', () async {
      fakePlatformBridge.nextDecision = const {
        'allowed': true,
        'scope': 'workspace',
      };
      final request = AgentTurnRequest(
        sessionId: 'thread-mcp-workspace',
        message: 'Read through MCP',
        workspaceId: workspaceDir.path,
      );
      var tools = await catalog.buildTools(
        registry: registry,
        request: request,
      );
      registry.registerTools(tools);
      await registry.getTool('mcp__filesystem__read_file')!.execute({
        'path': 'notes.txt',
      });
      expect(fakePlatformBridge.permissionRequestCount, equals(1));

      final nextRegistry = ToolsRegistry();
      tools = await catalog.buildTools(
        registry: nextRegistry,
        request: AgentTurnRequest(
          sessionId: 'thread-mcp-workspace-next',
          message: 'Read through MCP from another session',
          workspaceId: workspaceDir.path,
        ),
      );
      nextRegistry.registerTools(tools);
      await nextRegistry.getTool('mcp__filesystem__read_file')!.execute({
        'path': 'notes.txt',
      });

      expect(fakePlatformBridge.permissionRequestCount, equals(1));
    });

    test(
      'asks before each external workspace file capability and exposes only path details',
      () async {
        final externalDir = Directory(p.join(tempDir.path, 'external'))
          ..createSync(recursive: true);
        final externalFile = File(p.join(externalDir.path, 'notes.txt'))
          ..writeAsStringSync('external hello');
        final externalImage = File('${externalDir.path}/image.png')
          ..writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 2)));
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
        expect(
          jsonDecode(readResult)['file']['filePath'],
          equals(externalFile.path),
        );

        final imageResult = await registry.getTool('view_image')!.executeResult(
          {'path': externalImage.path},
          context: ToolContext(
            sessionId: 'thread-external',
            imageSupport: RouteImageSupport.supported,
          ),
        );
        expect(imageResult.isError, isFalse);
        expect(imageResult.blocks.length, 2);
        expect(
          fakePlatformBridge.lastPermissionPayload?['tool_name'],
          'view_image',
        );
        expect(
          fakePlatformBridge.lastPermissionPayload?['approval_key'],
          'external_workspace_path::view_image::${externalImage.resolveSymbolicLinksSync()}',
        );

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
        expect(
          globResult.replaceAll(r'\', '/'),
          contains(externalFile.path.replaceAll(r'\', '/')),
        );

        final grepResult = await registry.getTool('search_grep')!.execute({
          'pattern': 'updated',
          'path': externalDir.path,
        });
        expect(
          grepResult.replaceAll(r'\', '/'),
          contains(externalFile.path.replaceAll(r'\', '/')),
        );

        final createdFile = p.join(externalDir.path, 'created.txt');
        await registry.getTool('file_write')!.execute({
          'path': createdFile,
          'content': 'private content',
        });

        expect(fakePlatformBridge.permissionRequestCount, equals(6));
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

    test('builds workspace tools when workspaceId has exec_root: prefix', () async {
      final tools = await catalog.buildTools(
        registry: registry,
        request: AgentTurnRequest(
          sessionId: 'thread-exec-root',
          message: 'Work in execution root',
          workspaceId: 'exec_root:${workspaceDir.path}',
        ),
      );
      final names = tools.map((t) => t.schema.name).toList();
      expect(names, contains('shell_execute'));
      expect(names, contains('file_read'));
      expect(names, contains('file_edit'));
    });

    test('explicit workspaceId on request takes precedence over stale session execution_root', () async {
      final otherDir = Directory(p.join(tempDir.path, 'other-exec-root'))
        ..createSync(recursive: true);
      fakeSessionManager.sessionMetas['session-stale-root'] = {
        'execution_root': otherDir.path,
      };

      final tools = await catalog.buildTools(
        registry: registry,
        request: AgentTurnRequest(
          sessionId: 'session-stale-root',
          message: 'Work in explicit workspace',
          workspaceId: workspaceDir.path,
        ),
      );
      final names = tools.map((t) => t.schema.name).toList();
      expect(names, contains('shell_execute'));
      expect(names, contains('file_read'));
      expect(names, contains('file_edit'));
    });

    test('full_access executes an external path without prompting', () async {
      final externalFile = File(p.join(tempDir.path, 'full-access.txt'))
        ..writeAsStringSync('allowed');
      final externalImage = File('${tempDir.path}/full-access.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 2, height: 1)));
      await policyStore.seed(
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
      final imageResult = await registry.getTool('view_image')!.executeResult(
        {'path': externalImage.path},
        context: ToolContext(
          sessionId: 'thread-full-access',
          imageSupport: RouteImageSupport.supported,
        ),
      );
      expect(imageResult.isError, isFalse);
      expect(fakePlatformBridge.permissionRequestCount, equals(0));
    });

    test('denial prevents an external write', () async {
      fakePlatformBridge.nextDecision = const {
        'allowed': false,
        'scope': 'once',
      };
      final externalPath = p.join(tempDir.path, 'denied.txt');
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

      final deniedImage = File('${tempDir.path}/denied.png')
        ..writeAsBytesSync(img.encodePng(img.Image(width: 1, height: 1)));
      final imageResult = await registry.getTool('view_image')!.executeResult(
        {'path': deniedImage.path},
        context: ToolContext(
          sessionId: 'thread-denied',
          imageSupport: RouteImageSupport.supported,
        ),
      );
      expect(imageResult.isError, isTrue);
      expect(imageResult.errorCode?.name, 'permissionDenied');
      expect(fakePlatformBridge.permissionRequestCount, equals(2));
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
          payload.replaceAll(r'\', '/'),
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

    test('builds concise guidance when no workspace is attached', () {
      final context = const RuntimeContextBuilder().buildWithoutWorkspace();

      expect(
        context,
        equals(
          'No workspace is attached, so file and terminal tools are unavailable. If the user requests them, ask them to select an existing workspace or create one from the workspace control in the upper-left corner.',
        ),
      );
    });

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
