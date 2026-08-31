import '../../../models/delivery/models.dart';
import '../../../models/device_control.dart';

/// Represents a standard event in the Sanad Unified Protocol.
class CanonicalEvent {
  final String type;
  final Map<String, dynamic> payload;
  final String? sessionId;
  final String? runId;

  /// Phase 27 — canonical event id, preserved across all local/cloud copies.
  final String? eventId;

  /// Phase 27 — declarative delivery policy authored by the runtime.
  final DeliveryPolicy? delivery;

  CanonicalEvent({
    required this.type,
    required this.payload,
    this.sessionId,
    this.runId,
    this.eventId,
    this.delivery,
  });

  Map<String, dynamic> toJson() => {
    'type': type,
    'payload': payload,
    if (sessionId != null) 'session_id': sessionId,
    if (runId != null) 'run_id': runId,
    if (eventId != null) 'event_id': eventId,
    if (delivery != null) 'delivery': delivery!.toJson(),
  };

  factory CanonicalEvent.fromJson(Map<String, dynamic> json) {
    return CanonicalEvent(
      type: json['type'] as String,
      payload: json['payload'] as Map<String, dynamic>,
      sessionId: json['session_id'] as String?,
      runId: json['run_id'] as String?,
      eventId: json['event_id']?.toString(),
      delivery: json['delivery'] is Map<String, dynamic>
          ? DeliveryPolicy.fromJson(json['delivery'] as Map<String, dynamic>)
          : null,
    );
  }
}

/// Standard event types for Sanad Gateway
class CanonicalEventTypes {
  static const String thought = 'thought';
  static const String thoughtStream = 'thought_stream';
  static const String reasoningStream = 'reasoning_stream';
  static const String reasoning = 'reasoning';
  static const String toolCall = 'tool_call';
  static const String finalAnswer = 'final_answer';

  static const String getSessionHistory = 'get_session_history';
  static const String sessionHistory = 'session_history';
  static const String getSessions = 'get_sessions';
  static const String sessionsList = 'sessions_list';
  static const String updateSessionTitle = 'update_session_title';
  static const String sessionUpdated = 'session_updated';
  static const String deleteSession = 'delete_session';
  static const String sessionDeleted = 'session_deleted';

  static const String updateSessionPreferences = 'update_session_preferences';
  static const String sessionPreferencesUpdated = 'session_preferences_updated';
  static const String listWorkspaces = 'list_workspaces';
  static const String workspacesList = 'workspaces_list';
  static const String createWorkspace = 'create_workspace';
  static const String workspaceCreated = 'workspace_created';
  static const String renameWorkspace = 'workspace.rename';
  static const String workspaceRenamed = 'workspace.renamed';
  static const String removeWorkspace = 'workspace.remove';
  static const String workspaceRemoved = 'workspace.removed';
  static const String relocateWorkspace = 'workspace.relocate';
  static const String workspaceRelocated = 'workspace.relocated';
  static const String relocateWorkspacePreview = 'workspace.relocate.preview';
  static const String browseWorkspaceTree = 'browse_workspace_tree';
  static const String workspaceTree = 'workspace_tree';
  static const String listMcpServers = 'list_mcp_servers';
  static const String mcpServersList = 'mcp_servers_list';
  static const String saveMcpServer = 'save_mcp_server';
  static const String mcpServerSaved = 'mcp_server_saved';
  static const String mcpServerSavePreview = 'mcp.server.save.preview';
  static const String deleteMcpServer = 'delete_mcp_server';
  static const String mcpServerDeleted = 'mcp_server_deleted';
  static const String mcpServerDeletePreview = 'mcp.server.delete.preview';
  static const String replaceMcpConfig = 'replace_mcp_config';
  static const String mcpConfigReplaced = 'mcp_config_replaced';
  static const String inspectMcpServer = 'inspect_mcp_server';
  static const String mcpServerInspected = 'mcp_server_inspected';
  static const String mcpServerInspectPreview = 'mcp.server.inspect.preview';
  static const String previewMcpImport = 'preview_mcp_import';
  static const String mcpImportPreviewed = 'mcp_import_previewed';
  static const String exportMcpServers = 'export_mcp_servers';
  static const String mcpServersExported = 'mcp_servers_exported';
  static const String readAdvancedMcpServer = 'read_advanced_mcp_server';
  static const String mcpAdvancedRead = 'mcp_advanced_read';
  static const String previewAdvancedMcpServer = 'preview_advanced_mcp_server';
  static const String mcpAdvancedPreviewed = 'mcp_advanced_previewed';
  static const String saveAdvancedMcpServer = 'save_advanced_mcp_server';
  static const String mcpAdvancedSaved = 'mcp_advanced_saved';
  static const String startMcpOAuth = 'start_mcp_oauth';
  static const String mcpOAuthStarted = 'mcp_oauth_started';
  static const String getMcpOAuthStatus = 'get_mcp_oauth_status';
  static const String mcpOAuthStatus = 'mcp_oauth_status';
  static const String cancelMcpOAuth = 'cancel_mcp_oauth';
  static const String mcpOAuthCancelled = 'mcp_oauth_cancelled';
  static const String completeMcpOAuth = 'complete_mcp_oauth';
  static const String mcpOAuthCompleted = 'mcp_oauth_completed';
  static const String mcpOAuthCompletePreview = 'mcp.oauth.complete.preview';
  static const String searchSlashCommands = 'search_slash_commands';
  static const String slashCommandsList = 'slash_commands_list';
  static const String listSkills = 'list_skills';
  static const String skillsList = 'skills_list';
  static const String toolPermissionRequest = 'tool_permission_request';
  static const String toolPermissionResponse = 'tool_permission_response';
  static const String toolPermissionResolved = 'tool_permission_resolved';
  static const String platformToolCall = 'platform_tool_call';
  static const String platformToolResult = 'platform_tool_result';

