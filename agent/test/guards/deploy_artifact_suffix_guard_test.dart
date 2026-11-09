// Deploy-archive naming guard for every tracked file in this repository.
//
// The private Production deploy packs this repository into a release archive,
// and a root-owned artifact check on that host rejects any archive member whose
// final path component ends in `pem`, `key`, `p12`, `pfx`, `dump`, or `sql`.
// Only the public release verification key is allowlisted, because both clients
// embed it. A committed fixture with one of those suffixes therefore blocks
// every Production deploy, so the rule is enforced here instead of being
// rediscovered by a failed deployment.
//
// Rename a blocked file so its final path component ends in a safe suffix while
// keeping the real format readable as a double extension, for example
// `legacy_pre_112_schedules.sql.txt`. Never allowlist a fixture or test data.

import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// Suffixes the private Production deploy artifact check rejects, matched as a
/// case-insensitive suffix of the final path component.
const List<String> blockedSuffixes = <String>[
  '.pem',
  '.key',
  '.p12',
  '.pfx',
  '.dump',
  '.sql',
];

/// Repository-relative paths that stay allowed.
///
/// The single entry is the release verification key both clients embed; the
/// artifact check allowlists exactly this member by name.
const Set<String> allowedPaths = <String>{'client/release/shared/dsa_pub.pem'};

void main() {
  final repositoryRoot = findRepositoryRoot(Directory.current);

  test('no tracked file ends in a blocked deploy artifact suffix', () {
    final tracked = trackedFiles(repositoryRoot);
    expect(
      tracked,
      isNotEmpty,
      reason: 'The repository index must list tracked files.',
    );

    final offenders = <String>[];
    for (final path in tracked) {
      if (isAllowedTrackedPath(path)) continue;
      final suffix = blockedSuffixOf(path);
      if (suffix != null) offenders.add('$path ($suffix)');
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'The private Production deploy archives this repository and its '
          'host-side artifact check rejects any member whose final path '
          'component ends in ${blockedSuffixes.join(', ')}. Rename each file so '
          'its final path component ends in a safe suffix, keeping the real '
          'format as a trailing double extension '
          '(for example legacy_pre_112_schedules.sql.txt), then update every '
          'reference. Only ${allowedPaths.join(', ')} stays allowlisted because '
          'both clients embed it; never allowlist a fixture or test data.\n'
          'Offending tracked files:\n${offenders.map((o) => '  - $o').join('\n')}',
    );
  });

  test('the allowlist still names a tracked file', () {
    final tracked = trackedFiles(repositoryRoot).toSet();
    expect(
      tracked,
      contains('agent/pubspec.yaml'),
      reason: 'Tracked paths are relative to the repository root.',
    );

    final stale = allowedPaths.where((path) => !tracked.contains(path));

    expect(
      stale,
      isEmpty,
      reason:
          'These allowlist entries no longer name a tracked file. Remove them '
          'so the allowlist cannot silently absorb a future offender: '
          '${stale.join(', ')}',
    );
  });

  test('the suffix rule detects the suffixes it documents', () {
    for (final suffix in blockedSuffixes) {
      expect(
        blockedSuffixOf('agent/test/evolution/fixtures/legacy$suffix'),
        suffix,
        reason: '$suffix must be reported as blocked',
      );
      expect(
        blockedSuffixOf('agent/fixtures/legacy${suffix.toUpperCase()}'),
        suffix,
        reason: 'an uppercase final path component is blocked too',
      );
    }

    for (final safePath in <String>[
      'agent/fixtures/legacy_pre_112_schedules.sql.txt',
      'agent/fixtures/legacy_pre_112_schedules.sqlfixture',
      'agent/fixtures/legacy.dump.txt',
      'agent/lib/core/config.dart',
    ]) {
      expect(
        blockedSuffixOf(safePath),
        isNull,
        reason: '$safePath ends in a safe suffix',
      );
    }

    expect(
      blockedSuffixOf('client/release/shared/dsa_pub.pem'),
      '.pem',
      reason: 'the allowlisted key is exempt by path, not by suffix',
    );
    expect(
      isAllowedTrackedPath('client/release/shared/dsa_pub.pem'),
      isTrue,
      reason: 'the embedded release verification key is the one exception',
    );
    expect(
      isAllowedTrackedPath('client/release/shared/dsa_pub.pem.bak'),
      isFalse,
      reason: 'only the exact allowlisted path is exempt',
    );
  });
}

/// The blocked suffix that ends [path]'s final component, or `null`.
String? blockedSuffixOf(String path) {
  final finalComponent = path.split('/').last.toLowerCase();
  for (final suffix in blockedSuffixes) {
    if (finalComponent.endsWith(suffix)) return suffix;
  }
  return null;
}

/// Whether [path] is the explicit deploy-artifact allowlist member.
bool isAllowedTrackedPath(String path) => allowedPaths.contains(path);

/// Every path in the repository index, relative to its Git root.
///
/// The guard asserts repository state, so it reads the index instead of walking
/// the working tree: an untracked local artifact never fails it, and a committed
/// offender never escapes it.
List<String> trackedFiles(Directory repositoryRoot) {
  final ProcessResult result;
  try {
    result = Process.runSync(
      'git',
      <String>['ls-files', '-z', '--cached'],
      workingDirectory: repositoryRoot.path,
      stdoutEncoding: const Utf8Codec(allowMalformed: true),
    );
  } on ProcessException catch (error) {
    fail(
      'Could not run git in ${repositoryRoot.path}: ${error.message}.\nThis '
      'guard reads the Git index, so it needs Git on PATH.',
    );
  }

  if (result.exitCode != 0) {
    fail(
      'Could not list tracked files in ${repositoryRoot.path}: '
      '${result.stderr}\nThis guard reads the Git index, so it must run in a '
      'Git checkout.',
    );
  }

  return (result.stdout as String)
      .split('\u0000')
      .where((path) => path.isNotEmpty)
      .toList(growable: false);
}

/// The Git checkout root that contains [start], found by walking up for any
/// `.git` entry (a directory in a normal checkout, a file in a worktree or a
/// submodule).
Directory findRepositoryRoot(Directory start) {
  var directory = start.absolute;
  while (true) {
    final gitEntry = FileSystemEntity.typeSync('${directory.path}/.git');
    if (gitEntry != FileSystemEntityType.notFound) return directory;

    final parent = directory.parent;
    if (parent.path == directory.path) {
      fail(
        'Could not find a Git checkout above ${start.absolute.path}. This '
        'guard reads the tracked-file index, so it must run inside the '
        'repository.',
      );
    }
    directory = parent;
  }
}
