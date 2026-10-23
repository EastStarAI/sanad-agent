import 'package:equatable/equatable.dart';

/// The live `schedule.run_failed` notice (Task 139 protocol §6).
///
/// It is client-only and model-invisible: it announces that a run failed and
/// suggests pausing, and it is never written anywhere. The payload carries
/// **no** error text by construction — there is no field for one — so no
/// command output, file content, or timeline text can reach a live notice. The
/// bounded, redacted failure text lives in the run row and is read through
/// `schedule.runs`.
///
/// Durability comes from the runs table plus `consecutive_failures` in
/// `schedule.list`, never from this event.
class ScheduleRunFailureNotice extends Equatable {
  const ScheduleRunFailureNotice({
    required this.scheduleId,
    required this.runId,
    this.scheduleName,
    this.sessionId,
    this.consecutiveFailures = 0,
    this.suggestPause = false,
  });

  final String scheduleId;
  final String runId;

  /// The stored schedule name, or `null`; the Client localizes its own label.
  final String? scheduleName;

  /// The conversation the failed run belongs to.
  final String? sessionId;

  /// The current failure streak of the schedule (S22).
  final int consecutiveFailures;

  /// Whether the streak reached the pause suggestion (S16).
  final bool suggestPause;

  factory ScheduleRunFailureNotice.fromJson(Map<String, dynamic> json) {
    return ScheduleRunFailureNotice(
      scheduleId: json['schedule_id']?.toString() ?? '',
      runId: json['run_id']?.toString() ?? '',
      scheduleName: _blankToNull(json['schedule_name']),
      sessionId: _blankToNull(json['session_id']),
      consecutiveFailures: json['consecutive_failures'] is int ? json['consecutive_failures'] as int : 0,
      suggestPause: json['suggest_pause'] == true,
    );
  }

  /// Identity and streak only; it carries no text to leak.
  @override
  String toString() =>
      'ScheduleRunFailureNotice(scheduleId: $scheduleId, runId: $runId, '
      'consecutiveFailures: $consecutiveFailures, suggestPause: $suggestPause)';

  @override
  List<Object?> get props => [scheduleId, runId, scheduleName, sessionId, consecutiveFailures, suggestPause];
}

String? _blankToNull(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}
