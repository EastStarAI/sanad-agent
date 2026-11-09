import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:material_symbols_icons/symbols.dart';
import 'package:sanad_client/core/presentation/widgets/app_progress_indicator.dart';
import 'package:sanad_client/core/presentation/widgets/stop_action_button.dart';
import 'package:sanad_client/features/conversations/domain/models/message_delivery_intent.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_cubit.dart';
import 'package:sanad_client/features/voice/presentation/bloc/voice_stream_state.dart';
import 'package:sanad_client/l10n/app_localizations.dart';

import 'composer_helpers.dart';

/// Trail action: stop, acceptance, voice, or send, in that precedence.
class ComposerSendStopButton extends StatelessWidget {
  final ConversationInputAgentSlice agentSlice;
  final ConversationInputSlice inputSlice;
  final Capability capabilities;
  final SlashCommandTextController chatController;
  final void Function({MessageDeliveryIntent intent}) onSendAttempt;
  final VoidCallback? onStop;
  final Color dimTextColor;

  const ComposerSendStopButton({
    required this.agentSlice,
    required this.inputSlice,
    required this.capabilities,
    required this.chatController,
    required this.onSendAttempt,
    required this.onStop,
    required this.dimTextColor,
  });

  /// Sends the draft, but never an empty one.
  ///
  /// While dictation is running the button is enabled on purpose — the user may
  /// want to finish speaking and send in one press. The session is stopped and
  /// the button waits for the transcript before dispatching; a session that
  /// recognised nothing (or failed, or timed out) sends nothing at all instead
  /// of an empty message.
  ///
  /// The wait resumes on this widget's own `context`, which is why the composer
  /// keeps the trailing control in one stable slot: the row used to move Send
  /// between branches when the session left `listening`, so this continuation
  /// ran on an unmounted element and returned without dispatching.
  Future<void> _send(
    BuildContext context, {
    required bool isDictating,
  }) async {
    final dictation = readDictationCubit(context);
    if (isDictating && dictation != null) {
      final settled = await dictation.sendWhenSettled();
      if (!context.mounted) return;
      if (!settled) return;
      // The transcript is inserted from a state listener, so give that frame a
      // chance to land before reading the controller.
      await WidgetsBinding.instance.endOfFrame;
      if (!context.mounted) return;
      if (chatController.exportPlainText().trim().isEmpty) return;
      onSendAttempt(intent: MessageDeliveryIntent.auto);
      return;
    }
    if (chatController.exportPlainText().trim().isEmpty) return;
    onSendAttempt(intent: MessageDeliveryIntent.auto);
  }

