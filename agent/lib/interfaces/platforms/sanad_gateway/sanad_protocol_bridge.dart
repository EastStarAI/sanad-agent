import 'dart:io';

import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/appearance/appearance_store.dart';
import 'package:sanad_agent/core/app_config.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/update/agent_update_service.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_options_service.dart';
import 'package:sanad_agent/core/provider_runtime/model_selection_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_model_cache_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_state_service.dart';
import 'package:sanad_agent/core/provider_runtime/recent_model_selection_service.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_service.dart';
import 'package:sanad_agent/core/provider_runtime/runtime_recovery_service.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_preference_store.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_route_session_sync.dart';
import 'package:sanad_agent/core/provider_thinking/thinking_selection_resolver.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_catalog.dart';
import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/engine/compaction/compaction.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/evolution/db/user_secret_metadata_repository.dart';
import 'package:sanad_agent/interfaces/gateway_manager.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/device_settings_service.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';

import 'handlers/appearance_command_handler.dart';
import 'handlers/device_settings_command_handler.dart';
import 'handlers/device_control_command_handler.dart';
import 'handlers/provider_command_handler.dart';
import 'handlers/secret_command_handler.dart';
import 'handlers/session_fork_command_handler.dart';
import 'handlers/attachment_admission_command_handler.dart';
import 'handlers/session_query_handler.dart';
import 'handlers/session_recovery_command_handler.dart';
import 'handlers/session_compact_command_handler.dart';
import 'handlers/session_control_command_handler.dart';
import 'handlers/session_turn_replay_command_handler.dart';
import 'handlers/capability_discovery_command_handler.dart';
import 'handlers/computer_use_command_handler.dart';
import 'handlers/mcp_command_handler.dart';
import 'handlers/remote_cli_command_handler.dart';
import 'handlers/support/agent_event_envelope.dart' as canonical_envelope;
import 'handlers/workspace_command_handler.dart';
import 'protocol/canonical_command_translator.dart';
import 'protocol/canonical_events.dart';
import 'server_sanad_gateway_platform.dart';

import 'translators/agent_to_canonical.dart';
import 'translators/canonical_to_agent.dart';

class SanadProtocolBridge {
  final _logger = Logger('SanadProtocolBridge');

  ProviderCommandHandler? __providerHandler;
  SessionQueryHandler? __sessionQueryHandler;
  WorkspaceCommandHandler? __workspaceHandler;
  McpCommandHandler? __mcpHandler;
  CapabilityDiscoveryCommandHandler? __capabilityDiscoveryHandler;
  ComputerUseCommandHandler? __computerUseHandler;
  SessionRecoveryCommandHandler? __recoveryHandler;
  SessionTurnReplayCommandHandler? __turnReplayHandler;
  AttachmentAdmissionCommandHandler? __attachmentAdmissionHandler;
  SessionCompactCommandHandler? __compactHandler;
  SessionForkCommandHandler? __forkHandler;
  DeviceSettingsCommandHandler? __deviceSettingsHandler;
  DeviceControlCommandHandler? __deviceControlHandler;
  AppearanceCommandHandler? __appearanceHandler;
  RemoteCliCommandHandler? __remoteCliHandler;
  SessionControlCommandHandler? __sessionControlHandler;
  SecretCommandHandler? __secretHandler;

