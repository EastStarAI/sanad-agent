import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/utils/file_reference_link.dart';
import 'package:sanad_client/features/conversations/presentation/utils/skill_composer_utils.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';

class SlashCommandDispatchToken {
  final SlashCommandEntry entry;
  final int start;
  final int end;

  const SlashCommandDispatchToken({
    required this.entry,
    required this.start,
    required this.end,
  });
}

class ComposerFileToken {
  final String path;
  final String fileName;

  const ComposerFileToken({
    required this.path,
    required this.fileName,
  });

  String get exportText => FileReferenceLink.format(fileName: fileName, path: path);

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is ComposerFileToken &&
          runtimeType == other.runtimeType &&
          path == other.path &&
          fileName == other.fileName;

  @override
  int get hashCode => Object.hash(path, fileName);
}

class SlashCommandDispatchExport {
  final String plainText;
  final List<SlashCommandDispatchToken> tokens;
  final List<ComposerFileToken> fileTokens;

  const SlashCommandDispatchExport({
    required this.plainText,
    required this.tokens,
    this.fileTokens = const [],
  });
}

class SlashCommandTextController extends TextEditingController {
  static const int _tokenCodePointStart = 0xE000;
  static const int _tokenCodePointEnd = 0xF8FF;

  final Map<String, SlashCommandEntry> _tokensByMarker = <String, SlashCommandEntry>{};
  final Map<String, ComposerFileToken> _fileTokensByMarker = <String, ComposerFileToken>{};
  int _nextTokenCodePoint = _tokenCodePointStart;

  SlashCommandTextController();

  Map<String, ComposerFileToken> get fileTokensByMarker => Map.unmodifiable(_fileTokensByMarker);

  String exportPlainText() {
    return exportForDispatch().plainText;
  }

