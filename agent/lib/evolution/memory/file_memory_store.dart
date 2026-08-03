import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import '../../core/sanad_home/sanad_home_bootstrap.dart';
import '../../core/sanad_home/sanad_home_boundary.dart';
import 'memory_content_scanner.dart';

class FileMemoryStore {
  FileMemoryStore({this.memoryCharLimit = 2200, this.userCharLimit = 1375});

  static const String memoryFileName = 'MEMORY.md';
  static const String userFileName = 'USER.md';
  static const String entryDelimiter = '\n§\n';
  static const int maxConsolidationFailuresPerTurn = 3;

  final int memoryCharLimit;
  final int userCharLimit;

  List<String> _memoryEntries = const [];
  List<String> _userEntries = const [];
  final Map<String, String> _systemPromptSnapshot = {'memory': '', 'user': ''};
  int _consolidationFailures = 0;

  void loadFromDisk() {
    final memoriesDir = _memoriesDirectory();
    if (!memoriesDir.existsSync()) {
      SanadHomeBootstrap.state().ensureDirectoryPathSync('memories');
    }

    _memoryEntries = _dedupe(_readFile(_pathFor('memory')));
    _userEntries = _dedupe(_readFile(_pathFor('user')));

    _systemPromptSnapshot['memory'] = _renderBlock(
      'memory',
      _sanitizeEntriesForSnapshot(_memoryEntries, memoryFileName),
    );
    _systemPromptSnapshot['user'] = _renderBlock(
      'user',
      _sanitizeEntriesForSnapshot(_userEntries, userFileName),
    );
  }

  void resetConsolidationFailures() {
    _consolidationFailures = 0;
  }

  String? formatForSystemPrompt(String target) {
    final block = _systemPromptSnapshot[target] ?? '';
    return block.trim().isEmpty ? null : block;
  }

  Map<String, dynamic> read(String target) {
    return _withLock(target, () {
      _reloadTarget(target);
      final entries = List<String>.from(_entriesFor(target));
      return {
        'success': true,
        'target': target,
        'entries': entries,
        'entry_count': entries.length,
        'usage': _usage(target),
        'frozen_snapshot': true,
      };
    });
  }

  Map<String, dynamic> add(String target, String content) {
    final normalized = content.trim();
    if (normalized.isEmpty) {
      return _error('Content cannot be empty.');
    }

    final scanError = MemoryContentScanner.rejectionMessage(normalized);
    if (scanError != null) {
      return _error(scanError);
    }

    return _withLock(target, () {
      final drift = _reloadTarget(target, detectDrift: true);
      if (drift != null) {
        return drift;
      }
      final entries = List<String>.from(_entriesFor(target));
      if (entries.contains(normalized)) {
        return _success(target, 'Entry already exists; no duplicate added.');
      }

      final candidate = [...entries, normalized];
      if (_joinedLength(candidate) > _charLimit(target)) {
        return _capacityError(
          target,
          'Adding this ${_formatCount(normalized.length)} char entry would exceed the limit.',
        );
      }

      _commit(target, candidate);
      return _success(target, 'Entry added.');
    });
  }

  Map<String, dynamic> replace(String target, String oldText, String content) {
    final matchText = oldText.trim();
    final normalized = content.trim();
    if (normalized.isEmpty) {
      return _error('content cannot be empty. Use remove to delete entries.');
    }

    final scanError = MemoryContentScanner.rejectionMessage(normalized);
    if (scanError != null) {
      return _error(scanError);
    }

    return _withLock(target, () {
      final drift = _reloadTarget(target, detectDrift: true);
      if (drift != null) {
        return drift;
      }
      if (matchText.isEmpty) {
        return _recoverableError(
          target,
          'old_text is required for replace. Retry with a unique substring from current_entries.',
        );
      }

      final entries = List<String>.from(_entriesFor(target));
      final matches = _findMatches(entries, matchText);
      if (matches.isEmpty) {
        return _recoverableError(
          target,
          "No entry matched '$matchText'. Retry with a unique substring from current_entries.",
        );
      }
      if (matches.length > 1) {
        return _ambiguousMatchError(target, matchText, entries, matches);
      }

      final candidate = List<String>.from(entries);
      candidate[matches.first] = normalized;
      if (_joinedLength(candidate) > _charLimit(target)) {
        return _capacityError(
          target,
          'Replacement would exceed the limit. Shorten it or remove stale entries in one batch.',
        );
      }

      _commit(target, candidate);
      return _success(target, 'Entry replaced.');
    });
  }

