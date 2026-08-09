import 'package:flutter/material.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:flutter_streaming_text_markdown/flutter_streaming_text_markdown.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';

/// Application-owned Markdown boundary for both progressive and completed text.
///
/// Keeping the package choice here prevents conversation widgets from depending
/// on either renderer directly and makes fallback a one-line configuration
/// change if the streaming package proves unsuitable.
class AppMarkdownRenderer extends StatelessWidget {
  static const bool enableStreamingRenderer = true;

  final String data;
  final bool isFinal;
  final void Function(String text, String? href, String title)? onTapLink;
  final Map<String, MarkdownElementBuilder>? builders;
  final bool isStreaming;

  const AppMarkdownRenderer({
    super.key,
    required this.data,
    required this.isFinal,
    this.onTapLink,
    this.builders,
    this.isStreaming = false,
  });

  @override
  Widget build(BuildContext context) {
    final markdownStyle = MarkdownStyleHelper.getStyleSheet(
      context,
      isFinal: isFinal,
    );
    if (enableStreamingRenderer && isStreaming) {
      return StreamingTextMarkdown(
        text: data,
        markdownEnabled: true,
        animationsEnabled: false,
        fadeInEnabled: false,
        typingSpeed: Duration.zero,
        autoScroll: false,
        completeAnimationOnTap: false,
        textDirection: Directionality.of(context),
        styleSheet: markdownStyle.p,
        onLinkTap: (url, title) => onTapLink?.call(url, url, title),
      );
    }

    return MarkdownBody(
      data: data,
      styleSheet: markdownStyle,
      onTapLink: onTapLink,
      builders: builders ?? {'code': AppInlineCodeBuilder(context)},
    );
  }
}
