import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/dictation/presentation/utils/dictation_insertion.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_model_sheet.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

/// Composer mic button: starts, stops, and cancels a daemon-side dictation
/// session, and owns the composer range the transcript is written into.
///
/// The parent gates this widget on `capabilities.supportsDictation`; a device
/// that cannot dictate must render a disabled explainer instead.
///
/// Ownership notes (reference parity, see `features/dictation/AGENTS.md`):
/// * the session belongs to one [scopeKey]; changing it cancels the live
///   session so no transcript crosses conversations,
/// * writes are deferred while an IME composition is live,
/// * the caret is never stolen from outside the dictation range,
/// * the pre-session composer value is captured so cancel is one undo step,
/// * the client mirrors the daemon's session cap and stops itself at it.
class DictationMicButton extends StatefulWidget {
  const DictationMicButton({
    super.key,
    required this.chatController,
    required this.device,
    this.scopeKey,
    this.focusNode,
    this.dimTextColor,
    this.sessionLimit = const Duration(minutes: 5),
  });

  final SlashCommandTextController chatController;
  final DeviceConfig? device;

  /// Identity of the composer/conversation this button belongs to.
  final Object? scopeKey;
  final FocusNode? focusNode;
  final Color? dimTextColor;
  final Duration sessionLimit;

  @override
  State<DictationMicButton> createState() => _DictationMicButtonState();
}

class _DictationMicButtonState extends State<DictationMicButton> {
  final DictationInsertion _insertion = DictationInsertion();
  String _appliedText = '';
  Timer? _ticker;
  Duration _elapsed = Duration.zero;
  String? _announcedCode;

