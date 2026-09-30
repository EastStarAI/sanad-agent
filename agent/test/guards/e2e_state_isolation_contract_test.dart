import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

void main() {
  test('persistent E2E runtimes declare isolated home and state roots', () {
    final violations = <String>[];

    for (final file in _dartFiles(Directory('e2e_test'))) {
      final source = file.readAsStringSync();
      final opensPersistentRuntime = <String>[
        'setupDI(',
        'AgentStateDatabase(',
        'SessionDB(',
        'Process.start(',
      ].any(source.contains);
      if (opensPersistentRuntime && !_declaresBothRoots(source)) {
        violations.add(p.relative(file.path));
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'E2E files that open DI/SQLite or launch a process must explicitly '
          'isolate both SANAD_HOME and SANAD_STATE_HOME.',
    );
  });

  test('every CLI test suite installs isolated home and state roots', () {
    final violations = <String>[];
    for (final file in _dartFiles(Directory('test/cli'))) {
      if (!file.path.endsWith('_test.dart')) continue;
      final source = file.readAsStringSync();
      if (!source.contains('useIsolatedSanadTestHome();') &&
          !_declaresBothRoots(source)) {
        violations.add(p.relative(file.path));
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Every CLI test suite must override both Sanad roots before any '
          'command can resolve inherited user state.',
    );
  });

  test('Dart child-process tests pass isolated home and state roots', () {
    final violations = <String>[];

    for (final root in <Directory>[Directory('e2e_test'), Directory('test')]) {
      for (final file in _dartFiles(root)) {
        if (p.basename(file.path) == 'e2e_state_isolation_contract_test.dart') {
          continue;
        }
        final source = file.readAsStringSync();
        final startsDartProcess =
            source.contains('Platform.resolvedExecutable') &&
            (source.contains('Process.start(') ||
                source.contains('Process.run('));
        if (startsDartProcess && !_declaresBothRoots(source)) {
          violations.add(p.relative(file.path));
        }
      }
    }

    expect(
      violations,
      isEmpty,
      reason:
          'Tests that start a Dart child process must pass explicit '
          'SANAD_HOME and SANAD_STATE_HOME values instead of inheriting them.',
    );
  });
}

Iterable<File> _dartFiles(Directory root) sync* {
  if (!root.existsSync()) return;
  for (final entity in root.listSync(recursive: true, followLinks: false)) {
    if (entity is File && entity.path.endsWith('.dart')) yield entity;
  }
}

bool _declaresBothRoots(String source) {
  final declaresHome =
      source.contains('SANAD_HOME') || source.contains('setSanadHomeOverride(');
  final declaresState =
      source.contains('SANAD_STATE_HOME') ||
      source.contains('setSanadStateHomeOverride(');
  return declaresHome && declaresState;
}
