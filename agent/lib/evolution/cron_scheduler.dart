import 'dart:async';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/db/persisted_runtime_state_repository.dart';
import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_control.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_conversation_factory.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_run_recorder.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';

export 'scheduling/schedule_control.dart';
export 'scheduling/schedule_conversation_factory.dart';
export 'scheduling/schedule_run_recorder.dart';
export 'scheduling/scheduled_task_record.dart';

/// Result of a manual [CronScheduler.runNowSchedule] dispatch (Task 139 A2, S14).
class ScheduledRunNowResult {
  final String runId;
  final String sessionId;
  final DateTime acceptedAt;

  const ScheduledRunNowResult({
    required this.runId,
    required this.sessionId,
    required this.acceptedAt,
  });
}

class CronScheduler extends BasePlatform {
  final _logger = Logger('CronScheduler');

  @override
  String get platformId => 'cron';

  @override
  PlatformDescriptor get descriptor => const PlatformDescriptor(
    platformFamily: PlatformFamily.cli,
    transport: PlatformTransport.cli,
    platformInstanceId: 'cron',
  );

  late final StreamController<GatewayEvent> _controller =
      StreamController<GatewayEvent>.broadcast(onListen: _flushPendingEvents);

  final List<GatewayEvent> _pendingEvents = [];

  @override
  Stream<GatewayEvent> get eventStream => _controller.stream;

  final List<ScheduledTaskMetadata> _tasks = [];
  final SessionManager _sessionManager;
  final SessionDB _db;
  late final ScheduleRunRecorder _runRecorder;
  late final ScheduleConversationFactory _conversationFactory;
  ScheduleRunObserver? _runObserver;
  final PersistedRuntimeStateRepository? _persistedState;

  CronScheduler({
    SessionManager? sessionManager,
    SessionDB? db,
    ScheduleRunRecorder? runRecorder,
    ScheduleConversationFactory? conversationFactory,
    ScheduleRunObserver? runObserver,
    PersistedRuntimeStateRepository? persistedState,
    DateTime Function()? clock,
  }) : _sessionManager = sessionManager ?? SessionManager(),
       _db = db ?? (sessionManager?.db ?? SessionDB()),
       _persistedState = persistedState ??
           (getIt.isRegistered<PersistedRuntimeStateRepository>()
               ? getIt<PersistedRuntimeStateRepository>()
               : null) {
    _runRecorder = runRecorder ??
        ScheduleRunRecorder(
          db: _db,
          clock: clock,
        );
    _conversationFactory = conversationFactory ??
        ScheduleConversationFactory(
          sessionManager: _sessionManager,
          db: _db,
        );
    final persisted = _persistedState;
    _runObserver = runObserver ??
        (persisted != null
            ? ScheduleRunObserver(
                recorder: _runRecorder,
                lookupOutcome: (sessionId, runId) =>
                    ScheduleRunObserver.defaultLookupOutcome(
                  persisted,
                  sessionId,
                  runId,
                ),
                lookupError: (sessionId, runId) {
                  final notice = persisted.notices.findNotice(sessionId);
                  if (notice != null &&
                      (notice.requestId == runId || notice.runId == runId)) {
                    return notice.message;
                  }
                  return null;
                },
              )
            : null);
  }

  List<ScheduledTaskMetadata> get activeTasks => List.unmodifiable(_tasks);

  ScheduleRunRecorder get runRecorder => _runRecorder;
  ScheduleConversationFactory get conversationFactory => _conversationFactory;
  ScheduleRunObserver? get runObserver => _runObserver;

  int consecutiveFailures(String scheduleId) =>
      _runRecorder.consecutiveFailures(scheduleId);

  bool suggestPause(String scheduleId) =>
      _runRecorder.suggestPause(scheduleId);

