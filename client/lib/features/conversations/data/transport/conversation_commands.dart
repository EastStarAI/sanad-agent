import 'package:logging/logging.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/data/mappers/device_event_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/pending_steer_record.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/models/session_fork_result.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_request_id.dart';
import 'package:uuid/uuid.dart';

class ConversationCommands {
  static final _logger = Logger('ConversationCommands');

  final ConversationCommandGateway _gateway;
  final DeviceConversationStore _conversationStore;
  final DeviceEventMapper _mapper;
  int _historyHydrationGeneration = 0;
  Future<List<CanonicalEvent>>? _olderHistoryLoad;
  String? _olderHistoryCursor;
  Future<List<CanonicalEvent>>? _newerHistoryLoad;
  String? _newerHistoryCursor;

  ConversationCommands({
    required ConversationCommandGateway gateway,
    required DeviceConversationStore conversationStore,
    required DeviceEventMapper mapper,
  }) : _gateway = gateway,
       _conversationStore = conversationStore,
       _mapper = mapper;

  Future<String?> sendMessage(
    String message, {
    String? sessionId,
    String? workspaceId,
    String? context,
    String? providerId,
    String? model,
    String? thinkingMode,
    MessageDeliveryIntent intent = MessageDeliveryIntent.auto,
  }) async {
    if (!_gateway.isConnected) return null;

    final requestId = generateConversationRequestId();
    final isDraftRequest = sessionId == null && _conversationStore.currentSessionId == null;
    final targetSessionId = sessionId ?? _conversationStore.currentSessionId ?? const Uuid().v4();

    _conversationStore.beginOutgoingRequest(
      requestId: requestId,
      sessionId: targetSessionId,
      isDraftRequest: isDraftRequest,
    );

    _gateway.sendCommand(
      command: 'think',
      payload: {
        'request_id': requestId,
        'session_id': targetSessionId,
        'message': message,
        'delivery_intent': intent.wireValue,
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
        if (context != null && context.trim().isNotEmpty) 'context': context.trim(),
        if (providerId != null && providerId.trim().isNotEmpty) 'provider_id': providerId.trim(),
        if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
        if (thinkingMode != null && thinkingMode.trim().isNotEmpty) 'thinking_mode': thinkingMode.trim(),
      },
    );
    return requestId;
  }

  Future<void> steerMessage(
    String message, {
    required String requestId,
    required String sessionId,
  }) async {
    if (!_gateway.isConnected) return;

    _gateway.sendCommand(
      command: 'steer',
      payload: {'request_id': requestId, 'session_id': sessionId},
    );
  }

  Future<String?> deleteQueuedMessage({
    required String requestId,
    required String sessionId,
  }) async {
    if (!_gateway.isConnected) return null;
    final commandRequestId = generateConversationRequestId();
    _gateway.sendCommand(
      command: 'session.queued_message_delete',
      payload: {
        'session_id': sessionId,
        'request_id': requestId,
        'command_request_id': commandRequestId,
      },
    );
    return commandRequestId;
  }

  Future<String?> cancelPendingSteer({
    required String requestId,
    required String sessionId,
  }) async {
    if (!_gateway.isConnected) return null;
    final commandRequestId = generateConversationRequestId();
    _gateway.sendCommand(
      command: 'session.pending_steer_cancel',
      payload: {
        'session_id': sessionId,
        'request_id': requestId,
        'command_request_id': commandRequestId,
      },
    );
    return commandRequestId;
  }

