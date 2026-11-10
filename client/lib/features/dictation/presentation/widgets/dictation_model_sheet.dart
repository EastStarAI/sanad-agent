import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/dictation/presentation/dictation_model_text.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Model picker and first-use consent for local dictation.
///
/// Same shape, typography, and button treatment as
/// `full_access_confirmation_dialog.dart`: one dialog, no new visual language.
/// It lists the daemon catalog, downloads on explicit confirmation, and exposes
/// the preview policy and the daemon-reported unavailable reason.
class DictationModelSheet extends StatefulWidget {
  const DictationModelSheet({
    super.key,
    required this.device,
    this.isFirstUse = false,
  });

  final DeviceConfig device;
  final bool isFirstUse;

  static Future<void> show(
    BuildContext context, {
    required DeviceConfig device,
    bool isFirstUse = false,
  }) {
    // The sheet is pushed on a new route, so carry the cubit explicitly instead
    // of relying on the composer's provider ancestry.
    final cubit = context.read<DictationCubit>();
    return showDialog<void>(
      context: context,
      builder: (_) => BlocProvider.value(
        value: cubit,
        child: DictationModelSheet(
          device: device,
          isFirstUse: isFirstUse,
        ),
      ),
    );
  }

  @override
  State<DictationModelSheet> createState() => _DictationModelSheetState();
}

class _DictationModelSheetState extends State<DictationModelSheet> {
  @override
  void initState() {
    super.initState();
    // Ask the daemon for the catalog as soon as the sheet opens.
    unawaited(context.read<DictationCubit>().refreshStatus(widget.device));
  }

  Future<void> _download(DictationCubit cubit, String modelId) {
    // The cubit owns the installing state, so the progress bar keeps rendering
    // until the daemon reports the model installed (no local flicker).
    return cubit.installModel(modelId, device: widget.device);
  }

  Future<void> _cancelDownload(DictationCubit cubit) =>
      cubit.cancelInstallModel(device: widget.device);

  /// Installed and custom rows first, then the daemon's own order.
  ///
  /// A user opens this sheet to either use what is already on disk or add
  /// something new; sorting installed rows to the top is the whole ordering rule,
  /// so no sections, search, or grouping is needed.
  static List<DictationModelOption> _ordered(List<DictationModelOption> models) {
    final ordered = [...models];
    final index = {for (var i = 0; i < ordered.length; i++) ordered[i].id: i};
    ordered.sort((a, b) {
      if (a.installed != b.installed) return a.installed ? -1 : 1;
      return index[a.id]!.compareTo(index[b.id]!);
    });
    return ordered;
  }

  /// The one action the current unsupported state deserves.
  ///
  /// The runtime is the only reason the user can fix from here; the download
  /// itself is already offered by the model tiles below.
  Widget _statusAction(
    DictationCubit cubit,
    AppLocalizations l10n,
    DictationModelStatus model,
  ) {
    // Readiness reason, not the platform verdict: a supported device that is
    // missing its native shim is exactly the case this action exists for.
    switch (model.readinessReason) {
      case 'native_runtime_preparing':
        return const Padding(
          padding: EdgeInsets.only(top: 8),
          child: SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        );
      case 'native_runtime_missing':
      case 'native_runtime_install_failed':
        // Both are retryable from here: a source checkout builds the shim, a
        // released Agent re-fetches the verified runtime. The daemon decides
        // which, and answers `prepare_unavailable` when it can do neither.
        return Align(
          alignment: AlignmentDirectional.centerEnd,
          child: TextButton(
            key: const Key('dictation_prepare_runtime'),
            onPressed: () => cubit.prepareRuntime(widget.device),
            child: Text(l10n.dictationPrepareNow),
          ),
        );
      default:
        return const SizedBox.shrink();
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final bodyStyle = theme.textTheme.bodyMedium?.copyWith(height: 1.4);

    return BlocBuilder<DictationCubit, DictationState>(
      builder: (context, state) {
        final cubit = context.read<DictationCubit>();
        final model = state.model;
        // An empty catalog has two very different causes. A refusal from the
        // transport boundary never reached the daemon, so the reason — not the
        // missing model — is what the user has to read; only an answer that
        // genuinely listed nothing is the install state.
        final channelReason = dictationChannelRefusalLabel(l10n, state.errorCode);
        return AlertDialog(
          key: const Key('dictation_model_sheet'),
          title: Text(l10n.dictationSheetTitle),
          content: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(l10n.dictationSheetIntro, style: bodyStyle),
                  if (model.blockedReason != null) ...[
                    const SizedBox(height: 12),
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: colorScheme.errorContainer.withValues(alpha: 0.25),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: colorScheme.error.withValues(alpha: 0.3),
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '${l10n.dictationUnavailableTitle} · '
                            '${dictationReasonLabel(l10n, model.blockedReason!)}',
                            key: const Key('dictation_blocked_reason'),
                            style: bodyStyle,
                          ),
                          _statusAction(cubit, l10n, model),
                        ],
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  for (final option in _ordered(model.models))
                    _ModelTile(
                      option: option,
                      selected: option.id == model.selectedModelId,
                      installing: model.installingModelId == option.id,
                      // Another model's download locks every other row: the
                      // daemon refuses a second writer, so offering the button
                      // would only produce a refusal.
                      installBusy: model.installingModelId != null &&
                          model.installingModelId != option.id,
                      progress: model.installingModelId == option.id
                          ? model.downloadProgress
                          : null,
                      eta: model.installingModelId == option.id
                          ? model.installEta
                          : null,
                      phase: model.installingModelId == option.id
                          ? model.installingPhase
                          : null,
                      onDownload: () => _download(cubit, option.id),
                      onCancel: () => _cancelDownload(cubit),
                      onSelect: () => cubit.selectModel(
                        option.id,
                        device: widget.device,
                      ),
                    ),
                  if (model.models.isEmpty) ...[
                    const SizedBox(height: 12),
                    if (channelReason != null)
                      Text(
                        channelReason,
                        key: const Key('dictation_sheet_channel_reason'),
                        style: bodyStyle?.copyWith(color: colorScheme.error),
                      )
                    else
                      Text(
                        l10n.dictationModelRequired,
                        key: const Key('dictation_sheet_model_required'),
                        style: bodyStyle,
                      ),
                  ],
                ],
              ),
            ),
          ),
          actions: [
            TextButton(
              key: const Key('dictation_sheet_close'),
              onPressed: () => Navigator.of(context).pop(),
              child: Text(l10n.close),
            ),
          ],
        );
      },
    );
  }
}