  void _saveRecord(ScheduledTaskRecord record) {
    _sessionManager.db.saveScheduledTask(
      record.id,
      record.task,
      record.nextRunAt,
      record.sessionId,
      kind: record.kind.name,
      intervalMinutes: record.intervalMinutes,
      atTime: record.atTime,
      weekdays: record.weekdays,
      monthDay: record.monthDay,
      zone: record.zone,
      updatedAt: record.updatedAt,
      lastRunAt: record.lastRunAt,
      lastStatus: record.lastStatus,
      enabled: record.enabled,
      name: record.name,
      ownerKind: record.ownerKind.wireName,
      conversationMode: record.conversationMode.wireName,
      runSessionId: record.runSessionId,
      workspaceId: record.workspaceId,
      providerInstanceId: record.providerInstanceId,
      model: record.model,
    );
  }

  /// Creates and schedules a new task adhering to Decisions D2-D8 and Task 139 D1, D5.
  ScheduledTaskRecord createSchedule({
    required String task,
    required ScheduleDefinition definition,
    String? sessionId,
    String? id,
    String? name,
    ScheduleOwnerKind ownerKind = ScheduleOwnerKind.model,
    ScheduleConversationMode conversationMode = ScheduleConversationMode.continuous,
    String? runSessionId,
    String? workspaceId,
    String? providerInstanceId,
    String? model,
  }) {
    if (ownerKind == ScheduleOwnerKind.model) {
      if (sessionId == null || sessionId.trim().isEmpty) {
        throw const ScheduleValidationException(
          'Cannot create a scheduled task without a session context.',
        );
      }
    }

    final taskId = id ?? 'task_${DateTime.now().microsecondsSinceEpoch}';
    final now = DateTime.now().toUtc();
    final nextRunAt = OccurrenceCalculator.computeNextOccurrence(
      definition,
      from: now,
    );

    final record = ScheduledTaskRecord(
      id: taskId,
      task: task,
      sessionId: sessionId ?? '',
      kind: definition.kind,
      intervalMinutes: definition.intervalMinutes,
      atTime: definition.atTime,
      weekdays: definition.weekdays?.join(','),
      monthDay: definition.monthDay,
      zone: definition.zone,
      nextRunAt: nextRunAt,
      createdAt: now,
      updatedAt: now,
      enabled: true,
      name: name,
      ownerKind: ownerKind,
      conversationMode: conversationMode,
      runSessionId: runSessionId ?? (ownerKind == ScheduleOwnerKind.model ? sessionId : null),
      workspaceId: workspaceId,
      providerInstanceId: providerInstanceId,
      model: model,
    );

    _saveRecord(record);
    _scheduleInMemory(record);
    return record;
  }

  /// Compatibility method for existing tests/callers creating a one-shot task.
  void scheduleTask(
    DateTime time,
    String task, {
    String? sessionId,
    String? id,
  }) {
    if (sessionId == null || sessionId.trim().isEmpty) {
      throw const ScheduleValidationException(
        'Cannot create a scheduled task without a session context.',
      );
    }
    createSchedule(
      task: task,
      sessionId: sessionId,
      definition: ScheduleDefinition(
        kind: ScheduleKind.once,
        zone: 'local',
        onceAt: time.toUtc(),
      ),
      id: id,
    );
  }

  /// Reads one schedule without mutating it, or `null` when it is unknown.
  ScheduledTaskRecord? getSchedule(String id) {
    final row = _sessionManager.db.getScheduledTask(id);
    return row == null ? null : ScheduledTaskRecord.fromRow(row);
  }

  /// Lists all scheduled tasks device-wide (Decision D6).
  List<ScheduledTaskRecord> listSchedules() {
    final rows = _sessionManager.db.getAllScheduledTasks();
    return rows.map((r) => ScheduledTaskRecord.fromRow(r)).toList();
  }

  /// Cancels a schedule owned by [caller] (Decisions D6, D7, S10, S15).
  ScheduledTaskRecord cancelSchedule(
    String id, {
    String? callerSessionId,
    ScheduleCaller? caller,
  }) {
    final row = _sessionManager.db.getScheduledTask(id);
    if (row == null) {
      throw ScheduleNotFoundException('Schedule "$id" not found.');
    }
    final record = ScheduledTaskRecord.fromRow(row);
    final effectiveCaller = caller ??
        (callerSessionId != null
            ? ScheduleCaller.model(callerSessionId)
            : const ScheduleCaller.user());
    ScheduleControl.authorize(record, effectiveCaller);

    _cancelInMemory(id);
    _sessionManager.db.state.transaction((_) {
      _sessionManager.db.scheduledTaskRuns.deleteRunsForSchedule(id);
      _sessionManager.db.deleteScheduledTask(id);
    });
    return record;
  }