  /// Lazy accessors so optional runtime services registered after
  /// construction (e.g. in tests or deferred daemon startup) are only
  /// resolved when their handler is actually used.
  ProviderCommandHandler get _providerHandler =>
      __providerHandler ??= ProviderCommandHandler(
        catalog: getIt<ProviderCatalogService>(),
        instanceService: getIt<ProviderInstanceService>(),
        credentialService: getIt<ProviderCredentialService>(),
        authSession: getIt<ProviderAuthSessionService>(),
        cacheService: getIt<ProviderModelCacheService>(),
        repository: getIt<ProviderInstanceRepository>(),
        recentService: getIt<RecentModelSelectionService>(),
        modelOptions: getIt<ModelOptionsService>(),
        modelSelection: getIt<ModelSelectionService>(),
        readiness: getIt<ProviderReadinessService>(),
        state: getIt<ProviderStateService>(),
        config: getIt.isRegistered<Config>() ? getIt<Config>() : null,
        agentRuntime: getIt.isRegistered<AgentRuntimeService>()
            ? getIt<AgentRuntimeService>()
            : null,
        usageService: getIt.isRegistered<ProviderUsageService>()
            ? getIt<ProviderUsageService>()
            : null,
        bridge: this,
      );

  SessionQueryHandler get _sessionQueryHandler =>
      __sessionQueryHandler ??= SessionQueryHandler(
        sessionManager: getIt<SessionManager>(),
        orchestrator: getIt.isRegistered<SessionRunOrchestrator>()
            ? getIt<SessionRunOrchestrator>()
            : null,
        runtimeRecovery: getIt.isRegistered<RuntimeRecoveryService>()
            ? getIt<RuntimeRecoveryService>()
            : null,
        persistedState: getIt.isRegistered<PersistedRuntimeStateRepository>()
            ? getIt<PersistedRuntimeStateRepository>()
            : null,
        routeCoordinator: getIt.isRegistered<SessionRouteMutationCoordinator>()
            ? getIt<SessionRouteMutationCoordinator>()
            : null,
        routeTransitions: getIt.isRegistered<SessionRouteTransitionRepository>()
            ? getIt<SessionRouteTransitionRepository>()
            : null,
        thinkingSelectionResolver:
            getIt.isRegistered<ThinkingSelectionResolver>()
            ? getIt<ThinkingSelectionResolver>()
            : null,
        thinkingPreferenceStore:
            getIt.isRegistered<ThinkingRoutePreferenceStore>()
            ? getIt<ThinkingRoutePreferenceStore>()
            : null,
        thinkingRouteSessionSync: getIt.isRegistered<ThinkingRouteSessionSync>()
            ? getIt<ThinkingRouteSessionSync>()
            : null,
        compactionBoundaries: getIt.isRegistered<CompactionBoundaryRepository>()
            ? getIt<CompactionBoundaryRepository>()
            : null,
        bridge: this,
      );

  WorkspaceCommandHandler get _workspaceHandler =>
      __workspaceHandler ??= WorkspaceCommandHandler(
        runtimeService: getIt<LocalWorkspaceRuntimeService>(),
        policyStore: getIt.isRegistered<WorkspacePolicyStore>()
            ? getIt<WorkspacePolicyStore>()
            : null,
        admission: getIt.isRegistered<DeviceCommandAdmission>()
            ? getIt<DeviceCommandAdmission>()
            : null,
      );

  McpCommandHandler get _mcpHandler =>
      __mcpHandler ??= McpCommandHandler(
        runtimeService: getIt<LocalWorkspaceRuntimeService>(),
        admission: getIt.isRegistered<DeviceCommandAdmission>()
            ? getIt<DeviceCommandAdmission>()
            : null,
      );

  CapabilityDiscoveryCommandHandler get _capabilityDiscoveryHandler =>
      __capabilityDiscoveryHandler ??= CapabilityDiscoveryCommandHandler(
        runtimeService: getIt<LocalWorkspaceRuntimeService>(),
      );

  ComputerUseCommandHandler get _computerUseHandler =>
      __computerUseHandler ??= ComputerUseCommandHandler(
        envFileService: getIt.isRegistered<EnvFileService>()
            ? getIt<EnvFileService>()
            : null,
      );

  DeviceSettingsCommandHandler get _deviceSettingsHandler =>
      __deviceSettingsHandler ??= DeviceSettingsCommandHandler(
        settings: getIt<DeviceSettingsService>(),
        bridge: this,
      );

