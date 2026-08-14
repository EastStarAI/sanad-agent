import 'package:get_it/get_it.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:sanad_client/core/config/app_config.dart';
import 'package:sanad_client/core/navigation/navigation_history_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/local_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/standalone_daemon_controller.dart';
import 'package:sanad_client/features/devices/data/daemon/source_daemon_controller.dart';
import 'package:sanad_client/core/di/modules/socket_module.dart';
import 'package:sanad_client/core/di/modules/storage_module.dart';
import 'package:sanad_client/core/interfaces/socket_service.dart';
import 'package:sanad_client/features/devices/data/device_client_registry_impl.dart';
import 'package:sanad_client/features/devices/data/device_repository_impl.dart';
import 'package:sanad_client/features/devices/domain/device_client_registry.dart';
import 'package:sanad_client/features/devices/domain/device_repository.dart';
import 'package:sanad_client/features/devices/domain/stores/device_capabilities_store.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_service.dart';
import 'package:sanad_client/features/auth/domain/auth_repository.dart';
import 'package:sanad_client/features/auth/domain/client_instance_identity.dart';
import 'package:sanad_client/features/auth/data/auth_repository_impl.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_runtime_service.dart';
import 'package:sanad_client/features/mcp/data/mcp_runtime_client.dart';
import 'package:sanad_client/features/settings/data/device_settings_client.dart';
import 'package:sanad_client/features/settings/data/account_lifecycle_repository.dart';
import 'package:sanad_client/features/settings/data/device_skills_client.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client.dart';
import 'package:sanad_client/features/provider_setup/data/provider_setup_client_impl.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/infrastructure/local_tools/workspace_tool_runtime_context.dart';
import 'package:sanad_client/infrastructure/local_tools/tool_approval_service.dart';
import 'package:sanad_client/infrastructure/platform/auto_update_service.dart';
import 'package:sanad_client/infrastructure/local_tools/local_tool_execution_coordinator.dart';
import 'package:sanad_client/infrastructure/mcp/mcp_service.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';
import 'package:sanad_client/utils/app_platform.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/data/repositories/socket_conversation_repository.dart';
import 'package:sanad_client/features/conversations/domain/conversation_client.dart';
import 'package:sanad_client/features/conversations/data/conversation_client_registry_impl.dart';
import 'package:sanad_client/features/conversations/domain/stores/conversation_cache_store.dart';
import 'package:sanad_client/features/conversations/data/persistence/conversation_cache_persistor.dart';
import 'package:sanad_client/features/conversations/data/persistence/shared_preferences_conversation_cache_persistence.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_cache_persistence.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/devices/domain/device_preferences_repository.dart';
import 'package:sanad_client/features/devices/data/device_preferences_repository_impl.dart';
import 'package:sanad_client/features/devices/presentation/state/device_command_handler.dart';
import 'package:sanad_client/features/devices/data/device_connection_coordinator.dart';
import 'package:sanad_client/features/devices/data/device_command_client.dart';
import 'package:sanad_client/core/presentation/state/app_state.dart';

final getIt = GetIt.instance;

