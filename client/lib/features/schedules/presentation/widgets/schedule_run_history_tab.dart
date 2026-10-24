import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:go_router/go_router.dart';
import 'package:provider/provider.dart' show Provider, ProviderNotFoundException;
import 'package:sanad_client/core/navigation/app_routes.dart';
import 'package:sanad_client/features/conversations/data/repositories/conversation_cache_repository.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/session_messages_cubit.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_run.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_failure_text.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_format.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The Run history tab of one schedule (Task 139 C2, S8, S20).
///
/// Each row shows the run time, its status, its trigger, its duration, and its
/// own bounded error text — the only place a failure reason exists — plus
/// **Open conversation**, which lands on the run's user message when the Agent
/// reported a position (`has_position`, S20) and on the conversation otherwise.
/// Paging uses the opaque cursor the Agent minted; the Client never parses it.
class ScheduleRunHistoryTab extends StatelessWidget {
  const ScheduleRunHistoryTab({
    super.key,
    required this.deviceId,
    required this.scheduleId,
    required this.actionsEnabled,
  });

  final String deviceId;
  final String scheduleId;

  /// Whether the device can accept a request right now (S18).
  final bool actionsEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return BlocBuilder<SchedulesCubit, SchedulesState>(
      buildWhen: (previous, current) =>
          previous.detail != current.detail || previous.status != current.status || previous.failure != current.failure,
      builder: (context, state) {
        final detail = state.detail;
        final runs = detail?.runs ?? const <ScheduleRun>[];
        if (detail == null || (detail.loadingRuns && runs.isEmpty)) {
          return const Center(
            key: Key('schedule_runs_loading'),
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(strokeWidth: 2),
            ),
          );
        }
        final failure = detail.failure;
        if (failure != null && runs.isEmpty) {
          final detailText = scheduleFailureText(l10n, failure.code);
          return Padding(
            key: const Key('schedule_runs_error'),
            padding: const EdgeInsets.all(20),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.error_outline_rounded, size: 20, color: colorScheme.error),
                    const SizedBox(width: 12),
                    Expanded(child: Text(l10n.scheduleLoadRunsFailed)),
                  ],
                ),
                if (detailText != null) ...[
                  const SizedBox(height: 6),
                  Text(detailText, style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
                ],
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('schedule_runs_retry_btn'),
                  onPressed: actionsEnabled ? () => unawaited(context.read<SchedulesCubit>().refreshRuns()) : null,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(l10n.retry),
                ),
              ],
            ),
          );
        }
        if (runs.isEmpty) {
          return Padding(
            key: const Key('schedule_runs_empty'),
            padding: const EdgeInsets.all(20),
            child: Text(
              l10n.scheduleNoRuns,
              style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          );
        }
        return SingleChildScrollView(
          key: const Key('schedule_detail_runs_tab'),
          padding: const EdgeInsets.fromLTRB(20, 12, 20, 24),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              for (final run in runs)
                _ScheduleRunRow(
                  key: Key('schedule_run_row_${run.id}'),
                  run: run,
                  deviceId: deviceId,
                  scheduleId: scheduleId,
                  actionsEnabled: actionsEnabled,
                ),
              if (detail.canLoadMoreRuns)
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: TextButton.icon(
                    key: const Key('schedule_runs_load_more_btn'),
                    onPressed: () => unawaited(context.read<SchedulesCubit>().loadMoreRuns()),
                    icon: const Icon(Icons.expand_more, size: 18),
                    label: Text(l10n.loadMore),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _ScheduleRunRow extends StatelessWidget {
  const _ScheduleRunRow({
    super.key,
    required this.run,
    required this.deviceId,
    required this.scheduleId,
    required this.actionsEnabled,
  });

  final ScheduleRun run;
  final String deviceId;
  final String scheduleId;
  final bool actionsEnabled;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final duration = formatScheduleDuration(run.durationMs);
    final canOpen = run.sessionId != null;
    final period = _schedulePeriodOf(context, scheduleId);
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 8, 10),
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.35),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.2)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  formatScheduleInstant(
                    context,
                    run.runAt,
                    zone: period.zone,
                    // `run_at` travels as UTC, so a `local` schedule renders in
                    // the Agent offset the row's next instant carries.
                    wireOffset: period.agentOffset,
                  ),
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                ),
              ),
              _RunStatusPill(status: run.status),
            ],
          ),
          const SizedBox(height: 4),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text(
                '${l10n.scheduleRunTrigger}: ${scheduleRunTriggerLabel(run.trigger, l10n)}',
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
              ),
              Text(
                '${l10n.scheduleDuration}: ${duration ?? l10n.scheduleNotSet}',
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 11),
              ),
            ],
          ),
          if (run.error != null) ...[
            const SizedBox(height: 6),
            Text(
              run.error!,
              key: Key('schedule_run_error_${run.id}'),
              style: TextStyle(color: colorScheme.error, fontSize: 11),
            ),
          ],
          Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton.icon(
              key: Key('schedule_open_conversation_btn_${run.id}'),
              onPressed: actionsEnabled && canOpen ? () => _openConversation(context) : null,
              icon: const Icon(Icons.forum_outlined, size: 16),
              label: Text(l10n.scheduleOpenConversation, style: const TextStyle(fontSize: 11)),
              style: TextButton.styleFrom(
                minimumSize: const Size(0, 32),
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// The schedule's own zone and the Agent offset its instants render in.
  ///
  /// The run projection carries instants, not a zone: the schedule's zone is the
  /// one it fires in, and its `next_run_at` designator is this Client's only
  /// evidence of the Agent's `local` offset, so the history renders the same wall
  /// clock the list shows.
  static ({String? zone, String? agentOffset}) _schedulePeriodOf(
    BuildContext context,
    String scheduleId,
  ) {
    final schedule = context.read<SchedulesCubit>().state.scheduleById(scheduleId);
    return (zone: schedule?.zone, agentOffset: schedule?.nextRunAtOffset);
  }

  /// Opens the run inside its conversation (S8, S20).
  ///
  /// The run's `anchor_event_id` is the canonical history event id of its user
  /// message and the only anchor the history accepts, so it is recorded as the
  /// conversation's viewport anchor before navigating. The run's `message_id` is
  /// a different identity and is never substituted: passing it made the anchored
  /// load fail and the conversation open at its tail (Task 139 F2, protocol
  /// §9.1). Without an anchor — no position, or one the Agent could no longer
  /// resolve — the conversation opens at its own default place, which is not an
  /// error.
  void _openConversation(BuildContext context) {
    final sessionId = run.sessionId;
    if (sessionId == null) return;
    final anchor = run.anchorEventId;
    if (anchor != null && anchor.isNotEmpty) {
      _maybeRead<SessionMessagesCubit>(context)?.requestHistoryAnchor(
        deviceId: deviceId,
        sessionId: sessionId,
        anchorEventId: anchor,
      );
      _maybeRead<ConversationCacheRepository>(
        context,
      )?.recordSessionViewportAnchor(deviceId, sessionId, anchor);
    }
    context.go(AppRoutes.sessionLocation(deviceId, sessionId));
  }
}

/// A provider this row can live without: a surface pumped without the
/// conversation chrome still navigates, it just does not pre-position.
T? _maybeRead<T extends Object>(BuildContext context) {
  try {
    return Provider.of<T>(context, listen: false);
  } on ProviderNotFoundException {
    return null;
  }
}

class _RunStatusPill extends StatelessWidget {
  const _RunStatusPill({required this.status});

  final ScheduleRunStatus status;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      ScheduleRunStatus.succeeded => colorScheme.primary,
      ScheduleRunStatus.failed => colorScheme.error,
      ScheduleRunStatus.running => colorScheme.tertiary,
      _ => colorScheme.onSurfaceVariant,
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        scheduleRunStatusLabel(status, l10n),
        style: TextStyle(fontSize: 10, fontWeight: FontWeight.w600, color: color),
      ),
    );
  }
}