  AppearanceCommandHandler get _appearanceHandler =>
      __appearanceHandler ??= AppearanceCommandHandler(
        store: getIt.isRegistered<AppearanceStore>()
            ? getIt<AppearanceStore>()
            : const AppearanceStore(),
        bridge: this,
      );

  RemoteCliCommandHandler get _remoteCliHandler =>
      __remoteCliHandler ??= RemoteCliCommandHandler(
        bridge: this,
        authManager: getIt<AuthManager>(),
        workspaceRuntime: getIt.isRegistered<LocalWorkspaceRuntimeService>()
            ? getIt<LocalWorkspaceRuntimeService>()
            : null,
        registeredDeviceId: () {
          if (!getIt.isRegistered<ServerSanadGatewayPlatform>()) return null;
          return getIt<ServerSanadGatewayPlatform>().registeredDeviceId;
        },
      );

  void setRemoteCliHandlerForTesting(RemoteCliCommandHandler? handler) {
    __remoteCliHandler = handler;
  }

  SecretCommandHandler get _secretHandler =>
      __secretHandler ??= SecretCommandHandler(
        catalog: getIt.isRegistered<UserSecretCatalog>()
            ? getIt<UserSecretCatalog>()
            : UserSecretCatalog(
                vault: UserSecretVault(),
                metadata: getIt.isRegistered<UserSecretMetadataRepository>()
                    ? getIt<UserSecretMetadataRepository>()
                    : UserSecretMetadataRepository(
                        getIt<AgentStateDatabase>(),
                      ),
              ),
        bridge: this,
        broadcastFamilyEvent: (event) {
          if (getIt.isRegistered<GatewayManager>()) {
            getIt<GatewayManager>().publishFamilyEvent(event);
          }
        },
      );

  void setSecretCommandHandlerForTesting(SecretCommandHandler? handler) {
    __secretHandler = handler;
  }

  DeviceControlCommandHandler? get _deviceControlHandler {
    if (__deviceControlHandler != null) return __deviceControlHandler;
    if (getIt.isRegistered<DeviceControlCommandHandler>()) {
      return __deviceControlHandler = getIt<DeviceControlCommandHandler>();
    }
    if (!getIt.isRegistered<DeviceCommandAdmission>() ||
        !getIt.isRegistered<DaemonRestartCoordinator>() ||
        !getIt.isRegistered<Config>()) {
      return null;
    }
    return __deviceControlHandler = DeviceControlCommandHandler(
      admission: getIt<DeviceCommandAdmission>(),
      bridge: this,
      restartCoordinator: getIt<DaemonRestartCoordinator>(),
      updateService: () => AgentUpdateService(
        currentVersion: getIt<Config>().version,
        executablePath: Platform.resolvedExecutable,
        isSourceManaged: AppConfig.isSourceRun,
      ),
    );
  }

  SessionRecoveryCommandHandler? get _recoveryHandler => __recoveryHandler ??=
      (getIt.isRegistered<RuntimeRecoveryService>() &&
          getIt.isRegistered<SessionRunOrchestrator>() &&
          getIt.isRegistered<SessionManager>() &&
          getIt.isRegistered<ProviderInstanceRepository>())
      ? SessionRecoveryCommandHandler(
          recovery: getIt<RuntimeRecoveryService>(),
          orchestrator: getIt<SessionRunOrchestrator>(),
          sessionManager: getIt<SessionManager>(),
          instanceRepository: getIt<ProviderInstanceRepository>(),
          routeCoordinator:
              getIt.isRegistered<SessionRouteMutationCoordinator>()
              ? getIt<SessionRouteMutationCoordinator>()
              : null,
          bridge: this,
        )
      : null;

