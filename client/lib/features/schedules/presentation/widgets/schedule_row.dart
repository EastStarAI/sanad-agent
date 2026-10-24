import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_actions.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_format.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// One schedule in the device list (Task 139 C2).
///
/// The row shows the name (or a label derived from the task), the localized
/// recurrence summary, the next run in the schedule's own zone, the last
/// outcome, the paused state, and the consecutive-failure badge. Its actions are
/// the shared ones: pause/resume, run now, edit, and delete.
///
/// Availability follows the binding decisions rather than the row's mood:
/// - run now stays enabled on a paused row and never resumes it (S21);
/// - an orphaned model-owned row offers edit and delete only (S23, D10);
/// - nothing is offered while the device cannot accept it (S18).
class ScheduleRow extends StatelessWidget {
  const ScheduleRow({
    super.key,
    required this.schedule,
    required this.actionsEnabled,
    required this.onOpen,
    required this.onEdit,
  });

  final Schedule schedule;

  /// Whether the device can accept an action right now.
  final bool actionsEnabled;

  /// Opens the detail page.
  final VoidCallback onOpen;

  /// Opens the editor for this row.
  final VoidCallback onEdit;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final label = scheduleDisplayLabel(schedule, l10n);
    final summary = scheduleRecurrenceSummary(schedule: schedule, l10n: l10n, context: context);

    return Card(
      key: Key('schedule_row_${schedule.id}'),
      margin: const EdgeInsets.only(bottom: 10),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14),
                    ),
                  ),
                  if (schedule.isPaused) ...[
                    const SizedBox(width: 8),
                    _SchedulePill(
                      key: Key('schedule_paused_pill_${schedule.id}'),
                      label: l10n.schedulePaused,
                      color: colorScheme.onSurfaceVariant,
                    ),
                  ],
                  if (schedule.suggestsPause) ...[
                    const SizedBox(width: 8),
                    Tooltip(
                      message: l10n.scheduleFailureSuggestion,
                      child: _FailureBadge(
                        key: Key('schedule_failure_badge_${schedule.id}'),
                        count: schedule.consecutiveFailures,
                      ),
                    ),
                  ],
                ],
              ),
              if (summary != null) ...[
                const SizedBox(height: 4),
                Text(
                  summary,
                  style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
                ),
              ],
              const SizedBox(height: 6),
              _ScheduleMetaLine(
                label: l10n.scheduleNextRun,
                value: schedule.nextRunAt == null
                    ? l10n.scheduleNextRunUnknown
                    : l10n.scheduleInstantWithZone(
                        formatScheduleInstant(
                          context,
                          schedule.nextRunAt!,
                          zone: schedule.zone,
                          wireOffset: schedule.nextRunAtOffset,
                        ),
                        schedule.zone,
                      ),
              ),
              const SizedBox(height: 2),
              _ScheduleMetaLine(
                label: l10n.scheduleLastRun,
                value: schedule.lastOutcome == null
                    ? l10n.scheduleNeverRan
                    : [
                        scheduleLastOutcomeLabel(schedule.lastOutcome!, l10n),
                        if (schedule.lastRunAt != null)
                          formatScheduleInstant(
                            context,
                            schedule.lastRunAt!,
                            zone: schedule.zone,
                            // `last_run_at` travels as UTC, so a `local`
                            // schedule's Agent offset comes from the row's own
                            // next instant, the only field that carries it.
                            wireOffset: schedule.nextRunAtOffset,
                          ),
                      ].join(' · '),
              ),
              const SizedBox(height: 4),
              BlocSelector<SchedulesCubit, SchedulesState, ScheduleAction?>(
                selector: (state) => state.inFlightAction,
                builder: (context, inFlight) {
                  bool busyFor(ScheduleActionKind kind) =>
                      inFlight == ScheduleAction(kind: kind, scheduleId: schedule.id);
                  return Wrap(
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      if (schedule.canResume)
                        _ScheduleRowButton(
                          buttonKey: Key('schedule_resume_btn_${schedule.id}'),
                          label: l10n.resumeSchedule,
                          icon: Icons.play_arrow_rounded,
                          onPressed: actionsEnabled && !busyFor(ScheduleActionKind.resume)
                              ? () => unawaited(ScheduleActions.resume(context, schedule))
                              : null,
                        ),
                      if (!schedule.isPaused && !schedule.isOrphaned)
                        _ScheduleRowButton(
                          buttonKey: Key('schedule_pause_btn_${schedule.id}'),
                          label: l10n.pauseSchedule,
                          icon: Icons.pause_rounded,
                          onPressed: actionsEnabled && !busyFor(ScheduleActionKind.pause)
                              ? () => unawaited(ScheduleActions.pause(context, schedule))
                              : null,
                        ),
                      if (schedule.canRunNow)
                        _ScheduleRowButton(
                          buttonKey: Key('schedule_run_now_btn_${schedule.id}'),
                          label: l10n.runNow,
                          icon: Icons.bolt_rounded,
                          onPressed: actionsEnabled && !busyFor(ScheduleActionKind.runNow)
                              ? () => unawaited(ScheduleActions.runNow(context, schedule))
                              : null,
                        ),
                      _ScheduleRowButton(
                        buttonKey: Key('schedule_edit_btn_${schedule.id}'),
                        label: l10n.scheduleEdit,
                        icon: Icons.edit_outlined,
                        onPressed: actionsEnabled ? onEdit : null,
                      ),
                      _ScheduleRowButton(
                        buttonKey: Key('schedule_delete_btn_${schedule.id}'),
                        label: l10n.deleteSchedule,
                        icon: Icons.delete_outline_rounded,
                        destructive: true,
                        onPressed: actionsEnabled && !busyFor(ScheduleActionKind.delete)
                            ? () => unawaited(ScheduleActions.delete(context, schedule))
                            : null,
                      ),
                    ],
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ScheduleMetaLine extends StatelessWidget {
  const _ScheduleMetaLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '$label: ',
          style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
        ),
        Expanded(
          child: Text(
            value,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(color: colorScheme.onSurface, fontSize: 11),
          ),
        ),
      ],
    );
  }
}

class _SchedulePill extends StatelessWidget {
  const _SchedulePill({super.key, required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}

/// The consecutive-failure badge. It carries a count and no error text: the
/// bounded failure reason lives in the run history row, never in a live badge.
class _FailureBadge extends StatelessWidget {
  const _FailureBadge({super.key, required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.error;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline_rounded, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            '$count',
            style: TextStyle(fontSize: 10, fontWeight: FontWeight.w700, color: color),
          ),
        ],
      ),
    );
  }
}

class _ScheduleRowButton extends StatelessWidget {
  const _ScheduleRowButton({
    required this.buttonKey,
    required this.label,
    required this.icon,
    required this.onPressed,
    this.destructive = false,
  });

  /// The stable key of the button itself, so a surface test can read and drive
  /// exactly the action it names.
  final Key buttonKey;
  final String label;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool destructive;

  @override
  Widget build(BuildContext context) {
    final color = destructive ? Theme.of(context).colorScheme.error : Theme.of(context).colorScheme.onSurfaceVariant;
    return TextButton.icon(
      key: buttonKey,
      onPressed: onPressed,
      icon: Icon(icon, size: 16, color: onPressed == null ? null : color),
      label: Text(
        label,
        style: TextStyle(fontSize: 11, color: onPressed == null ? null : color),
      ),
      style: TextButton.styleFrom(
        minimumSize: const Size(0, 32),
        padding: const EdgeInsets.symmetric(horizontal: 8),
        tapTargetSize: MaterialTapTargetSize.padded,
      ),
    );
  }
}
