import 'schedule_model.dart';

/// Who is asking to control a schedule (Task 139 D5, S15).
///
/// Authority is decided by the receiving transport or tool family and is never
/// read from a payload: a model turn can only ever be [model], and only a
/// device-owner command can be [user]. A caller therefore cannot widen its own
/// scope, and there is no payload field that selects the kind.
enum ScheduleAuthority {
  /// A model turn inside a conversation (Task 112a D6).
  model,

  /// The human operating the device: a local, cloud, or CLI client command.
  user,
}

/// One control request's identity and authority.
class ScheduleCaller {
  final ScheduleAuthority authority;

  /// The calling conversation for a [ScheduleAuthority.model] caller. Always
  /// `null` for a device-owner caller, which is not scoped to a conversation.
  final String? sessionId;

  /// A model turn acting inside [sessionId].
  const ScheduleCaller.model(String this.sessionId)
    : authority = ScheduleAuthority.model;

  /// The device owner, acting with no conversation scope.
  const ScheduleCaller.user()
    : authority = ScheduleAuthority.user,
      sessionId = null;

  bool get isDeviceOwner => authority == ScheduleAuthority.user;
}

/// The addressed schedule does not exist.
class ScheduleNotFoundException implements Exception {
  final String message;
  const ScheduleNotFoundException(this.message);
  @override
  String toString() => message;
}

/// A caller asked to mutate a row it has no authority over (Task 112a D6).
class SchedulePermissionException implements Exception {
  final String message;
  const SchedulePermissionException(this.message);
  @override
  String toString() => message;
}

/// Resuming a `once` schedule whose instant has passed (Task 139 D6).
class ScheduleExpiredException implements Exception {
  final String message;
  const ScheduleExpiredException(this.message);
  @override
  String toString() => message;
}

/// A model-owned schedule whose owning conversation no longer exists, so it has
/// no dispatch target (Task 139 S23, D10).
class ScheduleOrphanedException implements Exception {
  final String message;
  const ScheduleOrphanedException(this.message);
  @override
  String toString() => message;
}

/// The single owner of schedule-control authority and of the validation every
/// control path must pass before it touches a row (Task 139 A2).
///
/// `CronScheduler` stays the only writer (112a D7); this owner decides whether a
/// caller may write and whether a requested state is even representable.
abstract final class ScheduleControl {
  /// Every accepted `conversation_mode` value, in wire form.
  static const Set<String> conversationModeWireValues = {'continuous',
    'new_each_run'};

  /// Validates a `conversation_mode` request value.
  ///
  /// `conversation_mode` is `NOT NULL` with no empty-string sentinel, so `null`
  /// is never a valid request: it is rejected here instead of reaching SQLite
  /// as a constraint failure. An unknown value is rejected for the same reason —
  /// the protocol owns a closed vocabulary and must not persist a mode no run
  /// can honor.
  static ScheduleConversationMode parseConversationMode(Object? raw) {
    if (raw is ScheduleConversationMode) return raw;
    final text = raw?.toString().trim().toLowerCase();
    if (text == null || text.isEmpty) {
      throw const ScheduleValidationException(
        'Conversation mode is required and cannot be empty. '
        'Accepted values are: continuous, new_each_run.',
      );
    }
    switch (text) {
      case 'continuous':
        return ScheduleConversationMode.continuous;
      case 'new_each_run':
        return ScheduleConversationMode.newEachRun;
      default:
        throw ScheduleValidationException(
          'Unknown conversation mode "$raw". '
          'Accepted values are: continuous, new_each_run.',
        );
    }
  }

  /// Throws unless [caller] may mutate [record] (S15).
  ///
  /// A user-owned row is mutable by device-owner authority only, because the
  /// model path must never claim work the user created. A model-owned row is
  /// mutable by its owning conversation and by device-owner authority.
  static void authorize(ScheduledTaskRecord record, ScheduleCaller caller) {
    if (caller.isDeviceOwner) return;
    final callerSessionId = caller.sessionId;
    if (record.ownerKind == ScheduleOwnerKind.model &&
        callerSessionId != null &&
        callerSessionId.isNotEmpty &&
        record.sessionId == callerSessionId) {
      return;
    }
    throw SchedulePermissionException(
      _permissionMessage(record, callerSessionId),
    );
  }

  static String _permissionMessage(
    ScheduledTaskRecord record,
    String? callerSessionId,
  ) {
    if (record.ownerKind == ScheduleOwnerKind.user) {
      return 'Schedule "${record.id}" is owned by the device user and cannot '
          'be modified from conversation "$callerSessionId".';
    }
    return 'Schedule "${record.id}" is owned by conversation '
        '"${record.sessionId}" and cannot be modified from conversation '
        '"$callerSessionId".';
  }

