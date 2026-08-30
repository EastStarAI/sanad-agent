import 'package:flutter/widgets.dart';

class SkillSlashQuery {
  final int slashIndex;
  final int cursorIndex;
  final String query;

  const SkillSlashQuery({
    required this.slashIndex,
    required this.cursorIndex,
    required this.query,
  });
}

class SkillComposerUtils {
  static SkillSlashQuery? detectSlashQuery(TextEditingValue value) {
    final query = _detectSlashToken(value);
    if (query == null) {
      return null;
    }
    // Runtime slash commands own index zero; mid-message slash stays skill-only.
    if (query.slashIndex == 0) {
      return null;
    }
    return query;
  }

  static SkillSlashQuery? detectRuntimeSlashQuery(TextEditingValue value) {
    final query = _detectSlashToken(value);
    if (query == null || query.slashIndex != 0) {
      return null;
    }
    return query;
  }

  static SkillSlashQuery? _detectSlashToken(TextEditingValue value) {
    final selection = value.selection;
    if (!selection.isValid || !selection.isCollapsed) {
      return null;
    }

    final cursor = selection.baseOffset;
    if (cursor < 0 || cursor > value.text.length) {
      return null;
    }

    final prefix = value.text.substring(0, cursor);
    final slashIndex = prefix.lastIndexOf('/');
    if (slashIndex < 0) {
      return null;
    }

    if (slashIndex > 0) {
      final previous = prefix[slashIndex - 1];
      if (!_isWhitespace(previous)) {
        return null;
      }
    }

    final token = prefix.substring(slashIndex + 1);
    if (token.contains('\n')) {
      return null;
    }

    // Exit slash command search after the second space
    final spaceCount = token.split(' ').length - 1;
    if (spaceCount >= 2) {
      return null;
    }

    return SkillSlashQuery(
      slashIndex: slashIndex,
      cursorIndex: cursor,
      query: token,
    );
  }

  static TextEditingValue applySkillSelection(
    TextEditingValue value, {
    required SkillSlashQuery query,
    required String skillName,
  }) {
    final updated = value.text.replaceRange(
      query.slashIndex,
      query.cursorIndex,
      skillName,
    );
    final selectionOffset = query.slashIndex + skillName.length;
    return value.copyWith(
      text: updated,
      selection: TextSelection.collapsed(offset: selectionOffset),
      composing: TextRange.empty,
    );
  }

  static bool _isWhitespace(String value) {
    return value.trim().isEmpty;
  }

  static String normalizeSlashSearchToken(String value) {
    return value.toLowerCase().replaceAll(RegExp(r'[\s\-_]+'), '');
  }
}
