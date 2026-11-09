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
/// * A lost range never re-inserts text the session already wrote: when the
///   range is gone but the previous text is still in the composer, that span is
///   recovered (nearest the anchor) and **replaced**. Re-inserting it is what
///   put one dictated phrase in the composer twice.
/// * Writes never run while an IME composition is live: the update is deferred
///   and flushed when composition ends, so Arabic preedit is never destroyed.
/// * Writes never steal a caret that sits outside the dictation range; only the
///   offsets after the replacement shift.
/// * The record belongs to the **composer**, not to the widget that drew it:
///   the composer row moves the mic button between two branches when the meter
///   takes the row, which rebuilds the button's `State` exactly when the
///   transcript moves from a partial to its final. See [of].
class DictationInsertion {
  int? _start;
  int? _end;
  String _owned = '';
  String? _pending;
  int? _anchor;

  /// The insertion record of one composer controller.
  ///
  /// A session's range is written by whichever `State` currently draws the mic
  /// button, but it belongs to the composer: the row rebuilds that button when
  /// the session starts and again when it ends, and a per-`State` record died
  /// there while its text stayed in the editor. The late final then found no
  /// range, took the first-write branch, and appended the whole transcript to
  /// the partial it was revising — the duplicate the owner saw.
  ///
  /// Keyed by the controller because that object lives exactly as long as the
  /// text it holds. Bounded, because a closed conversation must not pin its
  /// editor (and the text it keeps) forever.
  static DictationInsertion of(TextEditingController controller) {
    final existing = _owners.remove(controller);
    final record = existing ?? DictationInsertion();
    // Re-inserted on every lookup, so the map is in least-recently-used order.
    _owners[controller] = record;
    if (_owners.length > _maxOwners) _owners.remove(_owners.keys.first);
    return record;
  }

  static final Map<TextEditingController, DictationInsertion> _owners = {};

  /// One record per live composer; older records only held text that was
  /// already handed to the user.
  static const int _maxOwners = 4;

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
  ///
  /// [previous] is the text this session last wrote. It only matters when the
  /// owned range was lost (a rebuild, a transient empty partial): the session
  /// text must then *replace* what is already in the composer instead of being
  /// inserted a second time — the failure mode that duplicated a phrase.
  void apply(
    TextEditingController controller,
    String text, {
    String? previous,
  }) {
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
      final recovered = _recoverRange(controller, previous);
      if (recovered != null) {
        _replace(controller, value, recovered.$1, recovered.$2, text);
        _start = recovered.$1;
        _end = recovered.$1 + text.length;
        _owned = text;
        return;
      }
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
    apply(controller, pending, previous: _owned);
  }

  /// Locates the exact text this session last wrote, nearest the anchor.
  ///
  /// Only used when the owned range was lost: replacing the recovered span is
  /// what keeps a revision from being appended to the copy it revises.
  (int, int)? _recoverRange(
    TextEditingController controller,
    String? previous,
  ) {
    final target = previous?.trim();
    if (target == null || target.isEmpty) return null;
    final haystack = controller.text;
    if (haystack.isEmpty) return null;
    final anchor = (_anchor ?? _caretOffset(controller.value))
        .clamp(0, haystack.length);
    final matches = <int>[];
    var index = haystack.indexOf(target);
    while (index >= 0) {
      matches.add(index);
      if (matches.length > 32) break;
      index = haystack.indexOf(target, index + 1);
    }
    if (matches.isEmpty) return null;
    matches.sort((a, b) => (a - anchor).abs().compareTo((b - anchor).abs()));
    final start = matches.first;
    return (start, start + target.length);
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