  /// Deletes a schedule owned by [caller] (Task 139 S10, D7).
  ScheduledTaskRecord deleteSchedule(String id, ScheduleCaller caller) =>
      cancelSchedule(id, caller: caller);

  /// Pauses a schedule: sets `enabled=false`, cancels in-memory timer, and
  /// keeps `next_run_at` and `last_*` unchanged (Task 139 A2, S13).
  ScheduledTaskRecord pauseSchedule(String id, ScheduleCaller caller) {
    final row = _sessionManager.db.getScheduledTask(id);
    if (row == null) {
      throw ScheduleNotFoundException('Schedule "$id" not found.');
    }
    final existing = ScheduledTaskRecord.fromRow(row);
    ScheduleControl.authorize(existing, caller);

    final now = DateTime.now().toUtc();
    final updated = ScheduleControl.pauseRecord(existing, now: now);
    _saveRecord(updated);
    _cancelInMemory(id);
    return updated;
  }

  /// Resumes a paused schedule: recomputes `next_run_at` from now, sets
  /// `enabled=true`, and re-arms in memory (Task 139 A2, S13, D6).
  ScheduledTaskRecord resumeSchedule(String id, ScheduleCaller caller) {
    final row = _sessionManager.db.getScheduledTask(id);
    if (row == null) {
      throw ScheduleNotFoundException('Schedule "$id" not found.');
    }
    final existing = ScheduledTaskRecord.fromRow(row);
    ScheduleControl.authorize(existing, caller);

    final now = DateTime.now().toUtc();
    ScheduleControl.requireResumable(
      existing,
      now: now,
      sessionExists: (sid) => _sessionManager.getSessionRecord(sid) != null,
    );

    final nextRunAt = OccurrenceCalculator.computeNextOccurrence(
      existing.toDefinition(),
      from: now,
      previousRunAt: existing.lastRunAt,
    );

    final updated = ScheduleControl.resumeRecord(existing, now: now, nextRunAt: nextRunAt);
    _saveRecord(updated);
    _cancelInMemory(id);
    _scheduleInMemory(updated, now: now);
    return updated;
  }

  /// Dispatches a schedule immediately without altering its `next_run_at`,
  /// `last_run_at`, `last_status`, or `enabled` state (Task 139 A2, S14, S21).
  ScheduledRunNowResult runNowSchedule(String id, ScheduleCaller caller) {
    final row = _sessionManager.db.getScheduledTask(id);
    if (row == null) {
      throw ScheduleNotFoundException('Schedule "$id" not found.');
    }
    final record = ScheduledTaskRecord.fromRow(row);
    ScheduleControl.authorize(record, caller);

    ScheduleControl.requireDispatchTarget(
      record,
      sessionExists: (sid) => _sessionManager.getSessionRecord(sid) != null,
    );

    final targetSessionId = _conversationFactory.resolveDispatchSession(record);
    final now = DateTime.now().toUtc();
    final runId = _runRecorder.startRun(
      scheduleId: record.id,
      runAt: now,
      trigger: ScheduledTaskRunTrigger.manual,
    );

    _runObserver?.track(
      runId: runId,
      sessionId: targetSessionId,
      scheduleId: record.id,
    );

    try {
      _emitEvent(record.task, targetSessionId, runId: runId);
    } catch (e, stack) {
      _logger.severe('Failed to dispatch manual run for ${record.id}: $e', e, stack);
      _runRecorder.completeRun(
        runId,
        status: ScheduledTaskRunStatus.failed,
        error: e.toString(),
      );
      rethrow;
    }

    return ScheduledRunNowResult(
      runId: runId,
      sessionId: targetSessionId,
      acceptedAt: now,
    );
  }

