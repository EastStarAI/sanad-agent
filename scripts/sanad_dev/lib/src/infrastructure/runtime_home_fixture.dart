import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'compiled_cli_cache.dart';
import 'path_equivalence.dart';
import 'secure_runtime_file.dart';

export 'runtime_home_restore.dart';

/// Version of the fixture manifest schema.
///
/// Version 2 records [HomeFixtureManifest.includeMcpConfig] because
/// `mcp_config.json` is opt-in: it can carry provider headers and environment
/// values that must never be copied into a worktree by default.
const sanadDevFixtureSchemaVersion = 2;

/// Fixture directory below the invoking worktree: `<worktree>/.sanad-dev/fixtures`.
const sanadDevFixturesDirectoryName = 'fixtures';

/// Prefix of the sibling staging directory used while a restore is in flight.
///
/// It is deliberately beside the Home, never inside it, so the Home never shows
/// a partially restored tree, and a crashed restore is detectable and
/// recoverable on the next run.
const fixtureRestoreStagingDirectoryName = '.sanad-dev-reset-staging';

/// Sibling staging directory that belongs to exactly one Home.
///
/// Every worktree Test Home lives under `<user home>/.sanad/dev/homes/`, so a
/// fixed staging name would be shared by all of them: crash recovery in one
/// worktree could move another Home's backed-up `state.db` into its own Home,
/// and two parallel resets would delete each other's in-flight backups. The name
/// therefore carries a readable Home label plus a digest of the Home's canonical
/// path, and is only ever used for that one Home.
String sanadDevFixtureStagingPath(String homePath) {
  final canonicalHome = canonicalComparablePath(homePath);
  final digest = sha256.convert(utf8.encode(canonicalHome)).toString();
  return p.join(
    p.dirname(canonicalHome),
    '$fixtureRestoreStagingDirectoryName-'
    '${_stagingHomeLabel(p.basename(canonicalHome))}-${digest.substring(0, 8)}',
  );
}

/// Filesystem-safe, bounded label for a Home directory name.
String _stagingHomeLabel(String homeName) {
  final sanitized = homeName
      .toLowerCase()
      .replaceAll(RegExp('[^a-z0-9._-]+'), '-')
      .replaceAll(RegExp('^-+|-+\$'), '');
  if (sanitized.isEmpty) return 'home';
  return sanitized.length <= 40 ? sanitized : sanitized.substring(0, 40);
}

/// True when [relativePath] belongs to the SQLite database family.
///
/// The comparison ignores case so a Home restored on a case-insensitive disk
/// keeps `state.db` and its `-wal`/`-shm` sidecars in one swap group instead of
/// splitting them into two groups that both move the same file.
bool isFixtureDatabaseFamilyPath(String relativePath) =>
    fixtureDatabaseFamily.contains(
      relativePath.replaceAll('\\', '/').toLowerCase(),
    );

/// Home-relative files a fixture captures.
///
/// These are the Agent's state database (plus SQLite sidecars) and the
/// non-secret configuration files that live directly in the Sanad Home.
const fixtureIncludedFiles = <String>[
  'state.db',
  'state.db-wal',
  'state.db-shm',
  'config.yaml',
  'models_dev_cache.json',
  'mcp_config.json',
];

/// Included files that are captured only on explicit request.
const fixtureOptInFiles = <String>['mcp_config.json'];

/// The SQLite database and its sidecars, which must always move together.
const fixtureDatabaseFamily = <String>['state.db', 'state.db-wal', 'state.db-shm'];

/// Home-relative directories a fixture captures recursively.
const fixtureIncludedDirectories = <String>['skills', 'memories', 'workspaces'];

/// Substrings that always exclude a path, even inside an included directory.
///
/// Fixtures are copied into a worktree that may be shared or published, so the
/// exclusion is a denylist of secret-bearing names applied on top of the
/// include allowlist: the local gateway credential, `.env` provider keys, the
/// credential JSON files, OS-vault material, and private keys.
const fixtureExcludedNameFragments = <String>[
  '.env',
  'token',
  'secret',
  'credential',
  'vault',
  'keyring',
  'password',
  'apikey',
  'api_key',
  'id_rsa',
  '.pem',
  '.p12',
  '.p8',
  '.keystore',
];