  SessionTurnReplayCommandHandler? get _turnReplayHandler =>
      __turnReplayHandler ??=
          (getIt.isRegistered<SessionRunOrchestrator>() &&
              getIt.isRegistered<SessionManager>())
          ? SessionTurnReplayCommandHandler(
              orchestrator: getIt<SessionRunOrchestrator>(),
              sessionManager: getIt<SessionManager>(),
              persistedState:
                  getIt.isRegistered<PersistedRuntimeStateRepository>()
                  ? getIt<PersistedRuntimeStateRepository>()
                  : null,
              compactionBoundaries:
                  getIt.isRegistered<CompactionBoundaryRepository>()
                  ? getIt<CompactionBoundaryRepository>()
                  : null,
              attachmentStore: getIt.isRegistered<AttachmentStore>()
                  ? getIt<AttachmentStore>()
                  : null,
              bridge: this,
            )
          : null;

  AttachmentAdmissionCommandHandler? get _attachmentAdmissionHandler =>
      __attachmentAdmissionHandler ??= getIt.isRegistered<AttachmentStore>()
      ? AttachmentAdmissionCommandHandler(
          store: getIt<AttachmentStore>(),
          bridge: this,
        )
      : null;

  SessionCompactCommandHandler? get _compactHandler =>
      __compactHandler ??= getIt.isRegistered<SessionRunOrchestrator>()
      ? SessionCompactCommandHandler(
          orchestrator: getIt<SessionRunOrchestrator>(),
          bridge: this,
        )
      : null;

  SessionControlCommandHandler get _sessionControlHandler =>
      __sessionControlHandler ??= SessionControlCommandHandler(
        orchestrator: getIt<SessionRunOrchestrator>(),
        persistedState: getIt.isRegistered<PersistedRuntimeStateRepository>()
            ? getIt<PersistedRuntimeStateRepository>()
            : null,
      );

  SessionForkCommandHandler? get _forkHandler =>
      __forkHandler ??= getIt.isRegistered<SessionManager>()
      ? SessionForkCommandHandler(
          sessionManager: getIt<SessionManager>(),
          bridge: this,
        )
      : null;

  GatewayEvent? translateCommand(Map<String, dynamic> data, String platformId) {
    return CanonicalToAgent.translate(data, platformId);
  }

  CanonicalEvent translateResponse(GatewayResponse response) {
    final metadata = response.message.metadata;
    final canonicalEventType = metadata?['canonical_event_type'] as String?;
    final rawCanonicalPayload = metadata?['canonical_payload'];
    final canonicalPayload = rawCanonicalPayload is Map<String, dynamic>
        ? rawCanonicalPayload
        : rawCanonicalPayload is Map
        ? Map<String, dynamic>.from(rawCanonicalPayload)
        : null;
    if (canonicalEventType != null && canonicalPayload != null) {
      return CanonicalEvent(
        type: canonicalEventType,
        sessionId: response.sessionId,
        runId: response.runId,
        payload: {
          ...canonicalPayload,
          if (response.turnId != null &&
              !canonicalPayload.containsKey('turn_id'))
            'turn_id': response.turnId,
        },
        eventId: response.eventId,
        delivery: response.delivery,
      );
    }
    return AgentToCanonical.translate(response);
  }

  Future<bool> handleCommand(
    Map<String, dynamic> data,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final event = CanonicalCommandTranslator.translate(data);
    if (event == null) {
      return false;
    }

    await handleProtocolEvent(event, emitEnvelope);
    return true;
  }

