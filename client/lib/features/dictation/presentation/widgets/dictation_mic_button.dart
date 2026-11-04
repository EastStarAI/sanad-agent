import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/dictation/presentation/utils/dictation_insertion.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_model_sheet.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Composer mic button: starts, stops, and cancels a daemon-side dictation
/// session, and owns the composer range the transcript is written into.
///
/// The parent gates this widget on `capabilities.supportsDictation`; a device
/// that cannot dictate must render a disabled explainer instead.
class DictationMicButton extends StatefulWidget {
  const DictationMicButton({
    super.key,
    required this.chatController,
    required this.device,
    this.dimTextColor,
  });

  final SlashCommandTextController chatController;
  final DeviceConfig? device;
  final Color? dimTextColor;

  @override
  State<DictationMicButton> createState() => _DictationMicButtonState();
}

class _DictationMicButtonState extends State<DictationMicButton> {
  final DictationInsertion _insertion = DictationInsertion();
  String _appliedText = '';

  void _syncText(DictationState state) {
    final text = state.visibleText;
    if (text == _appliedText) return;
    if (text.isEmpty) {
      _insertion.removeOwned(widget.chatController);
    } else {
      _insertion.apply(widget.chatController, text);
    }
    _appliedText = text;
  }

  Future<void> _onPressed(DictationState state) async {
    final device = widget.device;
    if (device == null) return;
    final cubit = context.read<DictationCubit>();
    switch (state.status) {
      case DictationStatus.idle:
        _insertion.reset();
        _appliedText = '';
        await cubit.start(device);
        if (!mounted) return;
        if (cubit.state.sessionNeedsFirstUseSheet) {
          await DictationModelSheet.show(
            context,
            device: device,
            isFirstUse: true,
          );
        }
      case DictationStatus.listening:
        await cubit.stop();
      case DictationStatus.preparing:
      case DictationStatus.finalizing:
        break;
    }
  }

  Future<void> _openSheet(DictationState state) async {
    final device = widget.device;
    if (device == null) return;
    if (state.isActive) {
      await context.read<DictationCubit>().cancel();
      if (!mounted) return;
    }
    await DictationModelSheet.show(context, device: device);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return BlocConsumer<DictationCubit, DictationState>(
      listenWhen: (previous, current) =>
          previous.visibleText != current.visibleText,
      listener: (context, state) => _syncText(state),
      builder: (context, state) {
        final isActive = state.isActive;
        final isBusy =
            state.status == DictationStatus.preparing ||
            state.status == DictationStatus.finalizing;
        final color = isActive
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary;
        return SizedBox(
          width: 32,
          height: 32,
          child: IconButton(
            key: const Key('dictation_mic_btn'),
            tooltip: isActive
                ? l10n.dictationStopTooltip
                : l10n.dictationStartTooltip,
            onPressed: widget.device == null ? null : () => _onPressed(state),
            onLongPress:
                widget.device == null ? null : () => _openSheet(state),
            style: IconButton.styleFrom(
              backgroundColor: isActive
                  ? color.withValues(alpha: 0.12)
                  : Theme.of(context).colorScheme.primary.withValues(alpha: 0.08),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: EdgeInsets.zero,
            ),
            icon: isBusy
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: AppProgressIndicator(strokeWidth: 2, color: color),
                  )
                : Icon(
                    isActive ? Symbols.stop_circle : Symbols.mic,
                    size: 18,
                    color: isActive ? color : (widget.dimTextColor ?? color),
                  ),
          ),
        );
      },
    );
  }
}
