import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/core/agent_runtime_service.dart';
import 'package:sanad_agent/core/auth/auth_manager.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
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
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_mutation_coordinator.dart';
import 'package:sanad_agent/evolution/db/runtime/session_route_transition_repository.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/daemon_restart_coordinator.dart';
import 'package:sanad_agent/interfaces/runtime/device_settings_service.dart';

import 'handlers/device_settings_command_handler.dart';
import 'handlers/provider_command_handler.dart';
import 'handlers/session_query_handler.dart';
import 'handlers/session_recovery_command_handler.dart';
import 'handlers/session_turn_replay_command_handler.dart';
import 'handlers/workspace_command_handler.dart';
import 'protocol/canonical_events.dart';

import 'translators/agent_to_canonical.dart';
import 'translators/canonical_to_agent.dart';

class SanadProtocolBridge {
  final _logger = Logger('SanadProtocolBridge');

  ProviderCommandHandler? __providerHandler;
  SessionQueryHandler? __sessionQueryHandler;
  WorkspaceCommandHandler? __workspaceHandler;
  SessionRecoveryCommandHandler? __recoveryHandler;
  SessionTurnReplayCommandHandler? __turnReplayHandler;
  DeviceSettingsCommandHandler? __deviceSettingsHandler;

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
        bridge: this,
      );

  WorkspaceCommandHandler get _workspaceHandler =>
      __workspaceHandler ??= WorkspaceCommandHandler(
        runtimeService: getIt<LocalWorkspaceRuntimeService>(),
        envFileService: getIt.isRegistered<EnvFileService>()
            ? getIt<EnvFileService>()
            : null,
        policyStore: getIt.isRegistered<WorkspacePolicyStore>()
            ? getIt<WorkspacePolicyStore>()
            : null,
        bridge: this,
      );

  DeviceSettingsCommandHandler get _deviceSettingsHandler =>
      __deviceSettingsHandler ??= DeviceSettingsCommandHandler(
        settings: getIt<DeviceSettingsService>(),
        bridge: this,
      );

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
              bridge: this,
            )
          : null;

  SanadProtocolBridge();

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
        payload: canonicalPayload,
        eventId: response.eventId,
        delivery: response.delivery,
      );
    }
    final event = AgentToCanonical.translate(response);

    final sessionManager = getIt<SessionManager>();
    if (event.type == CanonicalEventTypes.thoughtStream ||
        event.type == CanonicalEventTypes.reasoningStream) {
      final sessionId = response.sessionId;
      final runId = response.runId ?? '';
      final deltaContent =
          response.message.reasoning ??
          response.message.thought ??
          response.message.content ??
          '';

      if (deltaContent.isNotEmpty) {
        final existing = sessionManager.getInFlightSnapshot(sessionId);
        var content = deltaContent;
        if (existing != null &&
            existing['type'] == event.type &&
            existing['run_id'] == runId &&
            existing['content'] is String) {
          content = '${existing['content']}$deltaContent';
        }
        final timestamp = DateTime.now().millisecondsSinceEpoch;

        sessionManager.saveInFlightSnapshot(sessionId, {
          'type': event.type,
          'status': 'running',
          'session_id': sessionId,
          'run_id': runId,
          'model_step_id': response.modelStepId,
          'content': content,
          'timestamp': timestamp,
          'updated_at': timestamp,
        });
      }
    } else if (event.type == CanonicalEventTypes.thought ||
        event.type == CanonicalEventTypes.reasoning ||
        event.type == CanonicalEventTypes.finalAnswer ||
        event.type == 'stopped' ||
        event.type == 'error' ||
        event.type == 'user_message') {
      sessionManager.clearInFlightSnapshot(response.sessionId);
    }

    return event;
  }

  Future<bool> handleCommand(
    Map<String, dynamic> data,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final command = data['command'] as String?;
    final payload = _readPayload(data);
    final sessionId = payload['session_id'] as String?;

    CanonicalEvent? event;
    switch (command) {
      case 'get_sessions':
        event = CanonicalEvent(
          type: CanonicalEventTypes.getSessions,
          payload: payload,
        );
      case 'get_session_history':
        event = CanonicalEvent(
          type: CanonicalEventTypes.getSessionHistory,
          sessionId: sessionId,
          payload: payload,
        );
      case 'delete_session':
        event = CanonicalEvent(
          type: CanonicalEventTypes.deleteSession,
          sessionId: sessionId,
          payload: payload,
        );
      case 'update_session_title':
        event = CanonicalEvent(
          type: CanonicalEventTypes.updateSessionTitle,
          sessionId: sessionId,
          payload: payload,
        );
      case 'update_session_preferences':
        event = CanonicalEvent(
          type: CanonicalEventTypes.updateSessionPreferences,
          sessionId: sessionId,
          payload: payload,
        );
      case 'list_workspaces':
        event = CanonicalEvent(
          type: CanonicalEventTypes.listWorkspaces,
          payload: payload,
        );
      case 'create_workspace':
        event = CanonicalEvent(
          type: CanonicalEventTypes.createWorkspace,
          payload: payload,
        );
      case 'workspace.rename':
        event = CanonicalEvent(
          type: CanonicalEventTypes.renameWorkspace,
          payload: payload,
        );
      case 'workspace.relocate':
        event = CanonicalEvent(
          type: CanonicalEventTypes.relocateWorkspace,
          payload: payload,
        );
      case 'browse_workspace_tree':
        event = CanonicalEvent(
          type: CanonicalEventTypes.browseWorkspaceTree,
          payload: payload,
        );
      case 'workspace.create_folder':
        event = CanonicalEvent(
          type: CanonicalEventTypes.createFolder,
          payload: payload,
        );
      case 'workspace.rename_folder':
        event = CanonicalEvent(
          type: CanonicalEventTypes.renameFolder,
          payload: payload,
        );
      case 'workspace.delete_folder':
        event = CanonicalEvent(
          type: CanonicalEventTypes.deleteFolder,
          payload: payload,
        );
      case 'list_mcp_servers':
        event = CanonicalEvent(
          type: CanonicalEventTypes.listMcpServers,
          payload: payload,
        );
      case 'save_mcp_server':
        event = CanonicalEvent(
          type: CanonicalEventTypes.saveMcpServer,
          payload: payload,
        );
      case 'delete_mcp_server':
        event = CanonicalEvent(
          type: CanonicalEventTypes.deleteMcpServer,
          payload: payload,
        );
      case 'replace_mcp_config':
        event = CanonicalEvent(
          type: CanonicalEventTypes.replaceMcpConfig,
          payload: payload,
        );
      case 'inspect_mcp_server':
        event = CanonicalEvent(
          type: CanonicalEventTypes.inspectMcpServer,
          payload: payload,
        );
      case 'preview_mcp_import':
        event = CanonicalEvent(
          type: CanonicalEventTypes.previewMcpImport,
          payload: payload,
        );
      case 'export_mcp_servers':
        event = CanonicalEvent(
          type: CanonicalEventTypes.exportMcpServers,
          payload: payload,
        );
      case 'read_advanced_mcp_server':
        event = CanonicalEvent(
          type: CanonicalEventTypes.readAdvancedMcpServer,
          payload: payload,
        );
      case 'preview_advanced_mcp_server':
        event = CanonicalEvent(
          type: CanonicalEventTypes.previewAdvancedMcpServer,
          payload: payload,
        );
      case 'save_advanced_mcp_server':
        event = CanonicalEvent(
          type: CanonicalEventTypes.saveAdvancedMcpServer,
          payload: payload,
        );
      case 'start_mcp_oauth':
        event = CanonicalEvent(
          type: CanonicalEventTypes.startMcpOAuth,
          payload: payload,
        );
      case 'get_mcp_oauth_status':
        event = CanonicalEvent(
          type: CanonicalEventTypes.getMcpOAuthStatus,
          payload: payload,
        );
      case 'cancel_mcp_oauth':
        event = CanonicalEvent(
          type: CanonicalEventTypes.cancelMcpOAuth,
          payload: payload,
        );
      case 'complete_mcp_oauth':
        event = CanonicalEvent(
          type: CanonicalEventTypes.completeMcpOAuth,
          payload: payload,
        );
      case 'search_slash_commands':
        event = CanonicalEvent(
          type: CanonicalEventTypes.searchSlashCommands,
          payload: payload,
        );
      case 'list_skills':
        event = CanonicalEvent(
          type: CanonicalEventTypes.listSkills,
          payload: payload,
        );
      case 'device.settings.get':
        event = CanonicalEvent(
          type: CanonicalEventTypes.deviceSettingsGet,
          payload: payload,
        );
      case 'device.settings.update':
        event = CanonicalEvent(
          type: CanonicalEventTypes.deviceSettingsUpdate,
          payload: payload,
        );
      case 'provider.setup_status':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerSetupStatus,
          payload: payload,
        );
      case 'provider.runtime_check':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerRuntimeCheck,
          payload: payload,
        );
      case 'provider.auth.start':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerAuthStart,
          payload: payload,
        );
      case 'provider.auth.poll':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerAuthPoll,
          payload: payload,
        );
      case 'provider.auth.submit':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerAuthSubmit,
          payload: payload,
        );
      case 'provider.auth.cancel':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerAuthCancel,
          payload: payload,
        );
      case 'provider.auth.status':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerAuthStatus,
          payload: payload,
        );
      case 'model.options':
        event = CanonicalEvent(
          type: CanonicalEventTypes.modelOptions,
          payload: payload,
        );
      case 'model.recommended_default':
        event = CanonicalEvent(
          type: CanonicalEventTypes.modelRecommendedDefault,
          payload: payload,
        );
      case 'model.set_default':
        event = CanonicalEvent(
          type: CanonicalEventTypes.modelSetDefault,
          payload: payload,
        );
      case 'system.check_computer_use_permissions':
        event = CanonicalEvent(
          type: CanonicalEventTypes.systemCheckComputerUsePermissions,
          payload: payload,
        );
      case 'system.request_computer_use_permissions':
        event = CanonicalEvent(
          type: CanonicalEventTypes.systemRequestComputerUsePermissions,
          payload: payload,
        );
      case 'system.toggle_computer_use':
        event = CanonicalEvent(
          type: CanonicalEventTypes.systemToggleComputerUse,
          payload: payload,
        );
      case 'workspace.get_policy':
        event = CanonicalEvent(
          type: CanonicalEventTypes.workspaceGetPolicy,
          payload: payload,
        );
      case 'workspace.set_permission_mode':
        event = CanonicalEvent(
          type: CanonicalEventTypes.workspaceSetPermissionMode,
          payload: payload,
        );
      case 'provider.templates.list':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerTemplatesList,
          payload: payload,
        );
      case 'provider.instances.list':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerInstancesList,
          payload: payload,
        );
      case 'provider.instance.create':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceCreate,
          payload: payload,
        );
      case 'provider.instance.update':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceUpdate,
          payload: payload,
        );
      case 'provider.instance.rename':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceRename,
          payload: payload,
        );
      case 'provider.instance.remove':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceRemove,
          payload: payload,
        );
      case 'provider.instance.set_default':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceSetDefault,
          payload: payload,
        );
      case 'provider.instance.test':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerInstanceTest,
          payload: payload,
        );
      case 'provider.credential.update':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerCredentialUpdate,
          payload: payload,
        );
      case 'provider.auth.reconnect':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerAuthReconnect,
          payload: payload,
        );
      case 'provider.auth.disconnect':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerAuthDisconnect,
          payload: payload,
        );
      case 'model.snapshot':
        event = CanonicalEvent(
          type: CanonicalEventTypes.modelSnapshot,
          payload: payload,
        );
      case 'model.refresh':
        event = CanonicalEvent(
          type: CanonicalEventTypes.modelRefresh,
          payload: payload,
        );
      case 'model.recent.list':
        event = CanonicalEvent(
          type: CanonicalEventTypes.modelRecentList,
          payload: payload,
        );
      case 'model.recent.record':
        event = CanonicalEvent(
          type: CanonicalEventTypes.modelRecentRecord,
          payload: payload,
        );
      // Task 55: provider account usage limits.
      case 'provider.usage.get':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerUsageGet,
          payload: payload,
        );
      case 'provider.usage.reset':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerUsageReset,
          payload: payload,
        );
      case 'provider.usage.support':
        event = CanonicalEvent(
          type: CanonicalEventTypes.providerUsageSupport,
          payload: payload,
        );
      // Device-directed conversation lifecycle commands.
      case 'session.pending_steer_cancel':
        event = CanonicalEvent(
          type: CanonicalEventTypes.sessionPendingSteerCancel,
          sessionId: sessionId,
          payload: payload,
        );
      case 'session.queued_message_delete':
        event = CanonicalEvent(
          type: CanonicalEventTypes.sessionQueuedMessageDelete,
          sessionId: sessionId,
          payload: payload,
        );
      case 'session.stop_recovery_ack':
        event = CanonicalEvent(
          type: CanonicalEventTypes.sessionStopRecoveryAck,
          sessionId: sessionId,
          payload: payload,
        );
      case 'session.stop_recovery_claim':
        event = CanonicalEvent(
          type: CanonicalEventTypes.sessionStopRecoveryClaim,
          sessionId: sessionId,
          payload: payload,
        );
      // Task 49: edit/retry of the latest historical turn.
      case 'session.turn_replay':
        event = CanonicalEvent(
          type: CanonicalEventTypes.sessionTurnReplay,
          sessionId: sessionId,
          payload: payload,
        );
      // Plan 30: runtime recovery commands
      case 'session.runtime_retry':
        event = CanonicalEvent(
          type: CanonicalEventTypes.sessionRuntimeRetry,
          sessionId: sessionId,
          payload: payload,
        );
      case 'session.runtime_stop':
        event = CanonicalEvent(
          type: CanonicalEventTypes.sessionRuntimeStop,
          sessionId: sessionId,
          payload: payload,
        );
      case 'session.runtime_continue_with_provider':
        event = CanonicalEvent(
          type: CanonicalEventTypes.sessionRuntimeContinueWithProvider,
          sessionId: sessionId,
          payload: payload,
        );
    }

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
      case CanonicalEventTypes.getSessionHistory:
        await emitEnvelope(_sessionQueryHandler.buildHistoryEnvelope(event));
        return;
      case CanonicalEventTypes.sessionPendingSteerCancel:
        final orchestrator = getIt<SessionRunOrchestrator>();
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString();
        final targetRequestId = event.payload['request_id']?.toString();
        final commandRequestId = event.payload['command_request_id']
            ?.toString();
        if (sessionId != null &&
            targetRequestId != null &&
            commandRequestId != null) {
          orchestrator.cancelPendingSteer(
            sessionId: sessionId,
            targetRequestId: targetRequestId,
            commandRequestId: commandRequestId,
          );
        }
        return;
      case CanonicalEventTypes.sessionQueuedMessageDelete:
        final orchestrator = getIt<SessionRunOrchestrator>();
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString();
        final targetRequestId = event.payload['request_id']?.toString();
        final commandRequestId = event.payload['command_request_id']
            ?.toString();
        if (sessionId != null &&
            targetRequestId != null &&
            commandRequestId != null) {
          orchestrator.deleteQueuedMessage(
            sessionId: sessionId,
            targetRequestId: targetRequestId,
            commandRequestId: commandRequestId,
          );
        }
        return;
      case CanonicalEventTypes.sessionStopRecoveryAck:
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString();
        final stopRequestId = event.payload['stop_request_id']?.toString();
        final claimantId =
            (event.payload['claimant_id'] ??
                    event.payload['command_request_id'])
                ?.toString();
        final recoveryOwnerToken = event.payload['recovery_owner_token']
            ?.toString();
        if (sessionId != null && stopRequestId != null) {
          getIt<SessionRunOrchestrator>().acknowledgeStopRecovery(
            sessionId,
            stopRequestId,
            claimantId: claimantId,
            recoveryOwnerToken: recoveryOwnerToken,
          );
        }
        return;
      case CanonicalEventTypes.sessionStopRecoveryClaim:
        final sessionId =
            event.sessionId ?? event.payload['session_id']?.toString();
        final stopRequestId = event.payload['stop_request_id']?.toString();
        final commandRequestId = event.payload['command_request_id']
            ?.toString();
        if (sessionId != null &&
            stopRequestId != null &&
            commandRequestId != null &&
            getIt.isRegistered<PersistedRuntimeStateRepository>()) {
          final claimed = getIt<PersistedRuntimeStateRepository>().pendingInputs
              .claimStopOutcome(
                sessionId: sessionId,
                stopRequestId: stopRequestId,
                claimantId: commandRequestId,
              );
          if (claimed != null) {
            await emitEnvelope(
              buildAgentEventEnvelope(
                CanonicalEvent(
                  type: CanonicalEventTypes.sessionStopDraftRecovery,
                  sessionId: sessionId,
                  payload: claimed.toPayload(),
                ),
              ),
            );
          }
        }
        return;
      case CanonicalEventTypes.getSessions:
        await emitEnvelope(_sessionQueryHandler.buildThreadsEnvelope(event));
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
          await _workspaceHandler.buildMcpServersEnvelope(event),
        );
        return;
      case CanonicalEventTypes.saveMcpServer:
        await emitEnvelope(
          await _workspaceHandler.buildSaveMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.deleteMcpServer:
        await emitEnvelope(
          await _workspaceHandler.buildDeleteMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.replaceMcpConfig:
        await emitEnvelope(
          await _workspaceHandler.buildReplaceMcpConfigEnvelope(event),
        );
        return;
      case CanonicalEventTypes.inspectMcpServer:
        await emitEnvelope(
          await _workspaceHandler.buildInspectMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.previewMcpImport:
        await emitEnvelope(
          await _workspaceHandler.buildPreviewMcpImportEnvelope(event),
        );
        return;
      case CanonicalEventTypes.exportMcpServers:
        await emitEnvelope(
          await _workspaceHandler.buildExportMcpServersEnvelope(event),
        );
        return;
      case CanonicalEventTypes.readAdvancedMcpServer:
        await emitEnvelope(
          await _workspaceHandler.buildReadAdvancedMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.previewAdvancedMcpServer:
        await emitEnvelope(
          await _workspaceHandler.buildPreviewAdvancedMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.saveAdvancedMcpServer:
        await emitEnvelope(
          await _workspaceHandler.buildSaveAdvancedMcpServerEnvelope(event),
        );
        return;
      case CanonicalEventTypes.startMcpOAuth:
        await emitEnvelope(
          await _workspaceHandler.buildStartMcpOAuthEnvelope(event),
        );
        return;
      case CanonicalEventTypes.getMcpOAuthStatus:
        await emitEnvelope(
          await _workspaceHandler.buildMcpOAuthStatusEnvelope(event),
        );
        return;
      case CanonicalEventTypes.cancelMcpOAuth:
        await emitEnvelope(
          await _workspaceHandler.buildCancelMcpOAuthEnvelope(event),
        );
        return;
      case CanonicalEventTypes.completeMcpOAuth:
        await emitEnvelope(
          await _workspaceHandler.buildCompleteMcpOAuthEnvelope(event),
        );
        return;
      case CanonicalEventTypes.searchSlashCommands:
        await emitEnvelope(
          await _workspaceHandler.buildSlashCommandsEnvelope(event),
        );
        return;
      case CanonicalEventTypes.listSkills:
        await emitEnvelope(await _workspaceHandler.buildSkillsEnvelope(event));
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
          await _workspaceHandler.buildCheckComputerUsePermissionsEnvelope(
            event,
          ),
        );
        return;
      case CanonicalEventTypes.systemRequestComputerUsePermissions:
        await emitEnvelope(
          await _workspaceHandler.buildRequestComputerUsePermissionsEnvelope(
            event,
          ),
        );
        return;
      case CanonicalEventTypes.systemToggleComputerUse:
        await emitEnvelope(
          await _workspaceHandler.buildToggleComputerUseEnvelope(event),
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

      default:
        _logger.fine('Ignoring unsupported protocol event: ${event.type}');
        return;
    }
  }

  Map<String, dynamic> buildAgentEventEnvelope(CanonicalEvent canonicalEvent) {
    final authManager = getIt<AuthManager>();
    final hardwareId = authManager.hardwareId ?? 'sanad-agent-local';

    final eventId = canonicalEvent.eventId ?? EventId.generate();
    final delivery =
        canonicalEvent.delivery ??
        DeliveryPolicy.origin(
          requestId: canonicalEvent.payload['request_id']?.toString(),
        );

    return {
      'device_id': hardwareId,
      'hardware_id': hardwareId,
      'type': 'event',
      'event': canonicalEvent.type,
      'payload': canonicalEvent.payload,
      if (canonicalEvent.sessionId != null)
        'session_id': canonicalEvent.sessionId,
      if (canonicalEvent.runId != null) 'run_id': canonicalEvent.runId,
      if (canonicalEvent.payload['request_id'] != null)
        'request_id': canonicalEvent.payload['request_id'],
      'event_id': eventId,
      'delivery': delivery.toJson(),
    };
  }

  Map<String, dynamic> _readPayload(Map<String, dynamic> data) {
    final payload = data['payload'];
    if (payload is Map<String, dynamic>) {
      return payload;
    }
    if (payload is Map) {
      return Map<String, dynamic>.from(payload);
    }
    return <String, dynamic>{};
  }
}
