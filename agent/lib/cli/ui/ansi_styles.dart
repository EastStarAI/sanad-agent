/// ANSI escape codes and terminal styling utilities.
class Ansi {
  // Styles
  static const String reset = '\x1B[0m';
  static const String bold = '\x1B[1m';
  static const String dim = '\x1B[2m';
  static const String italic = '\x1B[3m';
  static const String underline = '\x1B[4m';
  static const String inverse = '\x1B[7m';
  static const String strikethrough = '\x1B[9m';

  // Foreground colors
  static const String black = '\x1B[30m';
  static const String red = '\x1B[31m';
  static const String green = '\x1B[32m';
  static const String yellow = '\x1B[33m';
  static const String blue = '\x1B[34m';
  static const String magenta = '\x1B[35m';
  static const String cyan = '\x1B[36m';
  static const String white = '\x1B[37m';
  static const String gray = '\x1B[90m';

  // Bright foreground colors
  static const String brightRed = '\x1B[91m';
  static const String brightGreen = '\x1B[92m';
  static const String brightYellow = '\x1B[93m';
  static const String brightBlue = '\x1B[94m';
  static const String brightMagenta = '\x1B[95m';
  static const String brightCyan = '\x1B[96m';
  static const String brightWhite = '\x1B[97m';

  // Background colors
  static const String bgBlack = '\x1B[40m';
  static const String bgRed = '\x1B[41m';
  static const String bgGreen = '\x1B[42m';
  static const String bgYellow = '\x1B[43m';
  static const String bgBlue = '\x1B[44m';
  static const String bgMagenta = '\x1B[45m';
  static const String bgCyan = '\x1B[46m';
  static const String bgWhite = '\x1B[47m';
  static const String bgGray = '\x1B[100m';

  // Terminal cursor and screen controls
  static const String clearLine = '\x1B[2K';
  static const String clearToEndOfLine = '\x1B[0K';
  static const String carriageReturn = '\r';
  static const String cursorUp = '\x1B[1A';
  static const String cursorDown = '\x1B[1B';
  static const String cursorForward = '\x1B[1C';
  static const String cursorBack = '\x1B[1D';
  static const String hideCursor = '\x1B[?25l';
  static const String showCursor = '\x1B[?25h';

  /// Moves cursor up [lines] rows.
  static String moveCursorUp(int lines) => lines > 0 ? '\x1B[${lines}A' : '';

  /// Moves cursor down [lines] rows.
  static String moveCursorDown(int lines) => lines > 0 ? '\x1B[${lines}B' : '';

  /// Moves cursor to beginning of the line [lines] up.
  static String cursorPreviousLine(int lines) =>
      lines > 0 ? '\x1B[${lines}F' : '';

  /// Regular expression to match any ANSI escape sequence.
  static final RegExp ansiRegex = RegExp(
    r'\x1B(?:[@-Z\\-_]|\[[0-?]*[ -/]*[@-~])',
  );

  /// Strips all ANSI escape sequences from [text].
  static String strip(String text) => text.replaceAll(ansiRegex, '');

  /// Returns visible length of [text] excluding ANSI escape sequences.
  static int visibleLength(String text) => strip(text).length;

  /// Wraps [text] in [style] and appends [reset] if [enabled] is true.
  static String wrap(String text, String style, {bool enabled = true}) {
    if (!enabled || text.isEmpty) return text;
    return '$style$text$reset';
  }
}
