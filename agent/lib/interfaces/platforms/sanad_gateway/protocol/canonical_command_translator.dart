import 'canonical_events.dart';

/// Owns the wire-command to canonical-event translation of the Sanad Gateway.
///
/// `SanadProtocolBridge.handleCommand` dispatches the [CanonicalEvent] this
/// owner returns; every accepted command name and the shape of the event it
/// produces live here, so the bridge stays dispatch-only.
///
/// An accepted command's canonical event type is its own wire name, so each
/// table entry is the single [CanonicalEventTypes] constant that names both the
/// accepted command and the emitted type. A command whose type must differ from
/// its wire name needs an explicit branch in [translate]; no table renames a
/// command, and an unlisted command stays unhandled.
class CanonicalCommandTranslator {
  const CanonicalCommandTranslator._();

  /// Accepted commands whose event carries the payload only.
  static const Set<String> _payloadCommands = <String>{
    CanonicalEventTypes.getSessions,
    CanonicalEventTypes.searchSessions,
    CanonicalEventTypes.listWorkspaces,
    CanonicalEventTypes.createWorkspace,
    CanonicalEventTypes.renameWorkspace,
    CanonicalEventTypes.removeWorkspace,
    CanonicalEventTypes.relocateWorkspace,
    CanonicalEventTypes.browseWorkspaceTree,
    CanonicalEventTypes.createFolder,
    CanonicalEventTypes.renameFolder,
    CanonicalEventTypes.deleteFolder,
    CanonicalEventTypes.listMcpServers,
    CanonicalEventTypes.saveMcpServer,
    CanonicalEventTypes.deleteMcpServer,
    CanonicalEventTypes.replaceMcpConfig,
    CanonicalEventTypes.inspectMcpServer,
    CanonicalEventTypes.previewMcpImport,
    CanonicalEventTypes.exportMcpServers,
    CanonicalEventTypes.readAdvancedMcpServer,
    CanonicalEventTypes.previewAdvancedMcpServer,
    CanonicalEventTypes.saveAdvancedMcpServer,
    CanonicalEventTypes.startMcpOAuth,
    CanonicalEventTypes.getMcpOAuthStatus,
    CanonicalEventTypes.cancelMcpOAuth,
    CanonicalEventTypes.completeMcpOAuth,
    CanonicalEventTypes.searchSlashCommands,
    CanonicalEventTypes.listSkills,
    CanonicalEventTypes.deviceSettingsGet,
    CanonicalEventTypes.deviceSettingsUpdate,
    CanonicalEventTypes.getAppearance,
    CanonicalEventTypes.updateAppearance,
    CanonicalEventTypes.providerSetupStatus,
    CanonicalEventTypes.providerRuntimeCheck,
    CanonicalEventTypes.providerAuthStart,
    CanonicalEventTypes.providerAuthPoll,
    CanonicalEventTypes.providerAuthSubmit,
    CanonicalEventTypes.providerAuthCancel,
    CanonicalEventTypes.providerAuthStatus,
    CanonicalEventTypes.modelOptions,
    CanonicalEventTypes.modelRecommendedDefault,
    CanonicalEventTypes.modelSetDefault,
    CanonicalEventTypes.systemCheckComputerUsePermissions,
    CanonicalEventTypes.systemRequestComputerUsePermissions,
    CanonicalEventTypes.systemToggleComputerUse,
    CanonicalEventTypes.workspaceGetPolicy,
    CanonicalEventTypes.workspaceSetPermissionMode,
    CanonicalEventTypes.providerTemplatesList,
    CanonicalEventTypes.providerInstancesList,
    CanonicalEventTypes.providerInstanceCreate,
    CanonicalEventTypes.providerInstanceUpdate,
    CanonicalEventTypes.providerInstanceRename,
    CanonicalEventTypes.providerInstanceRemove,
    CanonicalEventTypes.providerInstanceSetDefault,
    CanonicalEventTypes.providerInstanceTest,
    CanonicalEventTypes.providerCredentialUpdate,
    CanonicalEventTypes.providerAuthReconnect,
    CanonicalEventTypes.providerAuthDisconnect,
    CanonicalEventTypes.modelSnapshot,
    CanonicalEventTypes.modelRefresh,
    CanonicalEventTypes.modelRecentList,
    CanonicalEventTypes.modelRecentRecord,
    // Task 55: provider account usage limits.
    CanonicalEventTypes.providerUsageGet,
    CanonicalEventTypes.providerUsageReset,
    CanonicalEventTypes.providerUsageSupport,
    // Task 140: user secrets protocol.
    CanonicalEventTypes.secretsList,
    CanonicalEventTypes.secretSet,
    CanonicalEventTypes.secretDelete,
    // Task 139: schedule control protocol.
    CanonicalEventTypes.scheduleList,
    CanonicalEventTypes.schedulePreview,
    CanonicalEventTypes.scheduleCreate,
    CanonicalEventTypes.scheduleUpdate,
    CanonicalEventTypes.schedulePause,
    CanonicalEventTypes.scheduleResume,
    CanonicalEventTypes.scheduleRunNow,
    CanonicalEventTypes.scheduleDelete,
    CanonicalEventTypes.scheduleRuns,
  };

