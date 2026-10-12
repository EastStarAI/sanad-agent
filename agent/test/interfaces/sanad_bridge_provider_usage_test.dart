// Focused protocol tests for Task 55 Gate B: provider.usage.get and
// provider.usage.support over the Sanad protocol bridge.
//
// Covers:
//   • Command-to-event translation and request correlation.
//   • `available` result surfaces snapshot windows when an adapter is wired.
//   • `unsupported` when no adapter is registered for the instance's template.
//   • `failed` when the instance does not exist.
//   • `auth_required` when the adapter cannot fetch (no credential).
//   • Raw token / response body never crosses the protocol boundary.
//   • Usage failure does NOT change instance status or readiness.
//   • provider.usage.support returns per-instance support flags.

import 'dart:async';
import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_state_service.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_adapter.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_models.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_service.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

void main() {
  late Directory tempDir;

  setUp(() async {
    getIt.allowReassignment = true;
    tempDir = await Directory.systemTemp.createTemp('sanad-bridge-usage');
    setSanadHomeOverride(tempDir.path);
    SessionManager.resetForTesting();
    getIt.registerSingleton<AuthManager>(AuthManager());
    getIt.registerSingleton<SessionManager>(SessionManager());

    final db = AgentStateDatabase.inMemory();
    getIt.registerSingleton<AgentStateDatabase>(db);
    final repo = ProviderInstanceRepository.fromDatabase(db.db);
    getIt.registerSingleton<ProviderInstanceRepository>(repo);
    final secretStore = SecureFileSecretStore();
    getIt.registerSingleton<SecretStore>(secretStore);
    getIt.registerSingleton<ProviderCredentialService>(
      ProviderCredentialService(repo, secretStore),
    );
    getIt.registerSingleton<ProviderInstanceService>(
      ProviderInstanceService(repo),
    );

    // Minimal stubs for ProviderCommandHandler's other dependencies (the usage
    // path does not invoke them, but the lazy constructor pulls them all).
    getIt.registerSingleton<ProviderCatalogService>(ProviderCatalogService());
    getIt.registerSingleton<ProviderAuthSessionService>(
      ProviderAuthSessionService(ProviderCredentialStore()),
    );
    getIt.registerSingleton<ProviderModelCacheService>(
      ProviderModelCacheService(
        repo,
        _StubRuntimeService(),
        buildDefaultThinkingCapabilityAssembler(),
      ),
    );
    getIt.registerSingleton<RecentModelSelectionService>(
      RecentModelSelectionService(repo),
    );
    getIt.registerSingleton<ModelOptionsService>(
      ModelOptionsService(
        EnvFileService(),
        ProviderCredentialResolver(EnvFileService(), ProviderCredentialStore()),
      ),
    );
    getIt.registerSingleton<ModelSelectionService>(
      ModelSelectionService(EnvFileService()),
    );
    getIt.registerSingleton<ProviderReadinessService>(
      ProviderReadinessService(repo, secretStore),
    );
    getIt.registerSingleton<ProviderStateService>(
      ProviderStateService(EnvFileService(), ProviderCredentialStore()),
    );
  });

  tearDown(() async {
    SessionManager.resetForTesting();
    setSanadHomeOverride(null);
    await tempDir.delete(recursive: true);
    await getIt.reset();
  });

  /// Registers a [ProviderUsageService] backed by [registry] and
  /// [httpClientFactory], then creates a fresh bridge.
  SanadProtocolBridge bridgeWith({
    required ProviderUsageRegistry registry,
    required UsageHttpClientFactoryFn httpClientFactory,
  }) {
    getIt.registerSingleton<ProviderUsageService>(
      ProviderUsageService(
        instanceRepository: getIt<ProviderInstanceRepository>(),
        secretStore: getIt<SecretStore>(),
        registry: registry,
        httpClientFactory: httpClientFactory,
      ),
    );
    return SanadProtocolBridge();
  }

  Future<Map<String, dynamic>> sendCommand(
    SanadProtocolBridge bridge,
    String command, {
    Map<String, dynamic> payload = const {},
  }) async {
    Map<String, dynamic>? captured;
    await bridge.handleCommand(
      {
        'command': command,
        'payload': payload,
        'device_id': 'test-device',
        'hardware_id': 'test-hw',
      },
      (envelope) async {
        captured ??= envelope;
      },
    );
    return captured ?? {};
  }

  String createInstance(String templateId, String displayName) {
    final svc = getIt<ProviderInstanceService>();
    final inst = svc.create(
      templateId: templateId,
      displayName: displayName,
      authMethod: templateId == 'openai-codex'
          ? ProviderAuthMethod.deviceCode
          : ProviderAuthMethod.apiKey,
    );
    return inst.id;
  }

  group('provider.usage.get protocol (Gate B)', () {
    test(
      'available result surfaces snapshot windows and echoes request_id',
      () async {
        // Register an adapter that returns a fixed snapshot.
        final registry = ProviderUsageRegistry();
        final instanceId = createInstance('openai-codex', 'ChatGPT');
        // Write a credential so canFetch is true.
        await getIt<ProviderCredentialService>().writeOAuthBundle(
          instanceId,
          SecretRecord(
            instanceId: instanceId,
            accessToken: 'token-xyz',
            authMethod: ProviderAuthMethod.deviceCode,
          ),
        );

        registry.register(
          _FixedAdapter(
            instanceId: instanceId,
            snapshot: ProviderUsageSnapshot(
              providerInstanceId: instanceId,
              providerTemplateId: 'openai-codex',
              source: 'test',
              fetchedAt: DateTime.utc(2026, 7, 19),
              windows: const [
                ProviderUsageWindow(
                  type: 'weekly',
                  label: 'Weekly',
                  usedPercent: 30,
                  remainingPercent: 70,
                ),
              ],
              availableResets: 1,
            ),
          ),
        );

        final bridge = bridgeWith(
          registry: registry,
          httpClientFactory: () => _NullClient(),
        );

        final env = await sendCommand(
          bridge,
          'provider.usage.get',
          payload: {
            'request_id': 'req-usage-1',
            'provider_instance_id': instanceId,
          },
        );

        expect(env['event'], CanonicalEventTypes.providerUsageResult);
        expect(env['request_id'], 'req-usage-1');
        final payload = env['payload'] as Map<String, dynamic>;
        expect(payload['status'], ProviderUsageResultStatus.available);
        expect(payload['provider_instance_id'], instanceId);
        final snap = payload['snapshot'] as Map<String, dynamic>;
        expect(snap['windows'], isNotEmpty);
        expect(snap['available_resets'], 1);
        // Token never crosses the boundary.
        expect(env.toString().contains('token-xyz'), isFalse);
      },
    );

    test(
      'unsupported when no adapter is registered for the template',
      () async {
        // Registry is empty — no adapter for 'openai'.
        final bridge = bridgeWith(
          registry: ProviderUsageRegistry(),
          httpClientFactory: () => _NullClient(),
        );
        final instanceId = createInstance('openai', 'OpenAI');

        final env = await sendCommand(
          bridge,
          'provider.usage.get',
          payload: {'request_id': 'req-2', 'provider_instance_id': instanceId},
        );

        final payload = env['payload'] as Map<String, dynamic>;
        expect(payload['status'], ProviderUsageResultStatus.unsupported);
        expect(payload['provider_instance_id'], instanceId);
        expect(payload.containsKey('snapshot'), isFalse);
      },
    );

    test('failed when instance does not exist', () async {
      final bridge = bridgeWith(
        registry: ProviderUsageRegistry(),
        httpClientFactory: () => _NullClient(),
      );

      final env = await sendCommand(
        bridge,
        'provider.usage.get',
        payload: {
          'request_id': 'req-3',
          'provider_instance_id': 'nonexistent-id',
        },
      );

      final payload = env['payload'] as Map<String, dynamic>;
      expect(payload['status'], ProviderUsageResultStatus.failed);
    });

    test('auth_required when credential is missing', () async {
      final registry = ProviderUsageRegistry();
      final instanceId = createInstance('openai-codex', 'ChatGPT No Cred');
      // No credential written → canFetch returns false.
      registry.register(_FixedAdapter(instanceId: instanceId, snapshot: null));

      final bridge = bridgeWith(
        registry: registry,
        httpClientFactory: () => _NullClient(),
      );

      final env = await sendCommand(
        bridge,
        'provider.usage.get',
        payload: {'request_id': 'req-4', 'provider_instance_id': instanceId},
      );

      final payload = env['payload'] as Map<String, dynamic>;
      expect(payload['status'], ProviderUsageResultStatus.authRequired);
    });

    test('usage failure does not change instance readiness/status', () async {
      final registry = ProviderUsageRegistry();
      final instanceId = createInstance('openai-codex', 'ChatGPT Stable');
      await getIt<ProviderCredentialService>().writeOAuthBundle(
        instanceId,
        SecretRecord(
          instanceId: instanceId,
          accessToken: 'tok',
          authMethod: ProviderAuthMethod.deviceCode,
        ),
      );
      // Adapter throws unavailable.
      registry.register(_ThrowingAdapter(instanceId));

      final bridge = bridgeWith(
        registry: registry,
        httpClientFactory: () => _NullClient(),
      );

      final env = await sendCommand(
        bridge,
        'provider.usage.get',
        payload: {'provider_instance_id': instanceId},
      );
      final payload = env['payload'] as Map<String, dynamic>;
      expect(payload['status'], ProviderUsageResultStatus.unavailable);

      // Instance status remains unchanged.
      final inst = getIt<ProviderInstanceRepository>().findById(instanceId);
      expect(inst, isNotNull);
      expect(inst!.status, isNot(InstanceStatus.error));
    });

    test(
      'no service registered → unsupported (graceful degradation)',
      () async {
        // Bridge built without ProviderUsageService in getIt.
        final bridge = SanadProtocolBridge();
        final instanceId = createInstance('openai', 'OpenAI');

        final env = await sendCommand(
          bridge,
          'provider.usage.get',
          payload: {'request_id': 'req-5', 'provider_instance_id': instanceId},
        );

        final payload = env['payload'] as Map<String, dynamic>;
        expect(payload['status'], ProviderUsageResultStatus.unsupported);
      },
    );
  });

  group('provider.usage.reset protocol (Gate D)', () {
    test(
      'concurrent retries with one idempotency key consume only once',
      () async {
        final instanceId = createInstance('openai-codex', 'ChatGPT');
        await getIt<ProviderCredentialService>().writeOAuthBundle(
          instanceId,
          SecretRecord(
            instanceId: instanceId,
            accessToken: 'token-a',
            authMethod: ProviderAuthMethod.deviceCode,
          ),
        );
        final adapter = _ResetAdapter();
        final registry = ProviderUsageRegistry()..register(adapter);
        final bridge = bridgeWith(
          registry: registry,
          httpClientFactory: () => _NullClient(),
        );

        Future<Map<String, dynamic>> reset(String requestId) => sendCommand(
          bridge,
          'provider.usage.reset',
          payload: {
            'request_id': requestId,
            'provider_instance_id': instanceId,
            'idempotency_key': 'same-reset',
          },
        );

        final results = await Future.wait([reset('reset-1'), reset('reset-2')]);

        expect(adapter.resetCalls, 1);
        expect(results.map((value) => value['request_id']), [
          'reset-1',
          'reset-2',
        ]);
        for (final envelope in results) {
          expect(
            envelope['event'],
            CanonicalEventTypes.providerUsageResetResult,
          );
          expect(
            (envelope['payload'] as Map<String, dynamic>)['status'],
            ProviderUsageResetStatus.reset,
          );
        }
      },
    );

    test('reset uses only the selected instance credential', () async {
      final instanceA = createInstance('openai-codex', 'ChatGPT A');
      final instanceB = createInstance('openai-codex', 'ChatGPT B');
      for (final entry in [(instanceA, 'token-a'), (instanceB, 'token-b')]) {
        await getIt<ProviderCredentialService>().writeOAuthBundle(
          entry.$1,
          SecretRecord(
            instanceId: entry.$1,
            accessToken: entry.$2,
            authMethod: ProviderAuthMethod.deviceCode,
          ),
        );
      }
      final adapter = _ResetAdapter();
      final bridge = bridgeWith(
        registry: ProviderUsageRegistry()..register(adapter),
        httpClientFactory: () => _NullClient(),
      );

      final envelope = await sendCommand(
        bridge,
        'provider.usage.reset',
        payload: {
          'request_id': 'scope-a',
          'provider_instance_id': instanceA,
          'idempotency_key': 'scope-key',
        },
      );

      expect(
        (envelope['payload'] as Map<String, dynamic>)['status'],
        ProviderUsageResetStatus.reset,
      );
      expect(adapter.fetchCredentials, everyElement('token-a'));
      expect(adapter.resetCredentials, ['token-a']);
      expect(adapter.seenInstanceIds, everyElement(instanceA));
      expect(adapter.fetchCredentials, isNot(contains('token-b')));
    });
  });

  group('provider.usage.support protocol (Gate B)', () {
    test('returns per-instance support flags', () async {
      final registry = ProviderUsageRegistry();
      registry.register(_FixedAdapter(instanceId: 'any', snapshot: null));

      final codexId = createInstance('openai-codex', 'ChatGPT');
      final openaiId = createInstance('openai', 'OpenAI');

      final bridge = bridgeWith(
        registry: registry,
        httpClientFactory: () => _NullClient(),
      );

      final env = await sendCommand(
        bridge,
        'provider.usage.support',
        payload: {
          'request_id': 'req-support',
          'provider_instance_ids': [codexId, openaiId],
        },
      );

      expect(env['event'], CanonicalEventTypes.providerUsageSupportResult);
      final payload = env['payload'] as Map<String, dynamic>;
      final support = payload['support'] as Map<String, dynamic>;
      expect(support[codexId], isTrue);
      expect(support[openaiId], isFalse);
    });
  });
}