/// Directory names that are excluded at any depth.
///
/// `logs/` and `request_dumps/` can appear inside an included directory (for
/// example `workspaces/<id>/logs/`), so the exclusion cannot be a top-level
/// path check.
const fixtureExcludedDirectorySegments = <String>['logs', 'request_dumps'];

/// File-name prefixes that are excluded at any depth (`id_ed25519`, `id_rsa`).
const fixtureExcludedNamePrefixes = <String>['id_'];

/// File-name suffixes that are excluded at any depth.
const fixtureExcludedNameSuffixes = <String>[
  '.key',
  '.pem',
  '.p12',
  '.p8',
  '.netrc',
];

/// Home-relative paths that are never captured or replaced by a fixture.
///
/// They are runtime/ownership state (`dev/`), heavyweight content
/// (`logs/`, `media/`, `attachments/`, `sessions/`, `bin/`), or the excluded
/// secret files above. Restoring a fixture leaves every one of them untouched.
const fixtureExcludedPaths = <String>[
  'dev',
  'logs',
  'media',
  'attachments',
  'sessions',
  'bin',
  '.env',
  '.local_token',
  '.local_token.lock',
  'provider_secrets.json',
  'provider_auth.json',
  'mcp_secrets.json',
  'auth.json',
  'agent_credentials.json',
  'agent_credential_backend.json',
];

final RegExp _fixtureNamePattern = RegExp(r'^[a-z0-9][a-z0-9._-]{0,63}$');

bool isValidSanadDevFixtureName(String name) =>
    _fixtureNamePattern.hasMatch(name.trim());

String sanadDevFixtureRoot(String workspaceRoot) => p.join(
  workspaceRoot,
  compiledCliCacheDirectoryName,
  sanadDevFixturesDirectoryName,
);

String sanadDevFixturePath(String workspaceRoot, String name) =>
    p.join(sanadDevFixtureRoot(workspaceRoot), name);

class HomeFixtureEntry {
  const HomeFixtureEntry({
    required this.relativePath,
    required this.size,
    required this.sha256,
  });

  final String relativePath;
  final int size;
  final String sha256;

  Map<String, Object?> toJson() => {
    'path': relativePath,
    'size': size,
    'sha256': sha256,
  };

  static HomeFixtureEntry fromJson(Map<String, dynamic> json) =>
      HomeFixtureEntry(
        relativePath: json['path']?.toString() ?? '',
        size: json['size'] is int ? json['size'] as int : -1,
        sha256: json['sha256']?.toString() ?? '',
      );
}

class HomeFixtureManifest {
  const HomeFixtureManifest({
    required this.name,
    required this.createdAt,
    required this.sourceHome,
    required this.entries,
    this.includeMcpConfig = false,
  });

  final String name;
  final DateTime createdAt;
  final String sourceHome;
  final List<HomeFixtureEntry> entries;

  /// Whether this fixture captured `mcp_config.json`.
  final bool includeMcpConfig;

  Map<String, Object?> toJson() => {
    'schema_version': sanadDevFixtureSchemaVersion,
    'name': name,
    'created_at': createdAt.toUtc().toIso8601String(),
    'source_home': sourceHome,
    'include_mcp_config': includeMcpConfig,
    'entries': entries.map((entry) => entry.toJson()).toList(),
  };

  static HomeFixtureManifest fromJson(Map<String, dynamic> json) {
    if (json['schema_version'] != sanadDevFixtureSchemaVersion) {
      throw const FormatException('Unsupported Sanad fixture schema version.');
    }
    final rawEntries = json['entries'];
    if (rawEntries is! List) {
      throw const FormatException('Sanad fixture entries must be a list.');
    }
    return HomeFixtureManifest(
      name: json['name']?.toString() ?? '',
      createdAt:
          DateTime.tryParse(json['created_at']?.toString() ?? '') ??
          DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
      sourceHome: json['source_home']?.toString() ?? '',
      includeMcpConfig: json['include_mcp_config'] == true,
      entries: rawEntries
          .whereType<Map>()
          .map(
            (entry) =>
                HomeFixtureEntry.fromJson(Map<String, dynamic>.from(entry)),
          )
          .toList(growable: false),
    );
  }
}

