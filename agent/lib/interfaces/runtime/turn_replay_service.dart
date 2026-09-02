import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/session_manager.dart';

enum TurnReplaySafety { safe, unsafe, unknown }

enum TurnReplayInspectionFailure {
  sessionNotFound,
  targetNotFound,
  targetIsNotLatestTurn,
  emptyMessage,
  targetNotReplayableInput,
  identityIncomplete,
  historyRevisionMismatch,
  targetPrecedesCompaction,
}

class TurnReplayAdmission {
  final int historyRevision;
  final String replacementTurnId;
  final String replacementMessageId;

  const TurnReplayAdmission({
    required this.historyRevision,
    required this.replacementTurnId,
    required this.replacementMessageId,
  });
}

class TurnReplayInspection {
  final String sessionId;
  final String targetRequestId;
  final String targetMessageId;
  final String targetTurnId;
  final String originalMessage;
  final int targetMessageIndex;
  final int historyRevision;
  final bool containsSteers;
  final TurnReplaySafety safety;
  final TurnReplayInspectionFailure? failure;

  const TurnReplayInspection({
    required this.sessionId,
    required this.targetRequestId,
    required this.targetMessageId,
    required this.targetTurnId,
    required this.originalMessage,
    required this.targetMessageIndex,
    required this.historyRevision,
    required this.containsSteers,
    required this.safety,
    this.failure,
  });

  bool get canReplay => failure == null;
  bool get requiresConfirmation =>
      safety == TurnReplaySafety.unsafe || safety == TurnReplaySafety.unknown;
}

/// Resolves a historical turn boundary and its daemon-owned tool replay safety.
///
/// Replay is permitted only for the latest active root user turn. Steer is
/// never a replay boundary.
class TurnReplayService {
  final SessionManager _sessionManager;
  final PersistedRuntimeStateRepository? _persistedState;
  final CompactionBoundaryRepository? _compactionBoundaries;

  const TurnReplayService({
    required SessionManager sessionManager,
    PersistedRuntimeStateRepository? persistedState,
    CompactionBoundaryRepository? compactionBoundaries,
  }) : _sessionManager = sessionManager,
       _persistedState = persistedState,
       _compactionBoundaries = compactionBoundaries;

  TurnReplayInspection inspect({
    required String sessionId,
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
    int? expectedHistoryRevision,
  }) {
    final session = _sessionManager.getSession(sessionId);
    if (session == null) {
      return _failure(
        sessionId,
        targetRequestId,
        TurnReplayInspectionFailure.sessionNotFound,
      );
    }
    if (expectedHistoryRevision != null &&
        expectedHistoryRevision != session.historyRevision) {
      return _failure(
        sessionId,
        targetRequestId,
        TurnReplayInspectionFailure.historyRevisionMismatch,
        historyRevision: session.historyRevision,
      );
    }

    final messages = session.messages;
    final targetIndex = _indexOfTarget(
      messages,
      targetRequestId: targetRequestId,
      targetMessageId: targetMessageId,
      targetTurnId: targetTurnId,
    );
    if (targetIndex < 0) {
      final pending = _persistedState?.pendingInputs.find(
        sessionId,
        targetRequestId,
      );
      final targetsEmbeddedSteer = _matchesEmbeddedSteer(
        messages,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
      );
      return _failure(
        sessionId,
        targetRequestId,
        pending == null && !targetsEmbeddedSteer
            ? TurnReplayInspectionFailure.targetNotFound
            : TurnReplayInspectionFailure.targetNotReplayableInput,
        historyRevision: session.historyRevision,
      );
    }

    final target = messages[targetIndex];
    if (MessageHistoryIdentity.isSteer(target) ||
        target.role != MessageRole.user) {
      return _failure(
        sessionId,
        targetRequestId,
        TurnReplayInspectionFailure.targetNotReplayableInput,
        historyRevision: session.historyRevision,
      );
    }
    final identity = MessageHistoryIdentity.read(target);
    if (!identity.replayEligible ||
        identity.messageId.isEmpty ||
        identity.turnId.isEmpty) {
      return _failure(
        sessionId,
        targetRequestId,
        TurnReplayInspectionFailure.identityIncomplete,
        historyRevision: session.historyRevision,
      );
    }
    if (targetMessageId != null &&
        targetMessageId.isNotEmpty &&
        identity.messageId != targetMessageId) {
      return _failure(
        sessionId,
        targetRequestId,
        TurnReplayInspectionFailure.targetNotFound,
        historyRevision: session.historyRevision,
      );
    }
    if (targetTurnId != null &&
        targetTurnId.isNotEmpty &&
        identity.turnId != targetTurnId) {
      return _failure(
        sessionId,
        targetRequestId,
        TurnReplayInspectionFailure.targetNotFound,
        historyRevision: session.historyRevision,
      );
    }

    final latestRootIndex = messages.lastIndexWhere(
      MessageHistoryIdentity.isRootUser,
    );
    if (targetIndex != latestRootIndex) {
      return _failure(
        sessionId,
        targetRequestId,
        TurnReplayInspectionFailure.targetIsNotLatestTurn,
        historyRevision: session.historyRevision,
      );
    }
    if (_compactionBoundaries?.targetPrecedesCompletedCompaction(
          sessionId: sessionId,
          messageId: identity.messageId,
        ) ==
        true) {
      return _failure(
        sessionId,
        targetRequestId,
        TurnReplayInspectionFailure.targetPrecedesCompaction,
        historyRevision: session.historyRevision,
      );
    }

    final originalMessage = target.content?.trim() ?? '';
    if (originalMessage.isEmpty) {
      return _failure(
        sessionId,
        targetRequestId,
        TurnReplayInspectionFailure.emptyMessage,
        historyRevision: session.historyRevision,
      );
    }

    final tail = messages.skip(targetIndex + 1);
    final containsSteers = tail.any(MessageHistoryIdentity.containsTurnSteers);
    final toolCallIds = <String>{};
    for (final message in tail) {
      for (final toolCall in message.toolCalls ?? const []) {
        toolCallIds.add(toolCall.id);
      }
    }

    var safety = TurnReplaySafety.safe;
    if (toolCallIds.isNotEmpty) {
      final workItem = _persistedState?.workItems.findByRequestId(
        sessionId,
        targetRequestId,
      );
      final replaySafety = Map<String, dynamic>.from(
        workItem?.continuationMetadata['tool_replay_safety'] as Map? ??
            const {},
      );
      if (toolCallIds.any((id) => replaySafety[id] == false)) {
        safety = TurnReplaySafety.unsafe;
      } else if (toolCallIds.any((id) => replaySafety[id] != true)) {
        safety = TurnReplaySafety.unknown;
      }
    }

    return TurnReplayInspection(
      sessionId: sessionId,
      targetRequestId: targetRequestId,
      targetMessageId: identity.messageId,
      targetTurnId: identity.turnId,
      originalMessage: originalMessage,
      targetMessageIndex: targetIndex,
      historyRevision: session.historyRevision,
      containsSteers: containsSteers,
      safety: safety,
    );
  }

