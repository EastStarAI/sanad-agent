import 'dart:async';
import 'package:logging/logging.dart';
import 'package:meta/meta.dart';
import 'package:sanad_agent/core/models/message.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';
import 'package:sanad_agent/evolution/session_manager.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/platforms/base_platform.dart';

class ScheduleNotFoundException implements Exception {
  final String message;
  const ScheduleNotFoundException(this.message);
  @override
  String toString() => message;
}

class SchedulePermissionException implements Exception {
  final String message;
  const SchedulePermissionException(this.message);
  @override
  String toString() => message;
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

  final StreamController<GatewayEvent> _controller =
      StreamController<GatewayEvent>.broadcast();

  @override
  Stream<GatewayEvent> get eventStream => _controller.stream;

  final List<ScheduledTaskMetadata> _tasks = [];
  final _sessionManager = SessionManager();

  List<ScheduledTaskMetadata> get activeTasks => List.unmodifiable(_tasks);

  /// Creates and schedules a new task adhering to Decisions D2-D8.
  ScheduledTaskRecord createSchedule({
    required String task,
    required String sessionId,
    required ScheduleDefinition definition,
    String? id,
  }) {
    if (sessionId.trim().isEmpty) {
      throw const ScheduleValidationException(
        'Cannot create a scheduled task without a session context.',
      );
    }

    final taskId = id ?? 'task_${DateTime.now().millisecondsSinceEpoch}';
    final now = DateTime.now().toUtc();
    final nextRunAt = OccurrenceCalculator.computeNextOccurrence(
      definition,
      from: now,
    );

    final record = ScheduledTaskRecord(
      id: taskId,
      task: task,
      sessionId: sessionId,
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
    );

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
      enabled: record.enabled,
    );

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
    final definition = ScheduleDefinition(
      kind: ScheduleKind.once,
      zone: 'local',
      onceAt: time.toUtc(),
    );
    createSchedule(
      task: task,
      sessionId: sessionId,
      definition: definition,
      id: id,
    );
  }

  /// Lists all scheduled tasks device-wide (Decision D6).
  List<ScheduledTaskRecord> listSchedules() {
    final rows = _sessionManager.db.getAllScheduledTasks();
    return rows.map((r) => ScheduledTaskRecord.fromRow(r)).toList();
  }

  /// Cancels a schedule owned by [callerSessionId] (Decisions D6, D7).
  ScheduledTaskRecord cancelSchedule(
    String id, {
    required String callerSessionId,
  }) {
    final row = _sessionManager.db.getScheduledTask(id);
    if (row == null) {
      throw ScheduleNotFoundException('Schedule "$id" not found.');
    }
    final record = ScheduledTaskRecord.fromRow(row);
    if (record.sessionId != callerSessionId) {
      throw SchedulePermissionException(
        'Schedule "$id" is owned by conversation "${record.sessionId}" and cannot be modified from conversation "$callerSessionId".',
      );
    }

    _cancelInMemory(id);
    _sessionManager.db.deleteScheduledTask(id);
    return record;
  }

  /// Updates a schedule owned by [callerSessionId] (Decisions D6, D7, D10).
  ScheduledTaskRecord updateSchedule({
    required String id,
    required String callerSessionId,
    String? task,
    ScheduleDefinition? definition,
  }) {
    final row = _sessionManager.db.getScheduledTask(id);
    if (row == null) {
      throw ScheduleNotFoundException('Schedule "$id" not found.');
    }
    final existing = ScheduledTaskRecord.fromRow(row);
    if (existing.sessionId != callerSessionId) {
      throw SchedulePermissionException(
        'Schedule "$id" is owned by conversation "${existing.sessionId}" and cannot be modified from conversation "$callerSessionId".',
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
    );

    _sessionManager.db.saveScheduledTask(
      updated.id,
      updated.task,
      updated.nextRunAt,
      updated.sessionId,
      kind: updated.kind.name,
      intervalMinutes: updated.intervalMinutes,
      atTime: updated.atTime,
      weekdays: updated.weekdays,
      monthDay: updated.monthDay,
      zone: updated.zone,
      updatedAt: updated.updatedAt,
      lastRunAt: updated.lastRunAt,
      lastStatus: updated.lastStatus,
      enabled: updated.enabled,
    );

    _cancelInMemory(id);
    _scheduleInMemory(updated);
    return updated;
  }

  void _scheduleInMemory(ScheduledTaskRecord record) {
    final now = DateTime.now().toUtc();
    final delay = record.nextRunAt.difference(now);

    _logger.info(
      'Scheduling task: "${record.task}" at ${record.nextRunAt} (delay: $delay, id: ${record.id})',
    );

    if (delay.isNegative) {
      if (record.kind == ScheduleKind.once) {
        _logger.warning('Task ${record.id} scheduled in the past. Executing immediately.');
        _sessionManager.db.deleteScheduledTask(record.id);
        _emitEvent(record.task, record.sessionId);
        return;
      } else {
        // Recurring schedule in the past: compute next future occurrence
        final nextRunAt = OccurrenceCalculator.computeNextOccurrence(
          record.toDefinition(),
          from: now,
          previousRunAt: record.lastRunAt,
        );
        final advanced = ScheduledTaskRecord(
          id: record.id,
          task: record.task,
          sessionId: record.sessionId,
          kind: record.kind,
          intervalMinutes: record.intervalMinutes,
          atTime: record.atTime,
          weekdays: record.weekdays,
          monthDay: record.monthDay,
          zone: record.zone,
          nextRunAt: nextRunAt,
          createdAt: record.createdAt,
          updatedAt: DateTime.now().toUtc(),
          lastRunAt: record.lastRunAt,
          lastStatus: record.lastStatus,
          enabled: record.enabled,
        );
        _sessionManager.db.saveScheduledTask(
          advanced.id,
          advanced.task,
          advanced.nextRunAt,
          advanced.sessionId,
          kind: advanced.kind.name,
          intervalMinutes: advanced.intervalMinutes,
          atTime: advanced.atTime,
          weekdays: advanced.weekdays,
          monthDay: advanced.monthDay,
          zone: advanced.zone,
          updatedAt: advanced.updatedAt,
          lastRunAt: advanced.lastRunAt,
          lastStatus: advanced.lastStatus,
          enabled: advanced.enabled,
        );
        _scheduleInMemory(advanced);
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

    if (record.kind == ScheduleKind.once) {
      _tasks.removeWhere((t) => t.id == record.id);
      _sessionManager.db.deleteScheduledTask(record.id);
      _emitEvent(record.task, record.sessionId);
    } else {
      final executionTime = DateTime.now().toUtc();
      final nextRunAt = OccurrenceCalculator.computeNextOccurrence(
        record.toDefinition(),
        from: executionTime,
        previousRunAt: executionTime,
      );

      final nextRecord = ScheduledTaskRecord(
        id: record.id,
        task: record.task,
        sessionId: record.sessionId,
        kind: record.kind,
        intervalMinutes: record.intervalMinutes,
        atTime: record.atTime,
        weekdays: record.weekdays,
        monthDay: record.monthDay,
        zone: record.zone,
        nextRunAt: nextRunAt,
        createdAt: record.createdAt,
        updatedAt: executionTime,
        lastRunAt: executionTime,
        lastStatus: 'fired',
        enabled: record.enabled,
      );

      _sessionManager.db.saveScheduledTask(
        nextRecord.id,
        nextRecord.task,
        nextRecord.nextRunAt,
        nextRecord.sessionId,
        kind: nextRecord.kind.name,
        intervalMinutes: nextRecord.intervalMinutes,
        atTime: nextRecord.atTime,
        weekdays: nextRecord.weekdays,
        monthDay: nextRecord.monthDay,
        zone: nextRecord.zone,
        updatedAt: nextRecord.updatedAt,
        lastRunAt: nextRecord.lastRunAt,
        lastStatus: nextRecord.lastStatus,
        enabled: nextRecord.enabled,
      );

      _tasks.removeWhere((t) => t.id == record.id);
      _scheduleInMemory(nextRecord);

      _emitEvent(record.task, record.sessionId);
    }
  }

  void _cancelInMemory(String id) {
    final idx = _tasks.indexWhere((t) => t.id == id);
    if (idx != -1) {
      _tasks[idx].timer.cancel();
      _tasks.removeAt(idx);
    }
  }

  void _emitEvent(String task, String sessionId) {
    _controller.add(
      GatewayEvent(
        sessionId: sessionId,
        platformId: platformId,
        type: 'cron',
        runId: 'cron_${DateTime.now().millisecondsSinceEpoch}',
        message: Message(role: MessageRole.user, content: task),
      ),
    );
  }

  @override
  Future<void> sendResponse(GatewayResponse response) async {
    _logger.info(
      'Received response for cron task: ${response.message.content}',
    );
  }

  @override
  Future<void> initialize() async {
    _logger.info('CronScheduler initializing from DB...');
    final dbTasks = _sessionManager.db.getAllScheduledTasks();

    for (var taskData in dbTasks) {
      final record = ScheduledTaskRecord.fromRow(taskData);
      if (!record.enabled) continue;

      if (record.kind == ScheduleKind.once) {
        // Grace period of 5 minutes for missed tasks during downtime
        if (record.nextRunAt.isAfter(DateTime.now().subtract(const Duration(minutes: 5)))) {
          _scheduleInMemory(record);
        } else {
          _logger.warning('Skipping stale task: "${record.task}" scheduled for ${record.nextRunAt}');
          _sessionManager.db.deleteScheduledTask(record.id);
        }
      } else {
        // Recurring task: restore and schedule next run
        _scheduleInMemory(record);
      }
    }
    _logger.info(
      'CronScheduler initialized with ${_tasks.length} active tasks.',
    );
  }

  @override
  Future<void> dispose() async {
    for (var t in _tasks) {
      t.timer.cancel();
    }
    _tasks.clear();
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
