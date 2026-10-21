import 'dart:async';

import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';
import 'package:sanad_client/features/conversations/domain/models/device_suspended_request.dart';
import 'package:sanad_client/features/conversations/domain/models/compaction_event_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/session_fork_result.dart';
import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/domain/models/stop_draft_recovery.dart';
import 'package:sanad_client/features/conversations/domain/models/turn_replay_result.dart';
import 'package:sanad_client/features/conversations/domain/models/device_workspace.dart';
import 'package:sanad_client/features/conversations/domain/repositories/conversation_repository.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_state.dart';
import 'package:sanad_client/features/devices/domain/device_preferences_repository.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';

/// Encapsulates turn intervention, steer, stop/recovery, turn replay, fork,
/// runtime notice recovery, and suspended requests for [SessionMessagesCubit].
class SessionInterventionCoordinator {
  static final _logger = Logger('SessionInterventionCoordinator');

  final ConversationRepository conversationRepository;
  final SessionCubit sessionCubit;
  final IDevicePreferencesRepository preferencesRepository;
  final DeviceConfig? Function() getCurrentAgent;
  final SessionMessagesState Function() getState;
  final void Function(SessionMessagesState) emit;
  final bool Function() getIsClosed;
  final void Function({
    required String sessionId,
    String? providerId,
    String? modelId,
  }) setPendingRouteSelection;
  final Map<String, String> nextMessageProviderByAgentId;
  final Map<String, String> nextMessageModelByAgentId;
  final Map<String, String> nextMessageThinkingByAgentId;
  final DeviceWorkspace? Function(DeviceConfig) selectedWorkspaceForAgent;

  final Set<String> _initiatedStopRequestIds = {};
  final Map<String, String> _stopRecoveryClaimIds = {};

  /// Stop-recovery acknowledgments already dispatched by this client.
  ///
  /// A second delivery of the same recovery (a reconnect replay, a duplicate
  /// stream event, or a rebuilt UI surface) must not dispatch a second
  /// acknowledgment, so the request id is claimed for the whole in-flight
  /// window and released only when the attempt settles.
  final Set<String> _inFlightStopRecoveryAckIds = {};

  /// Releases every in-flight stop-recovery acknowledgment claim.
  ///
  /// Called when the owning session surface is torn down or reset so a stale
  /// claim can never suppress a legitimate later acknowledgment.
  void clearInFlightStopRecoveryAcks() => _inFlightStopRecoveryAckIds.clear();

  SessionInterventionCoordinator({
    required this.conversationRepository,
    required this.sessionCubit,
    required this.preferencesRepository,
    required this.getCurrentAgent,
    required this.getState,
    required this.emit,
    required this.getIsClosed,
    required this.setPendingRouteSelection,
    required this.nextMessageProviderByAgentId,
    required this.nextMessageModelByAgentId,
    required this.nextMessageThinkingByAgentId,
    required this.selectedWorkspaceForAgent,
  });

  Future<void> steerMessage(String text, {required String requestId}) async {
    final agent = getCurrentAgent();
    final sessionId = getState().activeSessionId;
    if (agent == null || sessionId == null || sessionId.isEmpty) return;
    emit(getState().copyWith(
      queuedMutationRequestIds: {...getState().queuedMutationRequestIds, requestId},
    ));
    try {
      await conversationRepository.steerMessage(
        agent,
        text,
        requestId: requestId,
        sessionId: sessionId,
      );
    } catch (e) {
      emit(
        getState().copyWith(
          error: e.toString(),
          queuedMutationRequestIds: {...getState().queuedMutationRequestIds}..remove(requestId),
        ),
      );
    }
  }

  Future<void> deleteQueuedMessage({required String requestId}) async {
    final agent = getCurrentAgent();
    final sessionId = getState().activeSessionId;
    if (agent == null || sessionId == null || requestId.isEmpty) return;
    emit(getState().copyWith(
      queuedMutationRequestIds: {...getState().queuedMutationRequestIds, requestId},
    ));
    final operationId = await conversationRepository.deleteQueuedMessage(
      agent,
      requestId: requestId,
      sessionId: sessionId,
    );
    if (operationId == null) {
      emit(getState().copyWith(
        queuedMutationRequestIds: {...getState().queuedMutationRequestIds}..remove(requestId),
      ));
    }
  }