  /// Accepted commands that also bind the payload's `session_id` to the event.
  static const Set<String> _sessionScopedCommands = <String>{
    'attachment.admit',
    CanonicalEventTypes.getSessionHistory,
    CanonicalEventTypes.deleteSession,
    CanonicalEventTypes.updateSessionTitle,
    CanonicalEventTypes.updateSessionPreferences,
    CanonicalEventTypes.sessionPendingSteerCancel,
    CanonicalEventTypes.sessionQueuedMessageDelete,
    CanonicalEventTypes.sessionStopRecoveryAck,
    CanonicalEventTypes.sessionStopRecoveryClaim,
    // Task 49: edit/retry of the latest historical turn.
    CanonicalEventTypes.sessionTurnReplay,
    CanonicalEventTypes.sessionCompact,
    CanonicalEventTypes.sessionFork,
    // Plan 30: runtime recovery commands.
    CanonicalEventTypes.sessionRuntimeRetry,
    CanonicalEventTypes.sessionRuntimeStop,
    CanonicalEventTypes.sessionRuntimeContinueWithProvider,
  };

  /// Device-directed commands whose event payload also carries the envelope's
  /// `device_id` and, when the payload omits it, the envelope's `request_id`.
  static const Set<String> _deviceDirectedCommands = <String>{
    CanonicalEventTypes.deviceUpdateCheck,
    CanonicalEventTypes.deviceUpdateApply,
    CanonicalEventTypes.deviceRuntimeRestart,
    CanonicalEventTypes.deviceCliExecute,
    CanonicalEventTypes.deviceCliCancel,
  };

  /// Translates a gateway command envelope into the canonical event to
  /// dispatch, or `null` when no owner handles that command.
  static CanonicalEvent? translate(Map<String, dynamic> data) {
    final command = data['command'] as String?;
    final payload = _readPayload(data);
    final sessionId = payload['session_id'] as String?;

    if (command == null) {
      return null;
    }
    if (_deviceDirectedCommands.contains(command)) {
      return CanonicalEvent(
        type: command,
        payload: {
          ...payload,
          if (data['device_id'] != null) 'device_id': data['device_id'],
          if (data['request_id'] != null && !payload.containsKey('request_id'))
            'request_id': data['request_id'],
        },
        sessionId: sessionId,
      );
    }
    if (_sessionScopedCommands.contains(command)) {
      return CanonicalEvent(
        type: command,
        sessionId: sessionId,
        payload: payload,
      );
    }
    if (_payloadCommands.contains(command)) {
      return CanonicalEvent(type: command, payload: payload);
    }
    return null;
  }

  static Map<String, dynamic> _readPayload(Map<String, dynamic> data) {
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