// ── Test doubles ────────────────────────────────────────────────────────

class _FixedAdapter implements ProviderUsageAdapter {
  final String instanceId;
  final ProviderUsageSnapshot? snapshot;
  _FixedAdapter({required this.instanceId, required this.snapshot});

  @override
  String get templateId => 'openai-codex';

  @override
  String get sourceLabel => 'test';

  @override
  bool canFetch(ProviderUsageContext context) {
    // Return true only when the instance has a credential, so the auth_required
    // test path works without a real token.
    return context.credential?.accessToken != null ||
        context.credential?.apiKey != null;
  }

  @override
  Future<ProviderUsageSnapshot> fetch(ProviderUsageContext context) async {
    if (snapshot == null) {
      throw const ProviderUsageUnavailableException('no fixture');
    }
    return snapshot!;
  }
}

class _ThrowingAdapter implements ProviderUsageAdapter {
  final String instanceId;
  _ThrowingAdapter(this.instanceId);

  @override
  String get templateId => 'openai-codex';

  @override
  String get sourceLabel => 'test';

  @override
  bool canFetch(ProviderUsageContext context) => true;

  @override
  Future<ProviderUsageSnapshot> fetch(ProviderUsageContext context) async {
    throw const ProviderUsageUnavailableException('backend down');
  }
}

