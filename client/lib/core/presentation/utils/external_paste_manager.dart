import 'package:flutter/material.dart';
import 'package:logging/logging.dart';

/// Manages external paste events globally by finding the currently focused
/// [EditableTextState] and pasting the text into it at the correct cursor
/// position.
///
/// The text arrives from the macOS runner, which reads the pasteboard at the
/// key event itself. An external writer (a dictation tool, a launcher, a
/// clipboard manager) can restore the previous pasteboard immediately after it
/// posts Cmd+V, so text captured at the event is the only reliable copy.
class ExternalPasteManager {
  ExternalPasteManager._();

  static final _logger = Logger('ExternalPaste');

  /// Pastes the given [text] into the currently focused text field.
  static void handlePaste(String text) {
    if (text.isEmpty) return;

    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus.context == null) {
      _logger.warning('external paste dropped: no focused field');
      return;
    }

    final state = focus.context!.findAncestorStateOfType<EditableTextState>();
    if (state != null) {
      final value = state.textEditingValue;
      final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);

      final newText = value.text.replaceRange(selection.start, selection.end, text);
      final newOffset = selection.start + text.length;

      _logger.info('external paste inserted (${text.length} chars)');
      state.userUpdateTextEditingValue(
        value.copyWith(
          text: newText,
          selection: TextSelection.collapsed(offset: newOffset),
          composing: TextRange.empty,
        ),
        SelectionChangedCause.keyboard,
      );
    } else {
      // Fallback to standard paste intent if EditableTextState is not found
      _logger.info('external paste fell back to PasteTextIntent');
      Actions.maybeInvoke(
        focus.context!,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
    }
  }
}