  Map<String, dynamic> remove(String target, String oldText) {
    final matchText = oldText.trim();
    return _withLock(target, () {
      final drift = _reloadTarget(target, detectDrift: true);
      if (drift != null) {
        return drift;
      }
      if (matchText.isEmpty) {
        return _recoverableError(
          target,
          'old_text is required for remove. Retry with a unique substring from current_entries.',
        );
      }

      final entries = List<String>.from(_entriesFor(target));
      final matches = _findMatches(entries, matchText);
      if (matches.isEmpty) {
        return _recoverableError(
          target,
          "No entry matched '$matchText'. Retry with a unique substring from current_entries.",
        );
      }
      if (matches.length > 1) {
        return _ambiguousMatchError(target, matchText, entries, matches);
      }

      entries.removeAt(matches.first);
      _commit(target, entries);
      return _success(target, 'Entry removed.');
    });
  }

  Map<String, dynamic> applyBatch(
    String target,
    List<Map<String, dynamic>> operations,
  ) {
    if (operations.isEmpty) {
      return _error('operations cannot be empty.');
    }

    return _withLock(target, () {
      final drift = _reloadTarget(target, detectDrift: true);
      if (drift != null) {
        return drift;
      }

      final working = List<String>.from(_entriesFor(target));
      for (var index = 0; index < operations.length; index++) {
        final operation = operations[index];
        final action = operation['action']?.toString().trim() ?? '';
        final content = operation['content']?.toString().trim() ?? '';
        final oldText = operation['old_text']?.toString().trim() ?? '';
        final position = 'Operation ${index + 1}';

        if (action == 'add') {
          if (content.isEmpty) {
            return _batchError(
              target,
              '$position: content is required for add.',
            );
          }
          final scanError = MemoryContentScanner.rejectionMessage(content);
          if (scanError != null) {
            return _batchError(target, '$position: $scanError');
          }
          if (!working.contains(content)) {
            working.add(content);
          }
          continue;
        }

        if (action == 'replace' || action == 'remove') {
          if (oldText.isEmpty) {
            return _batchError(
              target,
              '$position: old_text is required for $action.',
            );
          }
          if (action == 'replace') {
            if (content.isEmpty) {
              return _batchError(
                target,
                '$position: content is required for replace.',
              );
            }
            final scanError = MemoryContentScanner.rejectionMessage(content);
            if (scanError != null) {
              return _batchError(target, '$position: $scanError');
            }
          }

          final matches = _findMatches(working, oldText);
          if (matches.isEmpty) {
            return _batchError(
              target,
              "$position: no entry matched '$oldText'.",
            );
          }
          if (matches.length > 1) {
            return _batchError(
              target,
              "$position: '$oldText' matched multiple entries.",
            );
          }
          if (action == 'replace') {
            working[matches.first] = content;
          } else {
            working.removeAt(matches.first);
          }
          continue;
        }

        return _batchError(
          target,
          "$position: unknown action '$action'. Use add, replace, or remove.",
        );
      }

      if (_joinedLength(working) > _charLimit(target)) {
        return _capacityError(
          target,
          'The final batch result would exceed the limit. Remove or shorten more entries in the same batch.',
        );
      }

      _commit(target, working);
      return _success(
        target,
        'Applied ${operations.length} operation(s) atomically.',
      );
    });
  }

  Directory _memoriesDirectory() =>
      Directory(SanadHomeBootstrap.state().child('memories'));

  File _pathFor(String target) {
    final fileName = target == 'user' ? userFileName : memoryFileName;
    return File(p.join(_memoriesDirectory().path, fileName));
  }

  List<String> _entriesFor(String target) {
    return target == 'user' ? _userEntries : _memoryEntries;
  }

  void _setEntries(String target, List<String> entries) {
    final immutable = List<String>.unmodifiable(entries);
    if (target == 'user') {
      _userEntries = immutable;
    } else {
      _memoryEntries = immutable;
    }
  }

  int _charLimit(String target) =>
      target == 'user' ? userCharLimit : memoryCharLimit;

  int _charCount(String target) => _joinedLength(_entriesFor(target));