  Future<void> cancelPendingSteer({required String requestId}) async {
    final agent = getCurrentAgent();
    final sessionId = getState().activeSessionId;
    if (agent == null || sessionId == null || requestId.isEmpty) return;
    emit(
      getState().copyWith(
        pendingSteerCancellationRequestIds: {
          ...getState().pendingSteerCancellationRequestIds,
          requestId,
        },
      ),
    );
    final operationId = await conversationRepository.cancelPendingSteer(
      agent,
      requestId: requestId,
      sessionId: sessionId,
    );
    if (operationId == null) {
      emit(
        getState().copyWith(
          pendingSteerCancellationRequestIds: {
            ...getState().pendingSteerCancellationRequestIds,
          }..remove(requestId),
        ),
      );
    }
  }

  Future<void> stop() async {
    final agent = getCurrentAgent();
    final sessionId = getState().activeSessionId;
    if (agent == null || sessionId == null) return;
    final requestId = const Uuid().v4();
    final recoveryOwnerToken = const Uuid().v4();
    final cache = sessionCubit.conversationCacheRepository;
    try {
      await cache?.markStopRecoveryPendingAndFlush(
        agent.id,
        sessionId,
        requestId,
        ownerToken: recoveryOwnerToken,
      );
    } catch (_) {
      return;
    }
    _initiatedStopRequestIds.add(requestId);
    final acceptedRequestId = await conversationRepository.stop(
      agent,
      sessionId: sessionId,
      requestId: requestId,
      recoveryOwnerToken: recoveryOwnerToken,
    );
    if (acceptedRequestId == null) {
      _initiatedStopRequestIds.remove(requestId);
      await cache?.unmarkStopRecoveryPendingAndFlush(agent.id, sessionId, requestId);
    }
  }

  Future<void> applyStopRecovery(DeviceConfig agent, StopDraftRecovery recovery) async {
    final cache = sessionCubit.conversationCacheRepository;
    if (cache == null) return;
    if (recovery.claimRequired) {
      if (_stopRecoveryClaimIds.containsKey(recovery.stopRequestId)) return;
      final claimId = const Uuid().v4();
      _stopRecoveryClaimIds[recovery.stopRequestId] = claimId;
      try {
        await cache.setStopRecoveryClaimAndFlush(
          agent.id,
          recovery.sessionId,
          recovery.stopRequestId,
          claimId,
        );
      } catch (_) {
        _stopRecoveryClaimIds.remove(recovery.stopRequestId);
        return;
      }
      final acceptedClaimId = await conversationRepository.claimStopRecovery(
        agent,
        sessionId: recovery.sessionId,
        stopRequestId: recovery.stopRequestId,
        commandRequestId: claimId,
      );
      if (acceptedClaimId == null) {
        _stopRecoveryClaimIds.remove(recovery.stopRequestId);
        try {
          await cache.clearStopRecoveryClaimAndFlush(
            agent.id,
            recovery.sessionId,
            recovery.stopRequestId,
          );
        } catch (_) {}
      }
      return;
    }
    final draft = cache.sessionDraft(agent.id, recovery.sessionId);
    final persistedClaimId = draft?.stopRecoveryClaimIds[recovery.stopRequestId];
    final recoveryOwnerToken = draft?.stopRecoveryOwnerTokens[recovery.stopRequestId];
    final claimedByThisClient =
        recovery.recoveryReason == 'daemon_restart' &&
        recovery.claimedBy != null &&
        (_stopRecoveryClaimIds[recovery.stopRequestId] == recovery.claimedBy ||
            persistedClaimId == recovery.claimedBy);
    final alreadyApplied =
        draft?.appliedStopRecoveryIds.contains(recovery.stopRequestId) == true;
    final isOwned = recovery.recoveryReason == 'daemon_restart'
        ? claimedByThisClient || alreadyApplied
        : (recoveryOwnerToken != null &&
              recoveryOwnerToken.isNotEmpty &&
              !alreadyApplied);
    if (!isOwned) return;
    if (_inFlightStopRecoveryAckIds.contains(recovery.stopRequestId)) return;
    _inFlightStopRecoveryAckIds.add(recovery.stopRequestId);
    try {
      final changed = await cache.prependStopRecoveryAndFlush(
        agent.id,
        recovery.sessionId,
        stopRequestId: recovery.stopRequestId,
        texts: recovery.inputs.map((input) => input.text),
      );
      if (!changed && !alreadyApplied) {
        _inFlightStopRecoveryAckIds.remove(recovery.stopRequestId);
        return;
      }
    } catch (_) {
      _inFlightStopRecoveryAckIds.remove(recovery.stopRequestId);
      return;
    }
    await conversationRepository.acknowledgeStopRecovery(
      agent,
      sessionId: recovery.sessionId,
      stopRequestId: recovery.stopRequestId,
      claimantId: recovery.recoveryReason == 'daemon_restart' ? recovery.claimedBy : null,
      recoveryOwnerToken:
          recovery.recoveryReason == 'user_stop' ? recoveryOwnerToken : null,
    );
    _initiatedStopRequestIds.remove(recovery.stopRequestId);
    _stopRecoveryClaimIds.remove(recovery.stopRequestId);
    try {
      await cache.clearStopRecoveryClaimAndFlush(
        agent.id,
        recovery.sessionId,
        recovery.stopRequestId,
      );
    } catch (_) {}
    if (recovery.recoveryReason == 'user_stop') {
      try {
        await cache.clearStopRecoveryOwnerTokenAndFlush(
          agent.id,
          recovery.sessionId,
          recovery.stopRequestId,
        );
      } catch (_) {}
    }
  }