Future<void> configureDependencies({
  Future<void> Function(String phase)? startupTrace,
}) async {
  final storageModule = StorageModule();
  final socketModule = SocketModule();

  if (!getIt.isRegistered<SharedPreferences>()) {
    getIt.registerSingleton<SharedPreferences>(await storageModule.prefs());
  }
  await startupTrace?.call('preferences-ready');

  if (!getIt.isRegistered<ClientInstanceIdentity>()) {
    getIt.registerLazySingleton<ClientInstanceIdentity>(
      () => ClientInstanceIdentity(preferences: getIt<SharedPreferences>()),
    );
  }
  if (!getIt.isRegistered<String>(instanceName: 'clientInstanceId')) {
    getIt.registerSingleton<String>(
      await getIt<ClientInstanceIdentity>().load(),
      instanceName: 'clientInstanceId',
    );
  }
  if (!getIt.isRegistered<ClientDisplayMetadata>()) {
    getIt.registerSingleton<ClientDisplayMetadata>(
      await getIt<ClientInstanceIdentity>().metadata(),
    );
  }

  if (!getIt.isRegistered<AuthService>()) {
    getIt.registerLazySingleton<AuthService>(
      () => AuthService(
        clientInstanceId: getIt<String>(instanceName: 'clientInstanceId'),
        clientMetadata: getIt<ClientDisplayMetadata>(),
      ),
    );
  }

  if (!getIt.isRegistered<IAuthRepository>()) {
    getIt.registerLazySingleton<IAuthRepository>(
      () => AuthRepositoryImpl(getIt<AuthService>()),
    );
  }
  if (!getIt.isRegistered<AccountLifecycleRepository>()) {
    getIt.registerLazySingleton<AccountLifecycleRepository>(
      () => AccountLifecycleRepository(authService: getIt<AuthService>()),
    );
  }

  if (!getIt.isRegistered<WorkspaceToolRuntimeContext>()) {
    getIt.registerLazySingleton<WorkspaceToolRuntimeContext>(
      () => WorkspaceToolRuntimeContext(),
    );
  }

  if (!getIt.isRegistered<McpService>()) {
    getIt.registerLazySingleton<McpService>(
      () => McpService(
        workspaceRuntimeContext: getIt<WorkspaceToolRuntimeContext>(),
      ),
    );
  }

  if (!getIt.isRegistered<LocalToolRuntimeService>()) {
    getIt.registerLazySingleton<LocalToolRuntimeService>(
      () => LocalToolRuntimeService(
        mcpService: getIt<McpService>(),
        workspaceRuntimeContext: getIt<WorkspaceToolRuntimeContext>(),
        conversationRepository: getIt<ConversationRepository>(),
        deviceRepository: getIt<IDeviceRepository>(),
        toolApprovalService: getIt<ToolApprovalService>(),
        prefs: getIt<SharedPreferences>(),
        webSearchService: null,
      ),
    );
  }

  if (!getIt.isRegistered<ToolApprovalService>()) {
    getIt.registerLazySingleton<ToolApprovalService>(
      () => const ToolApprovalService(),
    );
  }

  if (!getIt.isRegistered<String>(instanceName: 'hardwareId')) {
    final hardwareId = await socketModule.hardwareId(
      getIt<SharedPreferences>(),
    );
    getIt.registerSingleton<String>(hardwareId, instanceName: 'hardwareId');
  }
  await startupTrace?.call('hardware-id-ready');

  if (!getIt.isRegistered<SanadSocketService>(
    instanceName: 'cloudSocketService',
  )) {
    getIt.registerLazySingleton<SanadSocketService>(
      () => socketModule.socketService(
        hardwareId: getIt<String>(instanceName: 'hardwareId'),
        clientInstanceId: getIt<String>(instanceName: 'clientInstanceId'),
        clientMetadata: getIt<ClientDisplayMetadata>(),
        accessToken: getIt<AuthService>().accessToken,
      ),
      instanceName: 'cloudSocketService',
    );
  }

  if (!getIt.isRegistered<SanadSocketService>(
    instanceName: 'localSocketService',
  )) {
    getIt.registerLazySingleton<SanadSocketService>(
      () => socketModule.localSocketService(
        hardwareId: getIt<String>(instanceName: 'hardwareId'),
        clientInstanceId: getIt<String>(instanceName: 'clientInstanceId'),
        clientMetadata: getIt<ClientDisplayMetadata>(),
      ),
      instanceName: 'localSocketService',
    );
  }

  if (!getIt.isRegistered<SanadSocketService>()) {
    getIt.registerLazySingleton<SanadSocketService>(
      () => getIt<SanadSocketService>(
        instanceName: !AppPlatform.isDesktop || AppConfig.enableCloudGateway
            ? 'cloudSocketService'
            : 'localSocketService',
      ),
    );
  }

  if (!getIt.isRegistered<ISocketService>()) {
    getIt.registerLazySingleton<ISocketService>(
      () => getIt<SanadSocketService>(),
    );
  }

  if (!getIt.isRegistered<LocalDaemonController>()) {
    getIt.registerLazySingleton<LocalDaemonController>(() {
      if (AppConfig.isSourceRun) {
        return const SourceDaemonController();
      } else {
        return const StandaloneDaemonController();
      }
    });
  }

  if (!getIt.isRegistered<DeviceConnectionCoordinator>()) {
    String appVersion = '1.0.0';
    try {
      final packageInfo = await PackageInfo.fromPlatform();
      appVersion = packageInfo.version.split('+').first;
    } catch (_) {}

    getIt.registerLazySingleton<DeviceConnectionCoordinator>(
      () => DeviceConnectionCoordinator(
        cloudSocketService: getIt<SanadSocketService>(
          instanceName: 'cloudSocketService',
        ),
        localSocketService: getIt<SanadSocketService>(
          instanceName: 'localSocketService',
        ),
        currentDeviceId: getIt<String>(instanceName: 'hardwareId'),
        daemonController: getIt<LocalDaemonController>(),
        expectedVersion: appVersion,
      ),
      dispose: (coordinator) => coordinator.dispose(),
    );
  }
  await startupTrace?.call('package-version-ready');

  if (!getIt.isRegistered<DeviceCapabilitiesStore>()) {
    getIt.registerLazySingleton<DeviceCapabilitiesStore>(
      () => DeviceCapabilitiesStore(getIt<DeviceConnectionCoordinator>()),
    );
  }

  if (!getIt.isRegistered<IDeviceClientRegistry>()) {
    getIt.registerFactory<IDeviceClientRegistry>(
      () => DeviceClientRegistryImpl(getIt<DeviceConnectionCoordinator>()),
    );
  }

  if (!getIt.isRegistered<ManagedConversationClientRegistry>()) {
    getIt.registerLazySingleton<ManagedConversationClientRegistry>(
      () => ConversationClientRegistryImpl(
        getIt<DeviceConnectionCoordinator>(),
        getIt<DeviceCapabilitiesStore>(),
      ),
      dispose: (registry) {
        if (registry is ConversationClientRegistryImpl) {
          registry.dispose();
        }
      },
    );
  }

  if (!getIt.isRegistered<ConversationRepository>()) {
    getIt.registerFactory<ConversationRepository>(
      () => SocketConversationRepository(
        getIt<ManagedConversationClientRegistry>(),
      ),
    );
  }

  // Conversation cache store (Plan 32b): single owner of conversation cache,
  // drafts, and per-device state. Lazily hydrated by the persistor.
  if (!getIt.isRegistered<ConversationCacheStore>()) {
    getIt.registerLazySingleton<ConversationCacheStore>(
      () => ConversationCacheStore(),
      dispose: (store) => store.dispose(),
    );
  }

  if (!getIt.isRegistered<ConversationCachePersistence>()) {
    getIt.registerLazySingleton<ConversationCachePersistence>(
      () => SharedPreferencesConversationCachePersistence(
        getIt<SharedPreferences>(),
      ),
    );
  }

  if (!getIt.isRegistered<ConversationCachePersistor>()) {
    getIt.registerLazySingleton<ConversationCachePersistor>(
      () => ConversationCachePersistor(
        store: getIt<ConversationCacheStore>(),
        persistence: getIt<ConversationCachePersistence>(),
      ),
      dispose: (persistor) => persistor.dispose(),
    );
  }

  if (!getIt.isRegistered<ConversationCacheRepository>()) {
    getIt.registerLazySingleton<ConversationCacheRepository>(
      () => ConversationCacheRepository(
        cache: getIt<ConversationCacheStore>(),
        transport: getIt<ConversationRepository>(),
        flushPersistence: getIt<ConversationCachePersistor>().flush,
      ),
    );
  }

  if (!getIt.isRegistered<IDeviceRepository>()) {
    getIt.registerFactory<IDeviceRepository>(
      () => DeviceRepositoryImpl(
        getIt<SanadSocketService>(instanceName: 'cloudSocketService'),
        getIt<DeviceConnectionCoordinator>(),
      ),
    );
  }

  if (!getIt.isRegistered<IDevicePreferencesRepository>()) {
    getIt.registerLazySingleton<IDevicePreferencesRepository>(
      () => DevicePreferencesRepositoryImpl(getIt<SharedPreferences>()),
    );
  }

  if (!getIt.isRegistered<DeviceCommandHandler>()) {
    getIt.registerLazySingleton<DeviceCommandHandler>(
      () => DeviceCommandHandler(
        localToolRuntime: getIt<LocalToolRuntimeService>(),
        sanadSocketController: getIt<SanadSocketService>(),
      ),
    );
  }

  if (!getIt.isRegistered<McpRuntimeClient>()) {
    if (!getIt.isRegistered<DeviceCommandClient>()) {
      getIt.registerLazySingleton<DeviceCommandClient>(
        () => DeviceCommandClient(
          connectionCoordinator: getIt<DeviceConnectionCoordinator>(),
        ),
      );
    }
    getIt.registerLazySingleton<McpRuntimeClient>(
      () => McpRuntimeClient(
        commandClient: getIt<DeviceCommandClient>(),
        defaultDevice: () => getIt<IDeviceRepository>().getActiveAgent(),
      ),
    );
  }

  if (!getIt.isRegistered<DeviceSettingsClient>()) {
    getIt.registerLazySingleton<DeviceSettingsClient>(
      () => DeviceSettingsClient(getIt<DeviceCommandClient>()),
    );
    getIt.registerLazySingleton<DeviceSkillsClient>(
      () => DeviceSkillsClient(getIt<DeviceCommandClient>()),
    );
  }

  if (!getIt.isRegistered<ProviderSetupClient>()) {
    getIt.registerLazySingleton<ProviderSetupClient>(
      () => ProviderSetupClientImpl(
        connectionCoordinator: getIt<DeviceConnectionCoordinator>(),
        commandClient: getIt<DeviceCommandClient>(),
      ),
    );
  }

  if (!getIt.isRegistered<ProviderUsageCubit>()) {
    getIt.registerLazySingleton<ProviderUsageCubit>(
      () => ProviderUsageCubit(client: getIt<ProviderSetupClient>()),
    );
  }

  if (!getIt.isRegistered<LocalToolExecutionCoordinator>()) {
    getIt.registerLazySingleton<LocalToolExecutionCoordinator>(
      () => LocalToolExecutionCoordinator(
        agentCommandHandler: getIt<DeviceCommandHandler>(),
        sanadSocketController: getIt<SanadSocketService>(),
        localToolRuntime: getIt<LocalToolRuntimeService>(),
      ),
    );
  }

  if (!getIt.isRegistered<AutoUpdateService>()) {
    getIt.registerLazySingleton<AutoUpdateService>(
      () => AutoUpdateService(
        beforeQuitForUpdate: () => getIt<ConversationCachePersistor>().flush(),
      ),
      dispose: (service) => service.dispose(),
    );
  }

  if (!getIt.isRegistered<ConversationHistoryController>()) {
    getIt.registerLazySingleton<ConversationHistoryController>(
      () => ConversationHistoryController(),
      dispose: (ctrl) => ctrl.dispose(),
    );
  }

  if (!getIt.isRegistered<AppState>()) {
    getIt.registerLazySingleton<AppState>(
      () => AppState(
        authService: getIt<AuthService>(),
        mcpController: getIt<McpService>(),
        localToolRuntime: getIt<LocalToolRuntimeService>(),
        brainSocketController: getIt<SanadSocketService>(),
        agentCommandHandler: getIt<DeviceCommandHandler>(),
        toolExecutionCoordinator: getIt<LocalToolExecutionCoordinator>(),
        autoUpdateService: getIt<AutoUpdateService>(),
        hardwareId: getIt<String>(instanceName: 'hardwareId'),
      ),
      dispose: (state) => state.dispose(),
    );
  }
}
