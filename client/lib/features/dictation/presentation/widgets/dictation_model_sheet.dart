import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
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
    return showDialog<void>(
      context: context,
      builder: (_) => DictationModelSheet(
        device: device,
        isFirstUse: isFirstUse,
      ),
    );
  }

  @override
  State<DictationModelSheet> createState() => _DictationModelSheetState();
}

class _DictationModelSheetState extends State<DictationModelSheet> {
  String? _installingId;

  @override
  void initState() {
    super.initState();
    // Ask the daemon for the catalog as soon as the sheet opens.
    unawaited(context.read<DictationCubit>().refreshStatus(widget.device));
  }

  Future<void> _download(DictationCubit cubit, String modelId) async {
    setState(() => _installingId = modelId);
    await cubit.installModel(modelId, device: widget.device);
    if (mounted) setState(() => _installingId = null);
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
                  if (model.unavailableReason != null) ...[
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
                      child: Text(
                        '${l10n.dictationUnavailableTitle} · ${model.unavailableReason}',
                        style: bodyStyle,
                      ),
                    ),
                  ],
                  const SizedBox(height: 8),
                  for (final option in model.models)
                    _ModelTile(
                      option: option,
                      selected: option.id == model.selectedModelId,
                      isDownloading: _installingId == option.id,
                      progress: _installingId == option.id
                          ? model.downloadProgress
                          : null,
                      onDownload: () => _download(cubit, option.id),
                      onSelect: () => cubit.selectModel(
                        option.id,
                        device: widget.device,
                      ),
                    ),
                  if (model.models.isEmpty) ...[
                    const SizedBox(height: 12),
                    Text(l10n.dictationModelRequired, style: bodyStyle),
                  ],
                  const SizedBox(height: 12),
                  Text(
                    l10n.dictationPreviewPolicyTitle,
                    style: theme.textTheme.labelLarge,
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<DictationPreviewPolicy>(
                    key: const Key('dictation_preview_policy'),
                    segments: [
                      ButtonSegment(
                        value: DictationPreviewPolicy.live,
                        label: Text(l10n.dictationPreviewLive),
                      ),
                      ButtonSegment(
                        value: DictationPreviewPolicy.onStop,
                        label: Text(l10n.dictationPreviewOnStop),
                      ),
                    ],
                    selected: {state.previewPolicy},
                    onSelectionChanged: (selection) =>
                        cubit.setPreviewPolicy(selection.first),
                  ),
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
    required this.isDownloading,
    required this.progress,
    required this.onDownload,
    required this.onSelect,
  });

  final DictationModelOption option;
  final bool selected;
  final bool isDownloading;
  final double? progress;
  final VoidCallback onDownload;
  final VoidCallback onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final size = _formatBytes(option.totalBytes);

    Widget? action;
    if (isDownloading) {
      action = SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
          value: progress,
        ),
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
        onPressed: onDownload,
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
                            option.label,
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
                    if (option.note != null)
                      Text(
                        option.note!,
                        style: theme.textTheme.bodySmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                    if (size != null)
                      Text(
                        size,
                        style: theme.textTheme.labelSmall?.copyWith(
                          color: colorScheme.onSurfaceVariant,
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              if (action != null) action,
            ],
          ),
          if (isDownloading && progress != null) ...[
            const SizedBox(height: 6),
            ClipRRect(
              borderRadius: BorderRadius.circular(4),
              child: LinearProgressIndicator(
                key: const Key('dictation_download_progress'),
                value: progress,
                minHeight: 4,
              ),
            ),
          ],
        ],
      ),
    );
  }

  static String? _formatBytes(int? bytes) {
    if (bytes == null || bytes <= 0) return null;
    const mb = 1024 * 1024;
    final value = bytes / mb;
    return value >= 1024
        ? '${(value / 1024).toStringAsFixed(1)} GB'
        : '${value.toStringAsFixed(0)} MB';
  }
}
