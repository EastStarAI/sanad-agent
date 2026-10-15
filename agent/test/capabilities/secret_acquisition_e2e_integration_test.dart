import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/execution/direct_execution_backend.dart';
import 'package:sanad_agent/capabilities/permissions/process_environment_policy.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:test/test.dart';

import '../support/memory_agent_secret_store.dart';

class _E2EWorkspaceRuntimeService implements LocalWorkspaceRuntimeService {
  final Directory tempDir;
  _E2EWorkspaceRuntimeService(this.tempDir);

  @override
  Future<Map<String, dynamic>?> describeWorkspace(String workspaceId) async {
    return {
      'id': workspaceId,
      'path': tempDir.path,
    };
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  group('Gate G4: Secret Acquisition End-to-End Integration QA & Zero-Leak Audit', () {
    late AgentStateDatabase stateDb;
    late PlatformRuntimeBridge bridge;
    late MemoryAgentSecretStore secretStore;
    late Directory workspaceDir;
    late _E2EWorkspaceRuntimeService wsService;
    late LocalRuntimeCatalog catalog;

    setUp(() async {
      await getIt.reset();
      SessionManager.resetForTesting();
      await SanadHomeBootstrap.prepareAll();

      stateDb = AgentStateDatabase.inMemory();
      getIt.registerSingleton<AgentStateDatabase>(stateDb);

      bridge = PlatformRuntimeBridge();
      secretStore = MemoryAgentSecretStore();
      workspaceDir = await Directory.systemTemp.createTemp('sanad_secret_e2e_');
      wsService = _E2EWorkspaceRuntimeService(workspaceDir);

      catalog = LocalRuntimeCatalog(
        workspaceRuntimeService: wsService,
        platformRuntimeBridge: bridge,
        secretStore: secretStore,
      );
    });

    tearDown(() async {
      SessionManager.resetForTesting();
      await getIt.reset();
      stateDb.dispose();
      if (await workspaceDir.exists()) {
        await workspaceDir.delete(recursive: true);
      }
    });

    test('E2E Flow: Acquisition -> Vault Storage -> Discovery -> Safe Process Env Injection', () async {
      // 1. Build catalog tools
      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: AgentTurnRequest(
          sessionId: 'session-e2e-1',
          workspaceId: 'ws-e2e-1',
          message: 'Setup database and run migration',
        ),
      );

      final requestSecretTool =
          tools.firstWhere((t) => t.schema.name == 'system_request_secret');
      final listSecretsTool =
          tools.firstWhere((t) => t.schema.name == 'system_list_secrets');

      // 2. Intercept permission events emitted by PlatformRuntimeBridge
      String? suspendedRequestId;
      bridge.attachResponseSink((response) {
        final metadata = response.message.metadata;
        if (metadata != null) {
          final payload = metadata['canonical_payload'] as Map<String, dynamic>?;
          if (payload != null && payload['tool_name'] == 'system_request_secret') {
            suspendedRequestId = payload['request_id'] as String?;
          }
        }
      });

      // 3. Agent triggers system_request_secret asynchronously
      const secretPassword = 'UltraSecretPassword2026!#%';
      const secretUsername = 'cluster_admin';

      final toolExecutionFuture = requestSecretTool.execute(
        {
          'fields': [
            {'id': 'DB_USER', 'label': 'Database User', 'is_secret': false},
            {'id': 'DB_PASS', 'label': 'Database Password', 'is_secret': true},
          ],
          'reason': 'Database migration authentication',
          'target_vault': 'postgres_prod',
        },
        context: ToolContext(
          sessionId: 'session-e2e-1',
          metadata: {'workspace_path': workspaceDir.path},
        ),
      );

      // Allow the microtask queue to deliver the suspended request
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(suspendedRequestId, isNotNull);

      // 4. Flutter Client simulates user filling inputs and clicking "Save to Vault"
      final responseResult = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-e2e-1',
          payload: {
            'request_id': suspendedRequestId,
            'session_id': 'session-e2e-1',
            'allowed': true,
            'values': {
              'DB_USER': secretUsername,
              'DB_PASS': secretPassword,
            },
          },
        ),
      );
      expect(responseResult.isSuccess, isTrue);

      // 5. Tool execution completes: verify zero-leak envelope returned to LLM
      final envelopeJson = await toolExecutionFuture;
      final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;

      expect(envelope['status'], equals('stored'));
      expect(envelope['skipped'], isFalse);
      expect(envelope['target_vault'], equals('custom:postgres_prod'));
      expect(envelope['keys_stored'], contains('DB_USER'));
      expect(envelope['keys_stored'], contains('DB_PASS'));

      // STRICT ZERO-LEAK ASSERTION: The envelope JSON string returned to LLM must NOT contain secret values
      expect(envelopeJson.contains(secretPassword), isFalse);

      // 6. Verify secrets stored securely in AgentSecretStore under custom:* namespace
      expect(
        await secretStore.read('custom:postgres_prod:DB_USER'),
        equals(secretUsername),
      );
      expect(
        await secretStore.read('custom:postgres_prod:DB_PASS'),
        equals(secretPassword),
      );

      // 7. Verify bridge retention redacts secrets to prevent leaks in logs / memory
      final dupAttempt = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-e2e-1',
          payload: {
            'request_id': suspendedRequestId,
            'session_id': 'session-e2e-1',
            'allowed': true,
            'values': {'DB_PASS': 'leak-check'},
          },
        ),
      );
      expect(dupAttempt.errorCode, equals('ALREADY_RESOLVED'));

      // 8. Agent executes system_list_secrets: metadata discovery
      final listResultJson = await listSecretsTool.execute({});
      final listResult = jsonDecode(listResultJson) as Map<String, dynamic>;

