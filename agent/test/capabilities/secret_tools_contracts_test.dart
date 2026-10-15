import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/core/auth/agent_secret_namespaces.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:test/test.dart';

import '../support/memory_agent_secret_store.dart';

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

class _FakePlatformRuntimeBridge extends PlatformRuntimeBridge {
  Map<String, dynamic>? nextDecision;
  Map<String, dynamic>? lastPayload;

  @override
  Future<Map<String, dynamic>> requestToolPermission({
    required String sessionId,
    required Map<String, dynamic> payload,
    Duration timeout = const Duration(hours: 24),
  }) async {
    lastPayload = payload;
    return nextDecision ?? {'approved': true, 'values': {}};
  }
}

void main() {
  group('Task 84a: Secret Tool Contracts and Zero-Leak Envelopes', () {
    late _FakeWorkspaceRuntimeService wsService;
    late _FakePlatformRuntimeBridge bridge;
    late MemoryAgentSecretStore secretStore;
    late LocalRuntimeCatalog catalog;

    setUp(() async {
      await SanadHomeBootstrap.prepareAll();
      wsService = _FakeWorkspaceRuntimeService();
      bridge = _FakePlatformRuntimeBridge();
      secretStore = MemoryAgentSecretStore();

      catalog = LocalRuntimeCatalog(
        workspaceRuntimeService: wsService,
        platformRuntimeBridge: bridge,
        secretStore: secretStore,
      );
    });

    test('AC-84a.1 & AC-84a.2: registers system_request_secret and system_list_secrets in catalog', () async {
      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: AgentTurnRequest(
          sessionId: 's-1',
          workspaceId: 'ws-1',
          message: 'hi',
        ),
      );

      final requestSecretTool =
          tools.where((t) => t.schema.name == 'system_request_secret').firstOrNull;
      expect(requestSecretTool, isNotNull);
      expect((requestSecretTool as CallbackTool).toolSpec.category, equals('system'));
      expect(requestSecretTool.schema.parameters['required'], contains('fields'));
      expect(requestSecretTool.schema.parameters['required'], contains('reason'));

      final listSecretsTool =
          tools.where((t) => t.schema.name == 'system_list_secrets').firstOrNull;
      expect(listSecretsTool, isNotNull);
      expect((listSecretsTool as CallbackTool).toolSpec.category, equals('system'));
    });

    test('AC-84a.3 & AC-84a.4: user submission saves secrets directly to vault and returns zero-leak envelope', () async {
      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: AgentTurnRequest(
          sessionId: 's-1',
          workspaceId: 'ws-1',
          message: 'hi',
        ),
      );

      final requestSecretTool =
          tools.firstWhere((t) => t.schema.name == 'system_request_secret');

      bridge.nextDecision = {
        'approved': true,
        'values': {
          'api_key': 'super-secret-user-api-key-xyz',
          'db_pass': 'my-ultra-secret-password-123',
        },
      };

      final responseStr = await requestSecretTool.execute({
        'fields': [
          {'id': 'api_key', 'label': 'API Key', 'is_secret': true},
          {'id': 'db_pass', 'label': 'Database Password', 'is_secret': true},
        ],
        'reason': 'Database migration setup',
        'target_vault': 'custom:my_db',
      });

      // 1. Verify response is a clean non-leaking JSON envelope
      final response = jsonDecode(responseStr) as Map<String, dynamic>;
      expect(response['status'], equals('stored'));
      expect(response['skipped'], isFalse);
      expect(response['target_vault'], equals('custom:my_db'));
      expect(response['keys_stored'], containsAll(['api_key', 'db_pass']));

      // 2. ABSOLUTE ZERO-LEAK ASSERTION: The response string MUST NOT contain the plaintext values!
      expect(responseStr, isNot(contains('super-secret-user-api-key-xyz')));
      expect(responseStr, isNot(contains('my-ultra-secret-password-123')));

      // 3. Verify secrets are securely stored in the private AgentSecretStore
      final storedApiKey = await secretStore.read('custom:my_db:api_key');
      expect(storedApiKey, equals('super-secret-user-api-key-xyz'));

      final storedPass = await secretStore.read('custom:my_db:db_pass');
      expect(storedPass, equals('my-ultra-secret-password-123'));

      // 4. Verify index tracking key was populated
      final rawIndex = await secretStore.read(AgentSecretNamespaces.customIndexKey);
      expect(rawIndex, isNotNull);
      final indexList = jsonDecode(rawIndex!) as List;
      expect(indexList, contains('custom:my_db:api_key'));
      expect(indexList, contains('custom:my_db:db_pass'));
    });

    test('AC-84a.5: user skip returns skipped envelope without throwing or storing', () async {
      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: AgentTurnRequest(
          sessionId: 's-1',
          workspaceId: 'ws-1',
          message: 'hi',
        ),
      );

      final requestSecretTool =
          tools.firstWhere((t) => t.schema.name == 'system_request_secret');

      bridge.nextDecision = {
        'approved': false,
        'skipped': true,
        'reason': 'User opted to configure manually',
      };

      final responseStr = await requestSecretTool.execute({
        'fields': [
          {'id': 'token', 'label': 'Access Token'},
        ],
        'reason': 'Optional cloud sync',
      });

      final response = jsonDecode(responseStr) as Map<String, dynamic>;
      expect(response['status'], equals('skipped'));
      expect(response['skipped'], isTrue);
      expect(response['reason'], equals('User opted to configure manually'));
      expect(secretStore.values, isEmpty);
    });

    test('AC-84a.6: system_list_secrets returns metadata and presence without exposing raw secrets', () async {
      // Pre-seed vault with custom secrets and index
      await secretStore.write('custom:stripe:key', 'sk-live-mock-hidden-123');
      await secretStore.write('custom:stripe:webhook', 'whsec-hidden-xyz');
      await secretStore.write(
        AgentSecretNamespaces.customIndexKey,
        jsonEncode(['custom:stripe:key', 'custom:stripe:webhook']),
      );

      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: AgentTurnRequest(
          sessionId: 's-1',
          workspaceId: 'ws-1',
          message: 'hi',
        ),
      );

      final listSecretsTool =
          tools.firstWhere((t) => t.schema.name == 'system_list_secrets');

      final responseStr = await listSecretsTool.execute({
        'namespace_filter': 'custom',
      });

      final response = jsonDecode(responseStr) as Map<String, dynamic>;
      expect(response['status'], equals('success'));
      expect(response['count'], equals(2));

      final secrets = response['secrets'] as List;
      expect(secrets.length, equals(2));

      final keys = secrets.map((s) => s['key']).toList();
      expect(keys, containsAll(['custom:stripe:key', 'custom:stripe:webhook']));
      expect(secrets.every((s) => s['source'] == 'vault'), isTrue);

      // ZERO-LEAK ASSERTION: The response MUST NOT contain the secret plaintext
      expect(responseStr, isNot(contains('sk-live-mock-hidden-123')));
      expect(responseStr, isNot(contains('whsec-hidden-xyz')));
    });
  });
}
