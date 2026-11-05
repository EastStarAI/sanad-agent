// Issue 339: `provider.instance.test` must prove the credential, not merely
// that `/models` answered. These suites exercise the two-stage verification
// (live discovery + one minimal generation probe) against fakes only.

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_verifier.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/llm_http_exception.dart';
import 'package:sanad_agent/engine/adapters/llm_request_options.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/capabilities.dart';
import 'package:test/test.dart';

import '../../support/memory_provider_secret_store.dart';

const _secret = 'sk-verifier-credential-000123456789';

/// Adapter whose discovery and generation outcomes are scripted per test.
class _ScriptedAdapter implements LLMAdapter {
  _ScriptedAdapter({
    this.models = const ['gpt-4o'],
    this.generationError,
    this.discoveryError,
    this.hang = false,
  });

  final List<String> models;
  final Object? generationError;
  final Object? discoveryError;
  final bool hang;
  int generationCalls = 0;

  @override
  Future<List<ModelOption>> getAvailableModels() async {
    if (discoveryError != null) throw discoveryError!;
    return models.map((m) => ModelOption(value: m, label: m)).toList();
  }

  @override
  Future<AgentResponse> generateResponse(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) async {
    generationCalls++;
    if (hang) await Completer<AgentResponse>().future;
    if (generationError != null) throw generationError!;
    return AgentResponse(
      message: Message(role: MessageRole.assistant, content: 'OK'),
      model: modelOverride,
    );
  }

  @override
  Stream<AgentResponse> generateStream(
    List<dynamic> history, {
    List<dynamic>? tools,
    String? modelOverride,
    LLMRequestOptions options = const LLMRequestOptions(),
  }) => throw UnimplementedError();

  @override
  Future<int> getContextLimit([String? modelOverride]) async => 4096;
}

class _FakeRuntime extends AgentRuntimeService {
  _FakeRuntime(super.config, super.repo, this.adapter);

  final LLMAdapter adapter;

