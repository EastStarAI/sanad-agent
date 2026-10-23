import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Localized copy for one typed schedule failure (Task 139 C4, C5).
///
/// The mapping is total over [ScheduleErrorCode] and reads only an enum: the
/// Agent's own `message` is operator copy and never becomes UI text, and no
/// branch can carry a submitted value. A code this Client does not know returns
/// `null`, so the caller renders its own generic sentence instead of guessing.
String? scheduleFailureText(AppLocalizations l10n, ScheduleErrorCode code) {
  return switch (code) {
    ScheduleErrorCode.invalidRequest => l10n.scheduleErrorInvalidRequest,
    ScheduleErrorCode.invalidSchedule => l10n.scheduleErrorInvalidSchedule,
    ScheduleErrorCode.scheduleNotFound => l10n.scheduleErrorNotFound,
    ScheduleErrorCode.scheduleExpired => l10n.scheduleExpired,
    ScheduleErrorCode.scheduleOrphaned => l10n.scheduleErrorOrphaned,
    ScheduleErrorCode.permissionDenied => l10n.scheduleErrorPermissionDenied,
    ScheduleErrorCode.internalError => l10n.scheduleErrorInternal,
    ScheduleErrorCode.deviceUnavailable => l10n.scheduleUnavailableHint,
    ScheduleErrorCode.unknown => null,
  };
}