  Future<void> handleProtocolEvent(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    switch (event.type) {
      case 'attachment.admit':
        final handler = _attachmentAdmissionHandler;
        if (handler != null) {
          await handler.handle(event, emitEnvelope);
        }
        return;
      case CanonicalEventTypes.getSessionHistory:
        await emitEnvelope(_sessionQueryHandler.buildHistoryEnvelope(event));
        return;
      case CanonicalEventTypes.sessionPendingSteerCancel:
      case CanonicalEventTypes.sessionQueuedMessageDelete:
      case CanonicalEventTypes.sessionStopRecoveryAck:
      case CanonicalEventTypes.sessionStopRecoveryClaim:
        await _sessionControlHandler.handle(event, emitEnvelope);
        return;
      case CanonicalEventTypes.getSessions:
        await emitEnvelope(_sessionQueryHandler.buildThreadsEnvelope(event));
        return;
      case CanonicalEventTypes.searchSessions:
        await emitEnvelope(_sessionQueryHandler.buildSearchEnvelope(event));
        return;
      case CanonicalEventTypes.updateSessionTitle:
        final envelope = _sessionQueryHandler.buildUpdateSessionTitleEnvelope(
          event,
        );
        if (envelope != null) {
          await emitEnvelope(envelope);
        }
        return;
      case CanonicalEventTypes.deleteSession:
        final envelope = _sessionQueryHandler.buildDeleteSessionEnvelope(event);
        if (envelope != null) {
          await emitEnvelope(envelope);
        }
        return;
      case CanonicalEventTypes.updateSessionPreferences:
        final envelope = _sessionQueryHandler.buildSessionPreferencesEnvelope(
          event,
        );
        if (envelope != null) {
          await emitEnvelope(envelope);
        }
        return;
      case CanonicalEventTypes.listWorkspaces:
        await emitEnvelope(
          await _workspaceHandler.buildWorkspacesEnvelope(event),
        );
        return;
      case CanonicalEventTypes.createWorkspace:
        await emitEnvelope(
          await _workspaceHandler.buildCreateWorkspaceEnvelope(event),
        );
        return;
      case CanonicalEventTypes.renameWorkspace:
        await emitEnvelope(
          await _workspaceHandler.buildRenameWorkspaceEnvelope(event),
        );
        return;
      case CanonicalEventTypes.removeWorkspace:
        await emitEnvelope(
          await _workspaceHandler.buildRemoveWorkspaceEnvelope(event),
        );
        return;
      case CanonicalEventTypes.relocateWorkspace:
        await emitEnvelope(
          await _workspaceHandler.buildRelocateWorkspaceEnvelope(event),
        );
        return;
      case CanonicalEventTypes.browseWorkspaceTree:
        await emitEnvelope(
          await _workspaceHandler.buildWorkspaceTreeEnvelope(event),
        );
        return;
      case CanonicalEventTypes.createFolder:
        await emitEnvelope(
          await _workspaceHandler.buildCreateFolderEnvelope(event),
        );
        return;
      case CanonicalEventTypes.renameFolder:
        await emitEnvelope(
          await _workspaceHandler.buildRenameFolderEnvelope(event),
        );
        return;
      case CanonicalEventTypes.deleteFolder:
        await emitEnvelope(
          await _workspaceHandler.buildDeleteFolderEnvelope(event),
        );
        return;
      case CanonicalEventTypes.listMcpServers:
        await emitEnvelope(
          await _mcpHandler.buildMcpServersEnvelope(event),
        );
        return;
      case CanonicalEventTypes.saveMcpServer:
        await emitEnvelope(
          await _mcpHandler.buildSaveMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.deleteMcpServer:
        await emitEnvelope(
          await _mcpHandler.buildDeleteMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.replaceMcpConfig:
        await emitEnvelope(
          await _mcpHandler.buildReplaceMcpConfigEnvelope(event),
        );
        return;
      case CanonicalEventTypes.inspectMcpServer:
        await emitEnvelope(
          await _mcpHandler.buildInspectMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.previewMcpImport:
        await emitEnvelope(
          await _mcpHandler.buildPreviewMcpImportEnvelope(event),
        );
        return;
      case CanonicalEventTypes.exportMcpServers:
        await emitEnvelope(
          await _mcpHandler.buildExportMcpServersEnvelope(event),
        );
        return;
      case CanonicalEventTypes.readAdvancedMcpServer:
        await emitEnvelope(
          await _mcpHandler.buildReadAdvancedMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.previewAdvancedMcpServer:
        await emitEnvelope(
          await _mcpHandler.buildPreviewAdvancedMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.saveAdvancedMcpServer:
        await emitEnvelope(
          await _mcpHandler.buildSaveAdvancedMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.startMcpOAuth:
        await emitEnvelope(
          await _mcpHandler.buildStartMcpOAuthEnvelope(event),
        );
        return;
      case CanonicalEventTypes.getMcpOAuthStatus:
        await emitEnvelope(
          await _mcpHandler.buildMcpOAuthStatusEnvelope(event),
        );
        return;
      case CanonicalEventTypes.cancelMcpOAuth:
        await emitEnvelope(
          await _mcpHandler.buildCancelMcpOAuthEnvelope(event),
        );
        return;
      case CanonicalEventTypes.completeMcpOAuth:
        await emitEnvelope(
          await _mcpHandler.buildCompleteMcpOAuthEnvelope(event),
        );
        return;
      case CanonicalEventTypes.searchSlashCommands:
        await emitEnvelope(
          await _capabilityDiscoveryHandler.buildSlashCommandsEnvelope(event),
        );
        return;
      case CanonicalEventTypes.listSkills:
        await emitEnvelope(await _capabilityDiscoveryHandler.buildSkillsEnvelope(event));
        return;
      case CanonicalEventTypes.deviceSettingsGet:
        await emitEnvelope(
          await _deviceSettingsHandler.buildSnapshotEnvelope(event),
        );
        return;
      case CanonicalEventTypes.deviceSettingsUpdate:
        final result = await _deviceSettingsHandler.buildUpdateEnvelope(event);
        await emitEnvelope(result.envelope);
        if (result.restartRequired) {
          getIt<DaemonRestartCoordinator>().scheduleRestart();
        }
        return;
      case CanonicalEventTypes.getAppearance:
        await emitEnvelope(
          await _appearanceHandler.buildSnapshotEnvelope(event),
        );
        return;
      case CanonicalEventTypes.updateAppearance:
        await emitEnvelope(await _appearanceHandler.buildUpdateEnvelope(event));
        return;
      case CanonicalEventTypes.deviceUpdateCheck:
      case CanonicalEventTypes.deviceUpdateApply:
      case CanonicalEventTypes.deviceRuntimeRestart:
        final handler = _deviceControlHandler;
        if (handler == null) return;
        await emitEnvelope(
          await handler.buildEnvelope(
            event,
            deviceId: event.payload['device_id']?.toString(),
          ),
        );
        return;
      case CanonicalEventTypes.deviceCliExecute:
        await _remoteCliHandler.handleExecute(event, emitEnvelope);
        return;
      case CanonicalEventTypes.deviceCliCancel:
        await _remoteCliHandler.handleCancel(event, emitEnvelope);
        return;
      case CanonicalEventTypes.providerSetupStatus:
        await emitEnvelope(
          _providerHandler.buildProviderReadinessEnvelope(
            event,
            isRuntimeCheck: false,
          ),
        );
        return;
      case CanonicalEventTypes.providerRuntimeCheck:
        await emitEnvelope(
          _providerHandler.buildProviderReadinessEnvelope(
            event,
            isRuntimeCheck: true,
          ),
        );
        return;
      case CanonicalEventTypes.providerAuthStart:
        await emitEnvelope(
          await _providerHandler.buildProviderAuthStartEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerAuthPoll:
        await emitEnvelope(
          await _providerHandler.buildProviderAuthPollEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerAuthSubmit:
        await emitEnvelope(
          await _providerHandler.buildProviderAuthSubmitEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerAuthCancel:
        await emitEnvelope(
          _providerHandler.buildProviderAuthCancelEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerAuthStatus:
        await emitEnvelope(
          _providerHandler.buildProviderAuthStatusEnvelope(event),
        );
        return;
      case CanonicalEventTypes.modelOptions:
        await emitEnvelope(
          await _providerHandler.buildModelOptionsEnvelope(event),
        );
        return;
      case CanonicalEventTypes.modelRecommendedDefault:
        await emitEnvelope(
          _providerHandler.buildModelRecommendedDefaultEnvelope(event),
        );
        return;
      case CanonicalEventTypes.modelSetDefault:
        await emitEnvelope(
          await _providerHandler.buildModelSetDefaultEnvelope(event),
        );
        if (getIt.isRegistered<AgentRuntimeService>()) {
          getIt<AgentRuntimeService>().invalidate();
        }
        await emitEnvelope(
          await _providerHandler.buildCapabilitiesChangedEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerConfiguredOptions:
        await emitEnvelope(
          await _providerHandler.buildProviderConfiguredOptionsEnvelope(event),
        );
        return;
      case CanonicalEventTypes.systemCheckComputerUsePermissions:
        await emitEnvelope(
          await _computerUseHandler.buildCheckComputerUsePermissionsEnvelope(
            event,
          ),
        );
        return;
      case CanonicalEventTypes.systemRequestComputerUsePermissions:
        await emitEnvelope(
          await _computerUseHandler.buildRequestComputerUsePermissionsEnvelope(
            event,
          ),
        );
        return;
      case CanonicalEventTypes.systemToggleComputerUse:
        await emitEnvelope(
          await _computerUseHandler.buildToggleComputerUseEnvelope(event),
        );
        await emitEnvelope(
          await _providerHandler.buildCapabilitiesChangedEnvelope(event),
        );
        return;
      case CanonicalEventTypes.workspaceGetPolicy:
        await emitEnvelope(
          await _workspaceHandler.buildWorkspaceGetPolicyEnvelope(event),
        );
        return;
      case CanonicalEventTypes.workspaceSetPermissionMode:
        await emitEnvelope(
          await _workspaceHandler.buildWorkspaceSetPermissionModeEnvelope(
            event,
            emitEnvelope,
          ),
        );
        return;
      case CanonicalEventTypes.providerTemplatesList:
        await emitEnvelope(
          await _providerHandler.buildTemplatesListEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerInstancesList:
        await emitEnvelope(
          await _providerHandler.buildInstancesListEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerInstanceCreate:
        await emitEnvelope(
          await _providerHandler.buildInstanceCreateEnvelope(event),
        );
        await emitEnvelope(
          await _providerHandler.buildInstancesChangedBroadcastEnvelope(),
        );
        return;
      case CanonicalEventTypes.providerInstanceUpdate:
        await emitEnvelope(
          await _providerHandler.buildInstanceUpdateEnvelope(event),
        );
        await emitEnvelope(
          await _providerHandler.buildInstancesChangedBroadcastEnvelope(),
        );
        return;
      case CanonicalEventTypes.providerInstanceRename:
        await emitEnvelope(
          await _providerHandler.buildInstanceRenameEnvelope(event),
        );
        await emitEnvelope(
          await _providerHandler.buildInstancesChangedBroadcastEnvelope(),
        );
        return;
      case CanonicalEventTypes.providerInstanceRemove:
        await emitEnvelope(
          await _providerHandler.buildInstanceRemoveEnvelope(event),
        );
        await emitEnvelope(
          await _providerHandler.buildInstancesChangedBroadcastEnvelope(),
        );
        return;
      case CanonicalEventTypes.providerInstanceSetDefault:
        await emitEnvelope(
          await _providerHandler.buildInstanceSetDefaultEnvelope(event),
        );
        await emitEnvelope(
          await _providerHandler.buildInstancesChangedBroadcastEnvelope(),
        );
        return;
      case CanonicalEventTypes.providerInstanceTest:
        await emitEnvelope(
          await _providerHandler.buildInstanceTestEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerCredentialUpdate:
        await emitEnvelope(
          await _providerHandler.buildCredentialUpdateEnvelope(event),
        );
        await emitEnvelope(
          await _providerHandler.buildInstancesChangedBroadcastEnvelope(),
        );
        return;
      case CanonicalEventTypes.providerAuthReconnect:
        await emitEnvelope(
          await _providerHandler.buildAuthReconnectEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerAuthDisconnect:
        await emitEnvelope(
          await _providerHandler.buildAuthDisconnectEnvelope(event),
        );
        await emitEnvelope(
          await _providerHandler.buildInstancesChangedBroadcastEnvelope(),
        );
        return;
      case CanonicalEventTypes.modelSnapshot:
        await emitEnvelope(
          await _providerHandler.buildModelSnapshotEnvelope(event),
        );
        return;
      case CanonicalEventTypes.modelRefresh:
        await _providerHandler.handleModelRefreshCommand(event, emitEnvelope);
        return;
      case CanonicalEventTypes.modelRecentList:
        await emitEnvelope(
          await _providerHandler.buildModelRecentListEnvelope(event),
        );
        return;
      case CanonicalEventTypes.modelRecentRecord:
        await emitEnvelope(
          await _providerHandler.buildModelRecentRecordEnvelope(event),
        );
        return;
      // Task 55: provider account usage limits.
      case CanonicalEventTypes.providerUsageGet:
        await emitEnvelope(await _providerHandler.buildUsageGetEnvelope(event));
        return;
      case CanonicalEventTypes.providerUsageReset:
        await emitEnvelope(
          await _providerHandler.buildUsageResetEnvelope(event),
        );
        return;
      case CanonicalEventTypes.providerUsageSupport:
        await emitEnvelope(
          await _providerHandler.buildUsageSupportEnvelope(event),
        );
        return;
      // Task 49: historical turn edit/retry.
      case CanonicalEventTypes.sessionTurnReplay:
        await _turnReplayHandler?.handle(event, emitEnvelope);
        return;
      case CanonicalEventTypes.sessionCompact:
        try {
          await _compactHandler?.handle(event, emitEnvelope);
        } catch (error) {
          // Last-resort containment for the compaction command. Internal logs
          // are not exempt from the no-sensitive-payload rule: only allowlisted
          // diagnostics and bounded metadata may be logged, never raw
          // exception values, stack traces, unconstrained transport identifiers, or payload content.
          final diagnostics = CompactionDiagnostics.classify(error);
          _logger.warning(
            'Contained sessionCompact failure '
            '(stage=${diagnostics.stage}, cause=${diagnostics.cause}, '
            'has_session_id=${event.sessionId != null && event.sessionId!.isNotEmpty}, '
            'has_request_id=${event.payload['request_id'] != null && event.payload['request_id'].toString().isNotEmpty})',
          );
        }
        return;
      case CanonicalEventTypes.sessionFork:
        await _forkHandler?.handle(event, emitEnvelope);
        return;
      // Plan 30: runtime recovery commands
      case CanonicalEventTypes.sessionRuntimeRetry:
        await _recoveryHandler?.handleRuntimeRetry(event, emitEnvelope);
        return;
      case CanonicalEventTypes.sessionRuntimeStop:
        await _recoveryHandler?.handleRuntimeStop(event);
        return;
      case CanonicalEventTypes.sessionRuntimeContinueWithProvider:
        await _recoveryHandler?.handleRuntimeContinueWithProvider(
          event,
          emitEnvelope,
        );
        return;
      // Task 140: user secrets protocol.
      case CanonicalEventTypes.secretsList:
      case CanonicalEventTypes.secretSet:
      case CanonicalEventTypes.secretDelete:
        await _secretHandler.handle(event, emitEnvelope);
        return;

      default:
        _logger.fine('Ignoring unsupported protocol event: ${event.type}');
        return;
    }
  }

  Map<String, dynamic> buildAgentEventEnvelope(CanonicalEvent canonicalEvent) =>
      canonical_envelope.buildAgentEventEnvelope(canonicalEvent);
}