  /// Pauses schedules associated with a deleted session (Task 139 S23, A2, Q2).
  ///
  /// Applies only to the owning `session_id`, or to `run_session_id` when the
  /// mode is `continuous`. Clears `run_session_id` on a user-owned continuous
  /// row so its next run creates a new conversation.
  int pauseForDeletedSession(String sessionId) {
    if (sessionId.trim().isEmpty) return 0;
    final now = DateTime.now().toUtc();
    var pausedCount = 0;
    final tasks = _sessionManager.db.getAllScheduledTasks();
    for (final taskRow in tasks) {
      final record = ScheduledTaskRecord.fromRow(taskRow);
      final isOwningSession = record.sessionId == sessionId;
      final isContinuousRunSession =
          record.conversationMode == ScheduleConversationMode.continuous &&
          record.runSessionId == sessionId;

      if (!isOwningSession && !isContinuousRunSession) continue;

      _cancelInMemory(record.id);
      _saveRecord(ScheduleControl.pauseRecord(record, now: now));

      if (record.ownerKind == ScheduleOwnerKind.user &&
          record.conversationMode == ScheduleConversationMode.continuous) {
        _sessionManager.db.updateScheduleSettings(
          record.id,
          runSessionId: null,
        );
      }
      pausedCount++;
    }
    return pausedCount;
  }

  /// Updates a schedule owned by [caller] (Decisions D6, D7, D10, S24).
  ScheduledTaskRecord updateSchedule({
    required String id,
    String? callerSessionId,
    ScheduleCaller? caller,
    String? task,
    ScheduleDefinition? definition,
    Object? name = ScheduledTaskRepository.unset,
    Object? conversationMode = ScheduledTaskRepository.unset,
    Object? workspaceId = ScheduledTaskRepository.unset,
    Object? providerInstanceId = ScheduledTaskRepository.unset,
    Object? model = ScheduledTaskRepository.unset,
  }) {
    final row = _sessionManager.db.getScheduledTask(id);
    if (row == null) {
      throw ScheduleNotFoundException('Schedule "$id" not found.');
    }
    final existing = ScheduledTaskRecord.fromRow(row);
    final effectiveCaller = caller ??
        (callerSessionId != null
            ? ScheduleCaller.model(callerSessionId)
            : const ScheduleCaller.user());
    ScheduleControl.authorize(existing, effectiveCaller);

    ScheduleConversationMode? validatedMode;
    if (!identical(conversationMode, ScheduledTaskRepository.unset)) {
      if (conversationMode == null) {
        throw const ScheduleValidationException(
          'Conversation mode is required and cannot be null.',
        );
      }
      validatedMode = ScheduleControl.parseConversationMode(conversationMode);
    }

    final hasSettingsUpdate =
        !identical(name, ScheduledTaskRepository.unset) ||
        !identical(conversationMode, ScheduledTaskRepository.unset) ||
        !identical(workspaceId, ScheduledTaskRepository.unset) ||
        !identical(providerInstanceId, ScheduledTaskRepository.unset) ||
        !identical(model, ScheduledTaskRepository.unset);

    if (hasSettingsUpdate) {
      _sessionManager.db.updateScheduleSettings(
        id,
        name: name,
        conversationMode: validatedMode?.wireName ?? ScheduledTaskRepository.unset,
        workspaceId: workspaceId,
        providerInstanceId: providerInstanceId,
        model: model,
      );
    }

    final now = DateTime.now().toUtc();
    final effectiveDefinition = definition ?? existing.toDefinition();
    final effectiveTask = task ?? existing.task;

    final nextRunAt = OccurrenceCalculator.computeNextOccurrence(
      effectiveDefinition,
      from: now,
      previousRunAt: existing.lastRunAt,
    );

    final updated = ScheduledTaskRecord(
      id: existing.id,
      task: effectiveTask,
      sessionId: existing.sessionId,
      kind: effectiveDefinition.kind,
      intervalMinutes: effectiveDefinition.intervalMinutes,
      atTime: effectiveDefinition.atTime,
      weekdays: effectiveDefinition.weekdays?.join(','),
      monthDay: effectiveDefinition.monthDay,
      zone: effectiveDefinition.zone,
      nextRunAt: nextRunAt,
      createdAt: existing.createdAt,
      updatedAt: now,
      lastRunAt: existing.lastRunAt,
      lastStatus: existing.lastStatus,
      enabled: existing.enabled,
      name: !identical(name, ScheduledTaskRepository.unset)
          ? name as String?
          : existing.name,
      ownerKind: existing.ownerKind,
      conversationMode: validatedMode ?? existing.conversationMode,
      runSessionId: existing.runSessionId,
      workspaceId: !identical(workspaceId, ScheduledTaskRepository.unset)
          ? workspaceId as String?
          : existing.workspaceId,
      providerInstanceId: !identical(providerInstanceId, ScheduledTaskRepository.unset)
          ? providerInstanceId as String?
          : existing.providerInstanceId,
      model: !identical(model, ScheduledTaskRepository.unset)
          ? model as String?
          : existing.model,
    );

    _saveRecord(updated);
    _cancelInMemory(id);
    if (updated.enabled) {
      _scheduleInMemory(updated, now: now);
    }
    return updated;
  }