  Future<TurnReplayResult> replayTurn({
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
    int? expectedHistoryRevision,
    required TurnReplayAction action,
    String? message,
    List<Map<String, dynamic>>? attachmentEdits,
    bool confirmedReplayUnsafe = false,
    bool confirmedDropSteers = false,
  }) async {
    final agent = getCurrentAgent();
    final sessionId = getState().activeSessionId;
    if (agent == null || sessionId == null || sessionId.isEmpty) {
      return const TurnReplayResult(
        outcome: 'missing_session',
        safety: TurnReplaySafety.unknown,
        requiresConfirmation: false,
      );
    }
    final revision =
        expectedHistoryRevision ??
        sessionCubit.state.selectedSession?.historyRevision ??
        0;
    final repository = conversationRepository;
    final TurnReplayResult result;
    if (attachmentEdits != null) {
      if (repository is! AttachmentReplayRepository) {
        return const TurnReplayResult(
          outcome: 'attachments_unsupported',
          safety: TurnReplaySafety.unknown,
          requiresConfirmation: false,
        );
      }
      result = await (repository as AttachmentReplayRepository)
          .replayTurnWithAttachments(
            agent,
            sessionId: sessionId,
            targetRequestId: targetRequestId,
            targetMessageId: targetMessageId,
            targetTurnId: targetTurnId,
            expectedHistoryRevision: revision,
            action: action,
            message: message ?? '',
            attachmentEdits: attachmentEdits,
            providerInstanceId: getState().nextMessageProviderId,
            modelId: getState().nextMessageModel,
            thinkingMode: getState().nextMessageThinkingMode,
            confirmedReplayUnsafe: confirmedReplayUnsafe,
            confirmedDropSteers: confirmedDropSteers,
          );
    } else {
      result = await repository.replayTurn(
        agent,
        sessionId: sessionId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        expectedHistoryRevision: revision,
        action: action,
        message: message,
        providerInstanceId: getState().nextMessageProviderId,
        modelId: getState().nextMessageModel,
        thinkingMode: getState().nextMessageThinkingMode,
        confirmedReplayUnsafe: confirmedReplayUnsafe,
        confirmedDropSteers: confirmedDropSteers,
      );
    }
    final nextRevision = result.historyRevision;
    final selected = sessionCubit.state.selectedSession;
    if (nextRevision != null && selected != null && selected.id == sessionId) {
      sessionCubit.applyHistoryRevision(sessionId, nextRevision);
    }
    return result;
  }

