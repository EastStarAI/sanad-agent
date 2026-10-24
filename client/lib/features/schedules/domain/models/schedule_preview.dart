import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_instant.dart';

/// The `schedule.preview_result` answer for a candidate definition (Task 139
/// D4, protocol §7).
///
/// The preview is the Agent's own answer: the Client owns no second occurrence
/// calculator. An invalid definition is answered *inside* this result
/// (`valid: false` plus [errorCode]) instead of as an error envelope, because
/// reporting invalidity is the command's purpose.
class SchedulePreview extends Equatable {
  const SchedulePreview({
    required this.valid,
    this.nextRunAt,
    this.nextRunAtOffset,
    this.zone,
    this.errorCode,
  });

  /// Whether the candidate definition is a valid schedule.
  final bool valid;

  /// The next instant the candidate would fire, rendered in [zone].
  final DateTime? nextRunAt;

  /// The offset token the Agent wrote with [nextRunAt], which is what a `local`
  /// [zone] renders in (Task 139 F4).
  final String? nextRunAtOffset;

  /// The zone the Agent used for [nextRunAt].
  final String? zone;

  /// Why the definition was rejected; `null` when [valid] is true.
  final ScheduleErrorCode? errorCode;

  factory SchedulePreview.fromJson(Map<String, dynamic> json) {
    final rawError = json['error_code'];
    final nextRun = ScheduleInstant.tryParse(json['next_run_at']);
    return SchedulePreview(
      valid: json['valid'] == true,
      nextRunAt: nextRun?.instant,
      nextRunAtOffset: nextRun?.offset,
      zone: (json['zone']?.toString().trim().isEmpty ?? true) ? null : json['zone'].toString().trim(),
      errorCode: rawError == null ? null : ScheduleErrorCode.fromWireCode(rawError.toString()),
    );
  }

  @override
  List<Object?> get props => [valid, nextRunAt, nextRunAtOffset, zone, errorCode];
}
