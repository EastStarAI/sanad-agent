import 'dart:io';

import 'package:get_it/get_it.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/e2e_agent_runtime_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_rate_limiter.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_runtime/session_queue_provider_override.dart';
import 'package:sanad_agent/engine/adapters/llm_adapter.dart';
import 'package:sanad_agent/engine/adapters/models_dev_service.dart';
import 'package:sanad_agent/engine/agent_runner.dart';
import 'package:sanad_agent/capabilities/registry/tools_registry.dart';
import 'package:sanad_agent/capabilities/registry/toolsets.dart';
import 'package:sanad_agent/capabilities/runtime/local_runtime_catalog.dart';
import 'package:sanad_agent/capabilities/runtime/web_search/web_search_service.dart';
import 'package:sanad_agent/capabilities/runtime/web_search/web_fetch_service.dart';
import 'package:sanad_agent/capabilities/runtime/runtime_context_builder.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/capabilities/skills/skill_load_service.dart';
import 'package:sanad_agent/capabilities/skills/skill_registry.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/agent_state_maintenance_service.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/plugins/plugin_manager.dart';
import 'package:sanad_agent/engine/context_engine.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_daemon_server_platform.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/sanad_protocol_bridge.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart';
import 'package:sanad_agent/interfaces/runtime/local_runtime_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_checkpoint_store.dart';
import 'package:sanad_agent/interfaces/runtime/suspended_resume_service.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/device_settings_service.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_state_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_config_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_adapter.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_di.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_service.dart';

import 'package:sanad_agent/evolution/title_service.dart';

final GetIt getIt = GetIt.instance;

