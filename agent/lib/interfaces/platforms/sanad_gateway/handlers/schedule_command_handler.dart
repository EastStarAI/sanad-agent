import 'package:logging/logging.dart';
import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/evolution/cron_scheduler.dart';
import 'package:sanad_agent/evolution/db/scheduled_task_repository.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';

import '../sanad_protocol_bridge.dart';
import 'support/agent_event_envelope.dart';
import 'support/schedule_projection.dart';
import 'support/schedule_request.dart';

/// Owns the mutating schedule commands of the device-owner protocol
/// (Task 139 §Protocol): `schedule.create`, `schedule.update`,
/// `schedule.pause`, `schedule.resume`, `schedule.run_now`, and
/// `schedule.delete`.
///
/// Invariants:
/// - Authority comes from the transport, never from the payload. Only an
///   `owner`-stamped command acts, and it acts as the device owner
///   (`ScheduleCaller.user`); anything else is refused with `permission_denied`
///   and mutates nothing.
/// - A Client command always creates `owner_kind='user'`. `owner_kind` is set by
///   this command family and is not a payload field, so a hand-crafted payload
///   cannot claim the model kind (D5).
/// - Every request is validated completely before the first mutation; a
///   rejected request mutates nothing.
/// - The control layer (`CronScheduler` + `ScheduleControl`) is the only writer.
///   This handler never touches a repository directly.
/// - Each successful mutation broadcasts `schedule.changed` to every Sanad
///   client; `emitEnvelope` reaches only the requester.
class ScheduleCommandHandler {
  ScheduleCommandHandler({
    required CronScheduler scheduler,
    required SessionManager sessionManager,
    String defaultZone = 'local',
    SanadProtocolBridge? bridge,
    void Function(CanonicalEvent event)? broadcastFamilyEvent,
  }) : _scheduler = scheduler,
       _sessionManager = sessionManager,
       _defaultZone = defaultZone,
       _bridge = bridge,
       _broadcastFamilyEvent = broadcastFamilyEvent;

  final CronScheduler _scheduler;
  final SessionManager _sessionManager;

  /// Zone a definition uses when the request omits `zone`, matching the model
  /// tool's default so a screen-created and a model-created schedule agree.
  final String _defaultZone;
  final SanadProtocolBridge? _bridge;
  final void Function(CanonicalEvent event)? _broadcastFamilyEvent;

  static final Logger _logger = Logger('ScheduleCommandHandler');

  static const String createCommand = 'schedule.create';
  static const String updateCommand = 'schedule.update';
  static const String pauseCommand = 'schedule.pause';
  static const String resumeCommand = 'schedule.resume';
  static const String runNowCommand = 'schedule.run_now';
  static const String deleteCommand = 'schedule.delete';

  /// The stable message of a failure this handler could not classify. It never
  /// carries an exception value, a stack trace, or command output.
  static const String internalErrorMessage =
      'The schedule request could not be completed.';

  static const Set<String> _identityKeys = {
    'request_id',
    CommandAuthority.payloadKey,
  };

  static const Set<String> _idKeys = {..._identityKeys, 'id'};

  static const Set<String> _deleteKeys = {..._idKeys, 'confirm'};

  /// Editable settings and content of a schedule. Identity (`id`) is never one
  /// of them: the server mints it on create and addresses it on update.
  static const Set<String> _settingsKeys = {
    'name',
    'task',
    'conversation_mode',
    'workspace_id',
    'provider_instance_id',
    'model',
  };

  static const Set<String> _createKeys = {..._identityKeys, ..._settingsKeys};

  static const Set<String> _updateKeys = {..._idKeys, ..._settingsKeys};

  /// Dispatches a mutating schedule canonical event to its builder.
  Future<void> handle(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    switch (event.type) {
      case CanonicalEventTypes.scheduleCreate:
        await emitEnvelope(await buildCreateEnvelope(event));
        return;
      case CanonicalEventTypes.scheduleUpdate:
        await emitEnvelope(await buildUpdateEnvelope(event));
        return;
      case CanonicalEventTypes.schedulePause:
        await emitEnvelope(await buildPauseEnvelope(event));
        return;
      case CanonicalEventTypes.scheduleResume:
        await emitEnvelope(await buildResumeEnvelope(event));
        return;
      case CanonicalEventTypes.scheduleRunNow:
        await emitEnvelope(await buildRunNowEnvelope(event));
        return;
      case CanonicalEventTypes.scheduleDelete:
        await emitEnvelope(await buildDeleteEnvelope(event));
        return;
      default:
        _logger.fine('Ignoring unsupported schedule command: ${event.type}');
        return;
    }
  }

