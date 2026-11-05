// Issue 339: `provider.instance.test` proves the credential with a live
// discovery. The optional generation probe adds route proof for the *selected*
// model and must never reject a valid credential, so its failures are warnings
// unless they are an outright credential rejection.
//
// Fakes only: no test reaches a real provider endpoint.

import 'dart:async';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/models/agent_response.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_discovery_error.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_discovery_projection.dart';
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
    this.generationDelay,
    this.hang = false,
  });

  final List<String> models;
  final Object? generationError;
  final Object? discoveryError;
  final Duration? generationDelay;
  final bool hang;
  int generationCalls = 0;
  String? lastGenerationModel;
  LLMRequestOptions? lastGenerationOptions;

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
    lastGenerationModel = modelOverride;
    lastGenerationOptions = options;
    if (hang) await Completer<AgentResponse>().future;
    if (generationDelay != null) await Future<void>.delayed(generationDelay!);
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

/// Builds an HTTP response carrying the provider's rejection body and the
/// credential-bearing header the transport keeps.
http.Response _response(int status, String body) => http.Response(
  body,
  status,
  headers: {'x-api-key': _secret},
);

LlmHttpException _http(int status, [String body = '']) =>
    LlmHttpException.fromResponse(
      _response(status, body),
      operation: 'chat',
    );

