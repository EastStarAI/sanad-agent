/// Platform-stable canonicalization shared by the repository code generators.
///
/// Git for Windows checks text files out with `CRLF` unless the repository
/// pins the line ending, so a generated file or an embedded asset could
/// otherwise differ per platform: `--check` would report a clean Windows
/// checkout as stale, and a Windows release binary would embed `CRLF` skill
/// content while the committed hashes describe `LF` content. `.gitattributes`
/// pins `eol=lf` for those paths, and these helpers keep the tooling itself
/// correct even when a working tree predates that pin.
library;

import 'dart:convert';

const _crlf = '\r\n';
const _lf = '\n';

/// [text] with every `CRLF` sequence collapsed to `LF`.
///
/// A lone `CR` is left untouched: it is authored content, not a checkout
/// artifact.
String canonicalLineEndings(String text) =>
    text.contains(_crlf) ? text.replaceAll(_crlf, _lf) : text;

/// Whether [onDisk] still matches [rendered] apart from checkout line endings.
///
/// A pure line-ending difference is not staleness: Git stores both forms as the
/// same blob, and the generator always renders `LF`.
bool generatedSourceMatches({
  required String onDisk,
  required String rendered,
}) => canonicalLineEndings(onDisk) == canonicalLineEndings(rendered);

/// Canonical bytes for content that is embedded into the Agent executable.
///
/// Text that decodes as UTF-8 without NUL bytes is normalized to `LF` so the
/// embedded bundle is byte-identical on every platform. Anything else is
/// returned untouched, so a future binary asset is never rewritten.
List<int> canonicalContentBytes(List<int> bytes) {
  if (bytes.contains(0)) return bytes;
  final String text;
  try {
    text = utf8.decode(bytes);
  } on FormatException {
    return bytes;
  }
  if (!text.contains(_crlf)) return bytes;
  return utf8.encode(canonicalLineEndings(text));
}