  int _joinedLength(List<String> entries) {
    return entries.isEmpty ? 0 : entries.join(entryDelimiter).length;
  }

  Map<String, dynamic>? _reloadTarget(
    String target, {
    bool detectDrift = false,
  }) {
    if (detectDrift) {
      final drift = _detectExternalDrift(target);
      if (drift != null) {
        return drift;
      }
    }
    final freshEntries = _dedupe(_readFile(_pathFor(target)));
    _setEntries(target, freshEntries);
    return null;
  }

  List<String> _readFile(File file) {
    final relative = p.join('memories', file.uri.pathSegments.last);
    final boundary = SanadHomeBootstrap.state();
    if (!boundary.fileExists(relative)) {
      return const [];
    }
    final raw = utf8.decode(boundary.readSecretBytes(relative));
    return _parseRaw(raw);
  }

  List<String> _parseRaw(String raw) {
    if (raw.trim().isEmpty) {
      return const [];
    }
    return raw
        .split(entryDelimiter)
        .map((entry) => entry.trim())
        .where((entry) => entry.isNotEmpty)
        .toList(growable: false);
  }

  void _commit(String target, List<String> entries) {
    _writeAtomically(_pathFor(target), entries.join(entryDelimiter));
    _setEntries(target, entries);
  }

  void _writeAtomically(File destination, String content) {
    SanadHomeBootstrap.state().writeSecretBytesSync(
      p.join('memories', destination.uri.pathSegments.last),
      utf8.encode(content),
    );
  }

  Map<String, dynamic>? _detectExternalDrift(String target) {
    final file = _pathFor(target);
    final relative = p.join('memories', file.uri.pathSegments.last);
    final boundary = SanadHomeBootstrap.state();
    if (!boundary.fileExists(relative)) {
      return null;
    }
    final raw = utf8.decode(boundary.readSecretBytes(relative));
    if (raw.trim().isEmpty) {
      return null;
    }
    final entries = _parseRaw(raw);
    final rendered = entries.join(entryDelimiter);
    final oversizedEntry = entries.any(
      (entry) => entry.length > _charLimit(target),
    );
    if (raw.trim() == rendered && !oversizedEntry) {
      return null;
    }

    final backup = File(
      '${file.path}.bak.${DateTime.now().millisecondsSinceEpoch}',
    );
    String backupStatus;
    try {
      boundary.writeSecretBytesSync(
        p.join('memories', backup.uri.pathSegments.last),
        utf8.encode(raw),
      );
      backupStatus = backup.path;
    } catch (_) {
      backupStatus = 'backup_failed';
    }
    return {
      'success': false,
      'done': true,
      'target': target,
      'error':
          'Refusing to rewrite ${file.uri.pathSegments.last}: its current content cannot round-trip safely through the memory entry format.',
      'drift_backup': backupStatus,
      'remediation':
          'Preserve the source, rewrite it as a clean §-delimited entry list, then retry.',
    };
  }

  List<String> _sanitizeEntriesForSnapshot(
    List<String> entries,
    String fileName,
  ) {
    return entries
        .map((entry) {
          final findings = MemoryContentScanner.scan(entry);
          if (findings.isEmpty) {
            return entry;
          }
          return '[BLOCKED: $fileName entry contained ${findings.join(', ')} and was removed from the system prompt snapshot.]';
        })
        .toList(growable: false);
  }

  String _renderBlock(String target, List<String> entries) {
    if (entries.isEmpty) {
      return '';
    }
    final current = _joinedLength(entries);
    final limit = _charLimit(target);
    final pct = limit == 0
        ? 0
        : ((current / limit) * 100).floor().clamp(0, 100);
    final header = target == 'user'
        ? 'USER PROFILE (who the user is)'
        : 'MEMORY (your durable notes)';
    final divider = '═' * 46;
    return '$divider\n$header [$pct% - ${_formatCount(current)}/${_formatCount(limit)} chars]\n$divider\n${entries.join(entryDelimiter)}';
  }

  Map<String, dynamic> _success(String target, String message) {
    _consolidationFailures = 0;
    return {
      'success': true,
      'done': true,
      'target': target,
      'usage': _usage(target),
      'entry_count': _entriesFor(target).length,
      'message': message,
      'note': 'Memory update is complete; do not repeat it.',
    };
  }

