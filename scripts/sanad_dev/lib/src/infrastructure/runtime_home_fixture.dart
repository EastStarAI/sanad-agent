import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

import 'compiled_cli_cache.dart';
import 'secure_runtime_file.dart';

/// Version of the fixture manifest schema.
const sanadDevFixtureSchemaVersion = 1;

/// Fixture directory below the invoking worktree: `<worktree>/.sanad-dev/fixtures`.
const sanadDevFixturesDirectoryName = 'fixtures';

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
  });

  final String name;
  final DateTime createdAt;
  final String sourceHome;
  final List<HomeFixtureEntry> entries;

  Map<String, Object?> toJson() => {
    'schema_version': sanadDevFixtureSchemaVersion,
    'name': name,
    'created_at': createdAt.toUtc().toIso8601String(),
    'source_home': sourceHome,
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
bool isFixtureCapturedPath(String relativePath) {
  final normalized = relativePath.replaceAll('\\', '/');
  final segments = normalized.split('/').where((part) => part.isNotEmpty);
  if (segments.isEmpty) return false;
  final lowerSegments = segments.map((part) => part.toLowerCase()).toList();
  for (final fragment in fixtureExcludedNameFragments) {
    if (lowerSegments.any((segment) => segment.contains(fragment)))
      return false;
  }
  final head = lowerSegments.first;
  if (fixtureExcludedPaths.map((path) => path.toLowerCase()).contains(head)) {
    return false;
  }
  if (segments.length == 1) {
    return fixtureIncludedFiles
        .map((path) => path.toLowerCase())
        .contains(head);
  }
  return fixtureIncludedDirectories
      .map((path) => path.toLowerCase())
      .contains(head);
}

/// Lists every Home-relative path currently captured by a fixture.
///
/// Symbolic links are skipped: a fixture never follows a link out of the Home.
List<String> listFixtureSourcePaths(String homePath) {
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
    if (!isFixtureCapturedPath(name)) continue;
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
      if (!isFixtureCapturedPath(relative)) continue;
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
/// written fixture in place.
Future<HomeFixtureManifest> saveHomeFixture({
  required String workspaceRoot,
  required String homePath,
  required String name,
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
  final relativePaths = listFixtureSourcePaths(homePath);
  final destination = Directory(sanadDevFixturePath(workspaceRoot, name));
  final staging = Directory('${destination.path}.building');
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);

  final entries = <HomeFixtureEntry>[];
  for (final relative in relativePaths) {
    final source = File(p.join(home.path, relative));
    final bytes = source.readAsBytesSync();
    final target = File(p.join(staging.path, relative));
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(bytes, flush: true);
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
    entries: entries,
  );
  File(
    p.join(staging.path, 'fixture.json'),
  ).writeAsStringSync('${jsonEncode(manifest.toJson())}\n', flush: true);
  if (destination.existsSync()) destination.deleteSync(recursive: true);
  staging.renameSync(destination.path);
  return manifest;
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

/// Restores a saved fixture into [homePath].
///
/// Every captured file is staged inside the Home first and then moved into
/// place with a same-filesystem rename, so no destination file is ever
/// half-written. Captured files that the fixture does not contain are removed
/// so the restored state matches the fixture; every path outside the captured
/// set (secrets, journals, logs, media, `dev/`) is preserved untouched.
Future<HomeFixtureRestoreReport> restoreHomeFixture({
  required String workspaceRoot,
  required String homePath,
  required String name,
}) async {
  final manifest = await readHomeFixtureManifest(
    workspaceRoot: workspaceRoot,
    name: name,
  );
  final home = Directory(homePath);
  if (!home.existsSync()) {
    throw StateError('The Sanad Home does not exist: $homePath');
  }
  final fixtureRoot = Directory(sanadDevFixturePath(workspaceRoot, name));
  final stagingPath = p.join(home.path, '.sanad-dev-reset-staging');
  final staging = Directory(stagingPath);
  await secureRuntimeDirectory(home.path, stagingPath);
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  staging.createSync(recursive: true);

  for (final entry in manifest.entries) {
    final source = File(p.join(fixtureRoot.path, entry.relativePath));
    if (!source.existsSync()) {
      throw StateError(
        'Sanad fixture "$name" is incomplete: ${entry.relativePath} is missing.',
      );
    }
    final bytes = source.readAsBytesSync();
    if (entry.size != bytes.length ||
        sha256.convert(bytes).toString() != entry.sha256) {
      throw StateError(
        'Sanad fixture "$name" is corrupt: ${entry.relativePath} does not '
        'match its manifest.',
      );
    }
    final target = File(p.join(stagingPath, entry.relativePath));
    target.parent.createSync(recursive: true);
    target.writeAsBytesSync(bytes, flush: true);
  }

  final manifestPaths = manifest.entries
      .map((entry) => entry.relativePath.replaceAll('\\', '/'))
      .toSet();
  var removed = 0;
  for (final relative in listFixtureSourcePaths(homePath)) {
    if (manifestPaths.contains(relative)) continue;
    final file = File(p.join(home.path, relative));
    if (file.existsSync()) {
      file.deleteSync();
      removed++;
    }
  }
  var restored = 0;
  for (final entry in manifest.entries) {
    final source = File(p.join(stagingPath, entry.relativePath));
    final target = File(p.join(home.path, entry.relativePath));
    target.parent.createSync(recursive: true);
    if (target.existsSync()) target.deleteSync();
    source.renameSync(target.path);
    restored++;
  }
  if (staging.existsSync()) staging.deleteSync(recursive: true);
  _removeEmptyIncludedDirectories(homePath);
  return HomeFixtureRestoreReport(
    restoredFiles: restored,
    removedFiles: removed,
    preservedPaths: fixtureExcludedPaths.toList(growable: false),
  );
}

void _removeEmptyIncludedDirectories(String homePath) {
  for (final name in fixtureIncludedDirectories) {
    final directory = Directory(p.join(homePath, name));
    if (!directory.existsSync()) continue;
    final remaining = directory.listSync(recursive: true, followLinks: false);
    if (remaining.isNotEmpty) continue;
    directory.deleteSync();
  }
}
