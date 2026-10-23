import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_actions.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_editor_sheet.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_format.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The Details tab of one schedule (Task 139 C2, S8).
///
/// It presents what the Agent stored — the recurrence, the owner, the stored
/// workspace and route, and the conversation mode — plus the same actions the
/// list row offers, with the same availability rules: run now stays available on
/// a paused row and never resumes it (S21), and an orphaned model-owned row
/// offers edit and delete only (S23, D10).
class ScheduleDetailsTab extends StatelessWidget {
  const ScheduleDetailsTab({
    super.key,
    required this.schedule,
    required this.device,
    required this.deviceId,
    required this.actionsEnabled,
  });

  final Schedule schedule;
  final DeviceConfig? device;
  final String deviceId;

  /// Whether the device can accept an action right now (S18).
  final bool actionsEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final summary = scheduleRecurrenceSummary(schedule: schedule, l10n: l10n, context: context);
    final storedRoute = <String?>[schedule.providerInstanceId, schedule.model]
        .whereType<String>()
        .where((value) => value.trim().isNotEmpty)
        .join(' / ');

    return SingleChildScrollView(
      key: const Key('schedule_detail_details_tab'),
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Text(
                  scheduleDisplayLabel(schedule, l10n),
                  style: theme.textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700),
                ),
              ),
              if (schedule.isPaused)
                Container(
                  key: const Key('schedule_detail_paused_pill'),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                  decoration: BoxDecoration(
                    color: colorScheme.onSurfaceVariant.withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    l10n.schedulePaused,
                    style: TextStyle(fontSize: 11, color: colorScheme.onSurfaceVariant),
                  ),
                ),
            ],
          ),
          if (summary != null) ...[
            const SizedBox(height: 4),
            Text(summary, style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 13)),
          ],
          const Divider(height: 28),
          _DetailLine(
            label: l10n.scheduleOwner,
            value: scheduleOwnerLabel(schedule: schedule, l10n: l10n),
          ),
          if (schedule.ownerSessionId == null)
            _DetailHint(text: l10n.scheduleOwnedByDeviceHint),
          _DetailLine(
            label: l10n.scheduleNextRun,
            value: schedule.nextRunAt == null
                ? l10n.scheduleNextRunUnknown
                : l10n.scheduleInstantWithZone(
                    formatScheduleInstant(context, schedule.nextRunAt!, zone: schedule.zone),
                    schedule.zone,
                  ),
          ),
          _DetailLine(
            label: l10n.scheduleLastRun,
            value: schedule.lastOutcome == null
                ? l10n.scheduleNeverRan
                : [
                    scheduleLastOutcomeLabel(schedule.lastOutcome!, l10n),
                    if (schedule.lastRunAt != null)
                      formatScheduleInstant(context, schedule.lastRunAt!, zone: schedule.zone),
                  ].join(' · '),
          ),
          _DetailLine(
            label: l10n.scheduleConversationMode,
            value: scheduleConversationModeLabel(schedule.conversationMode, l10n),
          ),
          const Divider(height: 28),
          _DetailLine(
            label: l10n.scheduleWorkspace,
            value: schedule.workspaceId ?? l10n.scheduleNotSet,
          ),
          _DetailLine(
            label: l10n.scheduleModel,
            value: storedRoute.isEmpty ? l10n.scheduleNotSet : storedRoute,
          ),
          if (schedule.suggestsPause) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(Icons.error_outline_rounded, size: 16, color: colorScheme.error),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    l10n.scheduleFailureSuggestion,
                    key: const Key('schedule_detail_pause_suggestion'),
                    style: TextStyle(color: colorScheme.error, fontSize: 12),
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(height: 20),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (schedule.canResume)
                OutlinedButton.icon(
                  key: Key('schedule_resume_btn_${schedule.id}'),
                  onPressed: actionsEnabled
                      ? () => unawaited(ScheduleActions.resume(context, schedule))
                      : null,
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: Text(l10n.resumeSchedule),
                ),
              if (!schedule.isPaused && !schedule.isOrphaned)
                OutlinedButton.icon(
                  key: Key('schedule_pause_btn_${schedule.id}'),
                  onPressed: actionsEnabled
                      ? () => unawaited(ScheduleActions.pause(context, schedule))
                      : null,
                  icon: const Icon(Icons.pause_rounded, size: 18),
                  label: Text(l10n.pauseSchedule),
                ),
              if (schedule.canRunNow)
                FilledButton.icon(
                  key: Key('schedule_run_now_btn_${schedule.id}'),
                  onPressed: actionsEnabled
                      ? () => unawaited(ScheduleActions.runNow(context, schedule))
                      : null,
                  icon: const Icon(Icons.bolt_rounded, size: 18),
                  label: Text(l10n.runNow),
                ),
              OutlinedButton.icon(
                key: Key('schedule_edit_btn_${schedule.id}'),
                onPressed: actionsEnabled
                    ? () => unawaited(
                        ScheduleEditorSheet.show(
                          context,
                          cubit: context.read<SchedulesCubit>(),
                          device: device,
                          schedule: schedule,
                        ),
                      )
                    : null,
                icon: const Icon(Icons.edit_outlined, size: 18),
                label: Text(l10n.scheduleEdit),
              ),
              OutlinedButton.icon(
                key: Key('schedule_delete_btn_${schedule.id}'),
                onPressed: actionsEnabled
                    ? () async {
                        final deleted = await ScheduleActions.delete(context, schedule);
                        if (!context.mounted || !deleted) return;
                        // The schedule and its runs are gone; the list is the
                        // only place left to show.
                        context.go(AppRoutes.schedulesLocation(deviceId));
                      }
                    : null,
                icon: const Icon(Icons.delete_outline_rounded, size: 18),
                label: Text(l10n.deleteSchedule),
                style: OutlinedButton.styleFrom(foregroundColor: colorScheme.error),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class _DetailLine extends StatelessWidget {
  const _DetailLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 150,
            child: Text(
              label,
              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
          Expanded(child: Text(value, style: const TextStyle(fontSize: 12))),
        ],
      ),
    );
  }
}

class _DetailHint extends StatelessWidget {
  const _DetailHint({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(start: 150, bottom: 8),
      child: Text(
        text,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontSize: 11,
        ),
      ),
    );
  }
}
