// Shared fixture for the `ProviderCommandHandler` characterization suites.
//
// Every value is hermetic: an in-memory agent-state database, a temporary
// Sanad Home, an in-memory secret store, and a mock HTTP client so no test
// reaches the network or the OS credential vault.

import 'dart:async';
import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_state_service.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';
import 'package:sanad_agent/core/provider_thinking/provider_thinking_di.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/provider_command_handler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:test/test.dart';

import '../../../../../support/isolated_sanad_test_home.dart';
import '../../../../../support/memory_agent_secret_store.dart';

/// Hardware identity stamped on every envelope by the test [AuthManager].
const harnessHardwareId = 'device-characterization';

/// Fake API key used to exercise credential edits. Not a credential.
const harnessApiKey = 'sk-characterization-key-0001';

/// Installs isolated Sanad roots plus a fresh handler fixture for every test.
///
/// Call once from a suite's `main`, before any `setUp` that depends on it.
ProviderHandlerHarness installProviderHandlerHarness() {
  final harness = ProviderHandlerHarness._();
  useIsolatedSanadTestHome();
  setUp(harness._create);
  tearDown(harness._dispose);
  return harness;
}

class ProviderHandlerHarness {
  ProviderHandlerHarness._();

  late String home;
  late AgentStateDatabase db;
  late ProviderInstanceRepository repo;
  late MemoryProviderSecretStore secrets;
  late ProviderCredentialStore credStore;
  late EnvFileService env;
  late ProviderInstanceService instances;
  late ProviderCredentialService credentials;
  late ProviderCommandHandler handler;
  late RecordingRuntimeService runtime;
  late Config config;

  void _create() {
    home = getSanadHome();
    GetIt.instance.registerSingleton<AuthManager>(_TestAuthManager());

    db = AgentStateDatabase.inMemory();
    repo = ProviderInstanceRepository.fromDatabase(db.db);
    secrets = MemoryProviderSecretStore();
    credStore = ProviderCredentialStore(
      storePath: p.join(home, 'provider_auth.json'),
    );
    env = EnvFileService(envPath: p.join(home, '.env'));
    File(env.envPath).writeAsStringSync(
      'ACTIVE_PROVIDER=openai\n'
      'LLM_MODEL=gpt-4o-mini\n'
      'OPENAI_API_KEY=sk-env-placeholder\n',
    );

    credentials = ProviderCredentialService(repo, secrets);
    instances = ProviderInstanceService(repo);
    config = Config();
    runtime = RecordingRuntimeService(config, repo);

    final authSession = ProviderAuthSessionService(
      credStore,
      credService: credentials,
      instanceService: instances,
    );
    final cache = ProviderModelCacheService(
      repo,
      AgentRuntimeService(config, repo),
      buildDefaultThinkingCapabilityAssembler(),
    );
    // Live discovery is never reached: the mock answers 500 so options fall
    // back to the registry presets, the same path an unreachable endpoint
    // takes.
    final modelOptions = ModelOptionsService(
      env,
      ProviderCredentialResolver(env, credStore),
      clientFactory: () => MockClient((_) async => http.Response('', 500)),
    );

    handler = ProviderCommandHandler(
      catalog: ProviderCatalogService(),
      instanceService: instances,
      credentialService: credentials,
      authSession: authSession,
      cacheService: cache,
      repository: repo,
      recentService: RecentModelSelectionService(repo),
      modelOptions: modelOptions,
      modelSelection: ModelSelectionService(env),
      readiness: ProviderReadinessService(repo, secrets),
      state: ProviderStateService(env, credStore),
      config: config,
      agentRuntime: runtime,
      bridge: SanadProtocolBridge(),
    );
  }

  void _dispose() {
    db.dispose();
  }

  // ── Fixtures ────────────────────────────────────────────────────────────

  ProviderInstance createInstance({
    String templateId = 'openai',
    String displayName = 'OpenAI Work',
    String? authMethod,
    String? defaultModel = 'gpt-4o',
    bool makeDefault = false,
    DateTime? now,
  }) {
    return instances.create(
      templateId: templateId,
      displayName: displayName,
      authMethod:
          authMethod ??
          (templateId == 'openai-codex'
              ? ProviderAuthMethod.deviceCode
              : ProviderAuthMethod.apiKey),
      defaultModel: defaultModel,
      makeDefault: makeDefault,
      now: now,
    );
  }