  SlashCommandDispatchExport exportForDispatch() {
    final buffer = StringBuffer();
    final tokens = <SlashCommandDispatchToken>[];
    final fileTokens = <ComposerFileToken>[];
    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      final slashToken = _tokensByMarker[character];
      final fileToken = _fileTokensByMarker[character];
      if (slashToken != null) {
        final start = buffer.length;
        buffer.write(slashToken.insertText);
        tokens.add(
          SlashCommandDispatchToken(
            entry: slashToken,
            start: start,
            end: buffer.length,
          ),
        );
      } else if (fileToken != null) {
        buffer.write(fileToken.exportText);
        fileTokens.add(fileToken);
      } else {
        buffer.write(character);
      }
    }
    return SlashCommandDispatchExport(
      plainText: buffer.toString(),
      tokens: tokens,
      fileTokens: fileTokens,
    );
  }

  TextEditingValue applySlashCommandSelection({
    required TextEditingValue value,
    required SkillSlashQuery query,
    required SlashCommandEntry entry,
  }) {
    final marker = _allocateTokenMarker();
    _tokensByMarker[marker] = entry;
    final trailingSpacer = _needsTrailingSpacer(value, cursorIndex: query.cursorIndex) ? ' ' : '';
    final updatedText = value.text.replaceRange(
      query.slashIndex,
      query.cursorIndex,
      '$marker$trailingSpacer',
    );
    final selectionOffset = query.slashIndex + 1 + trailingSpacer.length;
    return value.copyWith(
      text: updatedText,
      selection: TextSelection.collapsed(offset: selectionOffset),
      composing: TextRange.empty,
    );
  }

  TextEditingValue insertFilePathToken({
    required TextEditingValue value,
    required String path,
    String? fileName,
  }) {
    final resolvedName = (fileName != null && fileName.trim().isNotEmpty)
        ? fileName.trim()
        : path.split(RegExp(r'[/\\]')).last.trim();
    final name = resolvedName.isEmpty ? 'file' : resolvedName;

    final marker = _allocateTokenMarker();
    _fileTokensByMarker[marker] = ComposerFileToken(
      path: path,
      fileName: name,
    );

    final selection = value.selection.isValid ? value.selection : TextSelection.collapsed(offset: value.text.length);
    final start = selection.start;
    final end = selection.end;
    final before = value.text.substring(0, start);
    final after = value.text.substring(end);
    final leadingSpace = before.isNotEmpty && !RegExp(r'\s$').hasMatch(before) ? ' ' : '';
    final trailingSpace = after.isEmpty || !RegExp(r'^\s').hasMatch(after) ? ' ' : '';
    final insertion = '$leadingSpace$marker$trailingSpace';

    return value.copyWith(
      text: value.text.replaceRange(start, end, insertion),
      selection: TextSelection.collapsed(offset: start + insertion.length),
      composing: TextRange.empty,
    );
  }

  void insertFileToken(String path, {String? fileName}) {
    value = insertFilePathToken(value: value, path: path, fileName: fileName);
  }

  void setDraftText(String rawText) {
    if (rawText.isEmpty) {
      _tokensByMarker.clear();
      _fileTokensByMarker.clear();
      value = TextEditingValue.empty;
      return;
    }

    final buffer = StringBuffer();
    int lastEnd = 0;

    for (final match in FileReferenceLink.pattern.allMatches(rawText)) {
      final reference = FileReferenceLink.parse(match);
      if (reference == null) {
        // Not a valid file URI: the text stays as typed and remains sendable.
        continue;
      }
      final marker = _allocateTokenMarker();
      _fileTokensByMarker[marker] = ComposerFileToken(
        path: reference.path,
        fileName: reference.fileName,
      );
      buffer.write(rawText.substring(lastEnd, match.start));
      buffer.write(marker);
      lastEnd = match.end;
    }

    buffer.write(rawText.substring(lastEnd));

    final newText = buffer.toString();
    value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: newText.length),
      composing: TextRange.empty,
    );
  }

  @override
  set value(TextEditingValue newValue) {
    _pruneMissingTokens(newValue.text);
    super.value = newValue;
  }

  @override
  TextSpan buildTextSpan({
    required BuildContext context,
    TextStyle? style,
    required bool withComposing,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final effectiveStyle = style ?? const TextStyle();
    final children = <InlineSpan>[];
    final buffer = StringBuffer();

    void flush() {
      if (buffer.isEmpty) {
        return;
      }
      children.add(TextSpan(text: buffer.toString(), style: effectiveStyle));
      buffer.clear();
    }

    for (final rune in text.runes) {
      final character = String.fromCharCode(rune);
      final slashToken = _tokensByMarker[character];
      final fileToken = _fileTokensByMarker[character];

      if (slashToken == null && fileToken == null) {
        buffer.write(character);
        continue;
      }

      flush();
      if (slashToken != null) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(slashToken.type.icon, size: 16, color: colorScheme.primary),
                const SizedBox(width: 4),
                Text(
                  slashToken.command,
                  style: GoogleFonts.inter(
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        );
      } else if (fileToken != null) {
        children.add(
          WidgetSpan(
            alignment: PlaceholderAlignment.middle,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FileExtensionIcon(fileName: fileToken.fileName, size: 16),
                const SizedBox(width: 4),
                Text(
                  fileToken.fileName,
                  style: GoogleFonts.inter(
                    color: colorScheme.primary,
                  ),
                ),
              ],
            ),
          ),
        );
      }
    }

    flush();
    return TextSpan(style: effectiveStyle, children: children);
  }

  String _allocateTokenMarker() {
    // First attempt from _nextTokenCodePoint to _tokenCodePointEnd
    while (_nextTokenCodePoint <= _tokenCodePointEnd) {
      final marker = String.fromCharCode(_nextTokenCodePoint);
      _nextTokenCodePoint += 1;
      if (_tokensByMarker.containsKey(marker) || _fileTokensByMarker.containsKey(marker)) {
        continue;
      }
      return marker;
    }

    // Wrap around to _tokenCodePointStart and reuse released markers
    _nextTokenCodePoint = _tokenCodePointStart;
    while (_nextTokenCodePoint <= _tokenCodePointEnd) {
      final marker = String.fromCharCode(_nextTokenCodePoint);
      _nextTokenCodePoint += 1;
      if (!_tokensByMarker.containsKey(marker) && !_fileTokensByMarker.containsKey(marker)) {
        return marker;
      }
    }

    throw StateError('No composer token markers are available.');
  }

  bool _needsTrailingSpacer(
    TextEditingValue value, {
    required int cursorIndex,
  }) {
    if (cursorIndex >= value.text.length) {
      return true;
    }
    return value.text[cursorIndex].trim().isNotEmpty;
  }

  void _pruneMissingTokens(String currentText) {
    final activeMarkers = currentText.runes.map(String.fromCharCode).toSet();
    _tokensByMarker.removeWhere((marker, _) => !activeMarkers.contains(marker));
    _fileTokensByMarker.removeWhere((marker, _) => !activeMarkers.contains(marker));
  }
}