void setupDI() {
  final e2eTestMode =
      Platform.environment['SANAD_E2E_TEST_MODE']?.trim().toLowerCase() ==
      'true';
  if (e2eTestMode) {
    final stateHome = Platform.environment['SANAD_STATE_HOME']?.trim() ?? '';
    final sanadHome = getSanadHome();
    if (stateHome.isEmpty ||
        Directory(stateHome).absolute.path ==
            Directory(sanadHome).absolute.path) {
      throw StateError(
        'SANAD_E2E_TEST_MODE requires SANAD_STATE_HOME to be isolated from SANAD_HOME.',
      );
    }
  }

  getIt.registerLazySingleton<AuthManager>(() => AuthManager());
  getIt.registerLazySingleton<Config>(() => Config());
  getIt.registerLazySingleton<ModelsDevService>(() => ModelsDevService());
  getIt.registerLazySingleton<SessionRunOrchestrator>(
    () => SessionRunOrchestrator(),
  );
  getIt.registerLazySingleton<SessionQueueProviderOverride>(
    () => getIt<SessionRunOrchestrator>(),
  );
  getIt.registerLazySingleton<GatewayManager>(() => GatewayManager());

  // ── Agent State Database (single SQLite connection owner) ──────────────
  // Registered before SessionDB/SessionManager and the provider repository so
  // they can all share one connection to state.db and never open it twice.
  getIt.registerLazySingleton<AgentStateDatabase>(() => AgentStateDatabase());

  // Persisted runtime state repository (post-Plan 30): durable mirror of
  // suspended runs, queued messages, and active runtime notices.
  getIt.registerLazySingleton<PersistedRuntimeStateRepository>(
    () =>
        PersistedRuntimeStateRepository.fromState(getIt<AgentStateDatabase>()),
  );
  getIt.registerLazySingleton<AgentStateMaintenanceService>(
    () => AgentStateMaintenanceService(getIt<AgentStateDatabase>()),
  );
  getIt.registerLazySingleton<SessionRouteTransitionRepository>(
    () => SessionRouteTransitionRepository(getIt<AgentStateDatabase>()),
  );
  getIt.registerLazySingleton<SessionRouteMutationCoordinator>(
    () => SessionRouteMutationCoordinator(
      state: getIt<AgentStateDatabase>(),
      workItems: getIt<PersistedRuntimeStateRepository>().workItems,
      transitions: getIt<SessionRouteTransitionRepository>(),
      providerInstances: getIt<ProviderInstanceRepository>(),
      executionState: getIt<PersistedRuntimeStateRepository>().executionState,
    ),
  );

  // ── Provider Runtime (Plan 19) ───────────────────────────────────────
  getIt.registerLazySingleton<EnvFileService>(() => EnvFileService());
  // Plan 29: instance/template repository sharing the AgentStateDatabase
  // connection. Plan 29 tables live inside state.db.
  getIt.registerLazySingleton<ProviderInstanceRepository>(
    () => ProviderInstanceRepository(getIt<AgentStateDatabase>()),
  );
  // Plan 29: instance-keyed secret store (atomic, locked, owner-only).
  getIt.registerLazySingleton<SecretStore>(() => SecureFileSecretStore());
  // Plan 29: instance credential edits (keep/replace/remove) + summaries.
  getIt.registerLazySingleton<ProviderCredentialService>(
    () => ProviderCredentialService(
      getIt<ProviderInstanceRepository>(),
      getIt<SecretStore>(),
    ),
  );
  // Plan 29: instance CRUD + name suggestion + draft/ready lifecycle.
  getIt.registerLazySingleton<ProviderInstanceService>(
    () => ProviderInstanceService(getIt<ProviderInstanceRepository>()),
  );
  getIt.registerLazySingleton<ProviderCredentialStore>(
    () => ProviderCredentialStore(),
  );
  getIt.registerLazySingleton<ProviderCatalogService>(
    () => ProviderCatalogService(),
  );
  getIt.registerLazySingleton<ProviderStateService>(
    () => ProviderStateService(
      getIt<EnvFileService>(),
      getIt<ProviderCredentialStore>(),
    ),
  );
  getIt.registerLazySingleton<ProviderCredentialResolver>(
    () => ProviderCredentialResolver(
      getIt<EnvFileService>(),
      getIt<ProviderCredentialStore>(),
    ),
  );
  getIt.registerLazySingleton<ProviderAuthSessionService>(
    () => ProviderAuthSessionService(
      getIt<ProviderCredentialStore>(),
      credService: getIt<ProviderCredentialService>(),
      instanceService: getIt<ProviderInstanceService>(),
    ),
  );
  getIt.registerLazySingleton<ProviderReadinessService>(
    () => ProviderReadinessService(
      getIt<ProviderInstanceRepository>(),
      getIt<SecretStore>(),
    ),
  );
  getIt.registerLazySingleton<ProviderConfigService>(
    () => ProviderConfigService(
      getIt<EnvFileService>(),
      getIt<ProviderCredentialStore>(),
    ),
  );
  getIt.registerLazySingleton<ModelOptionsService>(
    () => ModelOptionsService(
      getIt<EnvFileService>(),
      getIt<ProviderCredentialResolver>(),
    ),
  );
  getIt.registerLazySingleton<ModelSelectionService>(
    () => ModelSelectionService(getIt<EnvFileService>()),
  );

  getIt.registerLazySingleton<SessionManager>(() => SessionManager());
  getIt.registerLazySingleton<CronScheduler>(() => CronScheduler());
  getIt.registerLazySingleton<TitleService>(() => TitleService());

  // ── Agent Runtime (Plan 24: composite adapter cache) ──────────────────
  // Registered before LLMAdapter/AgentRunner so they can depend on it.
  // Plan 30: rate limiter + recovery service must be registered first so the
  // runtime can wire them into every turn-scoped adapter.
  getIt.registerLazySingleton<ProviderRateLimiter>(() => ProviderRateLimiter());

  getIt.registerLazySingleton<RuntimeRecoveryService>(
    () => RuntimeRecoveryService(
      getIt<ProviderInstanceRepository>(),
      getIt<ProviderRateLimiter>(),
      autoFailoverEnabled: getIt<Config>().providerAutoFailover,
    )..attachPersistedState(getIt<PersistedRuntimeStateRepository>()),
  );
  getIt.registerLazySingleton<DaemonRestartCoordinator>(
    () => DaemonRestartCoordinator(
      sessionOrchestrator: getIt<SessionRunOrchestrator>(),
    ),
  );
  getIt.registerLazySingleton<DeviceSettingsService>(
    () => DeviceSettingsService(
      config: getIt<Config>(),
      envFileService: getIt<EnvFileService>(),
      runtimeRecovery: getIt<RuntimeRecoveryService>(),
    ),
  );

  getIt.registerLazySingleton<AgentRuntimeService>(
    () => e2eTestMode
        ? E2eAgentRuntimeService(
            getIt<Config>(),
            getIt<ProviderInstanceRepository>(),
          )
        : AgentRuntimeService(
            getIt<Config>(),
            getIt<ProviderInstanceRepository>(),
            modelsDevService: getIt<ModelsDevService>(),
            credentialResolver: getIt<ProviderCredentialResolver>(),
            credService: getIt<ProviderCredentialService>(),
            rateLimiter: getIt<ProviderRateLimiter>(),
            recoveryService: getIt<RuntimeRecoveryService>(),
          ),
  );

  // Resolve the current default on every compatibility lookup. The runtime
  // still caches real adapters by RouteSignature, while a MissingProviderAdapter
  // resolved before onboarding is never frozen in dependency injection.
  getIt.registerFactory<LLMAdapter>(
    () => getIt<AgentRuntimeService>().defaultAdapter(),
  );

  getIt.registerLazySingleton<ProviderModelCacheService>(
    () => ProviderModelCacheService(
      getIt<ProviderInstanceRepository>(),
      getIt<AgentRuntimeService>(),
    ),
  );

  getIt.registerLazySingleton<RecentModelSelectionService>(
    () => RecentModelSelectionService(getIt<ProviderInstanceRepository>()),
  );

  // ── Task 55: Provider account usage limits ─────────────────────────────
  getIt.registerLazySingleton<ProviderUsageRegistry>(
    () => buildProviderUsageRegistry(),
  );
  getIt.registerLazySingleton<ProviderUsageService>(
    () => ProviderUsageService(
      instanceRepository: getIt<ProviderInstanceRepository>(),
      secretStore: getIt<SecretStore>(),
      registry: getIt<ProviderUsageRegistry>(),
      httpClientFactory: defaultProductionHttpClient,
    ),
  );

  // ── Plan 30: Rate limiter + runtime recovery ───────────────────────────
  // (Registered earlier, before AgentRuntimeService, so the runtime can wire
  // them into every turn-scoped adapter. Kept here as a no-op marker for the
  // dependency graph; the actual singletons live above.)

  getIt.registerLazySingleton<ToolsRegistry>(() {
    final registry = ToolsRegistry();
    registry.registerTools(Toolsets.coreTools);
    return registry;
  });
  getIt.registerLazySingleton<SkillRegistry>(() => const SkillRegistry());
  getIt.registerLazySingleton<SkillLoadService>(
    () => SkillLoadService(registry: getIt<SkillRegistry>()),
  );
  getIt.registerLazySingleton<RuntimeContextBuilder>(
    () => RuntimeContextBuilder(skillRegistry: getIt<SkillRegistry>()),
  );
  getIt.registerLazySingleton<PlatformRuntimeBridge>(
    () => PlatformRuntimeBridge(),
  );
  getIt.registerLazySingleton<SuspendedCheckpointStore>(
    () => SuspendedCheckpointStore(sessionManager: getIt<SessionManager>()),
  );
  getIt.registerLazySingleton<WorkspacePolicyStore>(
    () => const WorkspacePolicyStore(),
  );
  getIt.registerLazySingleton<PermissionManager>(
    () => PermissionManager(
      policyStore: getIt<WorkspacePolicyStore>(),
      platformRuntimeBridge: getIt<PlatformRuntimeBridge>(),
      checkpointStore: getIt<SuspendedCheckpointStore>(),
    ),
  );
  getIt.registerLazySingleton<WebSearchService>(
    () => WebSearchService(
      serperApiKeyResolver: () => getIt<Config>().serperApiKey,
      preferredProviderResolver: () => getIt<Config>().webSearchProvider,
    ),
  );
  getIt.registerLazySingleton<WebFetchService>(() => WebFetchService());

  getIt.registerLazySingleton<LocalRuntimeCatalog>(
    () => LocalRuntimeCatalog(
      workspaceRuntimeService: getIt<LocalWorkspaceRuntimeService>(),
      permissionManager: getIt<PermissionManager>(),
      platformRuntimeBridge: getIt<PlatformRuntimeBridge>(),
      webSearchService: getIt<WebSearchService>(),
      webFetchService: getIt<WebFetchService>(),
    ),
  );

  getIt.registerLazySingleton<SanadProtocolBridge>(() => SanadProtocolBridge());
  getIt.registerLazySingleton<LocalWorkspaceRuntimeService>(
    () => LocalWorkspaceRuntimeService(
      skillRegistry: getIt<SkillRegistry>(),
      skillLoadService: getIt<SkillLoadService>(),
      sessionDb: getIt<SessionManager>().db,
    ),
  );
  getIt.registerLazySingleton<LocalRuntimeOrchestrator>(
    () => LocalRuntimeOrchestrator(
      getIt<LocalWorkspaceRuntimeService>(),
      getIt<LocalRuntimeCatalog>(),
      runtimeContextBuilder: getIt<RuntimeContextBuilder>(),
    ),
  );
  getIt.registerLazySingleton<SuspendedResumeService>(
    () => SuspendedResumeService(
      checkpointStore: getIt<SuspendedCheckpointStore>(),
      sessionManager: getIt<SessionManager>(),
      runtimeCatalog: getIt<LocalRuntimeCatalog>(),
      runtimeContextBuilder: getIt<RuntimeContextBuilder>(),
      workspaceRuntimeService: getIt<LocalWorkspaceRuntimeService>(),
      permissionManager: getIt<PermissionManager>(),
    ),
  );
  getIt.registerLazySingleton<ServerSanadGatewayPlatform>(
    () => ServerSanadGatewayPlatform(),
  );
  getIt.registerLazySingleton<LocalDaemonServerPlatform>(
    () => LocalDaemonServerPlatform(),
  );

  getIt.registerLazySingleton<PluginManager>(() => PluginManager());

  // Compression receives the live turn-scoped adapter from AgentRunner. Keep
  // the shared engine provider-neutral so it cannot retain a pre-onboarding
  // MissingProviderAdapter.
  getIt.registerLazySingleton<ContextEngine>(() => ContextEngine());

  getIt.registerFactoryParam<AgentRunner, String?, void>(
    (sessionId, _) => AgentRunner(
      getIt<LLMAdapter>(),
      getIt<ToolsRegistry>().copy(),
      getIt<SessionManager>(),
      pluginManager: getIt<PluginManager>(),
      contextEngine: getIt<ContextEngine>(),
      existingSessionId: sessionId,
    ),
  );
}
