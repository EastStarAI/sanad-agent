// Task 140 guard: the Settings secrets read model can never read a value.
//
// `UserSecretVault.resolve` is the one call in the Agent that returns stored
// values, and it exists only for the shell backend that injects explicitly
// requested names into one child process (Task 84). Task 140 adds a second
// reader of user secrets — the catalog behind the Settings → Privacy &
// Security page — and that reader must stay structurally incapable of seeing a
// value. The page is write-only by design (decision K4): there is no reveal
// path to protect later because no reader can read.
//
// This guard is static rather than behavioral on purpose: a behavioral test
// only notices a value read it exercises, while a future "just for a diff"
// call would slip through. Source is scanned with comments removed, so prose
// that names a forbidden call (including this file's own documentation) never
// trips it and never hides one either.
//
// The table-shape half reads a real database instead of the DDL text, so it
// states the columns SQLite actually created.

import 'dart:io';

import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

/// Files that form the Task 140 metadata-and-catalog path.
const List<String> metadataPathFiles = <String>[
  'lib/capabilities/secrets/user_secret_catalog.dart',
  'lib/evolution/db/user_secret_metadata_repository.dart',
  'lib/evolution/db/schema/user_secrets_schema.dart',
];

/// Every value-returning member of the vault and its namespace.
///
/// `resolve` on the vault and `read` on a namespace are the only two ways a
/// stored value leaves the vault in-process, so both are forbidden here.
const List<String> forbiddenValueReads = <String>[
  'resolve(',
  '.read(',
];

void main() {
  final packageRoot = _findPackageRoot();

  group('the catalog path never reads a value', () {
    for (final relativePath in metadataPathFiles) {
      test('$relativePath contains no value-reading call', () {
        final code = _codeOnly(
          File('${packageRoot.path}/$relativePath').readAsStringSync(),
        );

        for (final forbidden in forbiddenValueReads) {
          expect(
            code,
            isNot(contains(forbidden)),
            reason:
                '$relativePath must never be able to read a stored value. '
                'The Settings screen is write-only (Task 140 K4): adding a '
                'value read here would create a reveal path with no owner.',
          );
        }
      });
    }

    test('the acquisition hook reads no value either', () {
      // `SecretAcquisition` only writes. Task 140 added a metadata write to
      // it, so re-check that the added call did not bring a read.
      final code = _codeOnly(
        File(
          '${packageRoot.path}/lib/capabilities/secrets/secret_acquisition.dart',
        ).readAsStringSync(),
      );

      expect(code, isNot(contains('_vault.resolve')));
      expect(code, isNot(contains('.read(')));
    });

    test('the catalog declares no value-bearing member', () {
      final code = _codeOnly(
        File(
          '${packageRoot.path}/lib/capabilities/secrets/user_secret_catalog.dart',
        ).readAsStringSync(),
      );

      // The projection and entry types carry metadata only. A member named
      // after a value would be the first step toward a reveal path.
      for (final forbidden in <String>[
        'String? get value',
        'String get value',
        'valueFor(',
        'readValue(',
        'revealValue',
        'previewValue',
      ]) {
        expect(code, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });

  group('the metadata table cannot hold a value', () {
    test('the created table has exactly the five non-secret columns', () {
      final state = AgentStateDatabase.inMemory();
      addTearDown(state.dispose);

      final columns = state.db
          .select('PRAGMA table_info(user_secret_metadata)')
          .map((row) => row['name'] as String)
          .toList();

      expect(columns, [
        'name',
        'description',
        'source',
        'created_at',
        'updated_at',
      ]);
    });

    test('the repository writes no value-shaped column', () {
      final code = _codeOnly(
        File(
          '${packageRoot.path}/lib/evolution/db/user_secret_metadata_repository.dart',
        ).readAsStringSync(),
      );

      // `recordValue` is named for the event it records, not a stored value;
      // the columns it names are the five above.
      expect(code, contains('recordValue'));
      for (final forbidden in <String>[
        'secret_value',
        'value_hash',
        'value_prefix',
        'value TEXT',
      ]) {
        expect(code, isNot(contains(forbidden)), reason: forbidden);
      }
    });
  });
}

/// [source] with line and block comments removed.
///
/// A guard that greps raw source cannot tell a forbidden call from a comment
/// that documents why it is forbidden, and the only ways to satisfy such a
/// guard are to delete the documentation or to weaken the guard. Removing
/// comments keeps the documentation and the check.
String _codeOnly(String source) {
  final withoutBlocks = source.replaceAll(RegExp(r'/\*.*?\*/', dotAll: true), '');
  return withoutBlocks
      .split('\n')
      .map((line) => line.replaceFirst(RegExp(r'//.*$'), ''))
      .join('\n');
}

Directory _findPackageRoot() {
  var directory = Directory.current;
  for (var depth = 0; depth < 4; depth++) {
    final hasPubspec = File('${directory.path}/pubspec.yaml').existsSync();
    final hasLib = Directory('${directory.path}/lib').existsSync();
    if (hasPubspec && hasLib) return directory;

    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }

  fail(
    'Could not locate the Agent package root from ${Directory.current.path}. '
    'Run this guard from the Agent package root.',
  );
}