  /// Seeds a verified cache row for the instance's current revisions and
  /// promotes it to `ready`, which is what a successful discovery produces.
  void seedVerifiedCache(String instanceId) {
    final instance = repo.findById(instanceId)!;
    repo.upsertModelCache(
      instanceId: instanceId,
      cacheKey: 'models',
      models: const [
        {'value': 'gpt-4o'},
      ],
      fetchedAt: DateTime.utc(2026, 1, 2, 3, 4, 5),
      source: 'live',
      configRevision: instance.configRevision,
      credentialRevision: instance.credentialRevision,
    );
    instances.markReadyIfComplete(instanceId, credentialConfigured: true);
  }

  // ── Command helpers ─────────────────────────────────────────────────────

  CanonicalEvent event(String type, [Map<String, dynamic> body = const {}]) =>
      CanonicalEvent(type: type, payload: body);

  Map<String, dynamic> payloadOf(Map<String, dynamic> envelope) =>
      Map<String, dynamic>.from(envelope['payload'] as Map);

  Future<Map<String, dynamic>> _build(
    String type,
    Map<String, dynamic> body,
    FutureOr<Map<String, dynamic>> Function(CanonicalEvent) build,
  ) async => await build(event(type, body));

  Future<Map<String, dynamic>> setupStatus({
    Map<String, dynamic> body = const {},
  }) async => handler.buildProviderReadinessEnvelope(
    event(CanonicalEventTypes.providerSetupStatus, body),
    isRuntimeCheck: false,
  );

  Future<Map<String, dynamic>> runtimeCheck({
    Map<String, dynamic> body = const {},
  }) async => handler.buildProviderReadinessEnvelope(
    event(CanonicalEventTypes.providerRuntimeCheck, body),
    isRuntimeCheck: true,
  );

  Future<Map<String, dynamic>> templates({
    Map<String, dynamic> body = const {},
  }) => _build(
    CanonicalEventTypes.providerTemplatesList,
    body,
    handler.buildTemplatesListEnvelope,
  );

  Future<Map<String, dynamic>> instancesList({
    Map<String, dynamic> body = const {},
  }) => _build(
    CanonicalEventTypes.providerInstancesList,
    body,
    handler.buildInstancesListEnvelope,
  );

  Future<Map<String, dynamic>> instanceCreate(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerInstanceCreate,
        body,
        handler.buildInstanceCreateEnvelope,
      );

  Future<Map<String, dynamic>> instanceUpdate(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerInstanceUpdate,
        body,
        handler.buildInstanceUpdateEnvelope,
      );

  Future<Map<String, dynamic>> instanceRename(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerInstanceRename,
        body,
        handler.buildInstanceRenameEnvelope,
      );

  Future<Map<String, dynamic>> instanceRemove(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerInstanceRemove,
        body,
        handler.buildInstanceRemoveEnvelope,
      );

  Future<Map<String, dynamic>> instanceSetDefault(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerInstanceSetDefault,
        body,
        handler.buildInstanceSetDefaultEnvelope,
      );

  Future<Map<String, dynamic>> instanceTest(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerInstanceTest,
        body,
        handler.buildInstanceTestEnvelope,
      );

  Future<Map<String, dynamic>> credentialUpdate(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerCredentialUpdate,
        body,
        handler.buildCredentialUpdateEnvelope,
      );

  Future<Map<String, dynamic>> authStart(Map<String, dynamic> body) => _build(
    CanonicalEventTypes.providerAuthStart,
    body,
    handler.buildProviderAuthStartEnvelope,
  );

  Future<Map<String, dynamic>> authPoll(Map<String, dynamic> body) => _build(
    CanonicalEventTypes.providerAuthPoll,
    body,
    handler.buildProviderAuthPollEnvelope,
  );

  Future<Map<String, dynamic>> authSubmit(Map<String, dynamic> body) => _build(
    CanonicalEventTypes.providerAuthSubmit,
    body,
    handler.buildProviderAuthSubmitEnvelope,
  );

  Future<Map<String, dynamic>> authCancel(Map<String, dynamic> body) => _build(
    CanonicalEventTypes.providerAuthCancel,
    body,
    handler.buildProviderAuthCancelEnvelope,
  );

