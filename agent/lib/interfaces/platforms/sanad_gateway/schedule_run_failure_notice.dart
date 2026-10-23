import 'package:logging/logging.dart';

import 'protocol/canonical_events.dart';

/// Publishes the live `schedule.run_failed` notice of a terminalized failed run
/// (Task 139 §Failure surfacing).
///
/// Ownership: this is the schedule family's publisher for a run outcome. It is
/// wired at the composition root into the scheduler's `ScheduleRunFailureSink`,
/// so no handler grows and `handlers/session_query_handler.dart` is untouched.
///
/// Invariants:
/// - The notice is live-only: it travels to the Sanad client family as a
///   canonical event and is never written to model history, so a model turn
///   never sees a run notice it did not create.
/// - It targets the run's own conversation through the event's `session_id`.
/// - Payload is exactly `{schedule_id, schedule_name, run_id, session_id,
///   consecutive_failures, suggest_pause}`. It carries **no error text**: the
///   bounded, redacted failure text lives in the run row and is read through
///   `schedule.runs` (coordinator decision 2026-10-23), so no command output,
///   file content, or timeline text can reach a live event.
/// - `schedule_name` is the schedule's stored name only — never a derived label
///   or an English recurrence sentence, because the Client localizes its own.
/// - `suggest_pause` is true from the third consecutive failure, manual runs
///   included (S16, S22); nothing here disables the schedule.
/// - Logging carries ids, a streak count, and a boolean only.
class ScheduleRunFailureNotice {
  ScheduleRunFailureNotice({
    required void Function(CanonicalEvent event) publishFamilyEvent,
    required String? Function(String scheduleId) scheduleName,
  }) : _publishFamilyEvent = publishFamilyEvent,
       _scheduleName = scheduleName;

  final void Function(CanonicalEvent event) _publishFamilyEvent;
  final String? Function(String scheduleId) _scheduleName;

  static final Logger _logger = Logger('ScheduleRunFailureNotice');

  /// The `error` observation is deliberately not part of the notice; see the
  /// class contract. It is accepted so this method is a `ScheduleRunFailureSink`.
  void publish({
    required String scheduleId,
    required String runId,
    required String sessionId,
    required int consecutiveFailures,
    required bool suggestPause,
    String? error,
  }) {
    if (scheduleId.isEmpty || runId.isEmpty || sessionId.isEmpty) {
      // A run without a conversation has nowhere to surface: durability comes
      // from the runs table plus `consecutive_failures` in `schedule.list`.
      _logger.fine(
        'Schedule run failure not published; schedule_id=$scheduleId, '
        'run_id=$runId, has_session=${sessionId.isNotEmpty}.',
      );
      return;
    }

    _logger.info(
      'Schedule run failed; schedule_id=$scheduleId, run_id=$runId, '
      'consecutive_failures=$consecutiveFailures, suggest_pause=$suggestPause.',
    );
    _publishFamilyEvent(
      CanonicalEvent(
        type: CanonicalEventTypes.scheduleRunFailed,
        sessionId: sessionId,
        payload: {
          'schedule_id': scheduleId,
          'schedule_name': _scheduleName(scheduleId),
          'run_id': runId,
          'session_id': sessionId,
          'consecutive_failures': consecutiveFailures,
          'suggest_pause': suggestPause,
        },
      ),
    );
  }
}
