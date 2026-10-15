import 'dart:io';

import 'package:path/path.dart' as p;

/// Returns a host-canonical path suitable for stable identity comparisons.
String canonicalComparablePath(String path) {
  final lexical = p.canonicalize(p.absolute(_stripWindowsDevicePrefix(path)));
  try {
    return p.canonicalize(
      _stripWindowsDevicePrefix(Directory(lexical).resolveSymbolicLinksSync()),
    );
  } catch (_) {
    return lexical;
  }
}

/// Compares path identities using host casing and separator semantics.
///
/// The lexical check avoids filesystem access for already-equivalent paths,
/// including non-existent drive, UNC, Unicode, and spaced fixture paths.
bool equivalentPaths(String? first, String second) {
  if (first == null) return false;
  final firstLexical = p.canonicalize(
    p.absolute(_stripWindowsDevicePrefix(first)),
  );
  final secondLexical = p.canonicalize(
    p.absolute(_stripWindowsDevicePrefix(second)),
  );
  if (p.equals(firstLexical, secondLexical)) return true;
  if (!p.equals(p.rootPrefix(firstLexical), p.rootPrefix(secondLexical))) {
    return false;
  }
  return p.equals(
    canonicalComparablePath(firstLexical),
    canonicalComparablePath(secondLexical),
  );
}

String _stripWindowsDevicePrefix(String path) {
  if (!Platform.isWindows) return path;
  final lower = path.toLowerCase();
  const devicePrefix = r'\\?\';
  const uncDevicePrefix = r'\\?\unc\';
  if (lower.startsWith(uncDevicePrefix)) {
    return r'\\' + path.substring(uncDevicePrefix.length);
  }
  if (lower.startsWith(devicePrefix)) {
    return path.substring(devicePrefix.length);
  }
  return path;
}
