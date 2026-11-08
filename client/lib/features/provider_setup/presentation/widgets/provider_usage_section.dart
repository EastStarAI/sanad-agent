import 'package:flutter/material.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:sanad_client/core/theme/app_typography.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Disclosure `Usage & limits` section embedded inside a provider instance
/// card (Task 55 §3.6).
///
/// Rendering rules (Task 55 §3.6):
///   • Does not render at all when the daemon reports `unsupported` or no
///     adapter exists. Never shows an empty section or noisy error.
///   • Loading and network failure never block the rest of the parent card;
///     the provider metadata and action buttons remain visible.
///   • Each returned window renders as its own row with a progress bar. Only
///     the windows the provider actually returns — no placeholders.
///   • Remaining is the headline ("58% remaining"); used is secondary
///     ("42% used").
///   • Shows plan name and extra details only when present.
///   • Footer shows an "Updated …" line and a `Refresh` control.
///   • Initial load shows a small inline indicator; a stale refresh keeps the
///     data visible with a non-destructive updating indicator.
///   • `auth_required` or transient failure shows a concise English message
///     with a `Retry` affordance and never changes instance status.
class ProviderUsageSection extends StatelessWidget {
  final DeviceConfig? agent;
  final String instanceId;

  /// The same account re-authentication the instance form's `Reconnect account`
  /// runs. Usage never implements a second reconnect path (issue 339 review 2).
  final VoidCallback onReconnect;

  const ProviderUsageSection({
    super.key,
    required this.agent,
    required this.instanceId,
    required this.onReconnect,
  });

