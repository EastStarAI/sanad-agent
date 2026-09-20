import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import 'package:sanad_client/features/conversations/domain/models/slash_command_entry.dart';
import 'package:sanad_client/features/conversations/presentation/utils/skill_composer_utils.dart';

class SlashSuggestionSurface extends StatelessWidget {
  final List<SlashCommandEntry> entries;
  final ValueChanged<SlashCommandEntry> onSelected;
  final Color borderColor;
  final String query;
  final int highlightedIndex;
  final ValueChanged<int>? onHighlightChanged;

  const SlashSuggestionSurface({
    super.key,
    required this.entries,
    required this.onSelected,
    required this.borderColor,
    required this.query,
    required this.highlightedIndex,
    this.onHighlightChanged,
  });

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;

    return ClipRRect(
      borderRadius: BorderRadius.circular(10),
      child: Container(
        width: double.infinity,
        decoration: BoxDecoration(
          color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.32),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: borderColor),
        ),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxHeight: 300),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: entries
                  .asMap()
                  .entries
                  .map(
                    (item) => InkWell(
                      key: ValueKey(
                        'slash_suggestion_${item.value.type.type}_${item.value.command}',
                      ),
                      onTap: () => onSelected(item.value),
                      onHover: (hovering) {
                        if (hovering) {
                          onHighlightChanged?.call(item.key);
                        }
                      },
                      child: Container(
                        color: item.key == highlightedIndex ? colorScheme.primary.withValues(alpha: 0.08) : null,
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                        child: Row(
                          children: [
                            Icon(item.value.type.icon, size: 16, color: colorScheme.primary),
                            const SizedBox(width: 10),
                            RichText(
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              text: _buildHighlightedCommandText(
                                context,
                                command: item.value.command,
                                query: query,
                              ),
                            ),
                            if (item.value.description != null && item.value.description!.trim().isNotEmpty)
                              Expanded(
                                child: Padding(
                                  padding: const EdgeInsetsDirectional.only(start: 8),
                                  child: Text(
                                    item.value.description!,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: GoogleFonts.inter(
                                      color: colorScheme.onSurfaceVariant,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  )
                  .toList(growable: false),
            ),
          ),
        ),
      ),
    );
  }

  TextSpan _buildHighlightedCommandText(
    BuildContext context, {
    required String command,
    required String query,
  }) {
    final colorScheme = Theme.of(context).colorScheme;
    final baseStyle = GoogleFonts.inter(
      color: colorScheme.onSurfaceVariant,
      fontSize: 14,
      fontWeight: FontWeight.normal,
    );
    final highlightedStyle = baseStyle.copyWith(
      color: colorScheme.onSurface,
    );
    final normalizedQuery = SkillComposerUtils.normalizeSlashSearchToken(query);

    if (normalizedQuery.isEmpty) {
      return TextSpan(
        text: command,
        style: baseStyle.copyWith(color: colorScheme.onSurface, fontWeight: FontWeight.w600),
      );
    }

    final spans = <TextSpan>[];
    var queryIndex = 0;
    for (final rune in command.runes) {
      final character = String.fromCharCode(rune);
      final normalizedCharacter = SkillComposerUtils.normalizeSlashSearchToken(character);
      final isMatch =
          normalizedCharacter.isNotEmpty &&
          queryIndex < normalizedQuery.length &&
          normalizedCharacter == normalizedQuery[queryIndex];
      spans.add(
        TextSpan(
          text: character,
          style: isMatch ? highlightedStyle : baseStyle,
        ),
      );
      if (isMatch) {
        queryIndex += 1;
      }
    }

    return TextSpan(children: spans);
  }
}