  void _scheduleInMemory(ScheduledTaskRecord record, {DateTime? now}) {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    final delay = record.nextRunAt.difference(effectiveNow);

    _logger.info(
      'Scheduling task: "${record.task}" at ${record.nextRunAt} (delay: $delay, id: ${record.id})',
    );

    if (delay.isNegative) {
      if (record.kind == ScheduleKind.once) {
        _logger.warning('Task ${record.id} scheduled in the past. Executing immediately.');
        _executeTask(record);
        return;
      } else {
        restoreRecurringSchedule(record, now: effectiveNow);
        return;
      }
    }

    _cancelInMemory(record.id);

    final timer = Timer(delay, () {
      _executeTask(record);
    });

    _tasks.add(
      ScheduledTaskMetadata(
        id: record.id,
        time: record.nextRunAt,
        task: record.task,
        sessionId: record.sessionId,
        timer: timer,
        record: record,
      ),
    );
  }

  @visibleForTesting
  void executeTaskForTesting(ScheduledTaskRecord record) => _executeTask(record);

  void _executeTask(ScheduledTaskRecord record) {
    _logger.info('Executing scheduled task: "${record.task}" (id: ${record.id})');
    final executionTime = DateTime.now().toUtc();
    final targetSessionId = _conversationFactory.resolveDispatchSession(record);
    final runId = _runRecorder.startRun(
      scheduleId: record.id,
      runAt: executionTime,
      trigger: ScheduledTaskRunTrigger.scheduled,
    );

    _runObserver?.track(
      runId: runId,
      sessionId: targetSessionId,
      scheduleId: record.id,
    );

    if (record.kind == ScheduleKind.once) {
      _tasks.removeWhere((t) => t.id == record.id);
      _sessionManager.db.deleteScheduledTask(record.id);
      try {
        _emitEvent(record.task, targetSessionId, runId: runId);
      } catch (e, stack) {
        _logger.severe('Failed to dispatch once task ${record.id}: $e', e, stack);
        _runRecorder.completeRun(
          runId,
          status: ScheduledTaskRunStatus.failed,
          error: e.toString(),
        );
      }
    } else {
      final nextRunAt = OccurrenceCalculator.computeNextOccurrence(
        record.toDefinition(),
        from: executionTime,
        // Anchor on the slot that just fired, not on timer lateness or an
        // older run, so the interval cadence never drifts (B-D3).
        previousRunAt: record.nextRunAt,
      );

      final nextRecord = ScheduleControl.withStatus(
        record,
        lastStatus: 'fired',
        lastRunAt: executionTime,
        updatedAt: executionTime,
        nextRunAt: nextRunAt,
      );

      // Persist advanced instant and last_status before emitting (B-D1)
      _saveRecord(nextRecord);

      _tasks.removeWhere((t) => t.id == record.id);
      _scheduleInMemory(nextRecord);

      try {
        _emitEvent(record.task, targetSessionId, runId: runId);
      } catch (e, stack) {
        _logger.severe('Failed to dispatch scheduled task ${record.id}: $e', e, stack);
        _runRecorder.completeRun(
          runId,
          status: ScheduledTaskRunStatus.failed,
          error: e.toString(),
        );
        _saveRecord(ScheduleControl.withStatus(
          nextRecord,
          lastStatus: 'error',
          updatedAt: DateTime.now().toUtc(),
        ));
      }
    }
  }