  String _updatedLabel(BuildContext context, DateTime at) {
    final l10n = AppLocalizations.of(context)!;
    final local = at.toLocal();
    final delta = DateTime.now().difference(local);
    if (delta.inSeconds < 30) return l10n.providerUsageJustNow;
    if (delta.inMinutes < 1) return l10n.providerUsageAgoSeconds(delta.inSeconds);
    if (delta.inHours < 1) return l10n.providerUsageAgoMinutes(delta.inMinutes);
    if (delta.inHours < 24) return l10n.providerUsageAgoHours(delta.inHours);
    return DateFormat('EEE, MMM d, HH:mm').format(local);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final deviceId = agent?.id ?? context.read<ProviderUsageCubit>().localDeviceId;

    return BlocBuilder<ProviderUsageCubit, ProviderUsageState>(
      buildWhen: (prev, next) {
        final a = prev.entry(deviceId, instanceId);
        final b = next.entry(deviceId, instanceId);
        return a != b;
      },
      builder: (context, state) {
        final entry = state.entry(deviceId, instanceId);

        // No entry yet, or the daemon has explicitly said this instance is
        // unsupported → render nothing. Never an empty placeholder section.
        if (entry == null) return const SizedBox.shrink();
        if (entry.phase == ProviderUsagePhase.hidden) {
          return const SizedBox.shrink();
        }

        final isLoading = entry.phase == ProviderUsagePhase.loading;
        final isStaleRefreshing = entry.backgroundRefreshing || entry.phase == ProviderUsagePhase.staleRefreshing;

        return Padding(
          padding: const EdgeInsets.only(top: 8),
          child: Container(
            key: Key('provider_usage_section_$instanceId'),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: theme.colorScheme.outlineVariant.withValues(alpha: 0.05),
                width: 1.0,
              ),
            ),
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    Icon(
                      Icons.speed_outlined,
                      size: 18,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                    ),
                    const SizedBox(width: 6),
                    Text(
                      AppLocalizations.of(context)!.providerUsageTitle,
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                    const Spacer(),
                    if (entry.result != null) ...[
                      Text(
                        entry.fetchedAt == null
                            ? AppLocalizations.of(context)!.providerUsageUpdatedJustNow
                            : AppLocalizations.of(context)!.providerUsageUpdated(
                                _updatedLabel(context, entry.fetchedAt!),
                              ),
                        style: TextStyle(
                          fontSize: 11,
                          color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                        ),
                      ),
                      const SizedBox(width: 4),
                      TextButton.icon(
                        onPressed: isStaleRefreshing
                            ? null
                            : () => context.read<ProviderUsageCubit>().refresh(instanceId: instanceId, agent: agent),
                        icon: isStaleRefreshing
                            ? const SizedBox(
                                width: 10,
                                height: 10,
                                child: AppProgressIndicator(strokeWidth: 1.5),
                              )
                            : const Icon(Icons.refresh, size: 12),
                        label: Text(
                          AppLocalizations.of(context)!.providerUsageRefresh,
                        ),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          textStyle: AppTypography.text(context, fontSize: 11),
                        ),
                      ),
                    ],
                    if (isLoading && entry.result == null)
                      const Padding(
                        padding: EdgeInsets.only(right: 4),
                        child: SizedBox(
                          width: 14,
                          height: 14,
                          child: FittedBox(
                            child: AppProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 10),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  child: _UsageBody(
                    cubit: context.read<ProviderUsageCubit>(),
                    agent: agent,
                    instanceId: instanceId,
                    entry: entry,
                    isStaleRefreshing: isStaleRefreshing,
                    onReconnect: onReconnect,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }
}

class _UsageBody extends StatelessWidget {
  final ProviderUsageCubit cubit;
  final DeviceConfig? agent;
  final String instanceId;
  final ProviderUsageEntry entry;
  final bool isStaleRefreshing;
  final VoidCallback onReconnect;

  const _UsageBody({
    required this.cubit,
    required this.agent,
    required this.instanceId,
    required this.entry,
    required this.isStaleRefreshing,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Loading phase with no prior snapshot: small inline indicator only.
    if (entry.phase == ProviderUsagePhase.loading || entry.result == null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Column(
            children: [
              const SizedBox(
                width: 18,
                height: 18,
                child: AppProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(height: 8),
              Text(
                AppLocalizations.of(context)!.providerUsageLoading,
                style: const TextStyle(fontSize: 12),
              ),
            ],
          ),
        ),
      );
    }

    final result = entry.result!;
    // Actionable guest-side statuses for available-with-snapshot are handled
    // below by [ProviderUsagePhase.fresh]; here we catch needsAttention.
    if (entry.phase == ProviderUsagePhase.needsAttention) {
      return _AttentionBody(
        instanceId: instanceId,
        result: entry.attentionResult ?? result,
        isStaleRefreshing: isStaleRefreshing,
        hasStaleSnapshot: entry.hasVisibleSnapshot,
        staleSnapshot: entry.hasVisibleSnapshot ? result.snapshot : null,
        onRetry: () => cubit.refresh(instanceId: instanceId, agent: agent),
        onReconnect: onReconnect,
      );
    }

    final snapshot = result.snapshot;
    if (snapshot == null) {
      // Defensive: `fresh` without a snapshot shouldn't happen, but never
      // render an empty section.
      return const SizedBox.shrink();
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (isStaleRefreshing)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              children: [
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: AppProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 6),
                Text(
                  AppLocalizations.of(context)!.providerUsageRefreshing,
                  style: TextStyle(
                    fontSize: 11,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                  ),
                ),
              ],
            ),
          ),
        if (snapshot.planName != null && snapshot.planName!.isNotEmpty) ...[
          Text(
            AppLocalizations.of(context)!.providerUsagePlan(snapshot.planName!),
            key: Key('provider_usage_plan_$instanceId'),
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 6),
        ],
        for (final window in snapshot.windows)
          Padding(
            // One key per reported window type, so the body is addressable by
            // automation without reading rendered text (issue 339 review 3).
            key: Key('provider_usage_window_${instanceId}_${window.type}'),
            padding: const EdgeInsets.only(bottom: 6),
            child: _WindowRow(window: window),
          ),
        if (snapshot.extraDetails.isNotEmpty) ...[
          const SizedBox(height: 2),
          for (final detail in snapshot.extraDetails)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                detail,
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
        ],
        if (snapshot.availableResets > 0) ...[
          const SizedBox(height: 6),
          _ResetControls(
            cubit: cubit,
            agent: agent,
            instanceId: instanceId,
            entry: entry,
            snapshot: snapshot,
          ),
        ],
      ],
    );
  }
}

class _WindowRow extends StatelessWidget {
  final ProviderUsageWindowDto window;