  @override
  void initState() {
    super.initState();
    widget.chatController.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant DictationMicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatController != widget.chatController) {
      oldWidget.chatController.removeListener(_onControllerChanged);
      widget.chatController.addListener(_onControllerChanged);
      _resetLocalState();
    }
    if (oldWidget.scopeKey != widget.scopeKey) {
      // A different conversation owns the composer now: drop this session.
      _resetLocalState();
      final cubit = context.read<DictationCubit>();
      if (cubit.state.isActive) unawaited(cubit.cancel());
    }
  }

  @override
  void dispose() {
    widget.chatController.removeListener(_onControllerChanged);
    _ticker?.cancel();
    super.dispose();
  }

  void _resetLocalState() {
    _insertion.reset();
    _appliedText = '';
    _ticker?.cancel();
    _ticker = null;
    _elapsed = Duration.zero;
    _announcedCode = null;
  }

  /// Replays a write that was deferred while the IME composition was live.
  void _onControllerChanged() {
    if (_insertion.hasPending && !widget.chatController.value.composing.isValid) {
      _insertion.flushPending(widget.chatController);
    }
  }

  void _syncText(DictationState state) {
    final text = state.visibleText;
    if (text == _appliedText) return;
    if (text.isEmpty) {
      // Cancel/discard is one step: the whole session range leaves the
      // composer, and user edits outside it are untouched.
      _insertion.removeOwned(widget.chatController);
    } else {
      _insertion.apply(widget.chatController, text);
    }
    _appliedText = text;
  }

  void _startTicker() {
    _ticker?.cancel();
    _elapsed = Duration.zero;
    _ticker = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      setState(() => _elapsed += const Duration(seconds: 1));
      if (_elapsed >= widget.sessionLimit) {
        timer.cancel();
        unawaited(context.read<DictationCubit>().stopForLimit());
      }
    });
  }

  void _stopTicker() {
    _ticker?.cancel();
    _ticker = null;
    if (_elapsed != Duration.zero) setState(() => _elapsed = Duration.zero);
  }

  Future<void> _onPressed(DictationState state) async {
    final device = widget.device;
    if (device == null) return;
    final cubit = context.read<DictationCubit>();
    switch (state.status) {
      case DictationStatus.idle:
        _resetLocalState();
        await cubit.start(device);
        if (!mounted) return;
        if (cubit.state.sessionNeedsFirstUseSheet) {
          await DictationModelSheet.show(
            context,
            device: device,
            isFirstUse: true,
          );
          return;
        }
        if (cubit.state.isActive) _startTicker();
      case DictationStatus.listening:
        _stopTicker();
        await cubit.stop();
        if (!mounted) return;
        widget.focusNode?.requestFocus();
      case DictationStatus.preparing:
      case DictationStatus.finalizing:
        break;
    }
  }

  Future<void> _openSheet(DictationState state) async {
    final device = widget.device;
    if (device == null) return;
    if (state.isActive) {
      _stopTicker();
      await context.read<DictationCubit>().cancel();
      if (!mounted) return;
    }
    await DictationModelSheet.show(context, device: device);
  }

  void _announce(DictationState state) {
    final code = state.errorCode;
    if (code == null || code == _announcedCode) return;
    final l10n = AppLocalizations.of(context)!;
    final message = switch (code) {
      'no_speech' => l10n.dictationNoSpeechDetected,
      'session_limit' => l10n.dictationLimitReached,
      'microphone_denied' => l10n.dictationMicrophoneDenied,
      'dictation_busy' => l10n.dictationBusy,
      _ => null,
    };
    _announcedCode = code;
    if (message == null) return;
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 4)),
    );
  }

  String get _elapsedLabel {
    final minutes = _elapsed.inMinutes;
    final seconds = _elapsed.inSeconds.remainder(60);
    return '$minutes:${seconds.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return BlocConsumer<DictationCubit, DictationState>(
      listenWhen: (previous, current) =>
          previous.visibleText != current.visibleText ||
          previous.errorCode != current.errorCode ||
          previous.status != current.status,
      listener: (context, state) {
        _announce(state);
        _syncText(state);
        if (!state.isActive) _stopTicker();
        if (state.status == DictationStatus.listening) {
          widget.focusNode?.unfocus();
        }
        if (state.status == DictationStatus.idle) {
          final code = state.errorCode;
          if (code == null) widget.focusNode?.requestFocus();
        }
      },
      builder: (context, state) {
        final isActive = state.isActive;
        final isBusy =
            state.status == DictationStatus.preparing ||
            state.status == DictationStatus.finalizing;
        final color = isActive
            ? Theme.of(context).colorScheme.error
            : Theme.of(context).colorScheme.primary;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (isActive && _elapsed != Duration.zero) ...[
              Text(
                _elapsedLabel,
                key: const Key('dictation_elapsed'),
                style: Theme.of(context).textTheme.labelSmall?.copyWith(
                      color: Theme.of(context).colorScheme.error,
                      fontFeatures: const [FontFeature.tabularFigures()],
                    ),
              ),
              const SizedBox(width: 6),
            ],
            SizedBox(
              width: 32,
              height: 32,
              child: IconButton(
                key: const Key('dictation_mic_btn'),
                tooltip: isActive
                    ? '${l10n.dictationStopTooltip} · $_elapsedLabel'
                    : l10n.dictationStartTooltip,
                onPressed:
                    widget.device == null ? null : () => _onPressed(state),
                onLongPress:
                    widget.device == null ? null : () => _openSheet(state),
                style: IconButton.styleFrom(
                  backgroundColor: isActive
                      ? color.withValues(alpha: 0.12)
                      : Theme.of(context)
                          .colorScheme
                          .primary
                          .withValues(alpha: 0.08),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                  padding: EdgeInsets.zero,
                ),
                icon: isBusy
                    ? SizedBox(
                        width: 16,
                        height: 16,
                        child:
                            AppProgressIndicator(strokeWidth: 2, color: color),
                      )
                    : Icon(
                        isActive ? Symbols.stop_circle : Symbols.mic,
                        size: 18,
                        color: isActive ? color : (widget.dimTextColor ?? color),
                      ),
              ),
            ),
          ],
        );
      },
    );
  }
}