  void _cancelInMemory(String id) {
    _tasks.removeWhere((t) {
      if (t.id == id) {
        t.timer.cancel();
        return true;
      }
      return false;
    });
  }

  void _emitEvent(String task, String sessionId, {String? runId}) {
    final effectiveRunId = runId ?? 'cron_${DateTime.now().millisecondsSinceEpoch}';
    final event = GatewayEvent(
      sessionId: sessionId,
      platformId: platformId,
      type: 'cron',
      runId: effectiveRunId,
      message: Message(role: MessageRole.user, content: task),
      metadata: {
        'payload': {
          // The run identity is the turn's request identity, so the durable
          // user message the turn commits is the run's history anchor (S9, S20).
          'request_id': effectiveRunId,
          // A schedule dispatch is always its own turn, never a steer: `queue`
          // keeps the orchestrator from treating it as steerable input while a
          // turn is active (it waits and runs afterwards) and still admits it
          // immediately on an idle conversation (Task 139 Delta 1).
          'delivery_intent': MessageDeliveryIntent.queue.name,
        },
      },
    );
    if (!_controller.hasListener) {
      _pendingEvents.add(event);
      return;
    }
    _controller.add(event);
  }

  void _flushPendingEvents() {
    if (_pendingEvents.isEmpty) return;
    final pending = List<GatewayEvent>.of(_pendingEvents);
    _pendingEvents.clear();
    // Deliver after the subscribing call returns so the listener is attached.
    scheduleMicrotask(() {
      for (final event in pending) {
        if (_controller.isClosed) return;
        _controller.add(event);
      }
    });
  }

  @override
  Future<void> sendResponse(GatewayResponse response) async {
    _logger.info(
      'Received response for cron task: ${response.message.content}',
    );
  }

  @override
  Future<void> initialize({DateTime? now}) async {
    final effectiveNow = (now ?? DateTime.now()).toUtc();
    _logger.info('CronScheduler initializing from DB at $effectiveNow...');

    final persisted = _persistedState;
    if (_runObserver != null && !_runObserver!.isListening && persisted != null) {
      _runObserver!.listen(persisted.executionState.changes);
    }

    _runRecorder.recoverInterruptedRuns(
      isRunActive: (sessionId, runId) {
        final item = _persistedState?.workItems.findActiveWorkItem(sessionId);
        return item != null && item.requestId == runId;
      },
    );

    final dbTasks = _sessionManager.db.getAllScheduledTasks();

    for (var taskData in dbTasks) {
      final record = ScheduledTaskRecord.fromRow(taskData);
      if (!record.enabled) continue;

      if (record.kind == ScheduleKind.once) {
        // B-D4: Grace period of 5 minutes for missed tasks during downtime
        if (record.nextRunAt.isAfter(effectiveNow.subtract(const Duration(minutes: 5)))) {
          _scheduleInMemory(record, now: effectiveNow);
        } else {
          _logger.warning('Skipping stale task: "${record.task}" scheduled for ${record.nextRunAt}');
          _sessionManager.db.deleteScheduledTask(record.id);
        }
      } else {
        // B-D2, B-D3, B-D6: Recurring schedule recovery and missed-occurrence policy
        restoreRecurringSchedule(record, now: effectiveNow);
      }
    }
    _logger.info(
      'CronScheduler initialized with ${_tasks.length} active tasks.',
    );
  }

