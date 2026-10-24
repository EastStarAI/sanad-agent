import 'package:sanad_agent/evolution/db/session_db.dart';
import 'package:sanad_agent/evolution/models/session_history_page.dart';
import 'package:sanad_agent/evolution/scheduling/schedule_model.dart';

/// Wire projection of `scheduled_tasks` and `scheduled_task_runs` for the
/// schedule protocol (Task 139 §Protocol).
///
/// The projection is structured and closed: `schedule.list`, `schedule.created`,
/// and `schedule.updated` all carry the same fields, and the Client composes its
/// own localized recurrence summary from them. The Agent's English recurrence
/// sentence (`ScheduleDefinition.humanRecurrenceSummary`) stays model-facing and
/// never becomes a UI string.
abstract final class ScheduleWireLimits {
  /// Largest `schedules` array a single `schedule.list_result` may carry.
  ///
  /// A device with more schedules than this reports `truncated: true` instead of
  /// growing an unbounded response; the cap is far above any realistic device
  /// and no client page depends on the tail.
  static const int maxListedSchedules = 500;

  /// Page size of `schedule.runs` when the request sends no `limit`.
  static const int defaultRunsPageSize = 50;

  /// Largest accepted `schedule.runs` page size.
  ///
  /// It equals the retention bound, so a page is always a slice of what was
  /// retained rather than a request the store cannot satisfy.
  static const int maxRunsPageSize = ScheduledTaskRunRetention.maxRunsPerSchedule;
}

/// The row projection shared by every single-row response and `schedule.list`.
abstract final class ScheduleRowProjection {
  static Map<String, dynamic> project({
    required ScheduledTaskRecord record,
    required int consecutiveFailures,
    required String? ownerSessionTitle,
  }) {
    final ownerSessionId = ownerSession(record);
    return {
      'id': record.id,
      'name': record.name,
      'task': record.task,
      'kind': record.kind.name,
      'interval_minutes': record.intervalMinutes,
      'at_time': record.atTime,
      'weekdays': _weekdays(record.weekdays),
      'month_day': record.monthDay,
      'zone': record.zone,
      'next_run_at': ScheduleZone.parse(record.zone).formatInstant(
        record.nextRunAt,
      ),
      'enabled': record.enabled,
      'owner_kind': record.ownerKind.wireName,
      'owner_session_id': ownerSessionId,
      'owner_session_title': ownerSessionId == null ? null : ownerSessionTitle,
      'conversation_mode': record.conversationMode.wireName,
      'workspace_id': record.workspaceId,
      'provider_instance_id': record.providerInstanceId,
      'model': record.model,
      'last_run_at': record.lastRunAt?.toUtc().toIso8601String(),
      'last_status': record.lastStatus,
      'consecutive_failures': consecutiveFailures,
      'created_at': record.createdAt.toUtc().toIso8601String(),
      'updated_at': record.updatedAt.toUtc().toIso8601String(),
    };
  }

  /// The conversation a schedule is bound to, or `null` when it has none yet.
  ///
  /// A model-owned row dispatches into its owning conversation. A user-owned
  /// `continuous` row dispatches into the conversation its first run created;
  /// `new_each_run` never binds one. An empty stored value is an absent one, so
  /// no payload presents the empty string as an identity (Task 139 D1).
  static String? ownerSession(ScheduledTaskRecord record) =>
      blankToNull(record.runSessionId) ?? blankToNull(record.sessionId);

  static List<String>? _weekdays(String? stored) {
    if (stored == null || stored.trim().isEmpty) return null;
    return [
      for (final day in stored.split(','))
        if (day.trim().isNotEmpty) day.trim(),
    ];
  }
}

/// The run projection every `schedule.runs_result` row uses.
abstract final class ScheduleRunProjection {
  /// Exactly `{id, run_at, status, trigger, duration_ms, error, session_id,
  /// message_id, has_position, anchor_event_id}`.
  ///
  /// `has_position` is true exactly when `message_id` is set, which is the only
  /// case in which the Client can open the run inside its conversation (S20).
  /// `anchor_event_id` is the identity that open actually navigates with: the
  /// canonical history event id of the run's user message, or `null` when there
  /// is none to open (see [anchorEventIdFor]). No conversation title, message
  /// text, or command output is projected here.
  static Map<String, dynamic> project(
    ScheduledTaskRun run, {
    String? anchorEventId,
  }) => {
    'id': run.id,
    'run_at': run.runAt.toUtc().toIso8601String(),
    'status': run.status.wireName,
    'trigger': run.trigger.wireName,
    'duration_ms': run.durationMs,
    'error': run.error,
    'session_id': run.sessionId,
    'message_id': run.messageId,
    'has_position': run.hasPosition,
    'anchor_event_id': anchorEventId,
  };

  /// The canonical history anchor [run]'s Open conversation navigates with.
  ///
  /// A run stores the identity of the message its turn committed; the history
  /// anchor addresses that message's durable row, so the id is built from the
  /// stored conversation through [SessionHistoryEventId] rather than formatted
  /// here. `null` while the run has no position, and also when that message row
  /// is no longer the active one — an anchor the history loader cannot resolve
  /// is indistinguishable from no anchor, and the run row's stored identity is
  /// never rewritten to fake a position it lost.
  static String? anchorEventIdFor(
    ScheduledTaskRun run, {
    required SessionDB db,
  }) {
    final sessionId = run.sessionId;
    final messageId = run.messageId;
    if (sessionId == null || messageId == null) return null;
    final messageRowId = db.activeRowIdForMessageId(sessionId, messageId);
    if (messageRowId == null) return null;
    return SessionHistoryEventId.forUserMessage(
      sessionId: sessionId,
      messageRowId: messageRowId,
    );
  }
}