  @override
  Widget build(BuildContext context) {
    final isEmpty = chatController.exportPlainText().trim().isEmpty;

    final hasWorkspace = !inputSlice.requiresWorkspace || inputSlice.selectedWorkspace != null;
    final inputCubit = maybeInputCubit(context);
    final attachments = inputCubit == null
        ? const <DraftAttachment>[]
        : context.watch<ConversationInputCubit>().state.draftAttachments;
    final attachmentsReady = attachments.every(
      (attachment) => attachment.status == DraftAttachmentStatus.ready,
    );
    final hasContent = !isEmpty || attachments.isNotEmpty;
    final dictation = maybeDictationCubit(context);
    final dictating = dictation?.state.isActive ?? false;
    final awaitingTranscript = dictation?.state.awaitingSend ?? false;
    final canSend =
        !awaitingTranscript &&
        agentSlice.isOnline &&
        (hasContent || dictating) &&
        attachmentsReady &&
        hasWorkspace &&
        inputSlice.pendingSuspendedRequest == null;

    final executionSnapshot = inputSlice.executionSnapshot;
    final isStopping = executionSnapshot?.isStopping ?? false;
    // A running dictation owns the trailing control: while the user speaks, the
    // Stop the row would otherwise show is the turn's, and pressing it beside
    // the mic's own Stop is two controls for one gesture. The session's Send
    // replaces it, and the turn Stop comes back the moment the composer is empty
    // again — the same rule typed text already follows.
    final showStopButton =
        !dictating &&
        !awaitingTranscript &&
        capabilities.supportsStop &&
        (executionSnapshot?.canStop == true || isStopping) &&
        isEmpty;

    final showVoiceButton =
        capabilities.supportsVoiceCall &&
        agentSlice.hasActiveAgent &&
        agentSlice.isOnline &&
        isEmpty &&
        executionSnapshot?.hasActiveWork != true;

    // The waiting control comes first: while the transcript is decoding, the
    // composer is still empty, so a turn Stop evaluated before this branch would
    // take the slot the send wait is holding.
    if (awaitingTranscript) {
      // The transcript is being decoded. A spinner that also stops: pressing it
      // abandons the automatic send while keeping whatever text arrives.
      return SizedBox(
        width: 32,
        height: 32,
        child: Tooltip(
          message: AppLocalizations.of(context)?.dictationAwaitingTranscriptTooltip ??
              'Press to stop',
          child: Material(
            color: Theme.of(context).colorScheme.onSurface,
            borderRadius: BorderRadius.circular(8),
            child: InkWell(
              key: const Key('send_message_waiting_dictation'),
              borderRadius: BorderRadius.circular(8),
              onTap: () => readDictationCubit(context)?.cancelPendingSend(),
              child: const Center(
                child: SizedBox(
                  width: 16,
                  height: 16,
                  child: AppProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.black,
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    }

    if (showStopButton) {
      // One design, one owner: the stop that ends a reply is the same widget the
      // dictation button becomes while listening.
      return StopActionButton(
        buttonKey: const Key('stop_message_btn'),
        tooltip: isStopping
            ? AppLocalizations.of(context)?.composerStoppingTooltip ??
                'Stopping response'
            : AppLocalizations.of(context)?.composerStopTooltip ??
                'Stop response',
        onPressed: isStopping ? null : onStop,
        busy: isStopping,
        progressIndicatorKey: const Key('stop_message_progress_indicator'),
      );
    }

    if (inputSlice.isAwaitingMessageAcceptance) {
      return SizedBox(
        width: 32,
        height: 32,
        child: IconButton(
          key: const Key('send_message_acceptance_indicator'),
          tooltip: 'Waiting for message acceptance',
          onPressed: null,
          style: IconButton.styleFrom(
            backgroundColor: Theme.of(context).colorScheme.onSurface,
            disabledBackgroundColor: Theme.of(context).colorScheme.onSurface,
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            padding: EdgeInsets.zero,
          ),
          icon: const SizedBox(
            width: 16,
            height: 16,
            child: AppProgressIndicator(
              strokeWidth: 2,
              color: Colors.black,
            ),
          ),
        ),
      );
    }

    if (showVoiceButton) {
      return SizedBox(
        width: 32,
        height: 32,
        child: BlocBuilder<VoiceStreamCubit, VoiceStreamState>(
          builder: (context, voiceState) {
            final isActive = voiceState.isSessionActive;
            final isConnecting = voiceState.status == VoiceSessionStatus.connecting;
            return IconButton(
              key: const Key('voice_chat_btn'),
              tooltip: isActive ? 'Stop voice session' : 'Start voice session',
              onPressed: () async {
                final voiceCubit = context.read<VoiceStreamCubit>();
                if (isActive) {
                  await voiceCubit.stopVoiceSession();
                } else {
                  final activeAgent = agentSlice.activeAgent;
                  if (activeAgent != null) {
                    // No session id from here: the cubit mints the one identity
                    // the whole voice session is claimed and routed by.
                    await voiceCubit.startVoiceSession(agent: activeAgent);
                  }
                }
              },
              style: IconButton.styleFrom(
                backgroundColor: isActive
                    ? (isConnecting ? Colors.orange.withValues(alpha: 0.1) : Colors.red.withValues(alpha: 0.1))
                    : Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
                padding: EdgeInsets.zero,
              ),
              icon: Icon(
                isConnecting ? Icons.hourglass_empty : Symbols.earthquake,
                size: 16,
                color: isActive ? (isConnecting ? Colors.orange : Colors.red) : Theme.of(context).colorScheme.primary,
              ),
            );
          },
        ),
      );
    }

    return SizedBox(
      width: 32,
      height: 32,
      child: IconButton(
        key: const Key('send_message_btn'),
        tooltip: executionSnapshot?.isExecuting == true
            ? AppLocalizations.of(context)?.composerSendSteerTooltip ??
                'Press Enter to steer • Ctrl/Cmd+Enter to queue'
            : AppLocalizations.of(context)?.composerSendTooltip ??
                'Send message',
        onPressed: canSend
            ? () => _send(context, isDictating: dictating)
            : null,
        style: IconButton.styleFrom(
          backgroundColor: canSend ? Theme.of(context).colorScheme.onSurface : dimTextColor.withValues(alpha: 0.1),
          disabledBackgroundColor: dimTextColor.withValues(alpha: 0.1),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
          padding: EdgeInsets.zero,
        ),
        icon: Icon(
          Icons.arrow_upward_rounded,
          size: 16,
          color: canSend ? Theme.of(context).colorScheme.surface : dimTextColor.withValues(alpha: 0.3),
        ),
      ),
    );
  }
}

