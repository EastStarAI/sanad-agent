import 'dart:io';

import 'package:path/path.dart' as p;

import '../discovery/local_gateway_discovery.dart';

/// Manages REPL command history with persistence to `SANAD_HOME/cli_history`
/// and up/down arrow cursor navigation.
class ReplHistory {
  final String historyFilePath;
  final int maxEntries;
  final List<String> entries;

  int _cursor = -1;
  String? _draft;

  ReplHistory({
    String? historyFilePath,
    String? sanadHomeOverride,
    this.maxEntries = 1000,
    List<String>? initialEntries,
  }) : historyFilePath =
           historyFilePath ??
           p.join(
             sanadHomeOverride ??
                 const LocalGatewayDiscovery().resolveSanadHome(),
             'cli_history',
           ),
       entries = initialEntries != null ? List.from(initialEntries) : [];

  /// Current navigation cursor index (-1 means at the bottom / new prompt).
  int get cursor => _cursor;

  /// Number of entries currently in history.
  int get length => entries.length;

  /// Loads history lines from [historyFilePath] if the file exists.
  Future<void> load() async {
    final file = File(historyFilePath);
    if (!await file.exists()) {
      return;
    }
    try {
      final lines = await file.readAsLines();
      entries.clear();
      for (final line in lines) {
        final trimmed = line.trim();
        if (trimmed.isNotEmpty) {
          entries.add(trimmed);
        }
      }
      if (entries.length > maxEntries) {
        entries.removeRange(0, entries.length - maxEntries);
      }
    } catch (_) {}
  }

  /// Persists current history entries to [historyFilePath].
  Future<void> save() async {
    final file = File(historyFilePath);
    try {
      if (!await file.parent.exists()) {
        await file.parent.create(recursive: true);
      }
      final toSave = entries.length > maxEntries
          ? entries.sublist(entries.length - maxEntries)
          : entries;
      await file.writeAsString('${toSave.join('\n')}\n', flush: true);
    } catch (_) {}
  }

  /// Appends a new command to history.
  ///
  /// Discards empty lines or duplicates of the immediate previous entry,
  /// and resets the navigation cursor to the bottom.
  void add(String command) {
    final trimmed = command.trim();
    if (trimmed.isEmpty) return;
    if (entries.isNotEmpty && entries.last == trimmed) {
      resetCursor();
      return;
    }
    entries.add(trimmed);
    if (entries.length > maxEntries) {
      entries.removeAt(0);
    }
    resetCursor();
  }

  /// Navigates to the previous (older) history entry.
  ///
  /// If navigating up from the bottom, [currentDraft] is preserved so the user
  /// can return to their in-progress text by pressing the Down arrow.
  String? previous(String currentDraft) {
    if (entries.isEmpty) return null;

    if (_cursor == -1) {
      _draft = currentDraft;
      _cursor = entries.length - 1;
      return entries[_cursor];
    }

    if (_cursor > 0) {
      _cursor--;
      return entries[_cursor];
    }

    // Already at the oldest entry
    return entries[_cursor];
  }

  /// Navigates to the next (newer) history entry.
  ///
  /// When navigating past the newest entry, restores the saved draft.
  String? next() {
    if (entries.isEmpty || _cursor == -1) return null;

    if (_cursor < entries.length - 1) {
      _cursor++;
      return entries[_cursor];
    }

    // Reached bottom: restore draft
    final restored = _draft ?? '';
    resetCursor();
    return restored;
  }

  /// Resets navigation state back to the fresh prompt position.
  void resetCursor() {
    _cursor = -1;
    _draft = null;
  }

  /// Clears in-memory history entries.
  void clear() {
    entries.clear();
    resetCursor();
  }
}
