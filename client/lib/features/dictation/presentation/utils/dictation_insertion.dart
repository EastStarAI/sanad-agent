import 'package:flutter/widgets.dart';

/// Tracks the composer range owned by dictation so live transcript text can be
/// replaced in place without ever overwriting text the user typed.
///
/// Rules:
/// * First write inserts at the caret and remembers the range it owns.
/// * Later writes replace only that range while it still contains exactly what
///   dictation last wrote.
/// * If the user edited inside or around the range, dictation stops owning it
///   and only appends the not-yet-inserted tail at the caret.
class DictationInsertion {
  int? _start;
  int? _end;
  String _owned = '';

  bool get hasRange => _start != null;

  /// The text dictation currently owns in the controller.
  String get ownedText => _owned;

  void reset() {
    _start = null;
    _end = null;
    _owned = '';
  }

  /// Applies [text] (the full session text so far) to [controller].
  void apply(TextEditingController controller, String text) {
    if (text.isEmpty) {
      removeOwned(controller);
      return;
    }

    final current = controller.text;
    final start = _start;
    final end = _end;

    if (start == null || end == null) {
      final caret = _caretOffset(controller, current);
      final updated = current.replaceRange(caret, caret, text);
      _write(controller, updated, caret + text.length);
      _start = caret;
      _end = caret + text.length;
      _owned = text;
      return;
    }

    final safeStart = start.clamp(0, current.length);
    final safeEnd = end.clamp(safeStart, current.length);
    final intact = current.substring(safeStart, safeEnd) == _owned;

    if (intact) {
      final updated = current.replaceRange(safeStart, safeEnd, text);
      _write(controller, updated, safeStart + text.length);
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
    final caret = _caretOffset(controller, current);
    final separator = _needsSeparator(current, caret) ? ' ' : '';
    final inserted = '$separator$tail';
    final updated = current.replaceRange(caret, caret, inserted);
    _write(controller, updated, caret + inserted.length);
    _start = caret;
    _end = caret + inserted.length;
    _owned = inserted;
  }

  /// Removes the range dictation owns, leaving user text untouched.
  void removeOwned(TextEditingController controller) {
    final start = _start;
    final end = _end;
    if (start == null || end == null) {
      reset();
      return;
    }
    final current = controller.text;
    final safeStart = start.clamp(0, current.length);
    final safeEnd = end.clamp(safeStart, current.length);
    if (current.substring(safeStart, safeEnd) == _owned) {
      final updated = current.replaceRange(safeStart, safeEnd, '');
      _write(controller, updated, safeStart);
    }
    reset();
  }

  static int _caretOffset(TextEditingController controller, String text) {
    final selection = controller.selection;
    if (!selection.isValid) return text.length;
    return selection.end.clamp(0, text.length);
  }

  static bool _needsSeparator(String text, int caret) {
    if (caret == 0) return false;
    final before = text[caret - 1];
    return before != ' ' && before != '\n';
  }

  static void _write(TextEditingController controller, String text, int caret) {
    controller.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: caret.clamp(0, text.length)),
    );
  }
}