  /// Soft-rewinds the target tail and accepts the replacement user record in
  /// one history-revision compare-and-swap. Dispatch happens after commit.
  /// The target is revalidated inside that transaction against current
  /// active history, so a newer root or revision change rolls back fully.
  TurnReplayAdmission? admitReplacement({
    required TurnReplayInspection inspection,
    required String replacementRequestId,
    required String replacementText,
    required String action,
  }) {
    if (!inspection.canReplay) return null;

    final replacement = Message(
      role: MessageRole.user,
      content: replacementText,
      metadata: {
        'request_id': replacementRequestId,
        'input_kind': MessageHistoryIdentity.rootTurn,
        'history_status': MessageHistoryIdentity.active,
        'turn_replay_action': action,
        'replays_turn_id': inspection.targetTurnId,
        'supersedes_turn_id': inspection.targetTurnId,
      },
    );
    final commit = _sessionManager.commitSoftRewindAdmission(
      sessionId: inspection.sessionId,
      expectedHistoryRevision: inspection.historyRevision,
      targetMessageId: inspection.targetMessageId,
      targetTurnId: inspection.targetTurnId,
      targetRequestId: inspection.targetRequestId,
      replacement: replacement,
    );
    if (commit == null) return null;
    return TurnReplayAdmission(
      historyRevision: commit.historyRevision,
      replacementTurnId: commit.replacementTurnId,
      replacementMessageId: commit.replacementMessageId,
    );
  }

  static bool _matchesEmbeddedSteer(
    List<Message> messages, {
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
  }) {
    for (final message in messages) {
      final rawSteers = message.metadata?['steer_messages'];
      if (rawSteers is! List) continue;
      for (final rawSteer in rawSteers) {
        if (rawSteer is! Map) continue;
        final steer = Map<String, dynamic>.from(rawSteer);
        if (steer['request_id']?.toString() != targetRequestId) continue;
        if (targetMessageId != null &&
            targetMessageId.isNotEmpty &&
            steer['message_id']?.toString() != targetMessageId) {
          continue;
        }
        if (targetTurnId != null &&
            targetTurnId.isNotEmpty &&
            steer['turn_id']?.toString() != targetTurnId) {
          continue;
        }
        return true;
      }
    }
    return false;
  }

  static int _indexOfTarget(
    List<Message> messages, {
    required String targetRequestId,
    String? targetMessageId,
    String? targetTurnId,
  }) {
    for (var index = messages.length - 1; index >= 0; index--) {
      final message = messages[index];
      if (message.role != MessageRole.user) continue;
      final identity = MessageHistoryIdentity.read(message);
      if (identity.requestId != targetRequestId) continue;
      if (targetMessageId != null &&
          targetMessageId.isNotEmpty &&
          identity.messageId != targetMessageId) {
        continue;
      }
      if (targetTurnId != null &&
          targetTurnId.isNotEmpty &&
          identity.turnId != targetTurnId) {
        continue;
      }
      return index;
    }
    return -1;
  }

  TurnReplayInspection _failure(
    String sessionId,
    String targetRequestId,
    TurnReplayInspectionFailure failure, {
    int historyRevision = 0,
  }) {
    return TurnReplayInspection(
      sessionId: sessionId,
      targetRequestId: targetRequestId,
      targetMessageId: '',
      targetTurnId: '',
      originalMessage: '',
      targetMessageIndex: -1,
      historyRevision: historyRevision,
      containsSteers: false,
      safety: TurnReplaySafety.unknown,
      failure: failure,
    );
  }
}
