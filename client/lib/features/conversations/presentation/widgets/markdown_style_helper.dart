import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:google_fonts/google_fonts.dart';
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;
import 'package:sanad_client/core/theme/app_color_scheme.dart';
import 'package:sanad_client/features/conversations/presentation/utils/text_utils.dart';
import 'package:sanad_client/shared/widgets/copy_button.dart';

/// Centralized helper for generating consistent Markdown style sheets and
/// element builders across conversation widgets (e.g. UserMessageTile, EventTile).
class MarkdownStyleHelper {
  /// Builds a [MarkdownStyleSheet] configured with the app's standard typography and colors.
  static MarkdownStyleSheet getStyleSheet(
    BuildContext context, {
    bool isFinal = true,
  }) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final codeColor = theme.colorScheme.codeColor;

    return MarkdownStyleSheet(
      p: GoogleFonts.roboto(
        color: isFinal ? theme.colorScheme.onSurface : theme.colorScheme.onSurfaceVariant,
        fontSize: 13,
        height: 1.5,
      ),
      code: GoogleFonts.firaCode(
        color: codeColor,
        fontSize: 13,
        height: 1.5,
      ),
      codeblockDecoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: theme.colorScheme.outline.withValues(alpha: 0.1),
        ),
      ),
      blockquote: GoogleFonts.roboto(
        color: isDark ? theme.colorScheme.onSurface.withValues(alpha: 0.9) : theme.colorScheme.onSurfaceVariant,
        fontSize: 13,
        height: 1.5,
      ),
      blockquoteDecoration: BoxDecoration(
        color: isDark
            ? theme.colorScheme.surfaceContainer.withValues(alpha: 0.5)
            : theme.colorScheme.surfaceContainer.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(6),
        border: Border(
          left: BorderSide(
            color: codeColor.withValues(alpha: 0.4),
            width: 4,
          ),
        ),
      ),
      blockquotePadding: const EdgeInsets.symmetric(
        horizontal: 16,
        vertical: 12,
      ),
    );
  }
}

/// Renders a multiline Markdown code block with content-owned direction.
///
/// Programming and untyped code stays LTR. Plain `text` blocks detect their
/// content direction, which also owns the horizontal viewport's leading edge.
class AppCodeBlock extends StatelessWidget {
  final String codeText;
  final Color codeColor;
  final String? language;

  const AppCodeBlock({
    super.key,
    required this.codeText,
    required this.codeColor,
    this.language,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final normalizedLanguage = language?.trim().toLowerCase();
    final codeDirection = normalizedLanguage == 'text' ? TextUtils.getTextDirection(codeText) : TextDirection.ltr;
    final languageLabel = language?.trim().isNotEmpty == true ? language!.trim() : 'Code';

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: colorScheme.outline.withValues(alpha: 0.1)),
      ),
      child: Directionality(
        textDirection: TextDirection.ltr,
        child: Stack(
          children: [
            Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 44, 8),
                  child: Text(
                    languageLabel,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.labelSmall?.copyWith(
                      color: colorScheme.onSurfaceVariant,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.all(16),
                  child: Directionality(
                    textDirection: codeDirection,
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        codeText,
                        textDirection: codeDirection,
                        style: GoogleFonts.firaCode(
                          color: codeColor,
                          fontSize: 12,
                          height: 1.5,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
            PositionedDirectional(
              top: 6,
              end: 8,
              child: CopyButton(
                text: codeText,
                successMessage: 'Code copied to clipboard',
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Custom builder for inline code and multiline fallback blocks in Markdown text.
class AppInlineCodeBuilder extends MarkdownElementBuilder {
  final BuildContext context;

  AppInlineCodeBuilder(this.context);

  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    final text = element.textContent;
    if (text.contains('\n')) {
      final theme = Theme.of(context);
      final codeColor = theme.colorScheme.codeColor;

      String codeText = text;
      if (codeText.endsWith('\n')) {
        codeText = codeText.substring(0, codeText.length - 1);
      }

      final languageClass = element.attributes['class'];
      final language = languageClass?.startsWith('language-') == true
          ? languageClass!.substring('language-'.length)
          : null;

      return AppCodeBlock(
        codeText: codeText,
        codeColor: codeColor,
        language: language,
      );
    }

    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;

    final backgroundColor = isDark
        ? theme.colorScheme.surfaceContainer.withValues(alpha: 0.8)
        : theme.colorScheme.surfaceContainer.withValues(alpha: 0.5);

    final borderColor = isDark
        ? theme.colorScheme.outline.withValues(alpha: 0.6)
        : theme.colorScheme.outline.withValues(alpha: 0.3);

    final textColor = theme.colorScheme.codeColor;
    const fontSize = 12.0;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2.0),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 5.0, vertical: 1.5),
        decoration: BoxDecoration(
          color: backgroundColor,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: borderColor, width: 0.5),
        ),
        child: Text(
          text,
          textDirection: TextDirection.ltr,
          style: GoogleFonts.firaCode(
            color: textColor,
            fontSize: fontSize,
            fontWeight: FontWeight.w500,
          ),
        ),
      ),
    );
  }
}
