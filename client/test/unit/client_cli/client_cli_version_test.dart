import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/client_cli/cli/sanad_client_runner.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_version.dart';

/// Locates the Client package root from the test working directory.
File _clientPubspec() {
  var directory = Directory.current;
  for (var depth = 0; depth < 3; depth++) {
    final candidate = File('${directory.path}/pubspec.yaml');
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  throw StateError('client/pubspec.yaml was not found from ${Directory.current.path}');
}

void main() {
  group('snadClientCliVersion', () {
    test('matches the client release version declared in pubspec.yaml', () {
      final versionLine = _clientPubspec()
          .readAsLinesSync()
          .map((line) => line.trim())
          .firstWhere((line) => line.startsWith('version:'), orElse: () => '');

      expect(versionLine, isNotEmpty, reason: 'client/pubspec.yaml must declare version:');
      final declared = versionLine.substring('version:'.length).trim().split('+').first;
      expect(sanadClientCliVersion, declared);
    });

    test('is a plain semantic version usable for major-version comparison', () {
      expect(
        RegExp(r'^\d+\.\d+\.\d+$').hasMatch(sanadClientCliVersion),
        isTrue,
        reason: 'the CLI compares major versions with the running Client',
      );
    });

    test('--version reports the shared constant', () async {
      final out = StringBuffer();
      final err = StringBuffer();

      final code = await const SanadClientRunner().run(
        ['--version'],
        stdoutSink: out,
        stderrSink: err,
      );

      expect(code, 0);
      expect(out.toString().trim(), 'sanad-client $sanadClientCliVersion');
      expect(err.toString(), isEmpty);
    });
  });
}
