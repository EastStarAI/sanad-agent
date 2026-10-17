import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/tools/system/host_capability_discovery_tool.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:test/test.dart';

class _FakeWorkspaceRuntimeService implements LocalWorkspaceRuntimeService {
  @override
  Future<Map<String, dynamic>?> describeWorkspace(String workspaceId) async {
    return {
      'id': workspaceId,
      'path': Directory.systemTemp.path,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('HostCapabilityDiscoveryTool (Task 83f)', () {
    late Directory tempDir;
    late HostCapabilityDiscoveryTool tool;

    setUp(() async {
      tempDir = await Directory.systemTemp.createTemp('sanad_host_discovery_test_');
      final fakeExe = File('${tempDir.path}/custom_tool');
      await fakeExe.writeAsString('#!/bin/sh\necho hi');

      tool = HostCapabilityDiscoveryTool(
        environment: {'PATH': tempDir.path},
      );
    });

    tearDown(() async {
      if (tempDir.existsSync()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('finds existing executable and returns canonical path', () async {
      final responseJson = await tool.execute({'executable_name': 'custom_tool'});
      final result = jsonDecode(responseJson) as Map<String, dynamic>;

      expect(result['name'], 'custom_tool');
      expect(result['found'], isTrue);
      expect(result['canonical_path'], contains('custom_tool'));
    });

    test('returns found: false for nonexistent binary', () async {
      final responseJson = await tool.execute({'executable_name': 'unknown_binary_xyz'});
      final result = jsonDecode(responseJson) as Map<String, dynamic>;

      expect(result['name'], 'unknown_binary_xyz');
      expect(result['found'], isFalse);
    });

    test('rejects path separators and directory traversal attacks', () async {
      for (final malicious in ['../etc/passwd', '/bin/sh', 'subdir/tool', 'tool\x00extra']) {
        final responseJson = await tool.execute({'executable_name': malicious});
        final result = jsonDecode(responseJson) as Map<String, dynamic>;

        expect(result['isError'], isTrue, reason: 'Must reject traversal: $malicious');
        expect(result['error'], contains('Invalid executable name'));
      }
    });

    test('common_tools: true queries bounded developer tool list', () async {
      final responseJson = await tool.execute({'common_tools': true});
      final result = jsonDecode(responseJson) as Map<String, dynamic>;

      expect(result.containsKey('tools'), isTrue);
      final tools = result['tools'] as List;
      expect(tools.length, equals(HostCapabilityDiscoveryTool.standardCommonTools.length));
    });
  });

  group('Catalog Redundancy & Omission Policy (Gate F2)', () {
    late _FakeWorkspaceRuntimeService wsService;
    late LocalRuntimeCatalog catalog;
    late Directory tempWsDir;

    setUp(() async {
      await SanadHomeBootstrap.prepareAll();
      WorkspacePolicyStore.clearMemoryCache();
      tempWsDir = await Directory.systemTemp.createTemp('sanad_catalog_ws_test_');
      wsService = _FakeWorkspaceRuntimeService();
      catalog = LocalRuntimeCatalog(
        workspaceRuntimeService: wsService,
      );
    });

    tearDown(() async {
      if (tempWsDir.existsSync()) {
        await tempWsDir.delete(recursive: true);
      }
    });

    AgentTurnRequest createRequest() {
      return AgentTurnRequest(
        sessionId: 'test-session',
        workspaceId: 'ws-123',
        message: 'test prompt',
        metadata: {'execution_root': tempWsDir.path},
      );
    }

    test('omits host discovery tool when disabled by owner policy', () async {
      const store = WorkspacePolicyStore();
      await store.saveSecurityPolicy(
        WorkspaceSecurityPolicy(
          workspaceId: 'ws-123',
          canonicalPath: tempWsDir.path,
          hostDiscoveryPolicy: HostDiscoveryPolicy.disabled,
          executionMode: ExecutionMode.protected,
        ),
      );

      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: createRequest(),
      );

      final hasDiscovery = tools.any((t) => t.schema.name == 'host_capability_discovery');
      expect(hasDiscovery, isFalse, reason: 'Tool must be omitted when hostDiscovery=disabled');
    });

    test('omits host discovery tool in Direct Developer mode (Redundancy check)', () async {
      const store = WorkspacePolicyStore();
      await store.saveSecurityPolicy(
        WorkspaceSecurityPolicy(
          workspaceId: 'ws-123',
          canonicalPath: tempWsDir.path,
          hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
          executionMode: ExecutionMode.direct,
        ),
      );

      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: createRequest(),
      );

      final hasDiscovery = tools.any((t) => t.schema.name == 'host_capability_discovery');
      expect(hasDiscovery, isFalse, reason: 'Tool must be omitted when shell has direct host PATH access');
    });

    test('includes host discovery tool in Protected mode for owner sessions', () async {
      const store = WorkspacePolicyStore();
      await store.saveSecurityPolicy(
        WorkspaceSecurityPolicy(
          workspaceId: 'ws-123',
          canonicalPath: tempWsDir.path,
          hostDiscoveryPolicy: HostDiscoveryPolicy.ownerOnly,
          executionMode: ExecutionMode.protected,
        ),
      );

      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: createRequest(),
      );

      final hasDiscovery = tools.any((t) => t.schema.name == 'host_capability_discovery');
      expect(hasDiscovery, isTrue, reason: 'Tool must be included in protected mode when enabled');
    });

    test('Full Access cannot override disabled host discovery policy', () async {
      const store = WorkspacePolicyStore();
      await store.saveSecurityPolicy(
        WorkspaceSecurityPolicy(
          workspaceId: 'ws-123',
          canonicalPath: tempWsDir.path,
          hostDiscoveryPolicy: HostDiscoveryPolicy.disabled,
          permissionMode: WorkspacePermissionMode.fullAccess,
          executionMode: ExecutionMode.protected,
        ),
      );

      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: createRequest(),
      );

      final hasDiscovery = tools.any((t) => t.schema.name == 'host_capability_discovery');
      expect(hasDiscovery, isFalse, reason: 'Full Access cannot override host discovery prohibition');
    });
  });
}
