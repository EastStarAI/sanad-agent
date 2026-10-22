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
/// A path that exists is resolved through its symbolic links, so
/// `/var/...` and `/private/var/...` (or any other aliased spelling) produce
/// one identity; this is the same resolution `SanadHomeBootstrap.canonicalRoot`
/// applies after it expands the configured root. Before the first creation the
/// normalized absolute path is still a stable input.
///
/// A leading `~` is expanded first, through the same [expandLeadingTilde]
/// helper as `SanadHomeBootstrap`, so a literal `~/...` `SANAD_HOME` (or
/// `--home`) names the same Home as the expanded spelling. An unexpandable `~`
/// keeps its literal spelling, which fails closed: the caller then sees an
/// identity that no daemon reports.
String canonicalSanadHomePath(String homePath) {
  final expanded = expandLeadingTilde(homePath) ?? homePath;
  final absolute = p.normalize(p.absolute(expanded));
  try {
    final type = FileSystemEntity.typeSync(absolute, followLinks: false);
    if (type != FileSystemEntityType.notFound) {
      return p.normalize(
        type == FileSystemEntityType.directory
            ? Directory(absolute).resolveSymbolicLinksSync()
            : File(absolute).resolveSymbolicLinksSync(),
      );
    }
  } on FileSystemException {
    // An unresolvable path keeps its normalized spelling; identity remains
    // deterministic for every caller that sees the same path.
  }
  return absolute;
}

/// Expands a leading `~` or `~/` to the current user's home directory.
///
/// Returns [value] unchanged when it has no leading `~`, and null when it has
/// one but the user home cannot be resolved. `SanadHomeBootstrap` turns null
/// into its `home_environment_missing` violation; identity derivation does not
/// throw, so a health payload can never fail to report because of it.
///
/// [environment] lets a caller that carries an injected environment (CLI
/// discovery) expand against that environment; it defaults to the process
/// environment.
///
/// The `~/` prefix is removed before joining: `path.join` treats a later
/// absolute segment as authoritative, so joining `~/.x` without dropping the
/// separator would silently produce `/.x`.
String? expandLeadingTilde(String value, {Map<String, String>? environment}) {
  if (!value.startsWith('~')) return value;
  // `~name/...` is another user's home and is not expanded here.
  if (value != '~' && !value.startsWith('~/')) return value;
  final env = environment ?? Platform.environment;
  final userHome = env['HOME'] ?? env['USERPROFILE'];
  if (userHome == null || userHome.isEmpty) return null;
  if (value == '~') return userHome;
  return p.join(userHome, value.substring(2));
}
