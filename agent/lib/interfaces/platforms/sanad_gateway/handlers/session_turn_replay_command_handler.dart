import 'dart:async';
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/core/models/user_attachment.dart';
import 'package:sanad_agent/evolution/attachments/attachment_store.dart';

import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/compaction_boundary_repository.dart';
import 'package:sanad_agent/evolution/db/message_history_identity.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/models/session_execution_snapshot.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/session_run_orchestrator.dart';
import 'package:sanad_agent/interfaces/runtime/turn_replay_service.dart';

import '../sanad_protocol_bridge.dart';

class SessionTurnReplayCommandHandler {
  static const Duration defaultIdleWaitTimeout = Duration(seconds: 15);
  static const Duration defaultIdlePollInterval = Duration(milliseconds: 25);

  final SessionRunOrchestrator _orchestrator;
  final SessionManager _sessionManager;
  final PersistedRuntimeStateRepository? _persistedState;
  final CompactionBoundaryRepository? _compactionBoundaries;
  final SanadProtocolBridge _bridge;
  final AttachmentStore? _attachmentStore;
  final Duration _idleWaitTimeout;
  final Duration _idlePollInterval;
  final Set<String> _sessionsInFlight = <String>{};

  SessionTurnReplayCommandHandler({
    required SessionRunOrchestrator orchestrator,
    required SessionManager sessionManager,
    PersistedRuntimeStateRepository? persistedState,
    CompactionBoundaryRepository? compactionBoundaries,
    required SanadProtocolBridge bridge,
    AttachmentStore? attachmentStore,
    Duration idleWaitTimeout = defaultIdleWaitTimeout,
    Duration idlePollInterval = defaultIdlePollInterval,
  }) : _orchestrator = orchestrator,
       _sessionManager = sessionManager,
       _persistedState = persistedState,
       _compactionBoundaries = compactionBoundaries,
       _bridge = bridge,
       _attachmentStore = attachmentStore,
       _idleWaitTimeout = idleWaitTimeout,
       _idlePollInterval = idlePollInterval;

