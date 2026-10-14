import 'dart:convert';
import 'dart:io';

import 'package:sanad_agent/capabilities/mcp/mcp_secret_store.dart';
import 'package:sanad_agent/core/auth/agent_secret_namespaces.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';

void main() {
  group('Task 83c: Unified Agent Secret Store & Migration', () {
    late Directory tempHome;
    late MemoryAgentSecretStore vault;

    setUp(() async {
      tempHome = await Directory.systemTemp.createTemp('sanad-unified-secrets-test');
      setSanadHomeOverride(tempHome.path);
      vault = MemoryAgentSecretStore();
    });

    tearDown(() async {
      setSanadHomeOverride(null);
      if (tempHome.existsSync()) await tempHome.delete(recursive: true);
    });

    test('AgentSecretNamespaces formats and detects keys accurately', () {
      expect(AgentSecretNamespaces.authKey('token'), equals('agent:auth:token'));
      expect(AgentSecretNamespaces.providerKey('uuid-1'), equals('providers:uuid-1'));
      expect(AgentSecretNamespaces.mcpKey('mcp-secret://ref-1'), equals('mcp:mcp-secret://ref-1'));

      expect(AgentSecretNamespaces.isAuthKey('agent:auth:token'), isTrue);
      expect(AgentSecretNamespaces.isProviderKey('providers:uuid-1'), isTrue);
      expect(AgentSecretNamespaces.isMcpKey('mcp:mcp-secret://ref-1'), isTrue);

      expect(AgentSecretNamespaces.isAuthKey('providers:uuid-1'), isFalse);
      expect(AgentSecretNamespaces.isProviderKey('mcp:ref'), isFalse);
    });

    test('SecureFileSecretStore writes directly to vault when configured', () async {
      final store = SecureFileSecretStore(agentSecretStore: vault);

      final record = SecretRecord(
        instanceId: 'inst-1',
        apiKey: 'sk-test-secret-12345678',
        authMethod: ProviderAuthMethod.apiKey,
      );

      await store.write('inst-1', record);

      // Verify stored in memory vault under providers namespace
      final storedRaw = await vault.read(AgentSecretNamespaces.providerKey('inst-1'));
      expect(storedRaw, isNotNull);
      final decoded = jsonDecode(storedRaw!) as Map<String, dynamic>;
      expect(decoded['api_key'], equals('sk-test-secret-12345678'));

      // Verify read returns from memory cache / vault
      final retrieved = store.read('inst-1');
      expect(retrieved, isNotNull);
      expect(retrieved!.apiKey, equals('sk-test-secret-12345678'));

      // Verify remove deletes from vault
      await store.remove('inst-1');
      expect(store.read('inst-1'), isNull);
      expect(await vault.read(AgentSecretNamespaces.providerKey('inst-1')), isNull);
    });

    test('SecureFileSecretStore successfully migrates provider_secrets.json to vault and removes legacy file', () async {
      // 1. Create a legacy provider_secrets.json
      final boundary = SanadHomeBootstrap.identity();
      final legacyPayload = {
        'version': 1,
        'instances': {
          'uuid-legacy-1': {
            'instance_id': 'uuid-legacy-1',
            'api_key': 'sk-legacy-key-1',
            'auth_method': 'api_key',
          },
          'uuid-legacy-2': {
            'instance_id': 'uuid-legacy-2',
            'api_key': 'sk-legacy-key-2',
            'auth_method': 'api_key',
          },
        },
      };
      await boundary.writeSecretBytes(
        'provider_secrets.json',
        utf8.encode(jsonEncode(legacyPayload)),
      );

      expect(boundary.fileExists('provider_secrets.json'), isTrue);

      // 2. Perform migration
      final store = SecureFileSecretStore(agentSecretStore: vault);
      final success = await store.migrateLegacy(deleteOnSuccess: true);

      expect(success, isTrue);

      // 3. Verify values migrated to vault
      final v1 = await vault.read(AgentSecretNamespaces.providerKey('uuid-legacy-1'));
      final v2 = await vault.read(AgentSecretNamespaces.providerKey('uuid-legacy-2'));
      expect(v1, isNotNull);
      expect(v2, isNotNull);
      expect(jsonDecode(v1!)['api_key'], equals('sk-legacy-key-1'));
      expect(jsonDecode(v2!)['api_key'], equals('sk-legacy-key-2'));

      // 4. Verify legacy file was deleted
      expect(boundary.fileExists('provider_secrets.json'), isFalse);

      // 5. Verify store reads successfully
      expect(store.read('uuid-legacy-1')!.apiKey, equals('sk-legacy-key-1'));
      expect(store.read('uuid-legacy-2')!.apiKey, equals('sk-legacy-key-2'));
    });

    test('SecureFileSecretStore aborts migration and retains legacy file if vault verification fails', () async {
      final boundary = SanadHomeBootstrap.identity();
      final legacyPayload = {
        'version': 1,
        'instances': {
          'uuid-fail-1': {
            'instanceId': 'uuid-fail-1',
            'apiKey': 'sk-fail-key',
            'authMethod': 'api_key',
          },
        },
      };
      await boundary.writeSecretBytes(
        'provider_secrets.json',
        utf8.encode(jsonEncode(legacyPayload)),
      );

      // Vault corrupts writes
      vault.corruptWrites = true;

      final store = SecureFileSecretStore(agentSecretStore: vault);
      final success = await store.migrateLegacy(deleteOnSuccess: true);

      expect(success, isFalse);
      // Legacy file must NOT be deleted!
      expect(boundary.fileExists('provider_secrets.json'), isTrue);
    });

    test('McpSecretStore writes and resolves secrets via vault', () async {
      final mcpStore = McpSecretStore(
        homeDirectoryPath: tempHome.path,
        agentSecretStore: vault,
      );

      final ref = await mcpStore.put('my-super-secret-mcp-token');
      expect(McpSecretStore.isReference(ref), isTrue);

      // Vault holds secret under mcp namespace
      final stored = await vault.read(AgentSecretNamespaces.mcpKey(ref));
      expect(stored, equals('my-super-secret-mcp-token'));

      // Resolve returns value
      expect(mcpStore.resolve(ref), equals('my-super-secret-mcp-token'));

      // Remove deletes from vault
      await mcpStore.remove(ref);
      expect(mcpStore.resolve(ref), isNull);
      expect(await vault.read(AgentSecretNamespaces.mcpKey(ref)), isNull);
    });

    test('McpSecretStore migrates mcp_secrets.json to vault and deletes legacy file', () async {
      final boundary = SanadHomeBootstrap.identity();
      final legacyMcp = {
        'mcp-secret://test-1': 'token-alpha',
        'mcp-secret://test-2': 'token-beta',
      };
      await boundary.writeSecretBytes(
        'mcp_secrets.json',
        utf8.encode(jsonEncode(legacyMcp)),
      );

      expect(boundary.fileExists('mcp_secrets.json'), isTrue);

      final mcpStore = McpSecretStore(
        homeDirectoryPath: tempHome.path,
        agentSecretStore: vault,
      );

      final success = await mcpStore.migrateLegacy(deleteOnSuccess: true);
      expect(success, isTrue);

      // Legacy file removed
      expect(boundary.fileExists('mcp_secrets.json'), isFalse);

      // Vault populated
      expect(await vault.read(AgentSecretNamespaces.mcpKey('mcp-secret://test-1')), equals('token-alpha'));
      expect(await vault.read(AgentSecretNamespaces.mcpKey('mcp-secret://test-2')), equals('token-beta'));

      // Resolve works
      expect(mcpStore.resolve('mcp-secret://test-1'), equals('token-alpha'));
      expect(mcpStore.resolve('mcp-secret://test-2'), equals('token-beta'));
    });
  });
}
