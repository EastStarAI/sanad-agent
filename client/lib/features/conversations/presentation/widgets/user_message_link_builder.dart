import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
// ignore: depend_on_referenced_packages
import 'package:markdown/markdown.dart' as md;
import 'package:sanad_client/features/conversations/presentation/utils/file_reference_link.dart';
import 'package:sanad_client/shared/widgets/file_extension_icon.dart';

/// Renders a file reference inside a user message as an inline chip
/// displaying [FileExtensionIcon] + the file name, without navigation.
class UserMessageFileChip extends StatelessWidget {
  final String fileName;
  final String fullPath;

  const UserMessageFileChip({
    super.key,
    required this.fileName,
    required this.fullPath,
  });

  static String extractFileName({required String href, String? text}) {
    final cleanText = text?.trim();
    if (cleanText != null &&
        cleanText.isNotEmpty &&
        !cleanText.toLowerCase().startsWith('file://') &&
        !cleanText.contains('/') &&
        !cleanText.contains('\\')) {
      return cleanText;
    }
    try {
      final uri = Uri.tryParse(href);
      if (uri != null && uri.pathSegments.isNotEmpty) {
        final last = uri.pathSegments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
        if (last.isNotEmpty) {
          return Uri.decodeComponent(last);
        }
      }
    } catch (_) {}

    final unescaped = Uri.decodeFull(href.replaceFirst(RegExp(r'^file:\/\/', caseSensitive: false), ''));
    final segments = unescaped.split(RegExp(r'[/\\]'));
    final last = segments.lastWhere((s) => s.isNotEmpty, orElse: () => '');
    return last.isNotEmpty ? last : href;
  }

  static String extractFullPath(String href) {
    try {
      final uri = Uri.tryParse(href);
      if (uri != null) {
        if (uri.isScheme('file')) {
          try {
            return uri.toFilePath();
          } catch (_) {
            return Uri.decodeFull(uri.path);
          }
        }
        return Uri.decodeFull(uri.path.isNotEmpty ? uri.path : href);
      }
    } catch (_) {}
    return href.toLowerCase().startsWith('file://') ? Uri.decodeFull(href.substring(7)) : href;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final colorScheme = theme.colorScheme;
    final isDark = theme.brightness == Brightness.dark;

    final chipBackground = isDark
        ? colorScheme.surfaceContainerHighest.withValues(alpha: 0.6)
        : colorScheme.surfaceContainerHighest.withValues(alpha: 0.4);
    final chipBorder = colorScheme.outline.withValues(alpha: 0.25);

    Widget chip = Container(
      key: const Key('user_message_file_chip'),
      padding: const EdgeInsetsDirectional.fromSTEB(6, 2, 8, 2),
      margin: const EdgeInsetsDirectional.only(end: 4, top: 1, bottom: 1),
      decoration: BoxDecoration(
        color: chipBackground,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: chipBorder, width: 0.5),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          FileExtensionIcon(
            fileName: fileName,
            size: 15,
          ),
          const SizedBox(width: 5),
          Flexible(
            child: Text(
              fileName,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: (theme.textTheme.bodyMedium ?? const TextStyle()).copyWith(
                fontSize: 12.5,
                fontWeight: FontWeight.w500,
                color: colorScheme.onSurface,
              ),
            ),
          ),
        ],
      ),
    );

    if (fullPath.isNotEmpty) {
      chip = Tooltip(
        message: fullPath,
        child: chip,
      );
    }

    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: () {},
      child: chip,
    );
  }
}

/// Custom Markdown element builder for links (`<a>`) inside user messages.
///
/// `file://` scheme links are rendered as inert [UserMessageFileChip] chips,
/// while non-`file://` links remain clickable and open via [onOpenUrl].
class UserMessageLinkBuilder extends MarkdownElementBuilder {
  final BuildContext context;
  final Future<void> Function(String? url) onOpenUrl;

  UserMessageLinkBuilder(this.context, {required this.onOpenUrl});

  @override
  Widget? visitElementAfterWithContext(
    BuildContext context,
    md.Element element,
    TextStyle? preferredStyle,
    TextStyle? parentStyle,
  ) {
    final href = element.attributes['href'];
    if (href != null && href.toLowerCase().startsWith('file://')) {
      final fileName = UserMessageFileChip.extractFileName(
        href: href,
        text: element.textContent,
      );
      final fullPath = UserMessageFileChip.extractFullPath(href);
      return Text.rich(
        TextSpan(
          children: [
            WidgetSpan(
              alignment: PlaceholderAlignment.middle,
              child: UserMessageFileChip(
                fileName: fileName,
                fullPath: fullPath,
              ),
            ),
          ],
        ),
      );
    }

    // Every widget returned here must stay a `Text` so the markdown builder
    // merges it into the surrounding paragraph; any other widget type is laid
    // out as a separate `Wrap` child and breaks the inline text flow.
    final text = element.textContent;
    final style = preferredStyle ?? parentStyle;
    if (href == null || href.isEmpty) {
      return Text.rich(TextSpan(text: text, style: style));
    }
    // Ordinary links keep the stylesheet's own link style and tap behavior
    // (registering an `a` builder removes the package's default recognizer).
    return Text.rich(
      TextSpan(
        text: text,
        style: style,
        mouseCursor: SystemMouseCursors.click,
        recognizer: TapGestureRecognizer()..onTap = () => unawaited(onOpenUrl(href)),
      ),
    );
  }

  /// Approximates the rendered text of a user message for line measurement:
  /// a `file://` reference renders as a compact icon + name chip, so its raw
  /// percent-encoded URI must not count toward the collapsed-line budget.
  static String measurableText(String text) => text.replaceAllMapped(
    FileReferenceLink.pattern,
    (match) => '\u2003${FileReferenceLink.unescapeLabel(match.group(1) ?? '')}',
  );
}