  @override
  LLMAdapter adapterFor(RouteSignature signature) => adapter;
}

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ProviderInstanceService instances;
  late ProviderCredentialService credentials;
  late MemoryProviderSecretStore secrets;
  late _ScriptedAdapter adapter;
  late Config config;
  late ProviderModelCacheService cache;
  late ProviderInstanceVerifier verifier;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    instances = ProviderInstanceService(repo);
    secrets = MemoryProviderSecretStore();
    credentials = ProviderCredentialService(repo, secrets);
    adapter = _ScriptedAdapter();
    config = Config(environment: {'OPENAI_API_KEY': _secret});
    cache = ProviderModelCacheService(
      repo,
      _FakeRuntime(config, repo, adapter),
      buildDefaultThinkingCapabilityAssembler(),
    );
    verifier = ProviderInstanceVerifier(
      cache: cache,
      repository: repo,
      instances: instances,
      credentials: credentials,
      runtime: _FakeRuntime(config, repo, adapter),
      probeTimeout: const Duration(milliseconds: 200),
    );
  });

  tearDown(() {
    state.dispose();
  });

  ProviderInstance createInstance({
    String? baseUrl = 'https://gateway.example/v1',
    String? defaultModel = 'gpt-4o',
    String templateId = 'custom',
  }) {
    final instance = ProviderInstance(
      id: 'inst-verify',
      templateId: templateId,
      displayName: 'Verify Me',
      protocol: ProviderProtocol.openaiCompatible,
      authMethod: ProviderAuthMethod.apiKey,
      baseUrl: baseUrl,
      defaultModel: defaultModel,
      createdAt: DateTime.now(),
      updatedAt: DateTime.now(),
    );
    repo.createInstance(instance);
    return instance;
  }

  Future<void> storeCredential() => credentials.applyApiKeyEdit(
    'inst-verify',
    action: 'replace',
    newApiKey: _secret,
  );

  Future<void> expectStatus(String status) async {
    expect(repo.findById('inst-verify')!.status, status);
  }

  group('two-stage verification', () {
    test('a working credential passes discovery and the probe', () async {
      createInstance();
      await storeCredential();

      final result = await verifier.verify('inst-verify');

      expect(result.success, isTrue);
      expect(result.modelsCount, 1);
      expect(result.model, 'gpt-4o');
      expect(result.failure, isNull);
      expect(result.probeLatency, isNotNull);
      expect(adapter.generationCalls, 1);
      await expectStatus(InstanceStatus.ready);

      final payload = result.toMap();
      expect(payload['success'], isTrue);
      expect(payload['models_count'], 1);
      expect(payload['latency_ms'], isA<int>());
      expect(payload.containsKey('failure'), isFalse);
    });

    test('a rejected key fails discovery, never probes, and marks needs_auth', () async {
      createInstance();
      await storeCredential();
      adapter = _ScriptedAdapter(
        discoveryError: LlmHttpException.fromResponse(
          _response(
            401,
            '{"error":{"message":"Invalid credential for $_secret"}}',
          ),
          operation: 'getAvailableModels',
        ),
      );
      verifier = ProviderInstanceVerifier(
        cache: ProviderModelCacheService(
          repo,
          _FakeRuntime(config, repo, adapter),
          buildDefaultThinkingCapabilityAssembler(),
        ),
        repository: repo,
        instances: instances,
        credentials: credentials,
        runtime: _FakeRuntime(config, repo, adapter),
      );

      final result = await verifier.verify('inst-verify');

      expect(result.success, isFalse);
      expect(result.failure!.kind, ProviderFailureCategory.invalidCredential);
      expect(result.failure!.statusCode, 401);
      expect(result.failure!.endpoint, 'https://gateway.example/v1/models');
      expect(result.failure!.summary.contains(_secret), isFalse);
      expect(adapter.generationCalls, 0);
      await expectStatus(InstanceStatus.needsAuth);
    });

    test('a key that lists models but cannot generate is rejected by the probe', () async {
      createInstance();
      await storeCredential();
      adapter = _ScriptedAdapter(
        generationError: LlmHttpException.fromResponse(
          _response(401, '{"error":{"message":"bad key $_secret"}}'),
          operation: 'chat',
        ),
      );
      verifier = ProviderInstanceVerifier(
        cache: ProviderModelCacheService(
          repo,
          _FakeRuntime(config, repo, adapter),
          buildDefaultThinkingCapabilityAssembler(),
        ),
        repository: repo,
        instances: instances,
        credentials: credentials,
        runtime: _FakeRuntime(config, repo, adapter),
      );

      final result = await verifier.verify('inst-verify');

      expect(result.success, isFalse);
      expect(result.modelsCount, 1);
      expect(result.model, 'gpt-4o');
      expect(result.failure!.kind, ProviderFailureCategory.invalidCredential);
      expect(
        result.failure!.endpoint,
        'https://gateway.example/v1/chat/completions',
      );
      expect(adapter.generationCalls, 1);
      await expectStatus(InstanceStatus.needsAuth);
    });

    test('a probe timeout is reported as a timeout and keeps draft', () async {
      createInstance();
      await storeCredential();
      adapter = _ScriptedAdapter(hang: true);
      verifier = ProviderInstanceVerifier(
        cache: ProviderModelCacheService(
          repo,
          _FakeRuntime(config, repo, adapter),
          buildDefaultThinkingCapabilityAssembler(),
        ),
        repository: repo,
        instances: instances,
        credentials: credentials,
        runtime: _FakeRuntime(config, repo, adapter),
        probeTimeout: const Duration(milliseconds: 30),
      );

      final result = await verifier.verify('inst-verify');

      expect(result.success, isFalse);
      expect(result.failure!.kind, ProviderFailureCategory.timeout);
      await expectStatus(InstanceStatus.draft);
    });

    test('a server-side probe failure marks error', () async {
      createInstance();
      await storeCredential();
      adapter = _ScriptedAdapter(
        generationError: LlmHttpException.fromResponse(
          _response(503, ''),
          operation: 'chat',
        ),
      );
      verifier = ProviderInstanceVerifier(
        cache: ProviderModelCacheService(
          repo,
          _FakeRuntime(config, repo, adapter),
          buildDefaultThinkingCapabilityAssembler(),
        ),
        repository: repo,
        instances: instances,
        credentials: credentials,
        runtime: _FakeRuntime(config, repo, adapter),
      );

      final result = await verifier.verify('inst-verify');

      expect(result.failure!.kind, ProviderFailureCategory.serverError);
      await expectStatus(InstanceStatus.error);
    });

    test('an unavailable runtime verifies discovery only', () async {
      createInstance();
      await storeCredential();
      final discoveryOnly = ProviderInstanceVerifier(
        cache: cache,
        repository: repo,
        instances: instances,
        credentials: credentials,
        probeEnabled: false,
      );

      final result = await discoveryOnly.verify('inst-verify');

      expect(result.success, isTrue);
      expect(result.modelsCount, 1);
      expect(result.probeLatency, isNull);
      expect(adapter.generationCalls, 0);
      await expectStatus(InstanceStatus.ready);
    });

    test('an empty model list fails without probing', () async {
      createInstance();
      adapter = _ScriptedAdapter(models: const []);
      final emptyList = ProviderInstanceVerifier(
        cache: ProviderModelCacheService(
          repo,
          _FakeRuntime(config, repo, adapter),
          buildDefaultThinkingCapabilityAssembler(),
        ),
        repository: repo,
        instances: instances,
        credentials: credentials,
        runtime: _FakeRuntime(config, repo, adapter),
      );

      final result = await emptyList.verify('inst-verify');

      expect(result.success, isFalse);
      expect(result.failure!.kind, ProviderFailureCategory.noModels);
      expect(adapter.generationCalls, 0);
    });

    test('an unknown instance is a contained failure', () async {
      final result = await verifier.verify('missing-id');

      expect(result.success, isFalse);
      expect(result.modelsCount, 0);
      expect(result.failure!.kind, ProviderFailureCategory.unknown);
      expect(result.failure!.message, 'Provider instance not found');
      expect(result.toMap()['message'], 'Provider instance not found');
    });

    test('a verified rediscovery returns a previously rejected instance to ready', () async {
      createInstance();
      await storeCredential();
      instances.applyConnectionOutcome(
        'inst-verify',
        const ProviderDiscoveryError(
          kind: ProviderFailureCategory.invalidCredential,
          statusCode: 401,
          message: 'Invalid credential (HTTP 401)',
        ),
        credentialConfigured: true,
      );
      await expectStatus(InstanceStatus.needsAuth);

      final result = await verifier.verify('inst-verify');

      expect(result.success, isTrue);
      await expectStatus(InstanceStatus.ready);
    });

    test('the probe prefers the instance default model', () async {
      createInstance(defaultModel: 'gpt-4o-mini');
      adapter = _ScriptedAdapter(models: const ['gpt-4o', 'gpt-4o-mini']);
      final preferred = ProviderInstanceVerifier(
        cache: ProviderModelCacheService(
          repo,
          _FakeRuntime(config, repo, adapter),
          buildDefaultThinkingCapabilityAssembler(),
        ),
        repository: repo,
        instances: instances,
        credentials: credentials,
        runtime: _FakeRuntime(config, repo, adapter),
      );

      final result = await preferred.verify('inst-verify');

      expect(result.success, isTrue);
      expect(result.model, 'gpt-4o-mini');
    });

    test('discovery noise never depends on the credential value', () async {
      createInstance();
      await storeCredential();
      await verifier.verify('inst-verify');

      // The stored secret is never part of the instance projection.
      expect(
        repo.readModelCache('inst-verify', 'models').toString().contains(_secret),
        isFalse,
      );
    });
  });

  group('status mapping', () {
    String statusFor(String kind, {int? statusCode}) =>
        ProviderInstanceService.statusForFailure(
          ProviderDiscoveryError(
            kind: kind,
            statusCode: statusCode,
            message: 'x',
          ),
        );

    test('a rejected credential is needs_auth', () {
      expect(
        statusFor(ProviderFailureCategory.invalidCredential, statusCode: 401),
        InstanceStatus.needsAuth,
      );
      expect(
        statusFor(ProviderFailureCategory.forbidden, statusCode: 403),
        InstanceStatus.needsAuth,
      );
    });

    test('definitive endpoint failures are error', () {
      for (final kind in [
        ProviderFailureCategory.endpointNotFound,
        ProviderFailureCategory.rateLimited,
        ProviderFailureCategory.serverError,
        ProviderFailureCategory.http,
      ]) {
        expect(statusFor(kind), InstanceStatus.error, reason: kind);
      }
    });

    test('unproven failures keep draft', () {
      for (final kind in [
        ProviderFailureCategory.network,
        ProviderFailureCategory.timeout,
        ProviderFailureCategory.noModels,
        ProviderFailureCategory.unknown,
      ]) {
        expect(statusFor(kind), InstanceStatus.draft, reason: kind);
      }
    });
  });
}

/// Builds an HTTP response carrying the provider's rejection body and the
/// credential-bearing header the transport keeps.
http.Response _response(int status, String body) => http.Response(
  body,
  status,
  headers: {'x-api-key': _secret},
);