class _ModelTile extends StatelessWidget {
  const _ModelTile({
    required this.option,
    required this.selected,
    required this.installing,
    required this.installBusy,
    required this.progress,
    required this.eta,
    required this.phase,
    required this.onDownload,
    required this.onCancel,
    required this.onSelect,
  });

  final DictationModelOption option;
  final bool selected;

  /// This row's own install is running.
  final bool installing;

  /// Another row's install is running, so this one cannot start.
  final bool installBusy;
  final double? progress;

  /// Remaining time from the daemon's observed rate.
  final Duration? eta;

  /// `downloading`, `verifying`, or `activating`.
  final String? phase;
  final VoidCallback onDownload;
  final VoidCallback onCancel;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = _formatBytes(l10n, option.sizeBytes);
    final description = option.descriptionFor(Localizations.localeOf(context));
    final badge = dictationModelBadge(l10n, option.badge);

    Widget? action;
    if (installing) {
      action = Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(strokeWidth: 2, value: progress),
          ),
          const SizedBox(width: 6),
          Text(
            progress == null
                ? l10n.dictationDownloading
                : '${(progress! * 100).round()}%',
            key: const Key('dictation_download_percent'),
            style: theme.textTheme.labelSmall,
          ),
        ],
      );
    } else if (option.installed && !selected) {
      action = TextButton(
        key: Key('dictation_use_${option.id}'),
        onPressed: onSelect,
        child: Text(l10n.dictationUse),
      );
    } else if (!option.installed && option.hosted) {
      action = FilledButton(
        key: Key('dictation_download_${option.id}'),
        // The daemon installs one model at a time, so a second row's button is
        // disabled rather than answered with a refusal.
        onPressed: installBusy ? null : onDownload,
        child: Text(l10n.dictationDownload),
      );
    } else if (!option.installed) {
      action = Text(
        l10n.dictationNotHosted,
        style: theme.textTheme.labelSmall?.copyWith(
          color: colorScheme.onSurfaceVariant,
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            // The model's own name, or the localized identity
                            // of a row the daemon owns: never daemon copy.
                            dictationModelTitle(
                              l10n,
                              id: option.id,
                              name: option.name,
                              labelCode: option.labelCode,
                            ),
                            key: Key('dictation_model_name_${option.id}'),
                            style: theme.textTheme.bodyMedium?.copyWith(
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                        if (option.installed) ...[
                          const SizedBox(width: 6),
                          Icon(Icons.check_circle,
                              size: 14, color: colorScheme.primary),
                        ],
                        // Streaming is a fact about the model, not a note: a
                        // streaming model writes while you speak, a batch model
                        // lands the text when you stop.
                        if (option.isStreaming) ...[
                          const SizedBox(width: 6),
                          Tooltip(
                            message: l10n.dictationModeStreaming,
                            child: Icon(
                              Symbols.graphic_eq,
                              key: const Key('dictation_mode_streaming_badge'),
                              size: 14,
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                        if (selected) ...[
                          const SizedBox(width: 6),
                          Text(
                            l10n.dictationSelected,
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.primary,
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (badge != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 2),
                        child: _BadgeChip(
                          key: Key('dictation_badge_${option.id}'),
                          label: badge,
                          emphasized: option.badge == 'recommended',
                        ),
                      ),
                    if (description.isNotEmpty)
                      Text(
                        description,
                        key: Key('dictation_model_description_${option.id}'),
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    Row(
                      children: [
                        if (size != null)
                          Text(
                            size,
                            key: Key('dictation_model_size_${option.id}'),
                            style: theme.textTheme.labelSmall?.copyWith(
                              color: colorScheme.onSurfaceVariant,
                            ),
                          ),
                        if (option.speedTier != null) ...[
                          if (size != null) const SizedBox(width: 8),
                          _SpeedBars(
                            key: Key('dictation_speed_${option.id}'),
                            tier: option.speedTier!,
                          ),
                        ],
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (action != null) action,
            ],
          ),
          if (installing) ...[
            const SizedBox(height: 6),
            // Real progress only: an indeterminate line under a row that knows
            // its percentage reads as decoration, not as state.
            if (progress != null)
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: LinearProgressIndicator(
                  key: const Key('dictation_download_progress'),
                  value: progress,
                  minHeight: 4,
                ),
              ),
            Row(
              children: [
                Expanded(child: _installCaption(l10n, theme, size)),
                TextButton(
                  key: Key('dictation_cancel_download_${option.id}'),
                  onPressed: onCancel,
                  child: Text(l10n.dictationCancelDownload),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  /// What the running install is doing, and how long it may still take.
  ///
  /// The size stays visible while it downloads: it is the fact that makes a
  /// multi-minute wait on a slow link legible.
  Widget _installCaption(
    AppLocalizations l10n,
    ThemeData theme,
    String? size,
  ) {
    final style = theme.textTheme.labelSmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final phaseLabel = switch (phase) {
      'verifying' => l10n.dictationDownloadVerifying,
      'activating' => l10n.dictationDownloadFinishing,
      _ => null,
    };
    final etaLabel = switch (eta) {
      final Duration remaining? when remaining.inMinutes >= 1 =>
        l10n.dictationDownloadEtaMinutes('${remaining.inMinutes}'),
      final Duration remaining? =>
        l10n.dictationDownloadEtaSeconds('${remaining.inSeconds}'),
      _ => null,
    };
    final detail = phaseLabel ?? etaLabel;
    final parts = <String>[
      if (size != null) size,
      if (detail != null) detail,
    ];
    if (parts.isEmpty) return const SizedBox.shrink();
    return Text(
      parts.join(' · '),
      key: Key('dictation_download_eta_${option.id}'),
      style: style,
    );
  }

  static String? _formatBytes(AppLocalizations l10n, int? bytes) {
    if (bytes == null || bytes <= 0) return null;
    const mb = 1024 * 1024;
    final value = bytes / mb;
    // Formatted through the locale: the unit is universal, the digits are not.
    return value >= 1024
        ? l10n.dictationModelSizeGb((value / 1024).toStringAsFixed(1))
        : l10n.dictationModelSizeMb(value.toStringAsFixed(0));
  }
}

/// A closed-set badge code, rendered as one small chip.
class _BadgeChip extends StatelessWidget {
  const _BadgeChip({
    super.key,
    required this.label,
    required this.emphasized,
  });

  final String label;
  final bool emphasized;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final background = emphasized
        ? colorScheme.primaryContainer
        : colorScheme.surfaceContainerHighest;
    final foreground = emphasized
        ? colorScheme.onPrimaryContainer
        : colorScheme.onSurfaceVariant;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: theme.textTheme.labelSmall?.copyWith(color: foreground),
      ),
    );
  }
}

/// Relative decoding speed as four bars, filled up to [tier].
///
/// It is a ranking the catalog declares, not a measurement, so it is drawn as
/// bars with a localized semantic label instead of a number.
class _SpeedBars extends StatelessWidget {
  const _SpeedBars({super.key, required this.tier});

  final int tier;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final colorScheme = Theme.of(context).colorScheme;
    final clamped = tier.clamp(1, 4);
    return Semantics(
      label: l10n.dictationSpeedSemantics(clamped),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var bar = 1; bar <= 4; bar++)
            Container(
              width: 3,
              height: 3.0 + bar * 2,
              margin: const EdgeInsetsDirectional.only(end: 2),
              decoration: BoxDecoration(
                color: bar <= clamped
                    ? colorScheme.primary
                    : colorScheme.outlineVariant,
                borderRadius: BorderRadius.circular(1),
              ),
            ),
        ],
      ),
    );
  }
}
