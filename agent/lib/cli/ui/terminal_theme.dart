import 'ansi_styles.dart';

/// Palette style presets for terminal UI rendering.
enum TerminalPalette { dark, light, plain }

/// Color and style definitions used by Markdown and terminal components.
class TerminalTheme {
  final TerminalPalette palette;
  final bool enableColor;

  // General text styles
  final String normal;
  final String bold;
  final String italic;
  final String dim;
  final String strikethrough;

  // Header styles
  final String h1;
  final String h2;
  final String h3;
  final String h4;
  final String h5;
  final String h6;

  // Block elements
  final String blockquoteBorder;
  final String blockquoteText;
  final String horizontalRule;

  // Lists
  final String bullet;
  final String listNumber;

  // Links & Code
  final String linkText;
  final String linkUrl;
  final String inlineCode;
  final String codeBlockBorder;
  final String codeBlockHeader;
  final String codeBlockText;

  // Syntax highlighting
  final String syntaxKeyword;
  final String syntaxString;
  final String syntaxNumber;
  final String syntaxComment;
  final String syntaxType;
  final String syntaxPunctuation;

  // Tables
  final String tableBorder;
  final String tableHeader;
  final String tableCell;

  // Tool status
  final String toolCalling;
  final String toolSuccess;
  final String toolError;
  final String toolCancelled;
  final String toolSpinner;
  final String toolTimer;

  // Reasoning / Thinking box
  final String reasoningBorder;
  final String reasoningTitle;
  final String reasoningText;
  final String reasoningSummary;

  // Status & notices
  final String info;
  final String success;
  final String warning;
  final String error;

  const TerminalTheme({
    required this.palette,
    this.enableColor = true,
    required this.normal,
    required this.bold,
    required this.italic,
    required this.dim,
    required this.strikethrough,
    required this.h1,
    required this.h2,
    required this.h3,
    required this.h4,
    required this.h5,
    required this.h6,
    required this.blockquoteBorder,
    required this.blockquoteText,
    required this.horizontalRule,
    required this.bullet,
    required this.listNumber,
    required this.linkText,
    required this.linkUrl,
    required this.inlineCode,
    required this.codeBlockBorder,
    required this.codeBlockHeader,
    required this.codeBlockText,
    required this.syntaxKeyword,
    required this.syntaxString,
    required this.syntaxNumber,
    required this.syntaxComment,
    required this.syntaxType,
    required this.syntaxPunctuation,
    required this.tableBorder,
    required this.tableHeader,
    required this.tableCell,
    required this.toolCalling,
    required this.toolSuccess,
    required this.toolError,
    required this.toolCancelled,
    required this.toolSpinner,
    required this.toolTimer,
    required this.reasoningBorder,
    required this.reasoningTitle,
    required this.reasoningText,
    required this.reasoningSummary,
    required this.info,
    required this.success,
    required this.warning,
    required this.error,
  });

  /// Dark theme optimized for modern dark terminal emulators.
  factory TerminalTheme.dark({bool enableColor = true}) {
    if (!enableColor) return TerminalTheme.plain();
    return const TerminalTheme(
      palette: TerminalPalette.dark,
      enableColor: true,
      normal: Ansi.reset,
      bold: Ansi.bold,
      italic: Ansi.italic,
      dim: Ansi.dim,
      strikethrough: Ansi.strikethrough,
      h1: '${Ansi.bold}${Ansi.brightCyan}',
      h2: '${Ansi.bold}${Ansi.brightBlue}',
      h3: '${Ansi.bold}${Ansi.brightYellow}',
      h4: '${Ansi.bold}${Ansi.brightMagenta}',
      h5: '${Ansi.bold}${Ansi.cyan}',
      h6: '${Ansi.bold}${Ansi.gray}',
      blockquoteBorder: Ansi.brightCyan,
      blockquoteText: Ansi.dim,
      horizontalRule: Ansi.gray,
      bullet: Ansi.brightCyan,
      listNumber: Ansi.cyan,
      linkText: '${Ansi.underline}${Ansi.brightBlue}',
      linkUrl: Ansi.dim,
      inlineCode: '${Ansi.brightYellow}${Ansi.bgBlack}',
      codeBlockBorder: Ansi.gray,
      codeBlockHeader: '${Ansi.bold}${Ansi.brightYellow}',
      codeBlockText: Ansi.white,
      syntaxKeyword: '${Ansi.bold}${Ansi.brightMagenta}',
      syntaxString: Ansi.brightGreen,
      syntaxNumber: Ansi.brightYellow,
      syntaxComment: '${Ansi.dim}${Ansi.gray}',
      syntaxType: Ansi.brightCyan,
      syntaxPunctuation: Ansi.white,
      tableBorder: Ansi.gray,
      tableHeader: '${Ansi.bold}${Ansi.brightCyan}',
      tableCell: Ansi.white,
      toolCalling: Ansi.brightYellow,
      toolSuccess: Ansi.brightGreen,
      toolError: Ansi.brightRed,
      toolCancelled: Ansi.gray,
      toolSpinner: Ansi.brightCyan,
      toolTimer: Ansi.dim,
      reasoningBorder: Ansi.brightMagenta,
      reasoningTitle: '${Ansi.bold}${Ansi.brightMagenta}',
      reasoningText: Ansi.dim,
      reasoningSummary: '${Ansi.italic}${Ansi.brightMagenta}',
      info: Ansi.brightCyan,
      success: Ansi.brightGreen,
      warning: Ansi.brightYellow,
      error: Ansi.brightRed,
    );
  }

