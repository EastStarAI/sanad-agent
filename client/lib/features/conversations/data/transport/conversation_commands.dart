import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/session_query.dart';
import 'package:sanad_client/features/conversations/domain/models/session_search.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/canonical_event.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/workspace_tree_snapshot.dart';
import 'package:sanad_client/features/conversations/data/mappers/device_event_mapper.dart';
import 'package:sanad_client/features/conversations/data/transport/command_response_errors.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_command_gateway.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_history_commands.dart';
import 'package:sanad_client/features/conversations/data/transport/workspace_commands.dart';
import 'package:sanad_client/features/conversations/domain/stores/device_conversation_store.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/models/session_fork_result.dart';
import 'package:sanad_client/features/conversations/data/transport/conversation_request_id.dart';
import 'package:uuid/uuid.dart';

class ConversationCommands {
  static final _logger = Logger('ConversationCommands');

  final ConversationCommandGateway _gateway;
  final DeviceConversationStore _conversationStore;
  final WorkspaceCommands _workspace;
  final ConversationHistoryCommands _history;

  /// Acknowledgement window for `session.compact`; equal to the gateway's
  /// default request window and intentionally not raised.
  static const defaultCompactAcknowledgementTimeout = Duration(seconds: 10);

  /// Upper bound for correlating a late `session.compact_result` after the
  /// acknowledgement window elapsed. Past it the outcome is unconfirmed.
  static const defaultCompactSettlementWindow = Duration(minutes: 10);

  final Duration _compactAcknowledgementTimeout;
  final Duration _compactSettlementWindow;

  ConversationCommands({
    required ConversationCommandGateway gateway,
    required DeviceConversationStore conversationStore,
    required DeviceEventMapper mapper,
    Duration compactAcknowledgementTimeout = defaultCompactAcknowledgementTimeout,
    Duration compactSettlementWindow = defaultCompactSettlementWindow,
  }) : _gateway = gateway,
       _conversationStore = conversationStore,
       _workspace = WorkspaceCommands(gateway: gateway),
       _history = ConversationHistoryCommands(
         gateway: gateway,
         conversationStore: conversationStore,
         mapper: mapper,
       ),
       _compactAcknowledgementTimeout = compactAcknowledgementTimeout,
       _compactSettlementWindow = compactSettlementWindow;

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

