import 'package:flutter/widgets.dart';

/// Tracks the composer range owned by dictation so transcript text can be
/// replaced in place without overwriting text the user typed.
///
/// Rules:
/// * First write inserts at the caret and remembers the range it owns.
/// * Later writes replace only that range while it still contains exactly what
///   dictation last wrote.
/// * If the user edited inside or around the range, dictation stops owning it
///   and only appends the not-yet-inserted tail at the caret.
/// * Writes never run while an IME composition is live: the update is deferred
///   and flushed when composition ends, so Arabic preedit is never destroyed.
/// * Writes never steal a caret that sits outside the dictation range; only the
///   offsets after the replacement shift.
class DictationInsertion {
  int? _start;
  int? _end;
  String _owned = '';
  String? _pending;
  int? _anchor;

  bool get hasRange => _start != null;

  /// The text dictation currently owns in the controller.
  String get ownedText => _owned;

  /// True when a write was deferred because an IME composition is live.
  bool get hasPending => _pending != null;

  /// Pins the insertion point to the caret the user had when the session
  /// started, so a transcript written at stop still lands where they began
  /// instead of wherever the caret wandered to.
  void begin(TextEditingController controller) {
    reset();
    _anchor = _caretOffset(controller.value);
  }

  void reset() {
    _start = null;
    _end = null;
    _owned = '';
    _pending = null;
    _anchor = null;
  }

  /// Applies [text] (the full session text so far) to [controller].
  void apply(TextEditingController controller, String text) {
    if (text.isEmpty) {
      removeOwned(controller);
      return;
    }

    final value = controller.value;
    if (value.composing.isValid) {
      // A live composition owns the text for now; replay it when it ends.
      _pending = text;
      return;
    }
    _pending = null;

    final start = _start;
    final end = _end;

    if (start == null || end == null) {
      final caret = (_anchor ?? _caretOffset(value)).clamp(0, value.text.length);
      final separator = _needsSeparator(value.text, caret) ? ' ' : '';
      final insertAt = caret + separator.length;
      _replace(controller, value, caret, caret, '$separator$text');
      _start = insertAt;
      _end = insertAt + text.length;
      _owned = text;
      return;
    }

    final safeStart = start.clamp(0, value.text.length);
    final safeEnd = end.clamp(safeStart, value.text.length);
    final intact = value.text.substring(safeStart, safeEnd) == _owned;

    if (intact) {
      _replace(controller, value, safeStart, safeEnd, text);
      _end = safeStart + text.length;
      _owned = text;
      return;
    }

    // The user touched the range: keep their edit and append only new text.
    final tail = text.startsWith(_owned) ? text.substring(_owned.length) : text;
    if (tail.isEmpty) {
      reset();
      return;
    }
    final caret =
        (_anchor ?? _caretOffset(value)).clamp(0, value.text.length);
    final separator = _needsSeparator(value.text, caret) ? ' ' : '';
    final insertAt = caret + separator.length;
    _replace(controller, value, caret, caret, '$separator$tail');
    _start = insertAt;
    _end = insertAt + tail.length;
    _owned = tail;
  }

  /// Applies a write that was deferred while an IME composition was live.
  void flushPending(TextEditingController controller) {
    final pending = _pending;
    if (pending == null) return;
    _pending = null;
    if (controller.value.composing.isValid) {
      _pending = pending;
      return;
    }
    apply(controller, pending);
  }

  /// Removes the range dictation owns, leaving user text untouched.
  void removeOwned(TextEditingController controller) {
    final start = _start;
    final end = _end;
    if (start == null || end == null) {
      reset();
      return;
    }
    final value = controller.value;
    final safeStart = start.clamp(0, value.text.length);
    final safeEnd = end.clamp(safeStart, value.text.length);
    if (value.text.substring(safeStart, safeEnd) == _owned) {
      _replace(controller, value, safeStart, safeEnd, '');
    }
    reset();
  }

  static void _replace(
    TextEditingController controller,
    TextEditingValue value,
    int start,
    int end,
    String replacement,
  ) {
    final text = value.text.replaceRange(start, end, replacement);
    final selection = _adjustSelection(
      value.selection,
      start: start,
      end: end,
      replacementLength: replacement.length,
    );
    controller.value = TextEditingValue(
      text: text,
      selection: _clampSelection(selection, text.length),
    );
  }

  /// A caret outside the replaced range keeps its place (shifted by the delta);
  /// a caret inside it moves to the end of the replacement.
  static TextSelection _adjustSelection(
    TextSelection selection, {
    required int start,
    required int end,
    required int replacementLength,
  }) {
    if (!selection.isValid) {
      return TextSelection.collapsed(offset: start + replacementLength);
    }
    if (start == end) {
      // Pure insertion at the caret: everything at or after it shifts.
      int shift(int offset) =>
          offset >= start ? offset + replacementLength : offset;
      return TextSelection(
        baseOffset: shift(selection.baseOffset),
        extentOffset: shift(selection.extentOffset),
        affinity: selection.affinity,
      );
    }
    final delta = replacementLength - (end - start);
    if (selection.end <= start) return selection;
    if (selection.start >= end) {
      return TextSelection(
        baseOffset: selection.baseOffset + delta,
        extentOffset: selection.extentOffset + delta,
      );
    }
    return TextSelection.collapsed(offset: start + replacementLength);
  }

  static TextSelection _clampSelection(TextSelection selection, int length) {
    int clamp(int offset) => offset.clamp(0, length);
    return TextSelection(
      baseOffset: clamp(selection.baseOffset),
      extentOffset: clamp(selection.extentOffset),
      affinity: selection.affinity,
    );
  }

  static int _caretOffset(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid) return value.text.length;
    return selection.end.clamp(0, value.text.length);
  }

  static bool _needsSeparator(String text, int caret) {
    if (caret == 0) return false;
    final before = text[caret - 1];
    return before != ' ' && before != '\n';
  }
}