  Future<void> handle(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final sessionId =
        event.sessionId ?? event.payload['session_id']?.toString() ?? '';
    final targetRequestId =
        event.payload['target_request_id']?.toString().trim() ?? '';
    final targetMessageId =
        event.payload['target_message_id']?.toString().trim() ?? '';
    final targetTurnId =
        event.payload['target_turn_id']?.toString().trim() ?? '';
    final commandRequestId =
        event.payload['request_id']?.toString().trim() ?? '';
    final action = event.payload['action']?.toString() ?? 'retry';
    final confirmed = event.payload['confirmed_replay_unsafe'] == true;
    final confirmedDropSteers = event.payload['confirmed_drop_steers'] == true;
    final expectedHistoryRevision = _parseRevision(
      event.payload['expected_history_revision'],
    );

    if (sessionId.isEmpty ||
        targetRequestId.isEmpty ||
        targetMessageId.isEmpty ||
        targetTurnId.isEmpty ||
        commandRequestId.isEmpty ||
        expectedHistoryRevision == null) {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        action: action,
        outcome: 'invalid_request',
        safety: TurnReplaySafety.unknown,
      );
      return;
    }
    if (action != 'retry' && action != 'edit') {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        action: action,
        outcome: 'invalid_request',
        safety: TurnReplaySafety.unknown,
      );
      return;
    }
    if (!_sessionsInFlight.add(sessionId)) {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        action: action,
        outcome: 'already_in_progress',
        safety: TurnReplaySafety.unknown,
      );
      return;
    }

    AttachmentStore? stagedAttachmentStore;
    var retainStagedAttachments = false;
    try {
      final replay = TurnReplayService(
        sessionManager: _sessionManager,
        persistedState: _persistedState,
        compactionBoundaries: _compactionBoundaries,
      );
      final inspection = replay.inspect(
        sessionId: sessionId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        expectedHistoryRevision: expectedHistoryRevision,
      );
      if (!inspection.canReplay) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: _failureName(inspection.failure!),
          safety: inspection.safety,
          containsSteers: inspection.containsSteers,
          historyRevision: inspection.historyRevision,
        );
        return;
      }
      if (inspection.requiresConfirmation && !confirmed) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: 'confirmation_required',
          safety: inspection.safety,
          requiresConfirmation: true,
          containsSteers: inspection.containsSteers,
          historyRevision: inspection.historyRevision,
        );
        return;
      }
      if (inspection.containsSteers && !confirmedDropSteers) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: 'steer_reinjection_confirmation_required',
          safety: inspection.safety,
          containsSteers: true,
          requiresSteerDropConfirmation: true,
          historyRevision: inspection.historyRevision,
        );
        return;
      }

      final editedMessage = event.payload['message']?.toString().trim();
      final replayMessage = action == 'edit'
          ? (editedMessage ?? '')
          : inspection.originalMessage;
      if (replayMessage.isEmpty) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: 'empty_message',
          safety: inspection.safety,
        );
        return;
      }

      await _orchestrator.requestStop(sessionId);
      final reachedIdle = await _waitForAuthoritativeIdle(sessionId);
      if (!reachedIdle) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: 'session_not_idle',
          safety: inspection.safety,
          containsSteers: inspection.containsSteers,
          historyRevision: inspection.historyRevision,
        );
        return;
      }
      final postIdle = replay.inspect(
        sessionId: sessionId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        expectedHistoryRevision: expectedHistoryRevision,
      );
      if (!postIdle.canReplay) {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: _postIdleFailureName(postIdle.failure!),
          safety: postIdle.safety,
          containsSteers: postIdle.containsSteers,
          historyRevision: postIdle.historyRevision,
        );
        return;
      }
      final targetRunId = _targetRunId(postIdle);
      final rawAttachmentEdits = event.payload['attachment_edits'];
      final sourceSession = _sessionManager.getSession(sessionId);
      final hasRetrySourceAttachments =
          rawAttachmentEdits == null &&
          action == 'retry' &&
          sourceSession != null &&
          postIdle.targetMessageIndex >= 0 &&
          postIdle.targetMessageIndex < sourceSession.messages.length &&
          sourceSession
              .messages[postIdle.targetMessageIndex]
              .attachments
              .isNotEmpty;
      if ((rawAttachmentEdits is List && rawAttachmentEdits.isNotEmpty) ||
          hasRetrySourceAttachments) {
        stagedAttachmentStore = _attachmentStore;
      }
      List<UserAttachment> replayAttachments;
      try {
        replayAttachments = await _stageReplayAttachments(
          event: event,
          inspection: postIdle,
          sessionId: sessionId,
          admissionId: commandRequestId,
          action: action,
        );
      } on Object {
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome: 'attachment_admission_failed',
          safety: postIdle.safety,
          historyRevision: postIdle.historyRevision,
        );
        return;
      }
      final admission = replay.admitReplacement(
        inspection: postIdle,
        replacementRequestId: commandRequestId,
        replacementText: replayMessage,
        action: action,
      );
      if (admission == null) {
        final current = replay.inspect(
          sessionId: sessionId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          expectedHistoryRevision: expectedHistoryRevision,
        );
        await _emitResult(
          emitEnvelope,
          sessionId: sessionId,
          requestId: commandRequestId,
          targetRequestId: targetRequestId,
          targetMessageId: targetMessageId,
          targetTurnId: targetTurnId,
          action: action,
          outcome:
              current.failure ==
                  TurnReplayInspectionFailure.historyRevisionMismatch
              ? 'history_revision_mismatch'
              : 'stale_turn_boundary',
          safety: inspection.safety,
          containsSteers: inspection.containsSteers,
          historyRevision: current.historyRevision,
        );
        return;
      }

      final session = _sessionManager.getSession(sessionId);
      final providerInstanceId = event.payload['provider_instance_id']
          ?.toString()
          .trim();
      final modelId = (event.payload['model_id'] ?? event.payload['model'])
          ?.toString()
          .trim();
      final thinkingMode = event.payload['thinking_mode']?.toString().trim();
      final request = AgentTurnRequest(
        sessionId: sessionId,
        message: replayMessage,
        workspaceId: session?.workspaceId,
        providerInstanceId:
            providerInstanceId == null || providerInstanceId.isEmpty
            ? null
            : providerInstanceId,
        model: modelId == null || modelId.isEmpty ? null : modelId,
        thinkingMode: thinkingMode == null || thinkingMode.isEmpty
            ? null
            : thinkingMode,
        requestId: commandRequestId,
        metadata: {
          'turn_replay_action': action,
          'replayed_request_id': targetRequestId,
          if (replayAttachments.isNotEmpty)
            'attachment_ids': replayAttachments
                .map((attachment) => attachment.id)
                .toList(growable: false),
        },
      );
      final gatewayEvent = GatewayEvent(
        sessionId: sessionId,
        platformId: 'sanad_client',
        message: Message(
          role: MessageRole.user,
          content: replayMessage,
          attachments: replayAttachments,
          metadata: {
            'request_id': commandRequestId,
            'message_id': admission.replacementMessageId,
            'turn_id': admission.replacementTurnId,
            'input_kind': MessageHistoryIdentity.rootTurn,
            'history_status': MessageHistoryIdentity.active,
          },
        ),
        metadata: {'command': 'think', 'payload': request.toMetadata()},
        turnRequest: request,
      );

      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        targetRunId: targetRunId,
        replacementMessageId: admission.replacementMessageId,
        replacementTurnId: admission.replacementTurnId,
        action: action,
        outcome: 'accepted',
        safety: postIdle.safety,
        containsSteers: postIdle.containsSteers,
        historyRevision: admission.historyRevision,
      );
      retainStagedAttachments = true;
      unawaited(_orchestrator.handleEvent(gatewayEvent));
    } catch (_) {
      await _emitResult(
        emitEnvelope,
        sessionId: sessionId,
        requestId: commandRequestId,
        targetRequestId: targetRequestId,
        targetMessageId: targetMessageId,
        targetTurnId: targetTurnId,
        action: action,
        outcome: 'failed',
        safety: TurnReplaySafety.unknown,
      );
    } finally {
      try {
        if (stagedAttachmentStore != null && !retainStagedAttachments) {
          await stagedAttachmentStore.discardAdmission(
            sessionId: sessionId,
            admissionId: commandRequestId,
          );
        }
      } finally {
        _sessionsInFlight.remove(sessionId);
      }
    }
  }

  Future<List<UserAttachment>> _stageReplayAttachments({
    required CanonicalEvent event,
    required TurnReplayInspection inspection,
    required String sessionId,
    required String admissionId,
    required String action,
  }) async {
    final session = _sessionManager.getSession(sessionId);
    if (session == null ||
        inspection.targetMessageIndex < 0 ||
        inspection.targetMessageIndex >= session.messages.length) {
      throw const FormatException('Attachment source is unavailable.');
    }
    final originals =
        session.messages[inspection.targetMessageIndex].attachments;
    final originalsById = {for (final item in originals) item.id: item};
    final raw = event.payload['attachment_edits'];
    final edits = raw == null && action == 'retry'
        ? originals.map<Object?>((item) => {'reference_id': item.id}).toList()
        : raw;
    if (edits is! List ||
        edits.length > UserAttachmentPolicy.maxFilesPerMessage) {
      throw const FormatException('Attachment edits are invalid.');
    }
    if (edits.isEmpty) return const [];
    final store = _attachmentStore;
    if (store == null) {
      throw const FormatException('Attachment store is unavailable.');
    }
    final staged = <UserAttachment>[];
    for (final value in edits) {
      if (value is! Map) {
        throw const FormatException('Attachment edit is invalid.');
      }
      final json = Map<String, dynamic>.from(value);
      if (json.keys.length == 1 && json['reference_id'] is String) {
        final id = (json['reference_id'] as String).trim();
        if (!originalsById.containsKey(id)) {
          throw const FormatException('Attachment reference is invalid.');
        }
        staged.add(
          await store.cloneAttachedForAdmission(
            sessionId: sessionId,
            attachmentId: id,
            admissionId: admissionId,
          ),
        );
        continue;
      }
      const keys = {'name', 'size_bytes', 'sha256', 'data_base64'};
      if (json.keys.toSet().difference(keys).isNotEmpty ||
          json.keys.length != keys.length ||
          json['name'] is! String ||
          json['size_bytes'] is! int ||
          json['sha256'] is! String ||
          json['data_base64'] is! String) {
        throw const FormatException('Attachment upload is invalid.');
      }
      final declaredSize = json['size_bytes'] as int;
      final declaredSha = json['sha256'] as String;
      final bytes = base64Decode(json['data_base64'] as String);
      if (declaredSize != bytes.length ||
          bytes.length > UserAttachmentPolicy.maxFileBytes ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(declaredSha) ||
          sha256.convert(bytes).toString() != declaredSha) {
        throw const FormatException('Attachment upload is invalid.');
      }
      final upload = await store.create(
        fileName: json['name'] as String,
        expectedSize: declaredSize,
        expectedSha256: declaredSha,
      );
      try {
        await store.write(upload, bytes);
        staged.add(
          await store.commit(
            upload,
            sessionId: sessionId,
            admissionId: admissionId,
          ),
        );
      } on Object {
        await store.cancel(upload);
        rethrow;
      }
    }
    final validation = UserAttachmentPolicy.validate(staged);
    if (validation is AttachmentAdmissionFailure) {
      throw const FormatException('Attachment edits exceed policy.');
    }
    return List.unmodifiable(staged);
  }

  /// Stop acknowledgement and terminal work items are not dispatch authority.
  /// Replay waits until the persisted snapshot is exactly [idle], including
  /// queued, running, waiting, blocked, and resuming work after scoped stop.
  Future<bool> _waitForAuthoritativeIdle(String sessionId) async {
    if (_persistedState == null) return false;
    final deadline = DateTime.now().add(_idleWaitTimeout);
    while (true) {
      final snapshot = _persistedState.executionSnapshots.getSnapshot(
        sessionId,
      );
      if (snapshot.state == SessionExecutionState.idle) return true;
      if (!DateTime.now().isBefore(deadline)) return false;
      await Future<void>.delayed(_idlePollInterval);
    }
  }

  Future<void> _emitResult(
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope, {
    required String sessionId,
    required String requestId,
    required String targetRequestId,
    String targetMessageId = '',
    String targetTurnId = '',
    String? targetRunId,
    String? replacementMessageId,
    String? replacementTurnId,
    required String action,
    required String outcome,
    required TurnReplaySafety safety,
    bool requiresConfirmation = false,
    bool requiresSteerDropConfirmation = false,
    bool containsSteers = false,
    int? historyRevision,
  }) {
    return emitEnvelope(
      _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.sessionTurnReplayResult,
          sessionId: sessionId,
          payload: {
            'session_id': sessionId,
            'request_id': requestId,
            'target_request_id': targetRequestId,
            'target_message_id': targetMessageId,
            'target_turn_id': targetTurnId,
            'target_run_id': ?targetRunId,
            'replacement_message_id': ?replacementMessageId,
            'replacement_turn_id': ?replacementTurnId,
            'action': action,
            'outcome': outcome,
            'replay_safety': safety.name,
            'requires_confirmation': requiresConfirmation,
            'requires_steer_drop_confirmation': requiresSteerDropConfirmation,
            'contains_steers': containsSteers,
            'history_revision': ?historyRevision,
          },
        ),
      ),
    );
  }

  String? _targetRunId(TurnReplayInspection inspection) {
    final messages = _sessionManager.getMessages(inspection.sessionId);
    for (final message in messages.skip(inspection.targetMessageIndex)) {
      final identity = MessageHistoryIdentity.read(message);
      if (identity.turnId != inspection.targetTurnId) break;
      if (identity.runId != null && identity.runId!.isNotEmpty) {
        return identity.runId;
      }
    }
    return null;
  }

  static int? _parseRevision(Object? value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString().trim() ?? '');
  }

  static String _failureName(TurnReplayInspectionFailure failure) =>
      switch (failure) {
        TurnReplayInspectionFailure.sessionNotFound => 'session_not_found',
        TurnReplayInspectionFailure.targetNotFound => 'turn_boundary_not_found',
        TurnReplayInspectionFailure.targetIsNotLatestTurn => 'not_latest_turn',
        TurnReplayInspectionFailure.emptyMessage => 'empty_message',
        TurnReplayInspectionFailure.targetNotReplayableInput =>
          'target_not_replayable_input',
        TurnReplayInspectionFailure.identityIncomplete => 'identity_incomplete',
        TurnReplayInspectionFailure.historyRevisionMismatch =>
          'history_revision_mismatch',
        TurnReplayInspectionFailure.targetPrecedesCompaction =>
          'target_precedes_compaction',
      };

  static String _postIdleFailureName(TurnReplayInspectionFailure failure) =>
      switch (failure) {
        TurnReplayInspectionFailure.targetNotFound ||
        TurnReplayInspectionFailure.targetIsNotLatestTurn ||
        TurnReplayInspectionFailure.identityIncomplete => 'stale_turn_boundary',
        TurnReplayInspectionFailure.historyRevisionMismatch =>
          'stale_turn_boundary',
        _ => _failureName(failure),
      };
}