  const _WindowRow({required this.window});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final remaining = _resolveRemaining();
    final used = _resolveUsed();
    final progress = (used ?? (remaining != null ? 100.0 - remaining : 0.0)) / 100.0;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              window.label,
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            // Remaining-first headline; used is secondary (Task 55 §3.6).
            Row(
              children: [
                if (remaining != null && used != null)
                  Text(
                    AppLocalizations.of(context)!.providerUsageUsedPercent(
                      _formatPercent(used),
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                if (remaining != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    AppLocalizations.of(
                      context,
                    )!.providerUsageRemainingPercent(_formatPercent(remaining)),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: theme.colorScheme.primary,
                    ),
                  ),
                ],
              ],
            ),
          ],
        ),
        const SizedBox(height: 4),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: progress.clamp(0.0, 1.0),
            minHeight: 6,
            backgroundColor: theme.colorScheme.onSurface.withValues(alpha: 0.08),
            valueColor: AlwaysStoppedAnimation<Color>(
              _progressColor(progress, theme),
            ),
          ),
        ),
        if (window.resetAt != null) ...[
          const SizedBox(height: 2),
          Align(
            alignment: Alignment.centerLeft,
            child: Tooltip(
              message: DateFormat('EEEE, MMMM d, y, HH:mm:ss').format(window.resetAt!.toLocal()),
              child: Text(
                AppLocalizations.of(
                  context,
                )!.providerUsageResetsAt(_formatLocalRelative(context, window.resetAt!)),
                style: TextStyle(
                  fontSize: 11,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                ),
              ),
            ),
          ),
        ],
        if (window.detail != null && window.detail!.isNotEmpty) ...[
          const SizedBox(height: 2),
          Text(
            window.detail!,
            style: TextStyle(
              fontSize: 11,
              color: theme.colorScheme.onSurface.withValues(alpha: 0.45),
            ),
          ),
        ],
      ],
    );
  }

  String _formatPercent(double value) {
    return value == value.roundToDouble() ? value.toInt().toString() : value.toStringAsFixed(1);
  }

  double? _resolveRemaining() {
    if (window.remainingPercent != null) return window.remainingPercent;
    if (window.usedPercent != null) {
      return (100.0 - window.usedPercent!).clamp(0.0, 100.0);
    }
    return null;
  }

  double? _resolveUsed() {
    if (window.usedPercent != null) return window.usedPercent;
    if (window.remainingPercent != null) {
      return (100.0 - window.remainingPercent!).clamp(0.0, 100.0);
    }
    return null;
  }

  Color _progressColor(double progress, ThemeData theme) {
    if (progress >= 0.9) return const Color(0xFFE53935);
    if (progress >= 0.7) return const Color(0xFFFB8C00);
    return theme.colorScheme.primary;
  }

  String _formatLocalRelative(BuildContext context, DateTime resetAt) {
    final l10n = AppLocalizations.of(context)!;
    final local = resetAt.toLocal();
    final now = DateTime.now();
    final delta = local.difference(now);
    if (delta.isNegative) return l10n.providerUsageResetsAnyMoment;
    if (delta.inMinutes < 1) return l10n.providerUsageResetsInMoment;
    if (delta.inHours < 1) {
      return l10n.providerUsageResetsInMinutes(delta.inMinutes);
    }
    if (delta.inHours < 24) {
      return l10n.providerUsageResetsInHours(delta.inHours);
    }
    if (delta.inDays <= 6) {
      return l10n.providerUsageResetsInDays(delta.inDays);
    }
    return l10n.providerUsageResetsOnDate(
      DateFormat('EEE, MMM d, HH:mm').format(local),
    );
  }
}

class _ResetControls extends StatelessWidget {
  final ProviderUsageCubit cubit;
  final DeviceConfig? agent;
  final String instanceId;
  final ProviderUsageEntry entry;
  final ProviderUsageSnapshotDto snapshot;

  const _ResetControls({
    required this.cubit,
    required this.agent,
    required this.instanceId,
    required this.entry,
    required this.snapshot,
  });

