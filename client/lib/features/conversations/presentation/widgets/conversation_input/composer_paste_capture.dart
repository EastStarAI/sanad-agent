import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_cubit.dart';
import 'package:sanad_client/features/conversations/presentation/bloc/conversation_input_state.dart';
import 'package:sanad_client/features/conversations/presentation/controllers/slash_command_text_controller.dart';
import 'package:sanad_client/features/conversations/presentation/utils/composer_input_router.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/conversation_input/conversation_input_slices.dart';
import 'package:sanad_client/features/devices/domain/models/capability.dart';
import 'package:super_clipboard/super_clipboard.dart';

import 'composer_helpers.dart';

class ComposerPasteIntent extends Intent {
  const ComposerPasteIntent();
}

/// Routes Cmd/Ctrl+V to the composer paste pipeline only while the message
/// field owns focus. When it does not, the action is disabled so the shortcut
/// falls through to the focused field's own paste behavior.
class _ComposerPasteAction extends Action<ComposerPasteIntent> {
  _ComposerPasteAction({required this.isComposerFocused, required this.onPaste});

  final bool Function() isComposerFocused;
  final VoidCallback onPaste;

  @override
  bool isEnabled(ComposerPasteIntent intent) => isComposerFocused();

  @override
  Object? invoke(ComposerPasteIntent intent) {
    onPaste();
    return null;
  }
}

/// Wraps the composer so Cmd/Ctrl+V runs the attachment-aware paste pipeline.
class ComposerPasteCapture extends StatefulWidget {
  const ComposerPasteCapture({
    this.sessionId,
    required this.chatController,
    required this.chatFocusNode,
    required this.agentSlice,
    required this.capabilities,
    required this.child,
    this.readClipboard,
  });

  final SlashCommandTextController chatController;
  final FocusNode chatFocusNode;
  final ConversationInputAgentSlice agentSlice;
  final Capability capabilities;
  final Widget child;
  final Future<ClipboardReader?> Function()? readClipboard;

  /// The conversation this composer shows; a paste completes into its draft.
  final String? sessionId;

  @override
  State<ComposerPasteCapture> createState() => _ComposerPasteCaptureState();
}

class _ComposerPasteCaptureState extends State<ComposerPasteCapture> {
  static const List<FileFormat> _supportedImageFormats = [
    Formats.png,
    Formats.jpeg,
    Formats.webp,
    Formats.gif,
    Formats.tiff,
    Formats.bmp,
    Formats.heic,
    Formats.heif,
    Formats.svg,
    Formats.ico,
  ];

  static String _extensionForFormat(FileFormat format) {
    if (format == Formats.png) return 'png';
    if (format == Formats.jpeg) return 'jpg';
    if (format == Formats.webp) return 'webp';
    if (format == Formats.gif) return 'gif';
    if (format == Formats.tiff) return 'tiff';
    if (format == Formats.bmp) return 'bmp';
    if (format == Formats.heic) return 'heic';
    if (format == Formats.heif) return 'heif';
    if (format == Formats.svg) return 'svg';
    if (format == Formats.ico) return 'ico';
    return 'png';
  }

  Future<void> _handlePaste(BuildContext context) async {
    // Bind the paste to the conversation shown now: clipboard reads are async
    // and the composer may rebind before every file is routed.
    final draftScope = ConversationInputCubit.draftScopeKey(
      deviceId: widget.agentSlice.activeAgent?.id,
      sessionId: widget.sessionId,
    );
    final readerFuture = widget.readClipboard?.call() ?? SystemClipboard.instance?.read();

    if (readerFuture == null) {
      _fallbackTextPaste();
      return;
    }

    try {
      final reader = await readerFuture;
      if (reader == null || !mounted) {
        _fallbackTextPaste();
        return;
      }

      final hasFileOrImage = reader.items.any(
        (item) => item.canProvide(Formats.fileUri) || _supportedImageFormats.any(item.canProvide),
      );

      if (!hasFileOrImage) {
        _fallbackTextPaste();
        return;
      }

      final items = <ComposerRoutableItem>[];
      final seenPaths = <String>{};
      var unreadable = 0;

      // Each clipboard item is read on its own: one unreadable item is
      // reported and never discards the other pasted files.
      for (final item in reader.items) {
        try {
          final routable = await _readClipboardItem(item, seenPaths);
          if (routable != null) items.add(routable);
        } catch (_) {
          unreadable++;
        }
      }

      if (items.isEmpty && unreadable > 0) {
        maybeInputCubit(context)?.setAttachmentError(const DraftAttachmentError(DraftAttachmentErrorKind.readFailed));
        return;
      }
      if (items.isEmpty) {
        _fallbackTextPaste();
        return;
      }

      final cubit = maybeInputCubit(context);
      if (cubit != null) {
        await ComposerInputRouter.routeItems(
          items: items,
          controller: widget.chatController,
          inputCubit: cubit,
          activeAgent: widget.agentSlice.activeAgent,
          capability: widget.capabilities,
          source: DraftAttachmentSource.paste,
          draftScope: draftScope,
        );
        if (unreadable > 0) {
          cubit.setAttachmentError(const DraftAttachmentError(DraftAttachmentErrorKind.readFailed));
        }
      }
      widget.chatFocusNode.requestFocus();
    } catch (_) {
      _fallbackTextPaste();
    }
  }

  /// Reads one clipboard item into a routable item, or `null` when it holds
  /// nothing attachable. Throws when the item cannot be read.
  Future<ComposerRoutableItem?> _readClipboardItem(ClipboardDataReader item, Set<String> seenPaths) async {
    if (item.canProvide(Formats.fileUri)) {
      final uri = await item.readValue(Formats.fileUri);
      if (uri == null || !uri.isScheme('file')) return null;
      final filePath = uri.toFilePath();
      return seenPaths.add(filePath) ? ComposerRoutableItem.fromFilePathSync(filePath) : null;
    }
    for (final format in _supportedImageFormats) {
      if (!item.canProvide(format)) continue;
      final bytes = await item.readFileBytes(format);
      if (bytes != null && bytes.isNotEmpty) {
        return ComposerRoutableItem.fromImageBytes(
          bytes: bytes,
          formatName: _extensionForFormat(format),
          suggestedName: await item.getSuggestedName(),
        );
      }
    }
    return null;
  }

  void _fallbackTextPaste() {
    final focusContext = widget.chatFocusNode.context;
    if (focusContext != null && focusContext.mounted) {
      Actions.maybeInvoke(
        focusContext,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Shortcuts(
      shortcuts: const <ShortcutActivator, Intent>{
        SingleActivator(LogicalKeyboardKey.keyV, meta: true): ComposerPasteIntent(),
        SingleActivator(LogicalKeyboardKey.keyV, control: true): ComposerPasteIntent(),
      },
      child: Actions(
        actions: <Type, Action<Intent>>{
          ComposerPasteIntent: _ComposerPasteAction(
            isComposerFocused: () => widget.chatFocusNode.hasFocus,
            onPaste: () => unawaited(_handlePaste(context)),
          ),
        },
        child: widget.child,
      ),
    );
  }
}

extension on DataReader {
  Future<Uint8List?> readFileBytes(FileFormat format) {
    final completer = Completer<Uint8List?>();
    final progress = getFile(
      format,
      (file) async {
        try {
          completer.complete(await file.readAll());
        } catch (error, stackTrace) {
          completer.completeError(error, stackTrace);
        }
      },
      onError: completer.completeError,
    );
    if (progress == null) completer.complete(null);
    return completer.future;
  }
}