  /// Creates a device-owned schedule that needs no conversation
  /// (`schedule.create` -> `schedule.created`).
  Future<Map<String, dynamic>> buildCreateEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = _requestIdOf(event);
    try {
      final fields = _admit(
        event,
        command: createCommand,
        allowed: {..._createKeys, ...ScheduleRequest.definitionFields},
      );
      final task = ScheduleRequest.requiredString(
        fields,
        'task',
        command: createCommand,
      );
      final definition = ScheduleRequest.parseDefinition(
        ScheduleRequest.definitionValues(fields, command: createCommand),
        defaultZone: _defaultZone,
      );
      final record = _scheduler.createSchedule(
        task: task,
        definition: definition,
        // Task 139 D5: the command family fixes the owner kind. A payload has no
        // `owner_kind` reader at all, and a user-owned row starts without a
        // conversation (D1).
        ownerKind: ScheduleOwnerKind.user,
        conversationMode:
            ScheduleRequest.optionalConversationMode(
              fields,
              command: createCommand,
            ) ??
            ScheduleConversationMode.continuous,
        name: ScheduleRequest.optionalString(
          fields,
          'name',
          command: createCommand,
        ),
        workspaceId: ScheduleRequest.optionalString(
          fields,
          'workspace_id',
          command: createCommand,
        ),
        providerInstanceId: ScheduleRequest.optionalString(
          fields,
          'provider_instance_id',
          command: createCommand,
        ),
        model: ScheduleRequest.optionalString(
          fields,
          'model',
          command: createCommand,
        ),
      );

      _logger.info(
        'Schedule created; schedule_id=${record.id}, '
        'owner_kind=${record.ownerKind.wireName}, '
        'conversation_mode=${record.conversationMode.wireName}.',
      );
      _broadcastChanged(record.id, 'created');

      return _rowEnvelope(
        CanonicalEventTypes.scheduleCreated,
        requestId,
        record,
      );
    } catch (error) {
      return _failureEnvelope(requestId, error, command: createCommand);
    }
  }

  /// Updates the editable settings and/or recurrence of a schedule
  /// (`schedule.update` -> `schedule.updated`).
  Future<Map<String, dynamic>> buildUpdateEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = _requestIdOf(event);
    try {
      final fields = _admit(
        event,
        command: updateCommand,
        allowed: {..._updateKeys, ...ScheduleRequest.definitionFields},
      );
      final id = ScheduleRequest.requiredId(fields, command: updateCommand);

      final hasTask = fields.containsKey('task');
      final name = ScheduleRequest.settingsValue(
        fields,
        'name',
        command: updateCommand,
      );
      final conversationMode = fields.containsKey('conversation_mode')
          ? ScheduleRequest.optionalConversationMode(
              fields,
              command: updateCommand,
            )
          : ScheduledTaskRepository.unset;
      final workspaceId = ScheduleRequest.settingsValue(
        fields,
        'workspace_id',
        command: updateCommand,
      );
      final providerInstanceId = ScheduleRequest.settingsValue(
        fields,
        'provider_instance_id',
        command: updateCommand,
      );
      final model = ScheduleRequest.settingsValue(
        fields,
        'model',
        command: updateCommand,
      );
      final recurrenceValues = ScheduleRequest.definitionValues(
        fields,
        command: updateCommand,
      );
      final hasSettings =
          !identical(name, ScheduledTaskRepository.unset) ||
          !identical(conversationMode, ScheduledTaskRepository.unset) ||
          !identical(workspaceId, ScheduledTaskRepository.unset) ||
          !identical(providerInstanceId, ScheduledTaskRepository.unset) ||
          !identical(model, ScheduledTaskRepository.unset);

      if (!hasTask && !hasSettings && recurrenceValues.isEmpty) {
        throw const ScheduleRequestException(
          ScheduleRequestException.invalidRequest,
          'schedule.update requires at least one of: task, name, '
          'conversation_mode, workspace_id, provider_instance_id, model, or a '
          'recurrence field.',
        );
      }

      // A partial recurrence merges over the stored shape exactly like the model
      // tool's update (112a D10, P7) instead of re-inferring a new shape.
      ScheduleDefinition? definition;
      if (recurrenceValues.isNotEmpty) {
        final existing = _scheduler.getSchedule(id);
        if (existing == null) {
          throw ScheduleNotFoundException('Schedule "$id" not found.');
        }
        definition = ScheduleRequest.parseDefinition(
          ScheduleDefinition.mergeUpdateArgs(
            existing.toDefinition(),
            recurrenceValues,
          ),
          defaultZone: existing.zone,
        );
      }

      final updated = _scheduler.updateSchedule(
        id: id,
        caller: const ScheduleCaller.user(),
        task: hasTask
            ? ScheduleRequest.requiredString(
                fields,
                'task',
                command: updateCommand,
              )
            : null,
        definition: definition,
        name: name,
        conversationMode: conversationMode,
        workspaceId: workspaceId,
        providerInstanceId: providerInstanceId,
        model: model,
      );

      _logger.info('Schedule updated; schedule_id=${updated.id}.');
      _broadcastChanged(updated.id, 'updated');

      return _rowEnvelope(
        CanonicalEventTypes.scheduleUpdated,
        requestId,
        updated,
      );
    } catch (error) {
      return _failureEnvelope(requestId, error, command: updateCommand);
    }
  }

  /// Pauses a schedule without shifting its stored instant
  /// (`schedule.pause` -> `schedule.updated`).
  Future<Map<String, dynamic>> buildPauseEnvelope(CanonicalEvent event) async {
    final requestId = _requestIdOf(event);
    try {
      final fields = _admit(
        event,
        command: pauseCommand,
        allowed: _idKeys,
      );
      final id = ScheduleRequest.requiredId(fields, command: pauseCommand);
      final record = _scheduler.pauseSchedule(id, const ScheduleCaller.user());

      _logger.info('Schedule paused; schedule_id=${record.id}.');
      _broadcastChanged(record.id, 'paused');

      return _rowEnvelope(
        CanonicalEventTypes.scheduleUpdated,
        requestId,
        record,
      );
    } catch (error) {
      return _failureEnvelope(requestId, error, command: pauseCommand);
    }
  }

  /// Resumes a paused schedule at its next future instant
  /// (`schedule.resume` -> `schedule.updated`).
  Future<Map<String, dynamic>> buildResumeEnvelope(CanonicalEvent event) async {
    final requestId = _requestIdOf(event);
    try {
      final fields = _admit(
        event,
        command: resumeCommand,
        allowed: _idKeys,
      );
      final id = ScheduleRequest.requiredId(fields, command: resumeCommand);
      final record = _scheduler.resumeSchedule(id, const ScheduleCaller.user());

      _logger.info('Schedule resumed; schedule_id=${record.id}.');
      _broadcastChanged(record.id, 'resumed');

      return _rowEnvelope(
        CanonicalEventTypes.scheduleUpdated,
        requestId,
        record,
      );
    } catch (error) {
      return _failureEnvelope(requestId, error, command: resumeCommand);
    }
  }

  /// Dispatches a schedule immediately, including while it is paused
  /// (`schedule.run_now` -> `schedule.run_accepted`).
  ///
  /// The run is recorded with `trigger='manual'` and the schedule keeps its
  /// `next_run_at`, `last_run_at`, `last_status`, and `enabled` (S14, S21).
  Future<Map<String, dynamic>> buildRunNowEnvelope(CanonicalEvent event) async {
    final requestId = _requestIdOf(event);
    try {
      final fields = _admit(
        event,
        command: runNowCommand,
        allowed: _idKeys,
      );
      final id = ScheduleRequest.requiredId(fields, command: runNowCommand);
      final result = _scheduler.runNowSchedule(id, const ScheduleCaller.user());

      _logger.info(
        'Schedule run accepted; schedule_id=$id, run_id=${result.runId}.',
      );
      _broadcastChanged(id, 'run_now');

      return _buildEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.scheduleRunAccepted,
          payload: {
            'request_id': ?requestId,
            'run_id': result.runId,
            'session_id': result.sessionId,
            'accepted_at': result.acceptedAt.toUtc().toIso8601String(),
          },
        ),
      );
    } catch (error) {
      return _failureEnvelope(requestId, error, command: runNowCommand);
    }
  }

  /// Deletes a schedule and its run rows, touching no conversation or message
  /// (`schedule.delete` -> `schedule.deleted`).
  Future<Map<String, dynamic>> buildDeleteEnvelope(CanonicalEvent event) async {
    final requestId = _requestIdOf(event);
    try {
      final fields = _admit(
        event,
        command: deleteCommand,
        allowed: _deleteKeys,
      );
      final id = ScheduleRequest.requiredId(fields, command: deleteCommand);
      ScheduleRequest.requireConfirmation(fields, command: deleteCommand);
      _scheduler.deleteSchedule(id, const ScheduleCaller.user());

      _logger.info('Schedule deleted; schedule_id=$id.');
      _broadcastChanged(id, 'deleted');

      return _buildEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.scheduleDeleted,
          payload: {
            'request_id': ?requestId,
            'id': id,
            'deleted': true,
          },
        ),
      );
    } catch (error) {
      return _failureEnvelope(requestId, error, command: deleteCommand);
    }
  }

  /// Applies the transport-authority and request-shape gate.
  ///
  /// Authority is decided by the transport-stamped `command_authority`; a
  /// payload can only lower its own authority. The unknown-field check runs
  /// before any value is read, so a forged field such as `owner_kind` is a
  /// rejected request rather than an ignored extra.
  Map<String, dynamic> _admit(
    CanonicalEvent event, {
    required String command,
    required Set<String> allowed,
  }) {
    final payload = event.payload;
    ScheduleRequest.requestId(payload, command);

    final authority = CommandAuthority.fromStamped(
      payload[CommandAuthority.payloadKey],
    );
    if (!authority.isOwner) {
      throw const ScheduleRequestException(
        'permission_denied',
        'Only the device owner may control schedules.',
      );
    }

    ScheduleRequest.rejectUnknownFields(
      payload: payload,
      allowed: allowed,
      command: command,
    );
    return payload;
  }

  /// Reads `request_id` defensively so a rejected envelope can still correlate.
  String? _requestIdOf(CanonicalEvent event) {
    final raw = event.payload['request_id'];
    return raw is String ? raw : null;
  }

  Map<String, dynamic> _rowEnvelope(
    String type,
    String? requestId,
    ScheduledTaskRecord record,
  ) {
    final ownerSessionId = ScheduleRowProjection.ownerSession(record);
    return _buildEnvelope(
      CanonicalEvent(
        type: type,
        payload: {
          'request_id': ?requestId,
          'schedule': ScheduleRowProjection.project(
            record: record,
            consecutiveFailures: _scheduler.consecutiveFailures(record.id),
            ownerSessionTitle: ownerSessionId == null
                ? null
                : _sessionManager.getSessionRecord(ownerSessionId)?.title,
          ),
        },
      ),
    );
  }

  void _broadcastChanged(String scheduleId, String change) {
    _broadcastFamilyEvent?.call(
      CanonicalEvent(
        type: CanonicalEventTypes.scheduleChanged,
        payload: {'schedule_id': scheduleId, 'change': change},
      ),
    );
  }

  /// Maps a failure to its protocol error code.
  ///
  /// The control layer's exceptions are the only classified outcomes; anything
  /// else is `internal_error` with a stable message, so an error envelope never
  /// carries a stack trace, a payload map, or command output.
  Map<String, dynamic> _failureEnvelope(
    String? requestId,
    Object error, {
    required String command,
  }) {
    final request = error is ScheduleRequestException ? error : null;
    final mapped = request == null ? _mapControlFailure(error) : null;
    final code = request?.code ?? mapped?.code ?? 'internal_error';
    final message =
        request?.message ?? mapped?.message ?? internalErrorMessage;

    if (code == 'internal_error') {
      _logger.severe('Schedule command failed; command=$command, code=$code.');
    } else {
      _logger.warning('Schedule command failed; command=$command, code=$code.');
    }
    return _error(requestId, code, message);
  }

  ({String code, String message})? _mapControlFailure(Object error) =>
      switch (error) {
        ScheduleNotFoundException(:final message) => (
          code: 'schedule_not_found',
          message: message,
        ),
        ScheduleExpiredException(:final message) => (
          code: 'schedule_expired',
          message: message,
        ),
        ScheduleOrphanedException(:final message) => (
          code: 'schedule_orphaned',
          message: message,
        ),
        SchedulePermissionException(:final message) => (
          code: 'permission_denied',
          message: message,
        ),
        ScheduleValidationException(:final message) => (
          code: 'invalid_schedule',
          message: message,
        ),
        _ => null,
      };

  Map<String, dynamic> _buildEnvelope(CanonicalEvent canonicalEvent) {
    final bridge = _bridge;
    if (bridge != null) {
      return bridge.buildAgentEventEnvelope(canonicalEvent);
    }
    return buildAgentEventEnvelope(canonicalEvent);
  }

  Map<String, dynamic> _error(String? requestId, String code, String message) {
    return _buildEnvelope(
      CanonicalEvent(
        type: 'error',
        payload: {
          'request_id': requestId,
          'code': code,
          'message': message,
        },
      ),
    );
  }
}
