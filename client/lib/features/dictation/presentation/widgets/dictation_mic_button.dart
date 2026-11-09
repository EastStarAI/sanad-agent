import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:logging/logging.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/devices/domain/models/device_config.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_cubit.dart';
import 'package:sanad_client/features/dictation/presentation/bloc/dictation_state.dart';
import 'package:sanad_client/features/dictation/presentation/utils/dictation_insertion.dart';
import 'package:sanad_client/features/dictation/presentation/widgets/dictation_model_sheet.dart';
import 'package:sanad_client/l10n/app_localizations.dart';
import 'package:sanad_client/utils/toast_utils.dart';

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
  static final _logger = Logger('DictationMicButton');

  /// The composer range this session writes into, shared with whichever button
  /// `State` replaces this one when the row swaps the meter in or out.
  late DictationInsertion _insertion;
  String? _announcedCode;

  @override
  void initState() {
    super.initState();
    _insertion = DictationInsertion.of(widget.chatController);
    widget.chatController.addListener(_onControllerChanged);
  }

  @override
  void didUpdateWidget(covariant DictationMicButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.chatController != widget.chatController) {
      oldWidget.chatController.removeListener(_onControllerChanged);
      widget.chatController.addListener(_onControllerChanged);
      // A range recorded against another editor says nothing about this one.
      _insertion = DictationInsertion.of(widget.chatController);
    }
    if (oldWidget.scopeKey != widget.scopeKey) {
      // A different conversation owns the composer now: drop this session. The
      // range stays in the composer's record, so the cancel below still removes
      // this session's text instead of leaving it in the new conversation.
      _forgetAnnouncement();
      final cubit = context.read<DictationCubit>();
      if (cubit.state.isActive) unawaited(cubit.cancel());
    }
  }

  @override
  void dispose() {
    widget.chatController.removeListener(_onControllerChanged);
    super.dispose();
  }

  /// Forgets this widget's own watch on the last refusal.
  ///
  /// It never touches the composer range: that record belongs to the composer
  /// and is released by the next session's `begin`, not by a rebuild.
  void _forgetAnnouncement() => _announcedCode = null;

  /// Replays a write that was deferred while the IME composition was live.
  void _onControllerChanged() {
    if (_insertion.hasPending && !widget.chatController.value.composing.isValid) {
      _insertion.flushPending(widget.chatController);
    }
  }

  /// One first-use sheet per session-ending refusal, not one per rebuild.
  bool _firstUseSheetShown = false;

  void _syncText(DictationState state) {
    final text = state.visibleText;
    // What this session already wrote into the composer. It lives with the
    // composer (see `DictationInsertion.of`), so it is still here when the row
    // rebuilt the button between the partial and the final.
    final previous = _insertion.ownedText;
    if (text == previous) return;
    if (text.isEmpty) {
      // Cancel/discard is one step: the whole session range leaves the
      // composer, and user edits outside it are untouched.
      _insertion.removeOwned(widget.chatController);
    } else {
      // `previous` is what this session already wrote: if the range was lost,
      // the new text replaces it instead of being appended to it.
      _insertion.apply(
        widget.chatController,
        text,
        previous: previous,
      );
    }
  }

  /// Ends the session in the composer: cancelled text is removed, while a
  /// finished one stays as ordinary user text.
  ///
  /// The range itself is deliberately **not** released here. A stop that lands
  /// after the audio ended leaves the client waiting for a final the daemon only
  /// delivers when it drains, and the row has rebuilt this button by then; that
  /// write has to replace the span this session owns instead of taking the
  /// first-write branch beside it. Only the next session's `begin` releases the
  /// range, so finished text is never rewritten by the following session.
  void _settle(DictationState state) {
    if (state.discardText) {
      _insertion.removeOwned(widget.chatController);
    }
  }

  Future<void> _onPressed(DictationState state) async {
    final device = widget.device;
    if (device == null) return;
    final cubit = context.read<DictationCubit>();
    switch (state.status) {
      case DictationStatus.idle:
        _forgetAnnouncement();
        // One press starts recording when a model is ready; the sheet only
        // appears when there is nothing to record with (or on long press).
        if (cubit.state.model.models.isEmpty || !cubit.state.model.isReady) {
          // Re-read the catalog whenever this press could not start: the daemon
          // may have installed a model, gained a `stt.model_path` override, or
          // restarted since the composer last asked.
          await cubit.refreshStatus(device);
          if (!mounted) return;
        }
        final ready = cubit.state.model.isReady &&
            cubit.state.model.blockedReason == null;
        _logger.info(
          'dictation press: ready=$ready '
          'selected=${cubit.state.model.selectedModelId} '
          'models=${cubit.state.model.models.length} '
          'reason=${cubit.state.model.blockedReason}',
        );
        if (!ready) {
          await DictationModelSheet.show(context, device: device);
          return;
        }
        // Pin the insertion to the caret the user had when they pressed.
        _insertion.begin(widget.chatController);
        await cubit.start(device);
      case DictationStatus.listening:
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
      'native_runtime_preparing' => l10n.dictationRuntimePreparing,
      'native_runtime_missing' => l10n.dictationRuntimeMissing,
      'unsupported_platform' => l10n.dictationUnsupportedPlatform,
      // A hosted device can refuse a session for reasons the local channel
      // never produces; each one gets its own sentence instead of a generic
      // failure notice.
      'relay_unavailable' => l10n.dictationRelayUnavailable,
      'relay_invalid_request' => l10n.dictationRelayInvalidRequest,
      'dictation_disabled' => l10n.dictationDisabled,
      'update_required' => l10n.dictationUpdateRequired,
      'invalid_session_identity' => l10n.dictationFailedGeneric,
      'remote_only_platform' => l10n.dictationUnsupportedPlatform,
      'dictation_unavailable' => l10n.dictationUnavailable,
      // A session refused for a missing model is the first-use state, not a
      // failure: the same sheet the readiness path opens is offered right here.
      'model_not_installed' => l10n.dictationModelNotInstalled,
      'sherpa_runtime_missing' => l10n.dictationSherpaRuntimeMissing,
      'audio_gap' => l10n.dictationFailedGeneric,
      'prepare_unavailable' => l10n.dictationFailedGeneric,
      // Unknown refusals are still a refusal: one localized generic notice, never
      // the raw daemon code. Lifecycle/preparing/ready states stay inline.
      _ => l10n.dictationFailedGeneric,
    };
    _announcedCode = code;
    _logger.info('dictation announce code=$code');
    // A notice, not a blocking bar: the toast surface is the app-wide feedback
    // owner, so dictation never pushes a SnackBar over the composer.
    ToastUtils.showInfo(context, message);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return BlocConsumer<DictationCubit, DictationState>(
      listenWhen: (previous, current) =>
          previous.visibleText != current.visibleText ||
          previous.errorCode != current.errorCode ||
          previous.status != current.status ||
          previous.sessionNeedsFirstUseSheet != current.sessionNeedsFirstUseSheet,
      listener: (context, state) {
        // A new session can hit the same condition again (say, two silent
        // attempts in a row), so the announced code only guards one session.
        if (state.status == DictationStatus.preparing || state.status == DictationStatus.listening) {
          _announcedCode = null;
          _firstUseSheetShown = false;
        }
        _announce(state);
        // A session that ended because no model was installed (a model removed
        // mid-session, or a readiness change between status and start) ends in
        // the install sheet instead of a dead end. This is the one consumer of
        // the cubit's first-use flag; the ordinary path opens the sheet before
        // the session ever starts.
        if (state.sessionNeedsFirstUseSheet && !_firstUseSheetShown) {
          _firstUseSheetShown = true;
          unawaited(_openSheet(state));
        }
        if (state.status == DictationStatus.idle) {
          // The session is over: cancelled text leaves, finished text stays.
          _settle(state);
        } else {
          // Includes the final the daemon delivers after Stop: the row has
          // already given the meter back, so this write has to replace the span
          // the session owns instead of starting a new one beside it.
          _syncText(state);
        }
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
        final isBusy = state.status == DictationStatus.preparing || state.status == DictationStatus.finalizing;
        final notReady =
            !state.model.isReady || state.model.blockedReason != null;
        final heldByPeer = !isActive && state.model.busy;
        final color = isActive
            ? Theme.of(context).colorScheme.error
            : notReady
            ? Theme.of(context).colorScheme.onSurfaceVariant
            : Theme.of(context).colorScheme.primary;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            SizedBox(
              // Same footprint as the send button; the composer row keeps one
              // rhythm and the icon stays 20 px inside it.
              width: 32,
              height: 32,
              child: Tooltip(
                // Two lines on purpose: the actions differ, and one long line
                // reads as a sentence the user has to parse instead of a hint.
                message: isBusy
                    ? l10n.dictationPreparingTooltip
                    : isActive
                    ? l10n.dictationStopTooltip
                    : heldByPeer
                    ? l10n.dictationBusy
                    : notReady
                    ? l10n.dictationNotReadyTooltip
                    : l10n.dictationStartTooltip,
                textAlign: TextAlign.center,
                child: IconButton(
                  key: const Key('dictation_mic_btn'),
                  onPressed: widget.device == null ? null : () => _onPressed(state),
                  onLongPress: widget.device == null ? null : () => _openSheet(state),
                  style: IconButton.styleFrom(
                    backgroundColor: isActive
                        ? color.withValues(alpha: 0.12)
                        : color.withValues(alpha: 0.08),
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
                      : state.status == DictationStatus.listening
                      // The button is the session control, not the meter: the
                      // meter lives in the composer row while audio is captured,
                      // so the button stays a plain, obvious Stop. Its tooltip is
                      // the only label — the control carries no visible text.
                      ? Icon(Symbols.stop, size: 20, color: color)
                      : Icon(
                          Symbols.mic,
                          size: 18,
                          color: widget.dimTextColor ?? color,
                        ),
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