  @override
  Widget build(BuildContext context) {
    final count = snapshot.availableResets;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                count == 1
                    ? AppLocalizations.of(
                        context,
                      )!.providerUsageResetAvailableSingle
                    : AppLocalizations.of(
                        context,
                      )!.providerUsageResetsAvailable(count),
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: entry.resetInProgress ? null : () => _start(context),
              icon: entry.resetInProgress
                  ? const SizedBox(width: 14, height: 14, child: AppProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.restart_alt, size: 14),
              label: Text(
                AppLocalizations.of(context)!.providerUsageResetLimits,
              ),
              style: TextButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
        ),
        if (entry.resetResult != null && entry.resetResult!.status != 'confirmation_required')
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              entry.resetResult!.message,
              style: TextStyle(
                fontSize: 11,
                color: entry.resetResult!.status == 'reset'
                    ? Colors.green[700]
                    : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.65),
              ),
            ),
          ),
      ],
    );
  }

  Future<void> _start(BuildContext context) async {
    final exhausted = snapshot.windows.any((window) => window.isExhausted);
    if (exhausted) {
      final approved = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: Text(
            AppLocalizations.of(context)!.providerUsageResetDialogTitle,
          ),
          content: Text(
            AppLocalizations.of(context)!.providerUsageResetDialogBody,
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: Text(
                AppLocalizations.of(context)!.providerUsageCancel,
              ),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: Text(
                AppLocalizations.of(context)!.providerUsageResetLimits,
              ),
            ),
          ],
        ),
      );
      if (approved != true || !context.mounted) return;
    }
    final result = await cubit.reset(instanceId: instanceId, agent: agent);
    if (!context.mounted || result.status != 'confirmation_required') return;
    final token = result.confirmationToken;
    if (token == null) return;
    final force = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: Text(
          AppLocalizations.of(context)!.providerUsageResetExhaustedTitle,
        ),
        content: Text(
          AppLocalizations.of(context)!.providerUsageResetExhaustedBody(
            result.message,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: Text(AppLocalizations.of(context)!.providerUsageCancel),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: Text(
              AppLocalizations.of(context)!.providerUsageResetAnyway,
            ),
          ),
        ],
      ),
    );
    if (force == true && context.mounted) {
      await cubit.reset(
        instanceId: instanceId,
        agent: agent,
        confirmationToken: token,
      );
    }
  }
}

class _AttentionBody extends StatelessWidget {
  final String instanceId;
  final ProviderUsageResultDto result;
  final bool isStaleRefreshing;
  final bool hasStaleSnapshot;
  final ProviderUsageSnapshotDto? staleSnapshot;
  final VoidCallback onRetry;
  final VoidCallback onReconnect;

  const _AttentionBody({
    required this.instanceId,
    required this.result,
    required this.isStaleRefreshing,
    required this.hasStaleSnapshot,
    required this.staleSnapshot,
    required this.onRetry,
    required this.onReconnect,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final l10n = AppLocalizations.of(context)!;
    final message = _messageFor(l10n, result.status);
    final needsReconnect = result.status == 'auth_required';

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasStaleSnapshot && staleSnapshot != null) ...[
          for (final window in staleSnapshot!.windows)
            Padding(
              key: Key('provider_usage_window_${instanceId}_${window.type}'),
              padding: const EdgeInsets.only(bottom: 6),
              child: Opacity(
                opacity: 0.55,
                child: _WindowRow(window: window),
              ),
            ),
          const SizedBox(height: 4),
        ],
        Row(
          children: [
            Icon(
              needsReconnect ? Icons.lock_outline : Icons.error_outline,
              size: 16,
              color: needsReconnect
                  ? Colors.amber[700]
                  : theme.colorScheme.error,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message,
                key: Key('provider_usage_message_$instanceId'),
                style: TextStyle(
                  fontSize: 12,
                  color: theme.colorScheme.onSurface.withValues(alpha: 0.7),
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Align(
          alignment: Alignment.centerRight,
          child: TextButton.icon(
            // Sign-in required runs the same account re-authentication the
            // instance form exposes; anything else is a usage refresh. The key
            // names the action, not its localized label (issue 339 review 3).
            key: Key(
              needsReconnect
                  ? 'provider_usage_reconnect_$instanceId'
                  : 'provider_usage_retry_$instanceId',
            ),
            onPressed: isStaleRefreshing
                ? null
                : (needsReconnect ? onReconnect : onRetry),
            icon: Icon(
              needsReconnect ? Icons.login : Icons.refresh,
              size: 14,
            ),
            label: Text(
              needsReconnect
                  ? l10n.providerUsageReconnect
                  : l10n.providerUsageRetry,
            ),
          ),
        ),
      ],
    );
  }

  String _messageFor(AppLocalizations l10n, String status) {
    // Never echo the daemon's English message: each status owns its localized
    // sentence (issue 339 review 2).
    switch (status) {
      case 'auth_required':
        return l10n.providerUsageAuthRequired;
      case 'unavailable':
        return l10n.providerUsageUnavailable;
      case 'failed':
        return l10n.providerUsageFailed;
      default:
        return l10n.providerUsageUnavailable;
    }
  }
}
