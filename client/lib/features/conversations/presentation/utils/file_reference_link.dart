/// One owner for the composer's file-reference Markdown form
/// `[<file name>](file:///<percent-encoded absolute path>)`.
///
/// The composer exports file tokens through [format], restores drafts through
/// [parse], and the user-message renderer measures through [pattern], so the
/// three surfaces can never disagree about what a file reference looks like.
abstract final class FileReferenceLink {
  /// Matches one exported reference. The label allows backslash escapes and
  /// the destination allows one level of balanced parentheses, so links
  /// written by older clients (unescaped `(`/`)` in the path) still match.
  static final RegExp pattern = RegExp(
    r'\[((?:\\.|[^\]\\])*)\]\(\s*<?(file:(?:[^()\s>]|\([^()\s]*\))*)>?\s*\)',
    caseSensitive: false,
  );

  /// Builds the Markdown link for [path] labelled with [fileName].
  ///
  /// `Uri.file` leaves `(` and `)` unencoded; they are percent-encoded here so
  /// an unbalanced parenthesis in a path cannot terminate the link early.
  /// Brackets and backslashes in the label are escaped for the same reason.
  static String format({required String fileName, required String path}) {
    final destination = Uri.file(path).toString().replaceAll('(', '%28').replaceAll(')', '%29');
    return '[${escapeLabel(fileName)}]($destination)';
  }

  /// Escapes Markdown-significant label characters.
  static String escapeLabel(String label) => label.replaceAllMapped(RegExp(r'[\\\[\]]'), (m) => '\\${m[0]}');

  /// Reverses [escapeLabel].
  static String unescapeLabel(String label) => label.replaceAllMapped(RegExp(r'\\(.)'), (m) => m[1]!);

  /// Parses one [pattern] match into its display name and absolute path, or
  /// null when the destination is not a valid `file` URI.
  static ({String fileName, String path})? parse(RegExpMatch match) {
    final label = match.group(1);
    final destination = match.group(2);
    if (label == null || destination == null) return null;
    final uri = Uri.tryParse(destination);
    if (uri == null || !uri.isScheme('file')) return null;
    try {
      final name = unescapeLabel(label).trim();
      return (fileName: name.isEmpty ? 'file' : name, path: uri.toFilePath());
    } catch (_) {
      return null;
    }
  }
}