  // ── Provider Runtime (Plan 19) ────────────────────────────────────────
  static const String providerSetupStatus = 'provider.setup_status';
  static const String providerRuntimeCheck = 'provider.runtime_check';
  static const String providerList = 'provider.list';
  static const String providerListConfigured = 'provider.list_configured';
  static const String providerSaveApiKey = 'provider.save_api_key';
  static const String providerSaveCustomEndpoint =
      'provider.save_custom_endpoint';
  static const String providerRemove = 'provider.remove';
  static const String providerAuthStart = 'provider.auth.start';
  static const String providerAuthPoll = 'provider.auth.poll';
  static const String providerAuthSubmit = 'provider.auth.submit';
  static const String providerAuthCancel = 'provider.auth.cancel';
  static const String providerAuthStatus = 'provider.auth.status';

  static const String providerListResult = 'provider.list_result';
  static const String providerListConfiguredResult =
      'provider.list_configured_result';
  static const String providerSaved = 'provider_saved';
  static const String providerRemoved = 'provider_removed';
  static const String providerAuthStarted = 'provider_auth_started';
  static const String providerAuthPolled = 'provider_auth_polled';
  static const String providerAuthCancelled = 'provider_auth_cancelled';
  static const String providerAuthStatusResult = 'provider_auth_status_result';
  static const String providerReadinessResult = 'provider_readiness_result';

  static const String modelOptions = 'model.options';
  static const String modelRecommendedDefault = 'model.recommended_default';
  static const String modelSetDefault = 'model.set_default';
  static const String modelOptionsResult = 'model_options_result';
  static const String modelRecommendedDefaultResult =
      'model_recommended_default_result';
  static const String modelSetDefaultResult = 'model_set_default_result';

  // ── Plan 24: live provider/model switching ────────────────────────────
  static const String capabilitiesChanged = 'capabilities_changed';
  static const String modelSwitched = 'model_switched';
  static const String providerConfiguredOptions = 'provider.configured_options';
  static const String providerConfiguredOptionsResult =
      'provider_configured_options_result';
  // ── Computer Use (OS UI Automation) ──────────────────────────────────
  static const String systemCheckComputerUsePermissions =
      'system.check_computer_use_permissions';
  static const String systemRequestComputerUsePermissions =
      'system.request_computer_use_permissions';
  static const String systemToggleComputerUse = 'system.toggle_computer_use';

  static const String systemCheckComputerUsePermissionsResult =
      'system_check_computer_use_permissions_result';
  static const String systemRequestComputerUsePermissionsResult =
      'system_request_computer_use_permissions_result';
  static const String systemToggleComputerUseResult =
      'system_toggle_computer_use_result';

  // ── Device runtime settings ───────────────────────────────────────────
  static const String deviceSettingsGet = 'device.settings.get';
  static const String deviceSettingsUpdate = 'device.settings.update';
  static const String deviceSettingsSnapshot = 'device.settings.snapshot';
  static const String deviceSettingsUpdated = 'device.settings.updated';

  // ── Plan 25: workspace policy relocation ──────────────────────────────
  static const String workspaceGetPolicy = 'workspace.get_policy';
  static const String workspaceSetPermissionMode =
      'workspace.set_permission_mode';
  static const String workspacePolicyChanged = 'workspace.policy_changed';

  // ── Folder Operations ─────────────────────────────────────────────────
  static const String createFolder = 'workspace.create_folder';
  static const String folderCreated = 'workspace.folder_created';
  static const String renameFolder = 'workspace.rename_folder';
  static const String folderRenamed = 'workspace.folder_renamed';
  static const String deleteFolder = 'workspace.delete_folder';
  static const String folderDeleted = 'workspace.folder_deleted';
  static const String deleteFolderPreview = 'workspace.delete_folder.preview';

