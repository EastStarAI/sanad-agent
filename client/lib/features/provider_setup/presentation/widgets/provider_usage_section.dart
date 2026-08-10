import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:intl/intl.dart';
import 'package:sanad_client/features/devices/data/device_inventory_source.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_cubit.dart';
import 'package:sanad_client/features/provider_setup/presentation/bloc/provider_usage_state.dart';

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

  const ProviderUsageSection({
    super.key,
    required this.agent,
    required this.instanceId,
  });

  String get _deviceId => agent?.id ?? DeviceInventoryIds.localDevice;

  String _updatedLabel(DateTime at) {
    final local = at.toLocal();
    final delta = DateTime.now().difference(local);
    if (delta.inSeconds < 30) return 'just now';
    if (delta.inMinutes < 1) return '${delta.inSeconds}s ago';
    if (delta.inHours < 1) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    return DateFormat('EEE, MMM d, HH:mm').format(local);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return BlocBuilder<ProviderUsageCubit, ProviderUsageState>(
      buildWhen: (prev, next) {
        final a = prev.entry(_deviceId, instanceId);
        final b = next.entry(_deviceId, instanceId);
        return a != b;
      },
      builder: (context, state) {
        final entry = state.entry(_deviceId, instanceId);

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
                      'Usage & limits',
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: theme.colorScheme.onSurface.withValues(alpha: 0.85),
                      ),
                    ),
                    const Spacer(),
                    if (entry.result != null) ...[
                      Text(
                        entry.fetchedAt == null ? 'Updated just now' : 'Updated ${_updatedLabel(entry.fetchedAt!)}',
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
                                child: CircularProgressIndicator(strokeWidth: 1.5),
                              )
                            : const Icon(Icons.refresh, size: 12),
                        label: const Text('Refresh'),
                        style: TextButton.styleFrom(
                          visualDensity: VisualDensity.compact,
                          padding: const EdgeInsets.symmetric(horizontal: 6),
                          textStyle: const TextStyle(fontSize: 11),
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
                            child: CircularProgressIndicator(strokeWidth: 2),
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

  const _UsageBody({
    required this.cubit,
    required this.agent,
    required this.instanceId,
    required this.entry,
    required this.isStaleRefreshing,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    // Loading phase with no prior snapshot: small inline indicator only.
    if (entry.phase == ProviderUsagePhase.loading || entry.result == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 12),
        child: Center(
          child: Column(
            children: [
              SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              SizedBox(height: 8),
              Text(
                'Loading usage…',
                style: TextStyle(fontSize: 12),
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
        result: entry.attentionResult ?? result,
        isStaleRefreshing: isStaleRefreshing,
        hasStaleSnapshot: entry.hasVisibleSnapshot,
        staleSnapshot: entry.hasVisibleSnapshot ? result.snapshot : null,
        onRetry: () => cubit.refresh(instanceId: instanceId, agent: agent),
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
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                const SizedBox(width: 6),
                Text(
                  'Refreshing…',
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
            'Plan: ${snapshot.planName}',
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
                    '${_formatPercent(used)}% used',
                    style: TextStyle(
                      fontSize: 11,
                      color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                    ),
                  ),
                if (remaining != null) ...[
                  const SizedBox(width: 8),
                  Text(
                    '${_formatPercent(remaining)}% remaining',
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
                'Resets ${_formatLocalRelative(window.resetAt!)}',
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

  String _formatLocalRelative(DateTime resetAt) {
    final local = resetAt.toLocal();
    final now = DateTime.now();
    final delta = local.difference(now);
    if (delta.isNegative) return 'any moment';
    if (delta.inMinutes < 1) return 'in a moment';
    if (delta.inHours < 1) return 'in ${delta.inMinutes} min';
    if (delta.inHours < 24) return 'in ${delta.inHours} h';
    if (delta.inDays <= 6) return 'in ${delta.inDays} d';
    return "on ${DateFormat('EEE, MMM d, HH:mm').format(local)}";
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
                '$count reset${count == 1 ? '' : 's'} available',
                style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
              ),
            ),
            TextButton.icon(
              onPressed: entry.resetInProgress ? null : () => _start(context),
              icon: entry.resetInProgress
                  ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.restart_alt, size: 14),
              label: const Text('Reset limits'),
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
          title: const Text('Reset usage limits?'),
          content: const Text('This will use one reset credit for this account.'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Reset limits')),
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
        title: const Text('Reset before limits are exhausted?'),
        content: Text('${result.message} A reset restores the full allowance and cannot be undone.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(dialogContext, true), child: const Text('Reset anyway')),
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
  final ProviderUsageResultDto result;
  final bool isStaleRefreshing;
  final bool hasStaleSnapshot;
  final ProviderUsageSnapshotDto? staleSnapshot;
  final VoidCallback onRetry;

  const _AttentionBody({
    required this.result,
    required this.isStaleRefreshing,
    required this.hasStaleSnapshot,
    required this.staleSnapshot,
    required this.onRetry,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final message = _messageFor(result.status, result.message);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (hasStaleSnapshot && staleSnapshot != null) ...[
          for (final window in staleSnapshot!.windows)
            Padding(
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
              result.status == 'auth_required' ? Icons.lock_outline : Icons.error_outline,
              size: 16,
              color: result.status == 'auth_required' ? Colors.amber[700] : theme.colorScheme.error,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                message,
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
            onPressed: isStaleRefreshing ? null : onRetry,
            icon: const Icon(Icons.refresh, size: 14),
            label: Text(
              result.status == 'auth_required' ? 'Reconnect' : 'Retry',
            ),
          ),
        ),
      ],
    );
  }

  String _messageFor(String status, String? message) {
    switch (status) {
      case 'auth_required':
        return 'Account sign-in is required to view usage limits.';
      case 'unavailable':
        return message ?? 'Usage information is temporarily unavailable. Please retry.';
      case 'failed':
        return message ?? 'Usage information could not be loaded. Please try again.';
      default:
        return message ?? 'Usage information is temporarily unavailable.';
    }
  }
}