class HomeFixtureRestoreReport {
  const HomeFixtureRestoreReport({
    required this.restoredFiles,
    required this.removedFiles,
    required this.preservedPaths,
  });

  final int restoredFiles;
  final int removedFiles;
  final List<String> preservedPaths;
}

/// True when [relativePath] is captured by the include allowlist and is not
/// excluded as secret-bearing.
///
/// Every comparison is case-insensitive, so a Home captured or restored on a
/// case-insensitive macOS or Windows disk classifies `.ENV`, `State.DB`, or
/// `MEMORIES/notes.md` exactly like its lowercase spelling instead of letting a
/// spelling variant slip past the denylist.
///
/// [includeMcpConfig] enables the `mcp_config.json` opt-in; every other rule is
/// independent of it.
bool isFixtureCapturedPath(
  String relativePath, {
  bool includeMcpConfig = false,
}) {
  final normalized = relativePath.replaceAll('\\', '/');
  final segments = normalized.split('/').where((part) => part.isNotEmpty);
  if (segments.isEmpty) return false;
  final lowerSegments = segments.map((part) => part.toLowerCase()).toList();
  for (final fragment in fixtureExcludedNameFragments) {
    if (lowerSegments.any((segment) => segment.contains(fragment))) {
      return false;
    }
  }
  for (final excluded in fixtureExcludedDirectorySegments) {
    if (lowerSegments.any((segment) => segment == excluded)) return false;
  }
  for (final segment in lowerSegments) {
    if (fixtureExcludedNamePrefixes.any(segment.startsWith)) return false;
    if (fixtureExcludedNameSuffixes.any(segment.endsWith)) return false;
  }
  final head = lowerSegments.first;
  if (_fixtureExcludedPathsLower.contains(head)) return false;
  if (segments.length == 1) {
    if (fixtureOptInFiles.contains(head)) return includeMcpConfig;
    return _fixtureIncludedFilesLower.contains(head);
  }
  return _fixtureIncludedDirectoriesLower.contains(head);
}

/// Lowercase forms of the path allowlist and denylist.
///
/// Comparing against these sets is what makes a Home classification independent
/// of the host's casing rules.
final Set<String> _fixtureExcludedPathsLower = {
  for (final path in fixtureExcludedPaths) path.toLowerCase(),
};
final Set<String> _fixtureIncludedFilesLower = {
  for (final path in fixtureIncludedFiles) path.toLowerCase(),
};
final Set<String> _fixtureIncludedDirectoriesLower = {
  for (final path in fixtureIncludedDirectories) path.toLowerCase(),
};

/// Lists every Home-relative path currently captured by a fixture.
///
/// Symbolic links are skipped: a fixture never follows a link out of the Home.
List<String> listFixtureSourcePaths(
  String homePath, {
  bool includeMcpConfig = false,
}) {
  final home = Directory(homePath);
  if (!home.existsSync()) return const [];
  final collected = <String>[];
  for (final name in fixtureIncludedFiles) {
    final file = File(p.join(home.path, name));
    if (!file.existsSync()) continue;
    if (FileSystemEntity.typeSync(file.path, followLinks: false) !=
        FileSystemEntityType.file) {
      continue;
    }
    if (!isFixtureCapturedPath(name, includeMcpConfig: includeMcpConfig)) {
      continue;
    }
    collected.add(name);
  }
  for (final name in fixtureIncludedDirectories) {
    final directory = Directory(p.join(home.path, name));
    if (!directory.existsSync()) continue;
    if (FileSystemEntity.typeSync(directory.path, followLinks: false) !=
        FileSystemEntityType.directory) {
      continue;
    }
    for (final entity in directory.listSync(
      recursive: true,
      followLinks: false,
    )) {
      if (entity is! File) continue;
      if (FileSystemEntity.typeSync(entity.path, followLinks: false) !=
          FileSystemEntityType.file) {
        continue;
      }
      final relative = p.relative(entity.path, from: home.path);
      if (!isFixtureCapturedPath(relative, includeMcpConfig: includeMcpConfig)) {
        continue;
      }
      collected.add(relative.replaceAll('\\', '/'));
    }
  }
  collected.sort();
  return collected;
}