void main() {
  late AgentStateDatabase state;
  late ProviderInstanceRepository repo;
  late ProviderInstanceService instances;
  late ProviderCredentialService credentials;
  late MemoryProviderSecretStore secrets;
  late _ScriptedAdapter adapter;
  late Config config;

  setUp(() {
    state = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(state.db);
    instances = ProviderInstanceService(repo);
    secrets = MemoryProviderSecretStore();
    credentials = ProviderCredentialService(repo, secrets);
    adapter = _ScriptedAdapter();
    config = Config(environment: {'OPENAI_API_KEY': _secret});
  });

  tearDown(() {
    state.dispose();
  });

  ProviderInstanceVerifier buildVerifier({
    Duration probeTimeout = const Duration(milliseconds: 200),
    Duration localProbeTimeout = const Duration(seconds: 1),
    bool probeEnabled = true,
    bool withRuntime = true,
  }) {
    final runtime = _FakeRuntime(config, repo, adapter);
    return ProviderInstanceVerifier(
      cache: ProviderModelCacheService(
        repo,
        runtime,
        buildDefaultThinkingCapabilityAssembler(),
      ),
      repository: repo,
      instances: instances,
      credentials: credentials,
      runtime: withRuntime ? runtime : null,
      probeEnabled: probeEnabled,
      probeTimeout: probeTimeout,
      localProbeTimeout: localProbeTimeout,
    );
  }

  ProviderInstance createInstance({
    String templateId = 'custom',
    String? baseUrl = 'https://gateway.example/v1',
    String? defaultModel = 'gpt-4o',
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

  Future<void> storeCredential() =>
      credentials.applyApiKeyEdit('inst-verify', action: 'replace', newApiKey: _secret);

  String status() => repo.findById('inst-verify')!.status;

  group('setup gate is discovery-only', () {
    test('a valid key whose first model is not a chat model passes setup', () async {
      // OpenAI-style catalogs list embeddings, audio and TTS entries first.
      adapter = _ScriptedAdapter(
        models: const [
          'text-embedding-3-large',
          'whisper-1',
          'gpt-4o',
        ],
      );
      createInstance(defaultModel: null);
      await storeCredential();

      final result = await buildVerifier().verify('inst-verify', probe: false);

      expect(result.success, isTrue);
      expect(result.modelsCount, 3);
      expect(result.probeState, ProbeState.notRun);
      expect(result.failure, isNull);
      expect(result.warning, isNull);
      // No generation request was ever made.
      expect(adapter.generationCalls, 0);
      // A confirmed credential without a model is not usable yet.
      expect(status(), InstanceStatus.draft);
    });

    test('setup never probes even when a model is selected', () async {
      createInstance();
      await storeCredential();

      final result = await buildVerifier().verify('inst-verify', probe: false);

      expect(result.success, isTrue);
      expect(result.probeState, ProbeState.notRun);
      expect(adapter.generationCalls, 0);
      expect(result.toMap()['probe_state'], ProbeState.notRun);
    });

    test('a definitive discovery failure blocks setup', () async {
      adapter = _ScriptedAdapter(
        discoveryError: _http(401, '{"error":{"message":"bad key $_secret"}}'),
      );
      createInstance();
      await storeCredential();

      final result = await buildVerifier().verify('inst-verify', probe: false);

      expect(result.success, isFalse);
      expect(result.failure!.kind, ProviderFailureCategory.invalidCredential);
      expect(result.failure!.isDefinitive, isTrue);
      expect(result.toMap()['failure'], containsPair('definitive', true));
      expect(adapter.generationCalls, 0);
      expect(status(), InstanceStatus.needsAuth);
    });

    test('a transient discovery failure does not block setup', () async {
      adapter = _ScriptedAdapter(discoveryError: _http(503));
      createInstance();
      await storeCredential();

      final result = await buildVerifier().verify('inst-verify', probe: false);

      // The setup gate sees a failure, but it is not definitive: the client
      // keeps going instead of rejecting a possibly valid credential.
      expect(result.success, isFalse);
      expect(result.failure!.isDefinitive, isFalse);
      // A non-definitive failure never moves the status (owner decision:
      // READY + warning, never a demotion it cannot justify).
      expect(status(), InstanceStatus.draft);
    });
  });

  group('generation probe', () {
    test('a working credential passes discovery and the probe', () async {
      createInstance();
      await storeCredential();

      final result = await buildVerifier().verify('inst-verify');

      expect(result.success, isTrue);
      expect(result.modelsCount, 1);
      expect(result.model, 'gpt-4o');
      expect(result.probeState, ProbeState.passed);
      expect(result.failure, isNull);
      expect(result.warning, isNull);
      expect(result.probeLatency, isNotNull);
      expect(adapter.generationCalls, 1);
      expect(adapter.lastGenerationModel, 'gpt-4o');
      expect(status(), InstanceStatus.ready);

      final payload = result.toMap();
      expect(payload['success'], isTrue);
      expect(payload['models_count'], 1);
      expect(payload['probe_state'], ProbeState.passed);
      expect(payload['latency_ms'], isA<int>());
      expect(payload.containsKey('failure'), isFalse);
      expect(payload.containsKey('warning'), isFalse);
    });

    test('no selected model skips the probe and reports the partial state', () async {
      createInstance(defaultModel: null);
      await storeCredential();

      final result = await buildVerifier().verify('inst-verify');

      expect(result.success, isTrue);
      expect(result.modelsCount, 1);
      expect(result.probeState, ProbeState.skipped);
      expect(result.model, isNull);
      expect(result.probeLatency, isNull);
      expect(result.failure, isNull);
      expect(result.warning, isNull);
      expect(adapter.generationCalls, 0);
      // A confirmed credential without a model is not usable yet.
      expect(status(), InstanceStatus.draft);
      expect(result.toMap()['probe_state'], ProbeState.skipped);
    });

    test('the probe uses only the selected model, never a list entry', () async {
      adapter = _ScriptedAdapter(
        models: const ['text-embedding-3-large', 'gpt-4o', 'gpt-4o-mini'],
      );
      createInstance(defaultModel: 'gpt-4o-mini');
      await storeCredential();

      final result = await buildVerifier().verify('inst-verify');

      expect(result.probeState, ProbeState.passed);
      expect(adapter.lastGenerationModel, 'gpt-4o-mini');
    });

    test('a probe 403 is a warning and keeps the status', () async {
      // Discovery accepted the key; the account may just not run this model.
      adapter = _ScriptedAdapter(generationError: _http(403, 'forbidden'));
      createInstance();
      await storeCredential();
      instances.markReady('inst-verify');

      final result = await buildVerifier().verify('inst-verify');

      expect(result.success, isTrue);
      expect(result.probeState, ProbeState.warning);
      expect(result.failure, isNull);
      expect(result.warning!.kind, ProbeWarning.forbidden);
      expect(result.warning!.cause.isDefinitive, isFalse);
      expect(status(), InstanceStatus.ready);
      // The warning is durable: it survives a reload of the instance row.
      final row = repo.readModelCache('inst-verify', 'models')!;
      expect(row['last_error'], contains('Access denied (HTTP 403)'));
      final restored = ProviderDiscoveryError.tryRestore(
        detailJson: row['last_error_detail'],
        legacyText: row['last_error'],
      );
      expect(restored!.isDefinitive, isFalse);
      expect(restored.kind, ProviderFailureCategory.forbidden);
    });

    test('a probe 401 persists its cause so the demotion survives a restart', () async {
      adapter = _ScriptedAdapter(
        generationError: _http(401, '{"error":{"message":"revoked $_secret"}}'),
      );
      createInstance();
      await storeCredential();
      instances.markReady('inst-verify');

      final result = await buildVerifier().verify('inst-verify');

      expect(result.success, isFalse);
      expect(status(), InstanceStatus.needsAuth);
      // Durable cause, readable exactly as the card reads it after a restart.
      final row = repo.readModelCache('inst-verify', 'models')!;
      expect(row['last_error'], contains('Invalid credential (HTTP 401)'));
      final projected = ProviderDiscoveryProjection.of(repo, repo.findById('inst-verify')!);
      expect(projected.error!.kind, ProviderFailureCategory.invalidCredential);
      expect(projected.error!.isDefinitive, isTrue);
      expect(projected.error!.summary.contains(_secret), isFalse);
    });

    test('a probe 401 is definitive and marks needs_auth', () async {
      adapter = _ScriptedAdapter(
        generationError: _http(401, '{"error":{"message":"bad key $_secret"}}'),
      );
      createInstance();
      await storeCredential();

      final result = await buildVerifier().verify('inst-verify');

      expect(result.success, isFalse);
      expect(result.modelsCount, 1);
      expect(result.model, 'gpt-4o');
      expect(result.probeState, ProbeState.failed);
      expect(result.failure!.kind, ProviderFailureCategory.invalidCredential);
      expect(
        result.failure!.endpoint,
        'https://gateway.example/v1/chat/completions',
      );
      expect(adapter.generationCalls, 1);
      expect(status(), InstanceStatus.needsAuth);
    });

    test('a probe 400 is a warning and leaves the status alone', () async {
      adapter = _ScriptedAdapter(generationError: _http(400));
      createInstance();
      await storeCredential();
      // The credential already proved itself: the instance is ready.
      instances.markReady('inst-verify');

      final result = await buildVerifier().verify('inst-verify');

      expect(result.success, isTrue);
      expect(result.probeState, ProbeState.warning);
      expect(result.failure, isNull);
      expect(result.warning!.kind, ProbeWarning.modelRejected);
      expect(result.warning!.model, 'gpt-4o');
      expect(result.warning!.cause.statusCode, 400);
      expect(status(), InstanceStatus.ready);
      expect(result.toMap()['warning'], containsPair('kind', 'model_rejected'));
    });

    test('a probe 404 keeps the instance ready', () async {
      adapter = _ScriptedAdapter(generationError: _http(404));
      createInstance();
      await storeCredential();
      instances.markReady('inst-verify');

      final result = await buildVerifier().verify('inst-verify');

      expect(result.probeState, ProbeState.warning);
      expect(result.warning!.kind, ProbeWarning.modelRejected);
      expect(status(), InstanceStatus.ready);
    });

    test('a probe 429 is a rate-limit warning', () async {
      adapter = _ScriptedAdapter(generationError: _http(429));
      createInstance();
      await storeCredential();
      instances.markReady('inst-verify');

      final result = await buildVerifier().verify('inst-verify');

      expect(result.probeState, ProbeState.warning);
      expect(result.warning!.kind, ProbeWarning.rateLimited);
      expect(status(), InstanceStatus.ready);
    });

    test('a probe 5xx is a warning, never needs_auth', () async {
      adapter = _ScriptedAdapter(generationError: _http(503));
      createInstance();
      await storeCredential();
      instances.markReady('inst-verify');

      final result = await buildVerifier().verify('inst-verify');

      expect(result.probeState, ProbeState.warning);
      expect(result.warning!.kind, ProbeWarning.unknown);
      expect(status(), InstanceStatus.ready);
    });

    test('a probe timeout is a warning and keeps readiness', () async {
      adapter = _ScriptedAdapter(hang: true);
      createInstance();
      await storeCredential();
      instances.markReady('inst-verify');

      final result = await buildVerifier(
        probeTimeout: const Duration(milliseconds: 30),
      ).verify('inst-verify');

      expect(result.success, isTrue);
      expect(result.probeState, ProbeState.warning);
      expect(result.warning!.kind, ProbeWarning.timeout);
      expect(status(), InstanceStatus.ready);
    });

    test('a probe network failure is a warning', () async {
      adapter = _ScriptedAdapter(
        generationError: const SocketException('Network unreachable'),
      );
      createInstance();
      await storeCredential();

      final result = await buildVerifier().verify('inst-verify');

      expect(result.probeState, ProbeState.warning);
      expect(result.warning!.kind, ProbeWarning.network);
    });

    test('the probe passes its output bound through the adapter options', () async {
      createInstance(templateId: 'openai');
      await storeCredential();

      await buildVerifier().verify('inst-verify');

      // Adapters translate the bound onto their own wire field; the verifier
      // never writes a wire parameter itself.
      expect(adapter.lastGenerationOptions?.maxOutputTokens, 1);
      expect(
        adapter.lastGenerationOptions?.timeout,
        const Duration(milliseconds: 200),
      );
    });

    test('an unavailable runtime verifies discovery only', () async {
      createInstance();
      await storeCredential();

      final result = await buildVerifier(withRuntime: false).verify('inst-verify');

      expect(result.success, isTrue);
      expect(result.probeState, ProbeState.notRun);
      expect(result.probeLatency, isNull);
      expect(adapter.generationCalls, 0);
      expect(status(), InstanceStatus.ready);
    });

    test('an empty model list fails without probing', () async {
      adapter = _ScriptedAdapter(models: const []);
      createInstance(defaultModel: null);

      final result = await buildVerifier().verify('inst-verify');

      expect(result.success, isFalse);
      expect(result.failure!.kind, ProviderFailureCategory.noModels);
      expect(adapter.generationCalls, 0);
    });
  });

  group('local engine probe budget', () {
    test('a slow local model passes inside the local budget', () async {
      adapter = _ScriptedAdapter(generationDelay: const Duration(milliseconds: 80));
      // `ollama` is a local template (optional API key) that may cold-load.
      createInstance(templateId: 'ollama', baseUrl: 'http://localhost:11434/v1');
      await storeCredential();

      final result = await buildVerifier(
        probeTimeout: const Duration(milliseconds: 20),
        localProbeTimeout: const Duration(seconds: 2),
      ).verify('inst-verify');

      expect(result.probeState, ProbeState.passed);
      expect(adapter.lastGenerationOptions?.timeout, const Duration(seconds: 2));
    });

    test('the same delay on a hosted provider times out as a warning', () async {
      adapter = _ScriptedAdapter(generationDelay: const Duration(milliseconds: 80));
      createInstance(templateId: 'openai');
      await storeCredential();

      final result = await buildVerifier(
        probeTimeout: const Duration(milliseconds: 20),
        localProbeTimeout: const Duration(seconds: 2),
      ).verify('inst-verify');

      expect(result.probeState, ProbeState.warning);
      expect(result.warning!.kind, ProbeWarning.timeout);
      expect(
        adapter.lastGenerationOptions?.timeout,
        const Duration(milliseconds: 20),
      );
    });
  });

  group('instance identity and status', () {
    test('an unknown instance is a contained failure', () async {
      final result = await buildVerifier().verify('missing-id');

      expect(result.success, isFalse);
      expect(result.modelsCount, 0);
      expect(result.probeState, ProbeState.notRun);
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
      expect(status(), InstanceStatus.needsAuth);

      final result = await buildVerifier().verify('inst-verify');

      expect(result.success, isTrue);
      expect(status(), InstanceStatus.ready);
    });

    test('discovery noise never depends on the credential value', () async {
      createInstance();
      await storeCredential();
      await buildVerifier().verify('inst-verify');

      expect(
        repo.readModelCache('inst-verify', 'models').toString().contains(_secret),
        isFalse,
      );
    });

    test('status mapping follows the failure category', () {
      String? statusFor(String kind, {int? statusCode}) =>
          ProviderInstanceService.statusForFailure(
            ProviderDiscoveryError(
              kind: kind,
              statusCode: statusCode,
              message: 'x',
            ),
          );

      expect(
        statusFor(ProviderFailureCategory.invalidCredential, statusCode: 401),
        InstanceStatus.needsAuth,
      );
      expect(
        statusFor(ProviderFailureCategory.forbidden, statusCode: 403),
        InstanceStatus.needsAuth,
      );
      expect(
        statusFor(ProviderFailureCategory.endpointNotFound, statusCode: 404),
        InstanceStatus.error,
      );
      expect(
        statusFor(ProviderFailureCategory.http, statusCode: 418),
        InstanceStatus.error,
      );
      // Non-definitive causes never map to a status: a rate limit, a provider
      // outage, a transport failure, or an unusable list describes the moment.
      for (final kind in [
        ProviderFailureCategory.rateLimited,
        ProviderFailureCategory.serverError,
        ProviderFailureCategory.network,
        ProviderFailureCategory.timeout,
        ProviderFailureCategory.noModels,
        ProviderFailureCategory.unknown,
      ]) {
        expect(statusFor(kind), isNull, reason: kind);
      }
      // A warning-grade copy never maps to a lifecycle status.
      expect(
        ProviderInstanceService.statusForFailure(
          const ProviderDiscoveryError(
            kind: ProviderFailureCategory.forbidden,
            statusCode: 403,
            message: 'x',
          ).asWarning(),
        ),
        isNull,
      );
    });

    test('definitiveness is narrower than the status mapping', () {
      expect(
        const ProviderDiscoveryError(
          kind: ProviderFailureCategory.invalidCredential,
          statusCode: 401,
          message: 'x',
        ).isDefinitive,
        isTrue,
      );
      // A warning-grade copy of a normally definitive kind proves nothing.
      expect(
        const ProviderDiscoveryError(
          kind: ProviderFailureCategory.forbidden,
          statusCode: 403,
          message: 'x',
        ).asWarning().isDefinitive,
        isFalse,
      );
      expect(
        const ProviderDiscoveryError(
          kind: ProviderFailureCategory.endpointNotFound,
          statusCode: 404,
          message: 'x',
        ).isDefinitive,
        isTrue,
      );
      expect(
        const ProviderDiscoveryError(
          kind: ProviderFailureCategory.rateLimited,
          statusCode: 429,
          message: 'x',
        ).isDefinitive,
        isFalse,
      );
      expect(
        const ProviderDiscoveryError(
          kind: ProviderFailureCategory.serverError,
          statusCode: 503,
          message: 'x',
        ).isDefinitive,
        isFalse,
      );
      expect(
        const ProviderDiscoveryError(
          kind: ProviderFailureCategory.timeout,
          message: 'x',
        ).isDefinitive,
        isFalse,
      );
    });
  });
}
