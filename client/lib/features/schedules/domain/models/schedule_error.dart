/// Why a schedule command or query did not succeed, as a code the Client can
/// localize (Task 139 C4, protocol §7).
///
/// Every value except [deviceUnavailable] and [unknown] is a `code` the Agent
/// sent: either in a protocol error envelope or, for `schedule.preview`, in its
/// own `error_code` result field. The Agent's `message` is deliberately not
/// carried here — it is operator-facing English, never UI copy.
enum ScheduleErrorCode {
  /// Unknown field, wrong wire type, missing or blank `id`/`schedule_id`,
  /// `confirm` absent, out-of-range `limit`, malformed or foreign cursor, or an
  /// `update` with nothing to change (`invalid_request`).
  invalidRequest,

  /// `ScheduleDefinition.parse` rejected the definition
  /// (`invalid_schedule`): vocabulary, `HH:MM`, weekday, `day_of_month`,
  /// interval bound, mixed shapes, or an unsupported zone.
  invalidSchedule,

  /// Unknown schedule id (`schedule_not_found`).
  scheduleNotFound,

  /// Resume of a `once` schedule whose instant has passed
  /// (`schedule_expired`, D6).
  scheduleExpired,

  /// `resume` or `run_now` of a model-owned schedule whose owning conversation
  /// was deleted (`schedule_orphaned`, S23, D10).
  scheduleOrphaned,

  /// An unverified transport, or a caller naming a row it does not own
  /// (`permission_denied`; not reachable from a Client command).
  permissionDenied,

  /// Repository or scheduler failure; nothing mutated (`internal_error`).
  internalError,

  /// The command never reached the Agent: the device is offline, the socket is
  /// not connected, or the request timed out. Not a protocol code.
  deviceUnavailable,

  /// A code this Client does not know yet; [ScheduleException.wireCode] keeps
  /// the protocol token for diagnosis.
  unknown;

  /// Maps a protocol error code to its typed counterpart.
  static ScheduleErrorCode fromWireCode(String? code) {
    return switch (code?.trim().toLowerCase()) {
      'invalid_request' => ScheduleErrorCode.invalidRequest,
      'invalid_schedule' => ScheduleErrorCode.invalidSchedule,
      'schedule_not_found' => ScheduleErrorCode.scheduleNotFound,
      'schedule_expired' => ScheduleErrorCode.scheduleExpired,
      'schedule_orphaned' => ScheduleErrorCode.scheduleOrphaned,
      'permission_denied' => ScheduleErrorCode.permissionDenied,
      'internal_error' => ScheduleErrorCode.internalError,
      _ => ScheduleErrorCode.unknown,
    };
  }
}

/// A typed refusal of a schedule command or query.
///
/// It carries the typed [code] and the schedule [scheduleId] the refusal is
/// about (safe: it is the row identity the user is acting on). [wireCode] is
/// kept only when [code] is [ScheduleErrorCode.unknown], so a formatted error
/// can never become a carrier for Agent message text.
class ScheduleException implements Exception {
  const ScheduleException(this.code, {this.scheduleId, this.wireCode});

  final ScheduleErrorCode code;
  final String? scheduleId;
  final String? wireCode;

  @override
  String toString() =>
      'ScheduleException(${code.name}, schedule: ${scheduleId ?? 'none'}'
      '${wireCode == null ? '' : ', wire: $wireCode'})';
}