  /// Throws when [record] has no dispatch target (S23, D10).
  ///
  /// Only a model-owned row can be orphaned: its runs append to the owning
  /// conversation, and nothing may re-create that conversation. A user-owned
  /// row always has a target — its stored `continuous` conversation or one it
  /// creates on the next dispatch.
  static void requireDispatchTarget(
    ScheduledTaskRecord record, {
    required bool Function(String sessionId) sessionExists,
  }) {
    if (record.ownerKind != ScheduleOwnerKind.model) return;
    final target = _modelTarget(record);
    if (target != null && sessionExists(target)) return;
    throw ScheduleOrphanedException(
      'Schedule "${record.id}" is owned by a conversation that no longer '
      'exists, so it has no dispatch target. Edit or delete it instead.',
    );
  }

  /// Throws when [record] cannot be resumed (D6, D10).
  static void requireResumable(
    ScheduledTaskRecord record, {
    required DateTime now,
    required bool Function(String sessionId) sessionExists,
  }) {
    requireDispatchTarget(record, sessionExists: sessionExists);
    if (record.kind == ScheduleKind.once && !record.nextRunAt.isAfter(now)) {
      throw ScheduleExpiredException(
        'Schedule "${record.id}" is a one-shot schedule whose instant '
        '(${record.nextRunAt.toIso8601String()}) has already passed, so it '
        'cannot be resumed. It never fires retroactively.',
      );
    }
  }

  /// True when a model-owned row has lost its owning conversation.
  static bool isOrphaned(
    ScheduledTaskRecord record, {
    required bool Function(String sessionId) sessionExists,
  }) {
    if (record.ownerKind != ScheduleOwnerKind.model) return false;
    final target = _modelTarget(record);
    return target == null || !sessionExists(target);
  }

  /// The conversation a model-owned row dispatches into, or null.
  ///
  /// A model-owned row mirrors its owning conversation in `run_session_id`;
  /// pre-Task-139 rows only carry `session_id`, which is why both are read.
  static String? _modelTarget(ScheduledTaskRecord record) {
    for (final candidate in [record.runSessionId, record.sessionId]) {
      if (candidate != null && candidate.trim().isNotEmpty) return candidate;
    }
    return null;
  }

  /// Produces a paused copy of [record] with `enabled = false` and bumped `updatedAt`.
  static ScheduledTaskRecord pauseRecord(
    ScheduledTaskRecord record, {
    required DateTime now,
  }) {
    return ScheduledTaskRecord(
      id: record.id,
      task: record.task,
      sessionId: record.sessionId,
      kind: record.kind,
      intervalMinutes: record.intervalMinutes,
      atTime: record.atTime,
      weekdays: record.weekdays,
      monthDay: record.monthDay,
      zone: record.zone,
      nextRunAt: record.nextRunAt,
      createdAt: record.createdAt,
      updatedAt: now,
      lastRunAt: record.lastRunAt,
      lastStatus: record.lastStatus,
      enabled: false,
      name: record.name,
      ownerKind: record.ownerKind,
      conversationMode: record.conversationMode,
      runSessionId: record.runSessionId,
      workspaceId: record.workspaceId,
      providerInstanceId: record.providerInstanceId,
      model: record.model,
    );
  }

  /// Produces a resumed copy of [record] with `enabled = true`, recomputed
  /// [nextRunAt], and bumped `updatedAt`.
  static ScheduledTaskRecord resumeRecord(
    ScheduledTaskRecord record, {
    required DateTime now,
    required DateTime nextRunAt,
  }) {
    return ScheduledTaskRecord(
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
      updatedAt: now,
      lastRunAt: record.lastRunAt,
      lastStatus: record.lastStatus,
      enabled: true,
      name: record.name,
      ownerKind: record.ownerKind,
      conversationMode: record.conversationMode,
      runSessionId: record.runSessionId,
      workspaceId: record.workspaceId,
      providerInstanceId: record.providerInstanceId,
      model: record.model,
    );
  }

  /// Copies [record] with updated execution status / timestamps.
  static ScheduledTaskRecord withStatus(
    ScheduledTaskRecord record, {
    required String lastStatus,
    DateTime? lastRunAt,
    DateTime? updatedAt,
    DateTime? nextRunAt,
  }) {
    return ScheduledTaskRecord(
      id: record.id,
      task: record.task,
      sessionId: record.sessionId,
      kind: record.kind,
      intervalMinutes: record.intervalMinutes,
      atTime: record.atTime,
      weekdays: record.weekdays,
      monthDay: record.monthDay,
      zone: record.zone,
      nextRunAt: nextRunAt ?? record.nextRunAt,
      createdAt: record.createdAt,
      updatedAt: updatedAt ?? record.updatedAt,
      lastRunAt: lastRunAt ?? record.lastRunAt,
      lastStatus: lastStatus,
      enabled: record.enabled,
      name: record.name,
      ownerKind: record.ownerKind,
      conversationMode: record.conversationMode,
      runSessionId: record.runSessionId,
      workspaceId: record.workspaceId,
      providerInstanceId: record.providerInstanceId,
      model: record.model,
    );
  }
}