  Future<String?> sendMessageWithAttachments(
    String message, {
    required String sessionId,
    String? workspaceId,
    String? context,
    String? providerId,
    String? model,
    String? thinkingMode,
    required List<Map<String, dynamic>> attachments,
    MessageDeliveryIntent intent = MessageDeliveryIntent.auto,
  }) async {
    if (!_gateway.isConnected) return null;
    if (attachments.isEmpty) {
      return sendMessage(
        message,
        sessionId: sessionId,
        workspaceId: workspaceId,
        context: context,
        providerId: providerId,
        model: model,
        thinkingMode: thinkingMode,
        intent: intent,
      );
    }
    final requestId = generateConversationRequestId();
    final List<String> attachmentIds;
    if (_gateway.isLocalTransport) {
      final response = await _gateway.request(
        command: 'attachment.admit',
        requestId: requestId,
        timeout: const Duration(seconds: 30),
        payload: {
          'request_id': requestId,
          'session_id': sessionId,
          'attachments': attachments,
        },
      );
      final responsePayload = response?['payload'] is Map
          ? Map<String, dynamic>.from(response!['payload'] as Map)
          : const <String, dynamic>{};
      final rawIds = responsePayload['attachment_ids'];
      attachmentIds = rawIds is List
          ? rawIds.whereType<String>().where((id) => id.isNotEmpty).toList(growable: false)
          : const <String>[];
      if (responsePayload['outcome'] != 'accepted') {
        throw StateError('Attachment admission failed.');
      }
    } else {
      attachmentIds = await _gateway.admitHostedAttachments(
        sessionId: sessionId,
        requestId: requestId,
        attachments: attachments,
      );
    }
    if (attachmentIds.length != attachments.length) {
      throw StateError('Attachment admission failed.');
    }

    _conversationStore.beginOutgoingRequest(
      requestId: requestId,
      sessionId: sessionId,
      isDraftRequest: false,
    );
    _gateway.sendCommand(
      command: 'think',
      payload: {
        'request_id': requestId,
        'session_id': sessionId,
        'message': message,
        'attachment_ids': attachmentIds,
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
    if (!_gateway.isConnected) {
      throw StateError('Cannot promote a queued message while disconnected.');
    }
    final commandRequestId = generateConversationRequestId();
    _gateway.sendCommand(
      command: 'steer',
      payload: {
        'request_id': requestId,
        'target_request_id': requestId,
        'command_request_id': commandRequestId,
        'session_id': sessionId,
        'message': message,
      },
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

    throwIfErrorResponse(result, 'Failed to create session');
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
    List<Map<String, dynamic>>? attachmentEdits,
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
        if (attachmentEdits != null) 'attachment_edits': attachmentEdits,
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
    // Listen before dispatch so a result arriving right after the
    // acknowledgement window cannot be missed.
    final lateResult = _CompactSettlement(
      events: _gateway.events,
      sessionId: sessionId,
      requestId: requestId,
      window: _compactSettlementWindow,
    );
    final Map<String, dynamic>? result;
    try {
      result = await _gateway.request(
        command: 'session.compact',
        payload: {'session_id': sessionId, 'request_id': requestId},
        requestId: requestId,
        timeout: _compactAcknowledgementTimeout,
      );
    } catch (_) {
      lateResult.cancel();
      rethrow;
    }
    if (result == null) {
      // Dispatched once, but unacknowledged in time: the daemon may still be
      // compacting. Never resend and never report this as a failure.
      return SessionCompactResult(
        outcome: SessionCompactResult.pendingOutcome,
        requestId: requestId,
        settlement: lateResult.future,
      );
    }
    lateResult.cancel();
    return SessionCompactResult.fromJson(responsePayload(result));
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
    final hasThinkingModeUpdate = thinkingMode != null;
    if ((nextModel == null || nextModel.isEmpty) &&
        !hasThinkingModeUpdate &&
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
        if (nextProviderId != null && nextProviderId.isNotEmpty) 'provider_instance_id': nextProviderId,
        if (hasThinkingModeUpdate) 'thinking_mode': nextThinkingMode ?? '',
      },
      requestId: requestId,
    );

    if (result == null) {
      throw StateError('Failed to update session preferences');
    }
    throwIfErrorResponse(result, 'Failed to update session preferences');
  }

  Future<SessionQueryResult> getSessions({SessionQueryRequest? query}) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'get_sessions',
      payload: {'request_id': requestId, ...?query?.toJson()},
      requestId: requestId,
    );

    final error = responseError(result);
    if (result != null && error == null) {
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

    _logger.severe(
      '❌ [ConversationCommands] Failed to get sessions'
      '${error == null ? '' : ' code=${error.code ?? 'error'}'}',
    );
    throw StateError('Failed to get sessions from gateway');
  }

  Future<SessionSearchPage> searchSessions({
    required String query,
    int limit = 20,
    String? cursor,
  }) async {
    final requestId = generateConversationRequestId();
    final result = await _gateway.request(
      command: 'search_sessions',
      payload: {
        'request_id': requestId,
        'query': query,
        'limit': limit,
        if (cursor != null) 'cursor': cursor,
      },
      requestId: requestId,
    );
    if (result == null) {
      throw const SessionSearchException(
        'gateway_unavailable',
        'Conversation search is unavailable.',
      );
    }
    final payload = responsePayload(result);
    final error = responseError(result);
    if (error != null) {
      throw SessionSearchException(
        error.code ?? 'session_search_failed',
        error.message ?? 'Conversation search failed.',
      );
    }
    final deviceId = result['device_id']?.toString();
    final hits = (payload['results'] as List? ?? const []).map((raw) {
      final hit = Map<String, dynamic>.from(raw as Map);
      final session = Map<String, dynamic>.from(hit['session'] as Map);
      if (deviceId != null && session['device_id'] == null) {
        session['device_id'] = deviceId;
      }
      hit['session'] = session;
      return SessionSearchHit.fromJson(hit);
    }).toList();
    return SessionSearchPage(
      hits: hits,
      nextCursor: payload['next_cursor']?.toString(),
      hasMore: payload['has_more'] == true,
    );
  }

  Future<List<DeviceWorkspace>> getWorkspaces() => _workspace.getWorkspaces();

  Future<List<SlashCommandEntry>> searchSlashCommands({
    String? query,
    String? workspaceId,
  }) => _workspace.searchSlashCommands(query: query, workspaceId: workspaceId);

  Future<WorkspaceTreeSnapshot> browseWorkspaceTree({
    String? workspaceId,
    String? path,
  }) => _workspace.browseWorkspaceTree(workspaceId: workspaceId, path: path);

  Future<DeviceWorkspace> createWorkspace({
    String? path,
    String? name,
    String? description,
  }) => _workspace.createWorkspace(
    path: path,
    name: name,
    description: description,
  );

  Future<DeviceWorkspace> renameWorkspace({
    required String workspaceId,
    required String displayName,
  }) => _workspace.renameWorkspace(
    workspaceId: workspaceId,
    displayName: displayName,
  );

  Future<void> removeWorkspace({required String workspaceId}) =>
      _workspace.removeWorkspace(workspaceId: workspaceId);

  Future<DeviceWorkspace> relocateWorkspace({
    required String workspaceId,
    required String newPath,
  }) => _workspace.relocateWorkspace(
    workspaceId: workspaceId,
    newPath: newPath,
  );

  Future<void> createFolder({required String parentPath, required String name}) =>
      _workspace.createFolder(parentPath: parentPath, name: name);

  Future<void> renameFolder({required String path, required String newName}) =>
      _workspace.renameFolder(path: path, newName: newName);

  Future<void> deleteFolder({required String path}) =>
      _workspace.deleteFolder(path: path);

  Future<List<CanonicalEvent>> loadSessionHistory(
    String sessionId, {
    String? anchorEventId,
  }) => _history.loadSessionHistory(sessionId, anchorEventId: anchorEventId);

  Future<List<CanonicalEvent>> loadAnchoredSessionHistory(
    String sessionId,
    String anchorEventId,
  ) => _history.loadAnchoredSessionHistory(sessionId, anchorEventId);

  Future<List<CanonicalEvent>> loadOlderSessionHistory(String sessionId) =>
      _history.loadOlderSessionHistory(sessionId);

  Future<List<CanonicalEvent>> loadNewerSessionHistory(String sessionId) =>
      _history.loadNewerSessionHistory(sessionId);

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

    if (result != null && responseError(result) == null) {
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

    if (result != null && responseError(result) == null) {
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
    Map<String, String>? secretValues,
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
        // Secret values are sent exactly as typed and only in this field;
        // they are never logged, cached or projected into the timeline.
        if (secretValues != null && secretValues.isNotEmpty) 'secret_values': secretValues,
      },
    );
  }
}