  // ── Plan 29: Multi-account & Model cache ────────────────────────────────
  static const String providerTemplatesList = 'provider.templates.list';
  static const String providerTemplatesResult = 'provider.templates.result';
  static const String providerInstancesList = 'provider.instances.list';
  static const String providerInstancesResult = 'provider.instances.result';
  static const String providerInstanceCreate = 'provider.instance.create';
  static const String providerInstanceCreated = 'provider.instance.created';
  static const String providerInstanceUpdate = 'provider.instance.update';
  static const String providerInstanceUpdated = 'provider.instance.updated';
  static const String providerInstanceRename = 'provider.instance.rename';
  static const String providerInstanceRenamed = 'provider.instance.renamed';
  static const String providerInstanceRemove = 'provider.instance.remove';
  static const String providerInstanceRemoved = 'provider.instance.removed';
  static const String providerInstanceSetDefault =
      'provider.instance.set_default';
  static const String providerInstanceDefaultChanged =
      'provider.instance.default_changed';
  static const String providerInstanceTest = 'provider.instance.test';
  static const String providerInstanceTestResult =
      'provider.instance.test_result';
  static const String providerCredentialUpdate = 'provider.credential.update';
  static const String providerCredentialUpdated = 'provider.credential.updated';
  static const String providerAuthReconnect = 'provider.auth.reconnect';
  static const String providerAuthDisconnect = 'provider.auth.disconnect';
  static const String modelSnapshot = 'model.snapshot';
  static const String modelSnapshotResult = 'model.snapshot_result';
  static const String modelRefresh = 'model.refresh';
  static const String modelCacheUpdated = 'model.cache_updated';
  static const String modelRecentList = 'model.recent.list';
  static const String modelRecentResult = 'model.recent.recent_result';
  static const String modelRecentRecord = 'model.recent.record';
  static const String modelRecentRecorded = 'model.recent.recent_recorded';
  static const String providerInstancesChanged = 'provider_instances_changed';

  // ── Plan 30: Runtime Recovery & Rate Limits ─────────────────────────────
  static const String sessionRuntimeNotice = 'session.runtime_notice';
  static const String sessionRuntimeNoticeCleared =
      'session.runtime_notice_cleared';
  static const String sessionExecutionStateChanged =
      'session.execution_state_changed';
  static const String sessionRuntimeRetry = 'session.runtime_retry';
  static const String sessionRuntimeStop = 'session.runtime_stop';
  static const String sessionRuntimeContinueWithProvider =
      'session.runtime_continue_with_provider';
  static const String sessionMessageClassified = 'session.message_classified';
  static const String sessionPendingSteerChanged =
      'session.pending_steer_changed';
  static const String sessionPendingSteerCancel =
      'session.pending_steer_cancel';
  static const String sessionPendingSteerCancelResult =
      'session.pending_steer_cancel_result';
  static const String sessionQueuedMessageDelete =
      'session.queued_message_delete';
  static const String sessionQueuedMessageDeleteResult =
      'session.queued_message_delete_result';
  static const String sessionStopDraftRecovery = 'session.stop_draft_recovery';
  static const String sessionStopRecoveryAck = 'session.stop_recovery_ack';
  static const String sessionStopRecoveryClaim = 'session.stop_recovery_claim';

  // ── Task 49: historical turn edit/retry ────────────────────────────────
  static const String sessionTurnReplay = 'session.turn_replay';
  static const String sessionTurnReplayResult = 'session.turn_replay_result';

  // ── Plan 53: Context compaction lifecycle ───────────────────────────────
  static const String contextCompactionStarted = 'context_compaction.started';
  static const String contextCompactionCompleted =
      'context_compaction.completed';
  static const String contextCompactionFailed = 'context_compaction.failed';
  static const String sessionCompact = 'session.compact';
  static const String sessionCompactResult = 'session.compact_result';

  // ── Task 55: Provider account usage limits ─────────────────────────────
  static const String providerUsageGet = 'provider.usage.get';
  static const String providerUsageResult = 'provider.usage.result';
  static const String providerUsageReset = 'provider.usage.reset';
  static const String providerUsageResetResult = 'provider.usage.reset_result';
  static const String providerUsageSupport = 'provider.usage.support';
  static const String providerUsageSupportResult =
      'provider.usage.support_result';

  // ── Task 82: remote device control ────────────────────────────────────
  static const String deviceUpdateCheck = DeviceControlCommands.updateCheck;
  static const String deviceUpdateCheckResult =
      DeviceControlCommands.updateCheckResult;
  static const String deviceUpdateApply = DeviceControlCommands.updateApply;
  static const String deviceUpdateApplyAccepted =
      DeviceControlCommands.updateApplyAccepted;
  static const String deviceUpdateProgress =
      DeviceControlCommands.updateProgress;
  static const String deviceUpdateResult = DeviceControlCommands.updateResult;
  static const String deviceRuntimeRestart =
      DeviceControlCommands.runtimeRestart;
  static const String deviceRuntimeRestartAccepted =
      DeviceControlCommands.runtimeRestartAccepted;
}
