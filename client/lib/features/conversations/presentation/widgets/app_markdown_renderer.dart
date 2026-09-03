import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:sanad_client/features/conversations/presentation/widgets/markdown_style_helper.dart';

/// Application-owned Markdown boundary for progressive and completed text.
///
/// Both states deliberately use the final-answer [MarkdownBody] with one style,
/// builder, directionality, and link-handling path.
class AppMarkdownRenderer extends StatelessWidget {
  final String data;
  final bool isFinal;
  final void Function(String text, String? href, String title)? onTapLink;
  final Map<String, MarkdownElementBuilder>? builders;

  const AppMarkdownRenderer({
    super.key,
    required this.data,
    required this.isFinal,
    this.onTapLink,
    this.builders,
  });

  @override
  Widget build(BuildContext context) {
    final markdownStyle = MarkdownStyleHelper.getStyleSheet(
      context,
      isFinal: isFinal,
    );
    return MarkdownBody(
      data: data,
      styleSheet: markdownStyle,
      onTapLink: onTapLink,
      builders: builders ?? {'code': AppInlineCodeBuilder(context)},
    );
  }
}