/// Correlates one late `session.compact_result` with the exact session and
/// request of a pending manual compaction. Settles at most once: with the
/// daemon's result, or as unconfirmed when the window elapses or the event
/// stream closes. It only observes events and never dispatches.
class _CompactSettlement {
  static const _resultEvent = 'session.compact_result';

  final String _sessionId;
  final String _requestId;
  final Completer<SessionCompactResult> _completer = Completer();
  late final StreamSubscription<Map<String, dynamic>> _subscription;
  late final Timer _timer;

  _CompactSettlement({
    required Stream<Map<String, dynamic>> events,
    required String sessionId,
    required String requestId,
    required Duration window,
  }) : _sessionId = sessionId,
       _requestId = requestId {
    _subscription = events.listen(_onEvent, onDone: _settleUnconfirmed);
    _timer = Timer(window, _settleUnconfirmed);
  }

  Future<SessionCompactResult> get future => _completer.future;

  void _onEvent(Map<String, dynamic> event) {
    final payload = responsePayload(event);
    final type = event['event'] as String? ?? payload['type'] as String?;
    if (type != _resultEvent) return;
    final requestId = event['request_id'] ?? payload['request_id'];
    final sessionId = event['session_id'] ?? payload['session_id'];
    if (requestId != _requestId || sessionId != _sessionId) return;
    _settle(SessionCompactResult.fromJson(payload));
  }

  void _settleUnconfirmed() => _settle(
    SessionCompactResult(
      outcome: SessionCompactResult.unconfirmedOutcome,
      requestId: _requestId,
    ),
  );

  void _settle(SessionCompactResult result) {
    if (_completer.isCompleted) return;
    _completer.complete(result);
    cancel();
  }

  void cancel() {
    _timer.cancel();
    unawaited(_subscription.cancel());
  }
}
