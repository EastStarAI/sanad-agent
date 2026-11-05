import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempDir;
  late ProviderInstanceRepository repo;
  late SecretStore secretStore;
  late ProviderReadinessService service;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sanad-readiness');
    setSanadHomeOverride(tempDir.path);
    repo = ProviderInstanceRepository.inMemory();
    secretStore = SecureFileSecretStore(
      storePath: '${tempDir.path}/secrets.json',
    );
    service = ProviderReadinessService(repo, secretStore);
  });

  tearDown(() {
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  test('no instance configured -> not ready', () {
    final result = service.runtimeCheck();
    expect(result.hasProvider, isFalse);
    expect(result.runtimeReady, isFalse);
    expect(result.reason, isNotNull);
  });

  test('instance present but no model -> not ready', () {
    repo.createInstance(
      ProviderInstance(
        id: 'inst-1',
        templateId: 'openrouter',
        displayName: 'OpenRouter',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        status: InstanceStatus.draft,
        isDefault: true,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    final result = service.runtimeCheck();
    expect(result.hasProvider, isTrue);
    expect(result.runtimeReady, isFalse);
    expect(result.reason, anyOf(contains('model'), contains('draft')));
  });

  test('instance ready with key and model', () async {
    repo.createInstance(
      ProviderInstance(
        id: 'inst-2',
        templateId: 'openrouter',
        displayName: 'OpenRouter',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'mistralai/mistral-large-2512',
        status: InstanceStatus.ready,
        isDefault: true,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    await secretStore.write(
      'inst-2',
      SecretRecord(
        instanceId: 'inst-2',
        apiKey: 'sk-or-test',
        authMethod: ProviderAuthMethod.apiKey,
      ),
    );
    final result = service.runtimeCheck();
    expect(result.hasProvider, isTrue);
    expect(result.runtimeReady, isTrue);
    expect(result.activeProvider, equals('inst-2'));
    expect(result.activeModel, equals('mistralai/mistral-large-2512'));
  });

  test(
    'instance with no default model fails closed (no fallback to _config)',
    () {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-4',
          templateId: 'openai',
          displayName: 'OpenAI',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          status: InstanceStatus.draft,
          isDefault: true,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      final result = service.setupStatus();
      expect(result.hasProvider, isTrue);
      expect(result.runtimeReady, isFalse);
      expect(result.reason, anyOf(contains('model'), contains('Model')));
    },
  );

  test(
    'configured true but runtime check fails for OAuth without session',
    () async {
      repo.createInstance(
        ProviderInstance(
          id: 'inst-3',
          templateId: 'openai-codex',
          displayName: 'Codex',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.external,
          defaultModel: 'gpt-5.4',
          status: InstanceStatus.needsAuth,
          isDefault: true,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      final setup = service.setupStatus();
      expect(setup.hasProvider, isTrue);
      final runtime = service.runtimeCheck();
      expect(runtime.runtimeReady, isFalse);
      expect(runtime.reason, anyOf(contains('Sign in'), contains('missing')));
    },
  );

  test('a rejected credential reports its sanitized cause, not the status name', () {
    const secret = 'sk-readiness-secret-000123456789';
    repo.createInstance(
      ProviderInstance(
        id: 'inst-rejected',
        templateId: 'custom',
        displayName: 'OpenCode Go',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        baseUrl: 'https://opencode.ai/zen/go/v1',
        defaultModel: 'gpt-4o',
        status: InstanceStatus.draft,
        isDefault: true,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
    final error = ProviderDiscoveryError.capture(
      LlmHttpException.fromResponse(
        http.Response(
          '{"error":{"message":"Invalid credential for $secret"}}',
          401,
          headers: {'x-api-key': secret},
        ),
        operation: 'getAvailableModels',
      ),
      endpoint: Uri.parse('https://opencode.ai/zen/go/v1/models'),
    );
    repo.upsertModelCache(
      instanceId: 'inst-rejected',
      cacheKey: 'models',
      models: const [
        {'value': 'gpt-4o'},
      ],
      fetchedAt: DateTime.utc(2026, 1, 2),
      source: 'fallback',
      configRevision: 1,
      credentialRevision: 1,
      lastError: error.summary,
      lastErrorDetail: error.toJson(),
    );

    final result = service.setupStatus();

    expect(result.runtimeReady, isFalse);
    expect(
      result.reason,
      'Invalid credential (HTTP 401) from https://opencode.ai/zen/go/v1/models',
    );
    expect(result.reason, isNot(contains('Instance status')));
    expect(result.discoveryError?.kind, ProviderFailureCategory.invalidCredential);
    expect(result.toMap()['discovery_error'], {
      'kind': ProviderFailureCategory.invalidCredential,
      'status_code': 401,
      'message': 'Invalid credential (HTTP 401)',
      'endpoint': 'https://opencode.ai/zen/go/v1/models',
    });
    expect(result.reason!.contains(secret), isFalse);
  });

  test(
    'non-default instance is never silently selected (fail-closed)',    () async {
      // A ready instance that is NOT the default must not be picked up by
      // implicit routing/readiness (Plan 29 §3.10, criterion 13/24).
      repo.createInstance(
        ProviderInstance(
          id: 'inst-no-default',
          templateId: 'openai',
          displayName: 'OpenAI (not default)',
          protocol: ProviderProtocol.openaiCompatible,
          authMethod: ProviderAuthMethod.apiKey,
          defaultModel: 'gpt-4o',
          status: InstanceStatus.ready,
          isDefault: false,
          configRevision: 1,
          credentialRevision: 1,
          createdAt: DateTime.now(),
          updatedAt: DateTime.now(),
        ),
      );
      await secretStore.write(
        'inst-no-default',
        SecretRecord(
          instanceId: 'inst-no-default',
          apiKey: 'sk-test',
          authMethod: ProviderAuthMethod.apiKey,
        ),
      );
      final result = service.runtimeCheck();
      // No default set → readiness reports no usable provider.
      expect(result.runtimeReady, isFalse);
      expect(result.hasProvider, isFalse);
    },
  );
}
