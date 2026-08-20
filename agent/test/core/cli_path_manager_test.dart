import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:sanad_agent/core/setup/cli_path_manager.dart';

void main() {
  group('CliPathManager', () {
    late Directory tempHome;
    late Directory tempBin;

    setUp(() async {
      tempHome = await Directory.systemTemp.createTemp('sanad-cli-path-home-');
      tempBin = Directory(p.join(tempHome.path, '.sanad', 'bin'));
      await tempBin.create(recursive: true);
      // Create a dummy sanad executable
      final exec = File(p.join(tempBin.path, 'sanad'));
      await exec.writeAsString('#!/bin/sh\necho "Sanad CLI"');
    });

    tearDown(() async {
      if (tempHome.existsSync()) {
        await tempHome.delete(recursive: true);
      }
    });

    test('creates and appends PATH export in shell profile idempotently', () async {
      final modified = await CliPathManager.ensureOnPath(
        customHomeDir: tempHome.path,
        customBinDir: tempBin.path,
      );

      if (!Platform.isWindows) {
        expect(modified, isTrue);

        final zshrc = File(p.join(tempHome.path, '.zshrc'));
        expect(zshrc.existsSync(), isTrue);
        final content = await zshrc.readAsString();
        expect(content, contains('export PATH="${tempBin.path}:\$PATH"'));

        // Running a second time should not duplicate the line
        final modifiedAgain = await CliPathManager.ensureOnPath(
          customHomeDir: tempHome.path,
          customBinDir: tempBin.path,
        );
        expect(modifiedAgain, isFalse);

        final contentAgain = await zshrc.readAsString();
        final occurrences = 'export PATH="${tempBin.path}:\$PATH"'
            .allMatches(contentAgain)
            .length;
        expect(occurrences, 1);
      }
    });

    test('creates symlink in ~/.local/bin if directory exists', () async {
      if (!Platform.isWindows) {
        final localBin = Directory(p.join(tempHome.path, '.local', 'bin'));
        await localBin.create(recursive: true);

        await CliPathManager.ensureOnPath(
          customHomeDir: tempHome.path,
          customBinDir: tempBin.path,
        );

        final link = Link(p.join(localBin.path, 'sanad'));
        expect(link.existsSync(), isTrue);
        expect(await link.target(), p.join(tempBin.path, 'sanad'));
      }
    });
  });
}