/// Snapshots [homePath] into `<workspaceRoot>/.sanad-dev/fixtures/<name>/`.
///
/// The fixture replaces any previous fixture with the same name and is written
/// through a staging directory so an interrupted save never leaves a partially
/// written fixture in place. Every fixture file is owner-only (`0600`) and
/// every fixture directory is `0700`.
Future<HomeFixtureManifest> saveHomeFixture({
  required String workspaceRoot,
  required String homePath,
  required String name,
  bool includeMcpConfig = false,
}) async {
  if (!isValidSanadDevFixtureName(name)) {
    throw FormatException(
      'Invalid fixture name "$name": use lowercase letters, digits, ".", "_" '
      'or "-" (max 64 characters).',
    );
  }
  final home = Directory(homePath);
  if (!home.existsSync()) {
    throw StateError('The Sanad Home does not exist: $homePath');
  }
  final relativePaths = listFixtureSourcePaths(
    homePath,
    includeMcpConfig: includeMcpConfig,
  );
  final destination = Directory(sanadDevFixturePath(workspaceRoot, name));
  final staging = Directory('${destination.path}.building');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  await sanadDevCreateOwnerOnlyDirectory(staging.path);
  await sanadDevCreateOwnerOnlyDirectory(p.dirname(staging.path));

  final entries = <HomeFixtureEntry>[];
  for (final relative in relativePaths) {
    final source = File(p.join(home.path, relative));
    final bytes = source.readAsBytesSync();
    final target = File(p.join(staging.path, relative));
    Directory(target.parent.path).createSync(recursive: true);
    target.writeAsBytesSync(bytes, flush: true);
    await sanadDevRestrictOwnerOnly(target.path);
    entries.add(
      HomeFixtureEntry(
        relativePath: relative,
        size: bytes.length,
        sha256: sha256.convert(bytes).toString(),
      ),
    );
  }
  final manifest = HomeFixtureManifest(
    name: name,
    createdAt: DateTime.now().toUtc(),
    sourceHome: home.resolveSymbolicLinksSync(),
    includeMcpConfig: includeMcpConfig,
    entries: entries,
  );
  final manifestFile = File(p.join(staging.path, 'fixture.json'));
  manifestFile.writeAsStringSync(
    '${jsonEncode(manifest.toJson())}\n',
    flush: true,
  );
  await sanadDevRestrictOwnerOnly(manifestFile.path);
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  staging.renameSync(destination.path);
  return manifest;
}

/// Applies an owner-only directory mode, creating the directory when missing.
///
/// Shared by fixture capture and restore: a fixture may be published or shared,
/// so it never inherits a permissive default mode.
Future<void> sanadDevCreateOwnerOnlyDirectory(String path) async {
  final directory = Directory(path);
  if (!directory.existsSync()) directory.createSync(recursive: true);
  await sanadDevRestrictOwnerOnly(path, directory: true);
}

/// Applies the owner-only file mode (0600) to [path], best effort.
Future<void> sanadDevRestrictOwnerOnly(
  String path, {
  bool directory = false,
}) async {
  try {
    await restrictRuntimePath(path, directory: directory);
  } on Object {
    // Permission hardening is best effort on filesystems without POSIX modes;
    // the capture rules remain the security boundary for content.
  }
}

Future<HomeFixtureManifest> readHomeFixtureManifest({
  required String workspaceRoot,
  required String name,
}) async {
  final file = File(
    p.join(sanadDevFixturePath(workspaceRoot, name), 'fixture.json'),
  );
  if (!file.existsSync()) {
    throw StateError('Unknown Sanad fixture "$name" for this worktree.');
  }
  final decoded = jsonDecode(await file.readAsString());
  if (decoded is! Map) {
    throw const FormatException('Sanad fixture manifest must be an object.');
  }
  return HomeFixtureManifest.fromJson(Map<String, dynamic>.from(decoded));
}

