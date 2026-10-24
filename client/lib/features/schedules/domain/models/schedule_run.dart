import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_instant.dart';

/// The lifecycle state of one run (Task 139 D9, protocol §4.5).
enum ScheduleRunStatus {
  running,
  succeeded,
  failed,

  /// A missed occurrence that never ran.
  skipped,

  /// A status this Client does not know yet; it is never presented as a
  /// success.
  unknown;

  static ScheduleRunStatus fromWire(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'running' => ScheduleRunStatus.running,
      'succeeded' => ScheduleRunStatus.succeeded,
      'failed' => ScheduleRunStatus.failed,
      'skipped' => ScheduleRunStatus.skipped,
      _ => ScheduleRunStatus.unknown,
    };
  }
}

/// What caused a run.
enum ScheduleRunTrigger {
  scheduled,
  manual,

  /// An in-grace recovery dispatch after a restart.
  recovery,

  /// A trigger this Client does not know yet.
  unknown;

  static ScheduleRunTrigger fromWire(Object? value) {
    return switch (value?.toString().trim().toLowerCase()) {
      'scheduled' => ScheduleRunTrigger.scheduled,
      'manual' => ScheduleRunTrigger.manual,
      'recovery' => ScheduleRunTrigger.recovery,
      _ => ScheduleRunTrigger.unknown,
    };
  }
}

/// One row of a schedule's run history (Task 139 S8, protocol §4.5).
///
/// The projection carries no conversation title, message text, task text, or
/// command output. [error] is the run's own bounded, redacted failure text and
/// is the only place a failure reason exists; the live `schedule.run_failed`
/// notice never carries one.
class ScheduleRun extends Equatable {
  const ScheduleRun({
    required this.id,
    required this.runAt,
    required this.status,
    required this.trigger,
    this.durationMs,
    this.error,
    this.sessionId,
    this.messageId,
    this.hasPosition = false,
  });

  final String id;

  /// When the run started, as an absolute instant.
  final DateTime runAt;

  final ScheduleRunStatus status;
  final ScheduleRunTrigger trigger;

  /// Dispatch acceptance to terminal state, or `null` while running.
  final int? durationMs;

  /// The bounded, redacted failure text of this run, or `null`.
  final String? error;

  /// The conversation the run appended to, or `null`.
  final String? sessionId;

  /// The `message_id` of the run's user message (S9, S20), or `null` until that
  /// message commits.
  final String? messageId;

  /// Whether the Agent reported a message anchor.
  final bool hasPosition;

  /// Whether **Open conversation** can land on this run's own user message.
  /// A position without a conversation to open it in is not navigable.
  bool get canOpenConversation => hasPosition && sessionId != null && messageId != null;

  /// Whether the run is still in flight.
  bool get isRunning => status == ScheduleRunStatus.running;

  factory ScheduleRun.fromJson(Map<String, dynamic> json) {
    return ScheduleRun(
      id: json['id']?.toString() ?? '',
      runAt: ScheduleInstant.utcTryParse(json['run_at']) ?? DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      status: ScheduleRunStatus.fromWire(json['status']),
      trigger: ScheduleRunTrigger.fromWire(json['trigger']),
      durationMs: _asInt(json['duration_ms']),
      error: _blankToNull(json['error']),
      sessionId: _blankToNull(json['session_id']),
      messageId: _blankToNull(json['message_id']),
      hasPosition: json['has_position'] == true,
    );
  }

  /// Identity and outcome only; it never carries the task text or message text.
  @override
  String toString() => 'ScheduleRun(id: $id, status: ${status.name}, trigger: ${trigger.name})';

  @override
  List<Object?> get props => [
    id,
    runAt,
    status,
    trigger,
    durationMs,
    error,
    sessionId,
    messageId,
    hasPosition,
  ];
}

/// One bounded page of `schedule.runs` (Task 139 protocol §4.5).
///
/// [nextCursor] is opaque: it is passed back unchanged and never parsed here.
class ScheduleRunsPage extends Equatable {
  const ScheduleRunsPage({
    required this.scheduleId,
    required this.runs,
    this.hasMore = false,
    this.nextCursor,
  });

  final String scheduleId;
  final List<ScheduleRun> runs;
  final bool hasMore;
  final String? nextCursor;

  factory ScheduleRunsPage.fromJson(Map<String, dynamic> json, {required String scheduleId}) {
    final entries = json['runs'];
    return ScheduleRunsPage(
      scheduleId: _blankToNull(json['schedule_id']) ?? scheduleId,
      runs: List<ScheduleRun>.unmodifiable([
        if (entries is List)
          for (final entry in entries)
            if (entry is Map) ScheduleRun.fromJson(Map<String, dynamic>.from(entry)),
      ]),
      hasMore: json['has_more'] == true,
      nextCursor: _blankToNull(json['next_cursor']),
    );
  }

  @override
  List<Object?> get props => [scheduleId, runs, hasMore, nextCursor];
}

/// The `schedule.run_accepted` result of Run now (Task 139 S14, S21).
///
/// It records that a manual run was accepted. It is not a terminal outcome: the
/// run row reaches its terminal state later.
class ScheduleRunAcceptance extends Equatable {
  const ScheduleRunAcceptance({
    required this.scheduleId,
    required this.runId,
    this.sessionId,
    this.acceptedAt,
  });

  final String scheduleId;
  final String runId;

  /// The conversation the run was dispatched into, or `null` when the Agent had
  /// to create one and reports it only on the run row.
  final String? sessionId;

  final DateTime? acceptedAt;

  factory ScheduleRunAcceptance.fromJson(Map<String, dynamic> json, {required String scheduleId}) {
    return ScheduleRunAcceptance(
      scheduleId: scheduleId,
      runId: _blankToNull(json['run_id']) ?? '',
      sessionId: _blankToNull(json['session_id']),
      acceptedAt: _asUtc(json['accepted_at']),
    );
  }

  @override
  List<Object?> get props => [scheduleId, runId, sessionId, acceptedAt];
}

String? _blankToNull(Object? value) {
  final text = value?.toString().trim();
  return text == null || text.isEmpty ? null : text;
}

int? _asInt(Object? value) => value is int ? value : int.tryParse(value?.toString() ?? '');

DateTime? _asUtc(Object? value) {
  final raw = value?.toString();
  if (raw == null || raw.isEmpty) return null;
  return DateTime.tryParse(raw)?.toUtc();
}