  Map<String, dynamic> _recoverableError(String target, String message) {
    return _consolidationFailure({
      'success': false,
      'target': target,
      'error': message,
      'current_entries': List<String>.from(_entriesFor(target)),
      'usage': _usage(target),
    });
  }

  Map<String, dynamic> _batchError(String target, String message) {
    return _recoverableError(
      target,
      '$message No operations were applied; the batch is all-or-nothing.',
    );
  }

  Map<String, dynamic> _capacityError(String target, String message) {
    return _recoverableError(
      target,
      '$message Consolidate with one operations batch, then retry.',
    );
  }

  Map<String, dynamic> _consolidationFailure(Map<String, dynamic> response) {
    _consolidationFailures++;
    if (_consolidationFailures <= maxConsolidationFailuresPerTurn) {
      return response;
    }
    return {
      'success': false,
      'done': true,
      'error':
          'Memory maintenance failed repeatedly in this turn. Stop retrying memory calls, leave memory unchanged, and continue answering the user.',
    };
  }

  Map<String, dynamic> _error(String message) {
    return {'success': false, 'error': message};
  }

  List<int> _findMatches(List<String> entries, String oldText) {
    final matches = <int>[];
    for (var index = 0; index < entries.length; index++) {
      if (entries[index].contains(oldText)) {
        matches.add(index);
      }
    }
    return matches;
  }

  Map<String, dynamic> _ambiguousMatchError(
    String target,
    String oldText,
    List<String> entries,
    List<int> matches,
  ) {
    return _consolidationFailure({
      'success': false,
      'target': target,
      'error': "Multiple entries matched '$oldText'. Be more specific.",
      'matches': matches.map((index) => _preview(entries[index])).toList(),
      'usage': _usage(target),
    });
  }

  String _preview(String value) {
    final oneLine = value.replaceAll(RegExp(r'\s+'), ' ').trim();
    return oneLine.length <= 120 ? oneLine : '${oneLine.substring(0, 120)}…';
  }

  List<String> _dedupe(List<String> entries) {
    return entries.toSet().toList(growable: false);
  }

  Map<String, dynamic> _withLock(
    String target,
    Map<String, dynamic> Function() action,
  ) {
    RandomAccessFile? handle;
    try {
      final lockFile = File('${_pathFor(target).path}.lock');
      final boundary = SanadHomeBootstrap.state();
      boundary.ensureDirectoryPathSync('memories');
      if (!lockFile.existsSync()) {
        boundary.writeSecretBytesSync(
          p.join('memories', lockFile.uri.pathSegments.last),
          const [],
        );
      } else {
        boundary.readSecretBytes(
          p.join('memories', lockFile.uri.pathSegments.last),
        );
      }
      handle = lockFile.openSync(mode: FileMode.append);
      handle.lockSync();
      return action();
    } on FileSystemException catch (error) {
      return {
        'success': false,
        'done': true,
        'target': target,
        'error': 'Memory file operation failed safely: ${error.message}',
      };
    } on SanadHomeBoundaryViolation catch (error) {
      return {
        'success': false,
        'done': true,
        'target': target,
        'error': 'Memory file operation failed safely: ${error.code}',
      };
    } on SanadHomeWriteFailure catch (error) {
      return {
        'success': false,
        'done': true,
        'target': target,
        'error': 'Memory file operation failed safely: ${error.code}',
      };
    } on FormatException {
      return {
        'success': false,
        'done': true,
        'target': target,
        'error':
            'Memory file operation failed safely because the file is not valid UTF-8.',
      };
    } finally {
      if (handle != null) {
        try {
          handle.unlockSync();
        } catch (_) {}
        try {
          handle.closeSync();
        } catch (_) {}
      }
    }
  }

  String _usage(String target) {
    final current = _charCount(target);
    final limit = _charLimit(target);
    final pct = limit == 0
        ? 0
        : ((current / limit) * 100).floor().clamp(0, 100);
    return '$pct% - ${_formatCount(current)}/${_formatCount(limit)} chars';
  }

  String _formatCount(int value) {
    final digits = value.abs().toString();
    final buffer = StringBuffer();
    for (var index = 0; index < digits.length; index++) {
      if (index > 0 && (digits.length - index) % 3 == 0) {
        buffer.write(',');
      }
      buffer.write(digits[index]);
    }
    final formatted = buffer.toString();
    return value < 0 ? '-$formatted' : formatted;
  }
}
