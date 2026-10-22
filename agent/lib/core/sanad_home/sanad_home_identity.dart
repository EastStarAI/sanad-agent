import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

/// Stable, non-secret identity of one Sanad Home root.
///
/// The runtime record of a Home, the daemon's `/health` payload and the local
/// gateway credential binding all derive this value from the same canonical
/// path, so a caller can prove that an answering daemon serves the Home it
/// selected without transmitting or logging the path itself.
///
/// The value is a truncated SHA-256 of [canonicalSanadHomePath], which is
/// stable across processes, restarts and release upgrades, and distinct for
/// every Home root.
String sanadHomeIdentity(String homePath) {
  final digest = sha256.convert(utf8.encode(canonicalSanadHomePath(homePath)));
  return digest.toString().substring(0, 16);
}

/// Canonical form of [homePath] that every process uses for identity
/// derivation.
///
/// A root that already exists is resolved through its symbolic links so that
/// `/var/...` and `/private/var/...` (or any other aliased spelling) produce
/// one identity. Before the first creation the normalized absolute path is
/// still a stable input.
String canonicalSanadHomePath(String homePath) {
  final absolute = p.normalize(p.absolute(homePath));
  try {
    if (FileSystemEntity.typeSync(absolute, followLinks: false) ==
        FileSystemEntityType.directory) {
      return p.normalize(Directory(absolute).resolveSymbolicLinksSync());
    }
  } on FileSystemException {
    // An unresolvable path keeps its normalized spelling; identity remains
    // deterministic for every caller that sees the same path.
  }
  return absolute;
}