  /// Restores a recurring schedule on startup using the missed-occurrence policy (Decision B-D2).
  @visibleForTesting
  void restoreRecurringSchedule(ScheduledTaskRecord record, {DateTime? now}) {
    final effectiveNow = (now ?? DateTime.now()).toUtc();

    if (record.nextRunAt.isAfter(effectiveNow)) {
      // Future instant: no missed occurrence
      _scheduleInMemory(record, now: effectiveNow);
      return;
    }

    final definition = record.toDefinition();
    final graceWindow = RecurrenceGracePolicy.computeGraceWindow(definition);
    final mostRecentMissed = OccurrenceCalculator.computeMostRecentDueInstant(
      definition,
      now: effectiveNow,
      previousRunAt: record.lastRunAt,
      nextRunAt: record.nextRunAt,
    );

    final missedBy = effectiveNow.difference(mostRecentMissed);
    final isInsideGrace = !missedBy.isNegative && missedBy <= graceWindow;

    final graceMinutes = graceWindow.inMinutes;
    final missedStr = missedBy.inMinutes > 0
        ? '${missedBy.inMinutes}m'
        : '${missedBy.inSeconds}s';

    final nextFutureRunAt = OccurrenceCalculator.computeNextOccurrence(
      definition,
      from: effectiveNow,
      // The most recent due instant lies on the stored slot grid, which is
      // the same anchor dispatch uses, so restart never re-anchors (B-D3).
      previousRunAt: mostRecentMissed,
    );

    if (isInsideGrace) {
      _logger.info(
        'Missed recurring task "${record.task}" (id: ${record.id}) at $mostRecentMissed is within grace window of ${graceMinutes}m (missed by $missedStr). Firing once and advancing to $nextFutureRunAt.',
      );

      final targetSessionId = _conversationFactory.resolveDispatchSession(record);
      final runId = _runRecorder.startRun(
        scheduleId: record.id,
        runAt: mostRecentMissed,
        trigger: ScheduledTaskRunTrigger.recovery,
      );

      _runObserver?.track(
        runId: runId,
        sessionId: targetSessionId,
        scheduleId: record.id,
      );

      final advanced = ScheduleControl.withStatus(
        record,
        lastStatus: 'fired',
        lastRunAt: effectiveNow,
        updatedAt: effectiveNow,
        nextRunAt: nextFutureRunAt,
      );

      // Persist BEFORE emitting (B-D1)
      _saveRecord(advanced);
      _scheduleInMemory(advanced, now: effectiveNow);

      try {
        _emitEvent(record.task, targetSessionId, runId: runId);
      } catch (e, stack) {
        _logger.severe('Failed to dispatch scheduled task ${record.id}: $e', e, stack);
        _runRecorder.completeRun(
          runId,
          status: ScheduledTaskRunStatus.failed,
          error: e.toString(),
        );
        _saveRecord(ScheduleControl.withStatus(
          advanced,
          lastStatus: 'error',
          updatedAt: DateTime.now().toUtc(),
        ));
      }
    } else {
      _logger.warning(
        'Skipping missed scheduled task "${record.task}" (id: ${record.id}): missed occurrence at $mostRecentMissed exceeded grace window of ${graceMinutes}m (missed by $missedStr). Advancing to $nextFutureRunAt.',
      );

      _runRecorder.recordSkipped(
        scheduleId: record.id,
        runAt: mostRecentMissed,
      );

      // S2: On a skipped occurrence, preserve previous lastRunAt (or null) so listings never imply a run that was skipped.
      final advanced = ScheduleControl.withStatus(
        record,
        lastStatus: 'skipped_missed',
        updatedAt: effectiveNow,
        nextRunAt: nextFutureRunAt,
      );

      _saveRecord(advanced);
      _scheduleInMemory(advanced, now: effectiveNow);
    }
  }

  @override
  Future<void> dispose() async {
    for (var t in _tasks) {
      t.timer.cancel();
    }
    _tasks.clear();
    _pendingEvents.clear();
    await _runObserver?.dispose();
    await _controller.close();
    _logger.info('CronScheduler disposed.');
  }
}

class ScheduledTaskMetadata {
  final String id;
  final DateTime time;
  final String task;
  final String sessionId;
  final Timer timer;
  final ScheduledTaskRecord? record;

  ScheduledTaskMetadata({
    required this.id,
    required this.time,
    required this.task,
    required this.sessionId,
    required this.timer,
    this.record,
  });
}