  Future<SessionForkResult> forkSession({
    required String targetMessageId,
    required String targetTurnId,
  }) async {
    final agent = getCurrentAgent();
    final sessionId = getState().activeSessionId;
    if (agent == null || sessionId == null || sessionId.isEmpty) {
      return const SessionForkResult(outcome: 'missing_session');
    }
    final result = await conversationRepository.forkSession(
      agent,
      sessionId: sessionId,
      targetMessageId: targetMessageId,
      targetTurnId: targetTurnId,
    );
    final child = result.child;
    if (result.isAccepted && child != null) {
      try {
        await sessionCubit.adoptForkedSession(
          child.copyWith(deviceId: child.deviceId ?? agent.id),
        );
      } catch (error, stackTrace) {
        _logger.warning(
          'Fork committed but child navigation failed.',
          error,
          stackTrace,
        );
        return SessionForkResult(
          outcome: result.outcome,
          child: child,
          navigationFailed: true,
        );
      }
    }
    return result;
  }

  Future<void> retryRuntimeNotice() async {
    final agent = getCurrentAgent();
    final notice = getState().runtimeNotice;
    if (agent == null || notice == null) {
      return;
    }
    final providerId = getState().nextMessageProviderId?.trim();
    final modelId = getState().nextMessageModel?.trim();
    await conversationRepository.retryRuntimeNotice(
      agent,
      sessionId: notice.sessionId,
      requestId: notice.requestId,
      providerInstanceId:
          providerId == null || providerId.isEmpty ? null : providerId,
      modelId: modelId == null || modelId.isEmpty ? null : modelId,
    );
  }

  Future<void> continueWithProvider({
    required String providerInstanceId,
    String? modelId,
  }) async {
    final agent = getCurrentAgent();
    final notice = getState().runtimeNotice;
    if (agent == null || notice == null) {
      return;
    }
    setPendingRouteSelection(
      sessionId: notice.sessionId,
      providerId: providerInstanceId,
      modelId: modelId,
    );
    emit(
      getState().copyWith(
        activeSessionId: notice.sessionId,
        pendingNextMessageProviderId: providerInstanceId,
        pendingNextMessageModel: modelId?.trim().isEmpty ?? true
            ? getState().pendingNextMessageModel
            : modelId!.trim(),
      ),
    );
    await conversationRepository.continueWithProvider(
      agent,
      sessionId: notice.sessionId,
      providerInstanceId: providerInstanceId,
      requestId: notice.requestId,
      modelId: modelId?.trim().isEmpty ?? true ? null : modelId!.trim(),
    );
  }

  Future<void> respondToSuspendedRequest(
    DeviceSuspendedRequest request, {
    required bool allow,
    String? scope,
    String? comment,
    String? answer,
    Map<String, String>? secretValues,
  }) async {
    final agent = getCurrentAgent();
    if (agent == null) return;
    try {
      await conversationRepository.respondToSuspendedRequest(
        agent,
        request,
        allow: allow,
        scope: scope,
        comment: comment,
        answer: answer,
        secretValues: secretValues,
      );
      emit(
        getState().copyWith(
          clearPendingSuspendedRequest: true,
        ),
      );
    } catch (e) {
      emit(getState().copyWith(error: e.toString()));
    }
  }

  Future<SessionCompactResult> compactSession() async {
    final agent = getCurrentAgent();
    final sessionId = getState().activeSessionId;
    if (agent == null || sessionId == null || sessionId.isEmpty) {
      return const SessionCompactResult(outcome: 'missing_session');
    }
    return conversationRepository.compactSession(
      agent,
      sessionId: sessionId,
    );
  }

  Future<List<SlashCommandEntry>> searchSlashCommands({String? query}) async {
    final agent = getCurrentAgent();
    if (agent == null) {
      return const [];
    }

    return conversationRepository.searchSlashCommands(
      agent,
      query: query,
      workspaceId: selectedWorkspaceForAgent(agent)?.id,
    );
  }
}
