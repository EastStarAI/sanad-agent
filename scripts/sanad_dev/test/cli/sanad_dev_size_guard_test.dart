import 'dart:io';

import 'package:test/test.dart';

void main() {
  group('sanad_dev size and cohesion guardrails', () {
    final packageDir = Directory.current.path.endsWith('sanad_dev')
        ? Directory.current
        : Directory('scripts/sanad_dev');

    final libDir = Directory('${packageDir.path}/lib');
    final testDir = Directory('${packageDir.path}/test');

    test(
      'no handwritten production file exceeds 700 lines and cli.dart <= 250 lines',
      () {
        final productionFiles = libDir
            .listSync(recursive: true)
            .whereType<File>()
            .where((f) => f.path.endsWith('.dart'))
            .toList();

        expect(productionFiles, isNotEmpty);

        for (final file in productionFiles) {
          final lineCount = file.readAsLinesSync().length;
          final relativePath = file.path.substring(packageDir.path.length + 1);

          if (file.path.endsWith('cli.dart')) {
            expect(
              lineCount,
              lessThanOrEqualTo(250),
              reason:
                  '$relativePath must not exceed 250 lines (current: $lineCount)',
            );
          } else {
            expect(
              lineCount,
              lessThanOrEqualTo(700),
              reason:
                  '$relativePath must not exceed 700 lines (current: $lineCount)',
            );
          }
        }
      },
    );

    test('no ordinary test file exceeds 700 lines', () {
      final testFiles = testDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((f) => f.path.endsWith('.dart'))
          .toList();

      expect(testFiles, isNotEmpty);

      for (final file in testFiles) {
        final lineCount = file.readAsLinesSync().length;
        final relativePath = file.path.substring(packageDir.path.length + 1);

        expect(
          lineCount,
          lessThanOrEqualTo(700),
          reason:
              '$relativePath must not exceed 700 lines (current: $lineCount)',
        );
      }
    });

    test('lib root contains only proven public or compatibility surfaces', () {
      final rootDartFiles =
          libDir
              .listSync(followLinks: false)
              .whereType<File>()
              .where((file) => file.path.endsWith('.dart'))
              .map((file) => file.uri.pathSegments.last)
              .toList()
            ..sort();

      expect(rootDartFiles, ['runtime_context.dart', 'sanad_dev_cli.dart']);
      expect(
        File('${libDir.path}/runtime_context.dart').readAsStringSync().trim(),
        "export 'src/infrastructure/runtime_context.dart';",
      );
    });

    test('internal modules do not route through root package facades', () {
      final srcFiles = Directory('${libDir.path}/src')
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));

      for (final file in srcFiles) {
        expect(
          file.readAsStringSync(),
          isNot(contains('package:sanad_dev/')),
          reason: '${file.path} must import its narrow internal owner directly',
        );
      }
    });

    test('tests use src owners and contain no nested contracts', () {
      final nestedContracts = testDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.uri.pathSegments.last == 'AGENTS.md');
      expect(nestedContracts, isEmpty);

      final testFiles = testDir
          .listSync(recursive: true)
          .whereType<File>()
          .where((file) => file.path.endsWith('.dart'));
      for (final file in testFiles) {
        for (final line in file.readAsLinesSync()) {
          final importLine = line.trimLeft();
          if (!importLine.startsWith('import ') ||
              !importLine.contains('package:sanad_dev/')) {
            continue;
          }
          expect(
            importLine.contains('package:sanad_dev/src/') ||
                importLine.contains('package:sanad_dev/sanad_dev_cli.dart'),
            isTrue,
            reason:
                '${file.path} must not depend on a root compatibility facade',
          );
        }
      }
    });
  });
}
