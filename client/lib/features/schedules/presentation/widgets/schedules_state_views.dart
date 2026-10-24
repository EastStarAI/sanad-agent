import 'package:flutter/material.dart';
import 'package:sanad_client/features/schedules/domain/models/schedule_error.dart';
import 'package:sanad_client/features/schedules/presentation/bloc/schedules_cubit.dart';
import 'package:sanad_client/features/schedules/presentation/widgets/schedule_failure_text.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// The four non-loaded presentations of a Schedules surface (Task 139 C4).
///
/// Each is a separate, keyed widget so a live check can tell the states apart,
/// and none of them presents a row: a snapshot is current only for
/// [SchedulesStatus.loaded].

/// A page skeleton while the first read of a device scope is in flight.
class SchedulesLoadingView extends StatelessWidget {
  const SchedulesLoadingView({super.key});

  @override
  Widget build(BuildContext context) {
    final color = Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08);
    Widget bar(double width, double height) => Container(
      width: width,
      height: height,
      decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(6)),
    );
    return Column(
      key: const Key('schedules_loading'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        for (var row = 0; row < 3; row++)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                bar(row.isEven ? 220 : 160, 12),
                const SizedBox(height: 8),
                bar(row.isEven ? 160 : 120, 10),
              ],
            ),
          ),
      ],
    );
  }
}

/// "No schedules yet" plus the create action (C2).
class SchedulesEmptyView extends StatelessWidget {
  const SchedulesEmptyView({super.key, required this.onCreate});

  /// `null` while the device cannot accept the action (S18).
  final VoidCallback? onCreate;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      key: const Key('schedules_empty'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.event_note_outlined, size: 22, color: colorScheme.onSurfaceVariant),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.scheduleEmpty, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 4),
              Text(
                l10n.scheduleEmptyHint,
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
              ),
              const SizedBox(height: 12),
              FilledButton.icon(
                key: const Key('schedules_empty_create_btn'),
                onPressed: onCreate,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: Text(l10n.newSchedule),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// The typed failure of the last read, in localized copy, plus Retry.
class SchedulesErrorView extends StatelessWidget {
  const SchedulesErrorView({super.key, required this.failure, required this.onRetry});

  final ScheduleFailure? failure;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final detail = scheduleFailureText(l10n, failure?.code ?? ScheduleErrorCode.unknown);
    return Column(
      key: const Key('schedules_error'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Icon(Icons.error_outline_rounded, size: 20, color: colorScheme.error),
            const SizedBox(width: 12),
            Expanded(child: Text(l10n.scheduleLoadFailed)),
          ],
        ),
        if (detail != null) ...[
          const SizedBox(height: 6),
          Text(detail, style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12)),
        ],
        const SizedBox(height: 12),
        OutlinedButton.icon(
          key: const Key('schedules_retry_btn'),
          onPressed: onRetry,
          icon: const Icon(Icons.refresh_rounded, size: 18),
          label: Text(l10n.retry),
        ),
      ],
    );
  }
}

/// The offline banner: actions are disabled and no list is presented as current.
class SchedulesUnavailableBanner extends StatelessWidget {
  const SchedulesUnavailableBanner({super.key, this.onRetry});

  /// Retry for an online device whose transport failed; `null` when offline, so
  /// an offline device is never asked to answer.
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    return Row(
      key: const Key('schedules_unavailable_banner'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Icon(Icons.cloud_off_outlined, size: 20, color: colorScheme.error),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(l10n.scheduleUnavailable, style: const TextStyle(fontWeight: FontWeight.w600)),
              const SizedBox(height: 2),
              Text(
                l10n.scheduleUnavailableHint,
                style: TextStyle(color: colorScheme.onSurfaceVariant, fontSize: 12),
              ),
              if (onRetry != null) ...[
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  key: const Key('schedules_unavailable_retry_btn'),
                  onPressed: onRetry,
                  icon: const Icon(Icons.refresh_rounded, size: 18),
                  label: Text(l10n.retry),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}