  Future<Map<String, dynamic>> authStatus(Map<String, dynamic> body) => _build(
    CanonicalEventTypes.providerAuthStatus,
    body,
    handler.buildProviderAuthStatusEnvelope,
  );

  Future<Map<String, dynamic>> authReconnect(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerAuthReconnect,
        body,
        handler.buildAuthReconnectEnvelope,
      );

  Future<Map<String, dynamic>> authDisconnect(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerAuthDisconnect,
        body,
        handler.buildAuthDisconnectEnvelope,
      );

  Future<Map<String, dynamic>> snapshot({
    Map<String, dynamic> body = const {},
  }) => _build(
    CanonicalEventTypes.modelSnapshot,
    body,
    handler.buildModelSnapshotEnvelope,
  );

  Future<Map<String, dynamic>> recentList({
    Map<String, dynamic> body = const {},
  }) => _build(
    CanonicalEventTypes.modelRecentList,
    body,
    handler.buildModelRecentListEnvelope,
  );

  Future<Map<String, dynamic>> recentRecord(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.modelRecentRecord,
        body,
        handler.buildModelRecentRecordEnvelope,
      );

  Future<Map<String, dynamic>> configuredOptions({
    Map<String, dynamic> body = const {},
  }) => _build(
    CanonicalEventTypes.providerConfiguredOptions,
    body,
    handler.buildProviderConfiguredOptionsEnvelope,
  );

  Future<Map<String, dynamic>> capabilities({
    Map<String, dynamic> body = const {},
  }) => _build(
    CanonicalEventTypes.capabilitiesChanged,
    body,
    handler.buildCapabilitiesChangedEnvelope,
  );

  Future<Map<String, dynamic>> instancesChanged() =>
      handler.buildInstancesChangedBroadcastEnvelope();

  Future<Map<String, dynamic>> modelOptions(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.modelOptions,
        body,
        handler.buildModelOptionsEnvelope,
      );

  Future<Map<String, dynamic>> recommendedDefault(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.modelRecommendedDefault,
        body,
        handler.buildModelRecommendedDefaultEnvelope,
      );

  Future<Map<String, dynamic>> setDefaultModel(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.modelSetDefault,
        body,
        handler.buildModelSetDefaultEnvelope,
      );

  Future<Map<String, dynamic>> usageGet(Map<String, dynamic> body) => _build(
    CanonicalEventTypes.providerUsageGet,
    body,
    handler.buildUsageGetEnvelope,
  );

  Future<Map<String, dynamic>> usageReset(Map<String, dynamic> body) => _build(
    CanonicalEventTypes.providerUsageReset,
    body,
    handler.buildUsageResetEnvelope,
  );

  Future<Map<String, dynamic>> usageSupport(Map<String, dynamic> body) =>
      _build(
        CanonicalEventTypes.providerUsageSupport,
        body,
        handler.buildUsageSupportEnvelope,
      );
}

/// [SecretStore] that keeps records in memory and masks summaries through the
/// real `SecretSummary.fromRecord` projection.
class MemoryProviderSecretStore implements SecretStore {
  final Map<String, SecretRecord> _records = {};

  @override
  SecretRecord? read(String instanceId) => _records[instanceId];

  @override
  Future<void> write(String instanceId, SecretRecord record) async {
    _records[instanceId] = record;
  }

  @override
  SecretSummary summary(String instanceId) =>
      SecretSummary.fromRecord(_records[instanceId], instanceId);

  @override
  Future<void> remove(String instanceId) async {
    _records.remove(instanceId);
  }

  @override
  List<String> listIds() => _records.keys.toList(growable: false);

  @override
  Future<void> pruneOrphans(Set<String> validInstanceIds) async {
    _records.removeWhere((id, _) => !validInstanceIds.contains(id));
  }
}

/// Counts adapter-cache invalidations so the mutation contract stays pinned.
class RecordingRuntimeService extends AgentRuntimeService {
  RecordingRuntimeService(super.config, super.repo);

  int invalidations = 0;

  @override
  void invalidate() {
    invalidations += 1;
    super.invalidate();
  }
}

class _TestAuthManager extends AuthManager {
  _TestAuthManager() : super(secretStore: MemoryAgentSecretStore());

  @override
  String? get hardwareId => harnessHardwareId;
}
