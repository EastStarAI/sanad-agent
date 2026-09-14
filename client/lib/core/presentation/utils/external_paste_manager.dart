import 'package:flutter/material.dart';

/// Manages external paste events globally by finding the currently focused
/// [EditableTextState] and pasting the text into it at the correct cursor position.
class ExternalPasteManager {
  ExternalPasteManager._();

  /// Pastes the given [text] into the currently focused text field.
  static void handlePaste(String text) {
    if (text.isEmpty) return;

    final focus = FocusManager.instance.primaryFocus;
    if (focus == null || focus.context == null) return;

    final state = focus.context!.findAncestorStateOfType<EditableTextState>();
    if (state != null) {
      final value = state.textEditingValue;
      final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);

      final newText = value.text.replaceRange(selection.start, selection.end, text);
      final newOffset = selection.start + text.length;

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
      Actions.maybeInvoke(
        focus.context!,
        const PasteTextIntent(SelectionChangedCause.keyboard),
      );
    }
  }
}