  /// Light theme optimized for white/light terminal backgrounds.
  factory TerminalTheme.light({bool enableColor = true}) {
    if (!enableColor) return TerminalTheme.plain();
    return const TerminalTheme(
      palette: TerminalPalette.light,
      enableColor: true,
      normal: Ansi.reset,
      bold: Ansi.bold,
      italic: Ansi.italic,
      dim: Ansi.dim,
      strikethrough: Ansi.strikethrough,
      h1: '${Ansi.bold}${Ansi.blue}',
      h2: '${Ansi.bold}${Ansi.cyan}',
      h3: '${Ansi.bold}${Ansi.magenta}',
      h4: '${Ansi.bold}${Ansi.black}',
      h5: '${Ansi.bold}${Ansi.blue}',
      h6: '${Ansi.bold}${Ansi.dim}',
      blockquoteBorder: Ansi.blue,
      blockquoteText: Ansi.dim,
      horizontalRule: Ansi.dim,
      bullet: Ansi.blue,
      listNumber: Ansi.blue,
      linkText: '${Ansi.underline}${Ansi.blue}',
      linkUrl: Ansi.dim,
      inlineCode: '${Ansi.magenta}${Ansi.bold}',
      codeBlockBorder: Ansi.dim,
      codeBlockHeader: '${Ansi.bold}${Ansi.blue}',
      codeBlockText: Ansi.black,
      syntaxKeyword: '${Ansi.bold}${Ansi.magenta}',
      syntaxString: Ansi.green,
      syntaxNumber: Ansi.yellow,
      syntaxComment: '${Ansi.dim}${Ansi.italic}',
      syntaxType: Ansi.blue,
      syntaxPunctuation: Ansi.black,
      tableBorder: Ansi.dim,
      tableHeader: '${Ansi.bold}${Ansi.blue}',
      tableCell: Ansi.black,
      toolCalling: Ansi.yellow,
      toolSuccess: Ansi.green,
      toolError: Ansi.red,
      toolCancelled: Ansi.dim,
      toolSpinner: Ansi.blue,
      toolTimer: Ansi.dim,
      reasoningBorder: Ansi.magenta,
      reasoningTitle: '${Ansi.bold}${Ansi.magenta}',
      reasoningText: Ansi.dim,
      reasoningSummary: '${Ansi.italic}${Ansi.magenta}',
      info: Ansi.blue,
      success: Ansi.green,
      warning: Ansi.yellow,
      error: Ansi.red,
    );
  }

  /// Plain theme with zero ANSI escape codes (for non-TTY, pipes, or NO_COLOR).
  factory TerminalTheme.plain() {
    return const TerminalTheme(
      palette: TerminalPalette.plain,
      enableColor: false,
      normal: '',
      bold: '',
      italic: '',
      dim: '',
      strikethrough: '',
      h1: '',
      h2: '',
      h3: '',
      h4: '',
      h5: '',
      h6: '',
      blockquoteBorder: '',
      blockquoteText: '',
      horizontalRule: '',
      bullet: '',
      listNumber: '',
      linkText: '',
      linkUrl: '',
      inlineCode: '',
      codeBlockBorder: '',
      codeBlockHeader: '',
      codeBlockText: '',
      syntaxKeyword: '',
      syntaxString: '',
      syntaxNumber: '',
      syntaxComment: '',
      syntaxType: '',
      syntaxPunctuation: '',
      tableBorder: '',
      tableHeader: '',
      tableCell: '',
      toolCalling: '',
      toolSuccess: '',
      toolError: '',
      toolCancelled: '',
      toolSpinner: '',
      toolTimer: '',
      reasoningBorder: '',
      reasoningTitle: '',
      reasoningText: '',
      reasoningSummary: '',
      info: '',
      success: '',
      warning: '',
      error: '',
    );
  }

  /// Helper to style [text] with [style], appending reset if color is enabled.
  String style(String text, String styleCode) {
    if (!enableColor || styleCode.isEmpty || text.isEmpty) return text;
    return '$styleCode$text${Ansi.reset}';
  }
}
