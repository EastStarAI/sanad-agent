import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_failure_text.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_format.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The shared schedule actions of every surface (Task 139 C2).
///
/// Pause, resume, run now, and delete are the same calls whether they start from
/// a list row, the detail page, or a dialog, so they live here instead of being
/// re-implemented per surface. A refusal becomes typed, localized, transient
/// copy: the Agent's own `message` is never shown, and nothing is stored.
///
/// Run now never resumes a paused schedule and stays available on a paused row
/// (S21); the caller decides availability from `Schedule.canRunNow` and
/// `Schedule.canResume`, and this class throws for an orphaned row instead of
/// silently doing nothing (S23, D10).
class ScheduleActions {
  ScheduleActions._();

  /// Pauses [schedule] (S13).
  static Future<ScheduleActionOutcome> pause(BuildContext context, Schedule schedule) {
    return _run(context, schedule, ScheduleActionKind.pause, (cubit) => cubit.pause(schedule.id));
  }

  /// Resumes [schedule]; an expired `once` refuses with localized copy (D6).
  static Future<ScheduleActionOutcome> resume(BuildContext context, Schedule schedule) {
    return _run(context, schedule, ScheduleActionKind.resume, (cubit) => cubit.resume(schedule.id));
  }

  /// Dispatches [schedule] now without moving its next instant (S14, S21).
  static Future<ScheduleActionOutcome> runNow(BuildContext context, Schedule schedule) {
    return _run(context, schedule, ScheduleActionKind.runNow, (cubit) => cubit.runNow(schedule.id));
  }

  /// Asks for confirmation, then deletes [schedule] and its run history (S10).
  ///
  /// Only the schedule and its runs go; its conversations stay readable. The
  /// answer reports whether the Agent accepted the deletion.
  static Future<bool> delete(BuildContext context, Schedule schedule) async {
    final confirmed = await confirmDelete(context, schedule);
    if (!confirmed || !context.mounted) return false;
    final outcome = await _run(
      context,
      schedule,
      ScheduleActionKind.delete,
      (cubit) => cubit.delete(schedule.id),
    );
    return outcome == ScheduleActionOutcome.success;
  }

  /// The one delete confirmation of the schedule surfaces (S10).
  static Future<bool> confirmDelete(BuildContext context, Schedule schedule) async {
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        key: const Key('schedule_delete_dialog'),
        title: Text(l10n.deleteSchedule),
        content: Text(l10n.deleteScheduleConfirm(scheduleDisplayLabel(schedule, l10n))),
        actions: [
          TextButton(
            key: const Key('schedule_delete_cancel_btn'),
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(MaterialLocalizations.of(dialogContext).cancelButtonLabel),
          ),
          TextButton(
            key: const Key('schedule_delete_confirm_btn'),
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              l10n.delete,
              style: TextStyle(color: Theme.of(dialogContext).colorScheme.error),
            ),
          ),
        ],
      ),
    );
    return confirmed == true;
  }

  /// Shows the typed reason an action was refused, or nothing for `unknown`.
  static void reportFailure(BuildContext context, ScheduleFailure? failure) {
    if (failure == null) return;
    final l10n = AppLocalizations.of(context)!;
    final text = scheduleFailureText(l10n, failure.code) ?? l10n.scheduleActionFailed;
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(
        SnackBar(
          key: const Key('schedule_action_failure_notice'),
          content: Text(text),
        ),
      );
  }

  static Future<ScheduleActionOutcome> _run(
    BuildContext context,
    Schedule schedule,
    ScheduleActionKind kind,
    Future<ScheduleActionOutcome> Function(SchedulesCubit cubit) action,
  ) async {
    if (schedule.isOrphaned && kind != ScheduleActionKind.delete) {
      // An orphaned model-owned row has no dispatch target (S23, D10): its
      // surface offers edit and delete only, so this is a programming error and
      // never a silent no-op.
      throw StateError('An orphaned schedule offers edit and delete only.');
    }
    final cubit = context.read<SchedulesCubit>();
    final outcome = await action(cubit);
    if (!context.mounted) return outcome;
    if (outcome == ScheduleActionOutcome.failed) {
      final failure = cubit.state.failure;
      // Only this schedule's own refusal is reported here; another row's failure
      // belongs to that row.
      if (failure != null && (failure.scheduleId == null || failure.scheduleId == schedule.id)) {
        reportFailure(context, failure);
      }
    }
    return outcome;
  }
}