class _ResetAdapter implements ProviderUsageResetAdapter {
  int resetCalls = 0;
  final List<String?> fetchCredentials = [];
  final List<String?> resetCredentials = [];
  final List<String> seenInstanceIds = [];

  @override
  String get templateId => 'openai-codex';

  @override
  String get sourceLabel => 'test-reset';

  @override
  bool canFetch(ProviderUsageContext context) =>
      context.credential?.accessToken?.isNotEmpty ?? false;

  @override
  Future<ProviderUsageSnapshot> fetch(ProviderUsageContext context) async {
    fetchCredentials.add(context.credential?.accessToken);
    seenInstanceIds.add(context.instanceId);
    return ProviderUsageSnapshot(
      providerInstanceId: context.instanceId,
      providerTemplateId: context.templateId,
      source: sourceLabel,
      fetchedAt: DateTime.now().toUtc(),
      windows: const [
        ProviderUsageWindow(
          type: ProviderUsageWindowType.weekly,
          label: 'Weekly',
          usedPercent: 100,
          remainingPercent: 0,
        ),
      ],
      availableResets: 1,
    );
  }

  @override
  Future<ProviderUsageResetAdapterResult> reset(
    ProviderUsageContext context, {
    required String idempotencyKey,
  }) async {
    resetCalls++;
    resetCredentials.add(context.credential?.accessToken);
    seenInstanceIds.add(context.instanceId);
    await Future<void>.delayed(const Duration(milliseconds: 10));
    return const ProviderUsageResetAdapterResult(
      ProviderUsageResetStatus.reset,
      availableResets: 0,
    );
  }
}

class _NullClient implements ProviderUsageHttpClient {
  @override
  Future<ProviderUsageHttpResponse> get(
    Uri url, {
    Map<String, String>? headers,
    Duration? timeout,
  }) async {
    return const ProviderUsageHttpResponse(200, '{}');
  }

  @override
  Future<ProviderUsageHttpResponse> post(
    Uri url, {
    Map<String, String>? headers,
    Object? body,
    Duration? timeout,
  }) async {
    return const ProviderUsageHttpResponse(200, '{}');
  }

  @override
  void close() {}
}

/// Minimal [AgentRuntimeService] stub for the model cache service dependency.
/// The usage protocol path never invokes it.
class _StubRuntimeService extends AgentRuntimeService {
  _StubRuntimeService()
    : super(Config(), ProviderInstanceRepository.inMemory());
}