  Future<Session> createSession({
    String? title,
    bool isTitlePlaceholder = false,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) async {
    final requestId = generateConversationRequestId();
    final normalizedTitle = title?.trim();
    final result = await _gateway.request(
      command: 'create_session',
      payload: {
        'request_id': requestId,
        if (normalizedTitle != null && normalizedTitle.isNotEmpty) 'title': normalizedTitle,
        if (normalizedTitle != null && normalizedTitle.isNotEmpty && isTitlePlaceholder) 'title_is_placeholder': true,
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
        if (providerId != null && providerId.trim().isNotEmpty) 'provider_id': providerId.trim(),
        if (model != null && model.trim().isNotEmpty) 'model': model.trim(),
        if (thinkingMode != null && thinkingMode.trim().isNotEmpty) 'thinking_mode': thinkingMode.trim(),
      },
      requestId: requestId,
    );

    if (result != null) {
      final payload = Map<String, dynamic>.from(
        result['payload'] as Map? ?? result,
      );
      final deviceId = result['device_id'] as String?;
      if (deviceId != null && payload['device_id'] == null) {
        payload['device_id'] = deviceId;
      }
      return Session.fromJson(payload);
    }

    throw StateError('Failed to create session');
  }

  Future<String?> stop({
    String? sessionId,
    String? requestId,
    String? recoveryOwnerToken,
  }) async {
    if (!_gateway.isConnected) return null;

    final targetSessionId = sessionId ?? _conversationStore.currentSessionId;
    final hasRecoverablePendingWork = _conversationStore.currentRuntimeNotice != null;
    final canStopAuthoritativeWork = _conversationStore.canStopSession(
      targetSessionId,
    );
    if (!canStopAuthoritativeWork &&
        !_conversationStore.isCurrentConversationProcessing &&
        !hasRecoverablePendingWork) {
      return null;
    }

    final effectiveRequestId = requestId ?? generateConversationRequestId();

    _gateway.sendCommand(
      command: 'stop',
      payload: {
        'request_id': effectiveRequestId,
        if (recoveryOwnerToken != null && recoveryOwnerToken.isNotEmpty) 'recovery_owner_token': recoveryOwnerToken,
        if (targetSessionId != null) 'session_id': targetSessionId,
      },
    );
    return effectiveRequestId;
  }

  Future<void> acknowledgeStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? claimantId,
    String? recoveryOwnerToken,
  }) async {
    if (!_gateway.isConnected) return;
    _gateway.sendCommand(
      command: 'session.stop_recovery_ack',
      payload: {
        'session_id': sessionId,
        'stop_request_id': stopRequestId,
        if (claimantId != null && claimantId.isNotEmpty) 'claimant_id': claimantId,
        if (recoveryOwnerToken != null && recoveryOwnerToken.isNotEmpty) 'recovery_owner_token': recoveryOwnerToken,
      },
    );
  }

  Future<String?> claimStopRecovery({
    required String sessionId,
    required String stopRequestId,
    String? commandRequestId,
  }) async {
    if (!_gateway.isConnected) return null;
    final effectiveCommandRequestId = commandRequestId ?? generateConversationRequestId();
    _gateway.sendCommand(
      command: 'session.stop_recovery_claim',
      payload: {
        'session_id': sessionId,
        'stop_request_id': stopRequestId,
        'command_request_id': effectiveCommandRequestId,
      },
    );
    return effectiveCommandRequestId;
  }

  Future<TurnReplayResult> replayTurn({
    required String sessionId,
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
    int? expectedHistoryRevision,
    required TurnReplayAction action,
    String? message,
    String? providerInstanceId,
    String? modelId,
    String? thinkingMode,
    bool confirmedReplayUnsafe = false,
    bool confirmedDropSteers = false,
  }) async {
    if (!_gateway.isConnected) {
      return const TurnReplayResult(
        outcome: 'disconnected',
        safety: TurnReplaySafety.unknown,
        requiresConfirmation: false,
      );
    }
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'session.turn_replay',
      payload: {
        'session_id': sessionId,
        'request_id': requestId,
        'target_request_id': targetRequestId,
        if (targetMessageId != null && targetMessageId.isNotEmpty) 'target_message_id': targetMessageId,
        if (targetTurnId != null && targetTurnId.isNotEmpty) 'target_turn_id': targetTurnId,
        if (expectedHistoryRevision != null) 'expected_history_revision': expectedHistoryRevision,
        'action': action.name,
        'confirmed_replay_unsafe': confirmedReplayUnsafe,
        'confirmed_drop_steers': confirmedDropSteers,
        if (message != null) 'message': message,
        if (providerInstanceId != null && providerInstanceId.trim().isNotEmpty)
          'provider_instance_id': providerInstanceId.trim(),
        if (modelId != null && modelId.trim().isNotEmpty) 'model_id': modelId.trim(),
        if (thinkingMode != null && thinkingMode.trim().isNotEmpty) 'thinking_mode': thinkingMode.trim(),
      },
      requestId: requestId,
    );
    final payload = Map<String, dynamic>.from(
      result?['payload'] as Map? ?? result ?? const {},
    );
    return TurnReplayResult.fromJson(payload);
  }

  Future<SessionCompactResult> compactSession({
    required String sessionId,
  }) async {
    if (!_gateway.isConnected) {
      return const SessionCompactResult(outcome: 'disconnected');
    }
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'session.compact',
      payload: {'session_id': sessionId, 'request_id': requestId},
      requestId: requestId,
    );
    final payload = Map<String, dynamic>.from(
      result?['payload'] as Map? ?? result ?? const {},
    );
    return SessionCompactResult.fromJson(payload);
  }

  Future<SessionForkResult> forkSession({
    required String sessionId,
    required String targetMessageId,
    required String targetTurnId,
  }) async {
    if (!_gateway.isConnected) {
      return const SessionForkResult(outcome: 'disconnected');
    }
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'session.fork',
      payload: {
        'session_id': sessionId,
        'request_id': requestId,
        'target_message_id': targetMessageId,
        'target_turn_id': targetTurnId,
      },
      requestId: requestId,
      timeout: const Duration(seconds: 30),
    );
    final payload = Map<String, dynamic>.from(
      result?['payload'] as Map? ?? result ?? const {},
    );
    final parsed = SessionForkResult.fromJson(payload);
    final deviceId = result?['device_id']?.toString();
    if (parsed.child == null || deviceId == null || deviceId.isEmpty) {
      return parsed;
    }
    return SessionForkResult(
      outcome: parsed.outcome,
      child: parsed.child!.copyWith(deviceId: deviceId),
      navigationFailed: parsed.navigationFailed,
    );
  }

  Future<void> retryRuntimeNotice({
    required String sessionId,
    String? requestId,
    String? providerInstanceId,
    String? modelId,
  }) async {
    if (!_gateway.isConnected) return;

    _gateway.sendCommand(
      command: 'session.runtime_retry',
      payload: {
        'session_id': sessionId,
        if (requestId != null && requestId.isNotEmpty) 'request_id': requestId,
        if (providerInstanceId != null && providerInstanceId.trim().isNotEmpty)
          'provider_instance_id': providerInstanceId.trim(),
        if (modelId != null && modelId.trim().isNotEmpty) 'model_id': modelId.trim(),
      },
    );
  }

  Future<void> continueWithProvider({
    required String sessionId,
    required String providerInstanceId,
    String? requestId,
    String? modelId,
  }) async {
    if (!_gateway.isConnected) return;

    _gateway.sendCommand(
      command: 'session.runtime_continue_with_provider',
      payload: {
        'session_id': sessionId,
        'provider_instance_id': providerInstanceId,
        if (requestId != null && requestId.isNotEmpty) 'request_id': requestId,
        if (modelId != null && modelId.trim().isNotEmpty) 'model_id': modelId.trim(),
      },
    );
  }

  Future<void> updateSessionPreferences({
    required String sessionId,
    String? providerId,
    String? model,
    String? thinkingMode,
  }) async {
    final nextModel = model?.trim();
    final nextThinkingMode = thinkingMode?.trim();
    final nextProviderId = providerId?.trim();
    if ((nextModel == null || nextModel.isEmpty) &&
        (nextThinkingMode == null || nextThinkingMode.isEmpty) &&
        (nextProviderId == null || nextProviderId.isEmpty)) {
      return;
    }

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'update_session_preferences',
      payload: {
        'request_id': requestId,
        'session_id': sessionId,
        if (nextModel != null && nextModel.isNotEmpty) 'model': nextModel,
        if (nextProviderId != null && nextProviderId.isNotEmpty) 'provider_id': nextProviderId,
        if (nextThinkingMode != null && nextThinkingMode.isNotEmpty) 'thinking_mode': nextThinkingMode,
      },
      requestId: requestId,
    );

    if (result == null) {
      throw StateError('Failed to update session preferences');
    }
  }

  Future<SessionQueryResult> getSessions({SessionQueryRequest? query}) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'get_sessions',
      payload: {'request_id': requestId, ...?query?.toJson()},
      requestId: requestId,
    );

    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      final sessions = payload['sessions'] as List? ?? [];
      final deviceId = result['device_id'] as String?;
      final mappedSessions = sessions.map((session) {
        final sessionMap = Map<String, dynamic>.from(session as Map);
        if (deviceId != null && sessionMap['device_id'] == null) {
          sessionMap['device_id'] = deviceId;
        }
        final sessionId = (sessionMap['session_id'] ?? sessionMap['id'])?.toString();
        if (sessionId != null && sessionId.isNotEmpty) {
          _conversationStore.hydrateSessionState(
            sessionMap,
            sessionId: sessionId,
          );
        }
        return Session.fromJson(sessionMap);
      }).toList();

      return SessionQueryResult(
        sessions: mappedSessions,
        nextCursor: payload['next_cursor']?.toString(),
        hasMore: payload['has_more'] == true,
      );
    }

    _logger.severe('❌ [ConversationCommands] Failed to get sessions');
    throw StateError('Failed to get sessions from gateway');
  }

  Future<List<DeviceWorkspace>> getWorkspaces() async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'list_workspaces',
      payload: {'request_id': requestId},
      requestId: requestId,
    );

    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      final workspaces = payload['workspaces'] as List? ?? [];
      return workspaces
          .map(
            (workspace) => DeviceWorkspace.fromJson(
              Map<String, dynamic>.from(workspace as Map),
            ),
          )
          .toList();
    }

    throw StateError('Failed to get workspaces');
  }

  Future<List<SlashCommandEntry>> searchSlashCommands({
    String? query,
    String? workspaceId,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'search_slash_commands',
      payload: {
        'request_id': requestId,
        if (query != null && query.trim().isNotEmpty) 'query': query.trim(),
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
      },
      requestId: requestId,
    );

    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      final commands = payload['commands'] as List? ?? [];
      return commands
          .whereType<Map>()
          .map((command) {
            final type = switch (command['type']?.toString()) {
              'runtime_action' => SlashCommandType.runtimeAction,
              'skill' => SlashCommandType.skill,
              _ => null,
            };
            if (type == null) return null;
            return SlashCommandEntry(
              sourceId: command['source']?.toString() ?? 'runtime',
              command: command['command']?.toString() ?? '',
              insertText: command['command']?.toString() ?? '',
              description: command['description']?.toString(),
              type: type,
            );
          })
          .whereType<SlashCommandEntry>()
          .where((entry) => entry.command.trim().isNotEmpty)
          .toList(growable: false);
    }

    throw StateError('Failed to search slash commands');
  }

  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({
    String? workspaceId,
    String? path,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'browse_workspace_tree',
      payload: {
        'request_id': requestId,
        if (workspaceId != null && workspaceId.trim().isNotEmpty) 'workspace_id': workspaceId.trim(),
        if (path != null && path.trim().isNotEmpty) 'path': path.trim(),
      },
      requestId: requestId,
    );

    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      return WorkspaceTreeSnapshot.fromJson(payload);
    }

    throw StateError('Failed to browse workspace tree');
  }

  Future<DeviceWorkspace> createWorkspace({
    String? path,
    String? name,
    String? description,
  }) async {
    final trimmedPath = path?.trim() ?? '';
    final trimmedName = name?.trim() ?? '';
    final trimmedDescription = description?.trim() ?? '';
    if (trimmedPath.isEmpty && trimmedName.isEmpty) {
      throw StateError('Workspace name or path is required');
    }

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'create_workspace',
      payload: {
        'request_id': requestId,
        if (trimmedPath.isNotEmpty) 'path': trimmedPath,
        if (trimmedName.isNotEmpty) 'name': trimmedName,
        if (trimmedDescription.isNotEmpty) 'description': trimmedDescription,
      },
      requestId: requestId,
    );

    if (result != null) {
      final payload = result['payload'] as Map<String, dynamic>? ?? result;
      final workspace = payload['workspace'];
      if (workspace is Map) {
        return DeviceWorkspace.fromJson(Map<String, dynamic>.from(workspace));
      }
    }

    throw StateError('Failed to create workspace');
  }

  Future<DeviceWorkspace> renameWorkspace({
    required String workspaceId,
    required String displayName,
  }) {
    return _mutateWorkspace(
      command: 'workspace.rename',
      payload: {
        'workspace_id': workspaceId.trim(),
        'display_name': displayName.trim(),
      },
    );
  }

  Future<void> removeWorkspace({required String workspaceId}) async {
    final normalizedId = workspaceId.trim();
    if (normalizedId.isEmpty) {
      throw StateError('Workspace id is required');
    }
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'workspace.remove',
      payload: {'request_id': requestId, 'workspace_id': normalizedId},
      requestId: requestId,
    );
    final payload = result?['payload'] as Map<String, dynamic>? ?? result;
    if (result?['event'] == 'workspace.removed' && payload?['workspace_id']?.toString() == normalizedId) {
      return;
    }
    if (result?['event'] == 'error') {
      throw StateError(
        payload?['message']?.toString() ?? 'Failed to remove workspace',
      );
    }
    throw StateError('Failed to remove workspace');
  }

  Future<DeviceWorkspace> relocateWorkspace({
    required String workspaceId,
    required String newPath,
  }) {
    return _mutateWorkspace(
      command: 'workspace.relocate',
      payload: {'workspace_id': workspaceId.trim(), 'new_path': newPath.trim()},
      previewEvent: 'workspace.relocate.preview',
    );
  }

  Future<DeviceWorkspace> _mutateWorkspace({
    required String command,
    required Map<String, dynamic> payload,
    String? previewEvent,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: command,
      payload: {'request_id': requestId, ...payload},
      requestId: requestId,
    );
    if (previewEvent != null && result?['event'] == previewEvent) {
      final preview = result?['payload'] as Map<String, dynamic>? ?? result;
      final token = preview?['confirmation_token']?.toString() ?? '';
      final fingerprint = preview?['confirmation_fingerprint']?.toString() ?? '';
      if (token.isEmpty || fingerprint.isEmpty) {
        throw StateError('Failed to update workspace');
      }
      return _mutateWorkspace(
        command: command,
        payload: {
          ...payload,
          'confirmation_token': token,
          'confirmation_fingerprint': fingerprint,
        },
      );
    }
    final response = result == null ? null : (result['payload'] as Map<String, dynamic>? ?? result);
    if (result?['event'] == 'error') {
      throw StateError(
        response?['message']?.toString() ?? 'Failed to update workspace',
      );
    }
    final workspace = response?['workspace'];
    if (workspace is Map) {
      return DeviceWorkspace.fromJson(Map<String, dynamic>.from(workspace));
    }
    throw StateError('Failed to update workspace');
  }

  Future<void> createFolder({
    required String parentPath,
    required String name,
  }) async {
    final trimmedParentPath = parentPath.trim();
    final trimmedName = name.trim();
    if (trimmedParentPath.isEmpty || trimmedName.isEmpty) {
      throw StateError('Parent path and folder name are required');
    }

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'workspace.create_folder',
      payload: {
        'request_id': requestId,
        'parent_path': trimmedParentPath,
        'name': trimmedName,
      },
      requestId: requestId,
    );
    _requireFolderMutationAcknowledgment(
      result,
      expectedEvent: 'workspace.folder_created',
      fallbackMessage: 'Failed to create folder',
    );
  }

  Future<void> renameFolder({
    required String path,
    required String newName,
  }) async {
    final trimmedPath = path.trim();
    final trimmedNewName = newName.trim();
    if (trimmedPath.isEmpty || trimmedNewName.isEmpty) {
      throw StateError('Folder path and new name are required');
    }

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'workspace.rename_folder',
      payload: {
        'request_id': requestId,
        'path': trimmedPath,
        'new_name': trimmedNewName,
      },
      requestId: requestId,
    );
    _requireFolderMutationAcknowledgment(
      result,
      expectedEvent: 'workspace.folder_renamed',
      fallbackMessage: 'Failed to rename folder',
    );
  }

  Future<void> deleteFolder({required String path}) async {
    final trimmedPath = path.trim();
    if (trimmedPath.isEmpty) {
      throw StateError('Folder path is required');
    }

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'workspace.delete_folder',
      payload: {'request_id': requestId, 'path': trimmedPath},
      requestId: requestId,
    );
    if (result?['event']?.toString() == 'workspace.delete_folder.preview') {
      final payload = result?['payload'] as Map<String, dynamic>? ?? result;
      final token = payload?['confirmation_token']?.toString() ?? '';
      final fingerprint = payload?['confirmation_fingerprint']?.toString() ?? '';
      if (token.isEmpty || fingerprint.isEmpty) {
        throw StateError('Failed to delete folder');
      }
      final confirmId = generateConversationRequestId();
      final confirmed = await _gateway.request(
        command: 'workspace.delete_folder',
        payload: {
          'request_id': confirmId,
          'path': trimmedPath,
          'confirmation_token': token,
          'confirmation_fingerprint': fingerprint,
        },
        requestId: confirmId,
      );
      _requireFolderMutationAcknowledgment(
        confirmed,
        expectedEvent: 'workspace.folder_deleted',
        fallbackMessage: 'Failed to delete folder',
      );
      return;
    }
    _requireFolderMutationAcknowledgment(
      result,
      expectedEvent: 'workspace.folder_deleted',
      fallbackMessage: 'Failed to delete folder',
    );
  }

  void _requireFolderMutationAcknowledgment(
    Map<String, dynamic>? result, {
    required String expectedEvent,
    required String fallbackMessage,
  }) {
    final event = result?['event']?.toString();
    if (event == expectedEvent) {
      return;
    }
    final payload = result?['payload'];
    final message = payload is Map ? payload['message'] : null;
    throw StateError(message?.toString() ?? fallbackMessage);
  }

  Future<List<CanonicalEvent>> loadSessionHistory(
    String sessionId, {
    String? anchorEventId,
  }) async {
    final generation = ++_historyHydrationGeneration;
    final restoredRetainedHistory = _conversationStore.activateSession(
      sessionId,
    );
    final retainedEvents = List<CanonicalEvent>.from(
      _conversationStore.currentMessages,
    );
    final retainedHistoryIsComplete =
        restoredRetainedHistory &&
        retainedEvents.isNotEmpty &&
        !_conversationStore.historyHasMore &&
        !_conversationStore.historyHasNewer;
    final baselineEventIds = retainedEvents.map((event) => event.id).toSet();

    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'get_session_history',
      payload: {
        'request_id': requestId,
        'session_id': sessionId,
        'limit': 100,
        if (anchorEventId != null) 'anchor_event_id': anchorEventId,
      },
      requestId: requestId,
    );

    if (result != null) {
      if (generation != _historyHydrationGeneration || _conversationStore.currentSessionId != sessionId) {
        return List<CanonicalEvent>.from(_conversationStore.currentMessages);
      }

      final payload = Map<String, dynamic>.from(
        result['payload'] as Map? ?? {},
      );
      _throwHistoryError(payload);
      final messagesData = payload['messages'] as List? ?? [];
      final queuedMessagesData = payload['queued_messages'] as List? ?? [];
      final pendingSteersData = payload['pending_steers'] as List? ?? [];
      _conversationStore.hydrateSessionState(payload, sessionId: sessionId);
      for (final raw in messagesData.whereType<Map>()) {
        final row = Map<String, dynamic>.from(raw);
        final type = row['type']?.toString();
        if (type != 'session_route_transition' && type != 'session_preferences_updated') {
          continue;
        }
        final metadata = Map<String, dynamic>.from(
          row['metadata'] as Map? ?? const {},
        );
        _conversationStore.applyRoutePayload({
          ...metadata,
          ...row,
          'session_id': row['session_id'] ?? metadata['session_id'] ?? sessionId,
        }, expectedSessionId: sessionId);
      }
      final events = _mapper.mapHistory(messagesData);
      final queuedEvents = _mapper.mapHistory(queuedMessagesData);
      final inFlight = payload['in_flight'];
      final transientEvents = _conversationStore.currentMessages
          .where((event) => !baselineEventIds.contains(event.id))
          .toList(growable: false);

      if (inFlight is Map) {
        final snapshotEvent = _mapper.mapLiveEvent({
          'device_id': '',
          'event': inFlight['type'] ?? 'thought_stream',
          'payload': Map<String, dynamic>.from(
            inFlight.cast<String, dynamic>(),
          ),
        });
        if (snapshotEvent != null) {
          events.add(snapshotEvent);
        }
      }

      if (_conversationStore.currentSessionId != sessionId) {
        return events;
      }

      final hydratedEvents = retainedHistoryIsComplete
          ? _mergeRetainedHistoryWithHydration(retainedEvents, events)
          : events;
      _conversationStore.setHistory(
        hydratedEvents,
        hasMore: retainedHistoryIsComplete ? false : payload['has_more'] == true,
        nextCursor: retainedHistoryIsComplete ? null : payload['next_cursor']?.toString(),
        hasNewer: retainedHistoryIsComplete ? false : payload['has_newer'] == true,
        nextNewerCursor: retainedHistoryIsComplete ? null : payload['next_newer_cursor']?.toString(),
      );
      _conversationStore.setQueuedMessages(queuedEvents);
      _conversationStore.hydratePendingSteers(
        pendingSteersData.whereType<Map>().map(
          (row) => PendingSteerRecord.fromJson(Map<String, dynamic>.from(row)),
        ),
        sessionId: sessionId,
      );
      final rawStopRecovery = payload['stop_draft_recovery'];
      if (rawStopRecovery is Map) {
        try {
          _conversationStore.applyStopRecovery(
            StopDraftRecovery.fromJson({
              ...Map<String, dynamic>.from(rawStopRecovery),
              'session_id': sessionId,
            }),
          );
        } on FormatException {
          // The durable payload remains available for a later hydration retry.
        }
      }
      final historyIdentityKeys = hydratedEvents.expand(_reconciliationIdentityKeys).toSet();
      for (final event in transientEvents) {
        if (_isAlreadyRepresentedInHistory(
          event,
          events,
          historyIdentityKeys,
        )) {
          continue;
        }
        _conversationStore.apply(event);
      }

      return List<CanonicalEvent>.from(_conversationStore.currentMessages);
    }

    _logger.severe(
      'History hydration failed phase=request session_id=$sessionId request_id=$requestId',
    );
    throw StateError('Session history request failed');
  }

  List<CanonicalEvent> _mergeRetainedHistoryWithHydration(
    List<CanonicalEvent> retained,
    List<CanonicalEvent> hydrated,
  ) {
    final foldedHydrated = _foldCanonicalEvents(hydrated);
    final hydratedById = {
      for (final event in foldedHydrated) event.id: event,
    };
    final merged = <CanonicalEvent>[
      for (final event in retained)
        switch (hydratedById.remove(event.id)) {
          final hydratedEvent? => event.merge(hydratedEvent),
          null => event,
        },
    ];
    merged.addAll(
      foldedHydrated.where(
        (event) => hydratedById.remove(event.id) != null,
      ),
    );
    return merged;
  }

  List<CanonicalEvent> _foldCanonicalEvents(
    Iterable<CanonicalEvent> events,
  ) {
    final folded = <CanonicalEvent>[];
    final indexById = <String, int>{};
    for (final event in events) {
      final index = indexById[event.id];
      if (index == null) {
        indexById[event.id] = folded.length;
        folded.add(event);
      } else {
        folded[index] = folded[index].merge(event);
      }
    }
    return folded;
  }

  Future<List<CanonicalEvent>> loadAnchoredSessionHistory(
    String sessionId,
    String anchorEventId,
  ) {
    return loadSessionHistory(sessionId, anchorEventId: anchorEventId);
  }

  Future<List<CanonicalEvent>> loadOlderSessionHistory(String sessionId) {
    final cursor = _conversationStore.historyNextCursor;
    if (_conversationStore.currentSessionId != sessionId || !_conversationStore.historyHasMore || cursor == null) {
      return Future.value(
        List<CanonicalEvent>.from(_conversationStore.currentMessages),
      );
    }
    final existing = _olderHistoryLoad;
    if (existing != null && _olderHistoryCursor == cursor) return existing;

    final generation = _historyHydrationGeneration;
    final load = _loadOlderSessionHistory(
      sessionId: sessionId,
      cursor: cursor,
      generation: generation,
    );
    _olderHistoryCursor = cursor;
    _olderHistoryLoad = load;
    return load.whenComplete(() {
      if (identical(_olderHistoryLoad, load)) {
        _olderHistoryLoad = null;
        _olderHistoryCursor = null;
      }
    });
  }

  Future<List<CanonicalEvent>> _loadOlderSessionHistory({
    required String sessionId,
    required String cursor,
    required int generation,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'get_session_history',
      payload: {
        'request_id': requestId,
        'session_id': sessionId,
        'limit': 100,
        'cursor': cursor,
      },
      requestId: requestId,
    );
    if (result == null) {
      throw StateError('Older session history request failed');
    }
    if (generation != _historyHydrationGeneration || _conversationStore.currentSessionId != sessionId) {
      return List<CanonicalEvent>.from(_conversationStore.currentMessages);
    }
    final payload = Map<String, dynamic>.from(result['payload'] as Map? ?? {});
    _throwHistoryError(payload);
    final events = _mapper.mapHistory(payload['messages'] as List? ?? const []);
    _conversationStore.prependHistory(
      events,
      hasMore: payload['has_more'] == true,
      nextCursor: payload['next_cursor']?.toString(),
      requestedCursor: cursor,
    );
    return List<CanonicalEvent>.from(_conversationStore.currentMessages);
  }

  Future<List<CanonicalEvent>> loadNewerSessionHistory(String sessionId) {
    final cursor = _conversationStore.historyNextNewerCursor;
    if (_conversationStore.currentSessionId != sessionId || !_conversationStore.historyHasNewer || cursor == null) {
      return Future.value(
        List<CanonicalEvent>.from(_conversationStore.currentMessages),
      );
    }
    final existing = _newerHistoryLoad;
    if (existing != null && _newerHistoryCursor == cursor) return existing;

    final generation = _historyHydrationGeneration;
    final load = _loadNewerSessionHistory(
      sessionId: sessionId,
      cursor: cursor,
      generation: generation,
    );
    _newerHistoryCursor = cursor;
    _newerHistoryLoad = load;
    return load.whenComplete(() {
      if (identical(_newerHistoryLoad, load)) {
        _newerHistoryLoad = null;
        _newerHistoryCursor = null;
      }
    });
  }

  Future<List<CanonicalEvent>> _loadNewerSessionHistory({
    required String sessionId,
    required String cursor,
    required int generation,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'get_session_history',
      payload: {
        'request_id': requestId,
        'session_id': sessionId,
        'limit': 100,
        'cursor': cursor,
      },
      requestId: requestId,
    );
    if (result == null) {
      throw StateError('Newer session history request failed');
    }
    if (generation != _historyHydrationGeneration || _conversationStore.currentSessionId != sessionId) {
      return List<CanonicalEvent>.from(_conversationStore.currentMessages);
    }
    final payload = Map<String, dynamic>.from(result['payload'] as Map? ?? {});
    _throwHistoryError(payload);
    final events = _mapper.mapHistory(
      payload['messages'] as List? ?? const [],
    );
    _conversationStore.appendHistory(
      events,
      hasNewer: payload['has_newer'] == true,
      nextNewerCursor: payload['next_newer_cursor']?.toString(),
      requestedCursor: cursor,
    );
    return List<CanonicalEvent>.from(_conversationStore.currentMessages);
  }

  void _throwHistoryError(Map<String, dynamic> payload) {
    final rawError = payload['error'];
    if (rawError is! Map) return;
    final error = Map<String, dynamic>.from(rawError);
    final code = error['code']?.toString() ?? 'history_failed';
    final message = error['message']?.toString() ?? 'Session history request failed';
    throw StateError('$code: $message');
  }

  Iterable<String> _reconciliationIdentityKeys(CanonicalEvent event) sync* {
    if (event.id.isNotEmpty) yield 'id:${event.id}';
    final messageId = event.messageId;
    if (messageId != null && messageId.isNotEmpty) {
      yield 'message:$messageId';
    }
    if (event.modelStepId != null && event.modelStepId!.isNotEmpty) {
      yield 'model_step:${event.kind.name}:${event.modelStepId}';
    }
    if (event.toolCallId != null && event.toolCallId!.isNotEmpty) {
      yield 'tool_call:${event.toolCallId}';
    }
    final requestId = event.metadata?['request_id']?.toString();
    if (requestId != null && requestId.isNotEmpty) {
      yield 'request:${event.kind.name}:$requestId';
    }
    final runId = event.runId;
    if (event.modelStepId == null && event.toolCallId == null && runId != null && runId.isNotEmpty) {
      yield 'run:${event.kind.name}:$runId';
    }
  }

  bool _isAlreadyRepresentedInHistory(
    CanonicalEvent transient,
    List<CanonicalEvent> history,
    Set<String> historyIdentityKeys,
  ) {
    final transientIdentityKeys = _reconciliationIdentityKeys(transient).toSet();
    final isRepresented = transientIdentityKeys.any(
      historyIdentityKeys.contains,
    );

    // A live tool result can arrive while the history request is in flight.
    // The returned snapshot may still contain the matching tool as running, so
    // identity alone is not enough: reapply the terminal live event to merge
    // its output and advance the stale history row.
    if (transient.kind == EventKind.toolCall && transient.status != EventStatus.running && isRepresented) {
      final matchingHistory = history.where((persisted) {
        if (persisted.kind != EventKind.toolCall) return false;
        return _reconciliationIdentityKeys(persisted).any(transientIdentityKeys.contains);
      });
      if (matchingHistory.any(
        (persisted) => persisted.status == EventStatus.running || isNewerToolTerminalEvent(persisted, transient),
      )) {
        return false;
      }
    }

    // Running thinking chunks may be newer than the persisted in-flight
    // snapshot and must still merge into it.
    if (transient.kind != EventKind.thinking && transient.kind != EventKind.reasoning && isRepresented) {
      return true;
    }
    if (transient.kind != EventKind.userMessage) return false;

    return history.any((persisted) {
      if (persisted.kind != EventKind.userMessage || persisted.text != transient.text) {
        return false;
      }
      if (persisted.sessionId != null && transient.sessionId != null && persisted.sessionId != transient.sessionId) {
        return false;
      }
      return persisted.timestamp.difference(transient.timestamp).abs() <= const Duration(minutes: 2);
    });
  }

  Future<void> updateSessionTitle(String sessionId, String title) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'update_session_title',
      payload: {
        'request_id': requestId,
        'session_id': sessionId,
        'title': title,
      },
      requestId: requestId,
    );

    if (result != null) {
      _logger.info(
        '✅ [ConversationCommands] Session title updated: $sessionId',
      );
    } else {
      _logger.severe('❌ [ConversationCommands] Failed to update session title');
    }
  }

  Future<void> deleteSession(String sessionId) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'delete_session',
      payload: {'request_id': requestId, 'session_id': sessionId},
      requestId: requestId,
    );

    if (result != null) {
      _logger.info('✅ [ConversationCommands] Session deleted: $sessionId');
    } else {
      _logger.severe('❌ [ConversationCommands] Failed to delete session');
      throw StateError(
        'The daemon did not confirm deletion of session $sessionId',
      );
    }
  }

  Future<void> respondToSuspendedRequest(
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
  }) async {
    if (!_gateway.isConnected) return;

    _gateway.sendCommand(
      command: 'tool_permission_response',
      payload: {
        'session_id': request.sessionId,
        'request_id': request.requestId,
        'allowed': allow,
        'scope': scope ?? request.scope,
        if (comment != null && comment.trim().isNotEmpty) 'comment': comment.trim(),
        if (answer != null && answer.trim().isNotEmpty) 'answer': answer.trim(),
      },
    );
  }
}