      expect(listResult['secrets'], isA<List>());
      final secrets = listResult['secrets'] as List;

      expect(secrets, anyElement(predicate((item) =>
          item is Map &&
          item['key'] == 'custom:postgres_prod:DB_PASS' &&
          item['source'] == 'vault' &&
          item['has_value'] == true)));

      // STRICT ZERO-LEAK ASSERTION: Discovery output must NOT contain plaintext secrets
      expect(listResultJson.contains(secretPassword), isFalse);

      // 9. Process Environment Injection: execution backend runs command safely
      final policy = const ProcessEnvironmentPolicy();
      final backend = DirectExecutionBackend(
        processEnvironmentPolicy: policy,
        secretStore: secretStore,
      );

      // DirectExecutionBackend automatically resolves vault secrets for 'postgres_prod' from secretStore
      final stopwatch = Stopwatch()..start();
      final echoCmd = Platform.isWindows ? 'echo %DB_USER%' : 'echo \$DB_USER';
      final execResultJson = await backend.executeCommand(
        command: echoCmd,
        workingDir: workspaceDir.path,
        timeoutMs: 5000,
        stopwatch: stopwatch,
        context: ToolContext(
          sessionId: 'session-e2e-1',
          metadata: {'custom_vault': 'postgres_prod'},
        ),
      );

      final execResult = jsonDecode(execResultJson) as Map<String, dynamic>;
      expect(execResult['isError'], isNull);
      expect((execResult['output'] as String).trim(), equals(secretUsername));
      // Command string itself and JSON result did not contain raw password
      expect(execResultJson.contains(secretPassword), isFalse);
    });

    test('E2E Flow: User clicks Skip returns clean skipped envelope without storing', () async {
      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: AgentTurnRequest(
          sessionId: 'session-e2e-2',
          workspaceId: 'ws-e2e-2',
          message: 'Setup secret',
        ),
      );

      final requestSecretTool =
          tools.firstWhere((t) => t.schema.name == 'system_request_secret');

      String? suspendedRequestId;
      bridge.attachResponseSink((response) {
        final metadata = response.message.metadata;
        if (metadata != null) {
          final payload = metadata['canonical_payload'] as Map<String, dynamic>?;
          if (payload != null && payload['tool_name'] == 'system_request_secret') {
            suspendedRequestId = payload['request_id'] as String?;
          }
        }
      });

      final toolExecutionFuture = requestSecretTool.execute(
        {
          'fields': [
            {'id': 'api_key', 'label': 'API Key', 'is_secret': true},
          ],
          'reason': 'API Access',
        },
        context: ToolContext(
          sessionId: 'session-e2e-2',
          metadata: {'workspace_path': workspaceDir.path},
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(suspendedRequestId, isNotNull);

      // Simulate user clicking "Skip" in the Flutter UI
      final responseResult = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-e2e-2',
          payload: {
            'request_id': suspendedRequestId,
            'session_id': 'session-e2e-2',
            'allowed': false,
            'skipped': true,
          },
        ),
      );
      expect(responseResult.isSuccess, isTrue);

      final envelopeJson = await toolExecutionFuture;
      final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;

      expect(envelope['status'], equals('skipped'));
      expect(envelope['skipped'], isTrue);
      expect(envelope['keys_stored'], isNull);

      // Verify no secrets written to store
      expect(secretStore.values, isEmpty);
    });

    test('E2E Flow: Optional Workspace .env Atomic Write with 0600 Permissions', () async {
      final tools = await catalog.buildTools(
        registry: ToolsRegistry(),
        request: AgentTurnRequest(
          sessionId: 'session-e2e-3',
          workspaceId: 'ws-e2e-3',
          message: 'Store in env',
        ),
      );

      final requestSecretTool =
          tools.firstWhere((t) => t.schema.name == 'system_request_secret');

      String? suspendedRequestId;
      bridge.attachResponseSink((response) {
        final metadata = response.message.metadata;
        if (metadata != null) {
          final payload = metadata['canonical_payload'] as Map<String, dynamic>?;
          if (payload != null && payload['tool_name'] == 'system_request_secret') {
            suspendedRequestId = payload['request_id'] as String?;
          }
        }
      });

      final toolExecutionFuture = requestSecretTool.execute(
        {
          'fields': [
            {'id': 'SECRET_TOKEN', 'label': 'Auth Token', 'is_secret': true},
          ],
          'reason': 'Local Docker testing',
          'write_to_workspace_env': '.env',
        },
        context: ToolContext(
          sessionId: 'session-e2e-3',
          metadata: {'workspace_path': workspaceDir.path},
        ),
      );

      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(suspendedRequestId, isNotNull);

      final responseResult = await bridge.handlePermissionResponse(
        CanonicalEvent(
          type: CanonicalEventTypes.toolPermissionResponse,
          sessionId: 'session-e2e-3',
          payload: {
            'request_id': suspendedRequestId,
            'session_id': 'session-e2e-3',
            'allowed': true,
            'values': {
              'SECRET_TOKEN': 'mock_token_value_999',
            },
          },
        ),
      );
      expect(responseResult.isSuccess, isTrue);

      final envelopeJson = await toolExecutionFuture;
      final envelope = jsonDecode(envelopeJson) as Map<String, dynamic>;

      expect(envelope['status'], equals('stored'));

      // Check workspace .env file created
      final envFile = File('${workspaceDir.path}/.env');
      expect(await envFile.exists(), isTrue);
      final envContent = await envFile.readAsString();
      expect(envContent, contains('SECRET_TOKEN=mock_token_value_999'));

      if (!Platform.isWindows) {
        final stat = await envFile.stat();
        expect(stat.modeString(), contains('rw-------'));
      }
    });
  });
}
