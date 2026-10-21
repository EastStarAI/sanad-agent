import 'dart:io';

import 'package:test/test.dart';

/// Regression coverage for `scripts/lint_wiki.dart`.
///
/// The linter walks the whole checkout to discover `AGENTS.md` contracts. After
/// `fvm flutter pub get` / `flutter pub get`, Flutter materializes dependency
/// link trees inside the workspace
/// (`client/linux|windows/flutter/ephemeral/.plugin_symlinks/` and
/// `client/macos/Flutter/ephemeral/.symlinks/`) that resolve into the pub
/// cache. Third-party packages there ship their own `AGENTS.md`, which used to
/// be reported as unindexed repository contracts.
///
/// These tests drive the real script in a temporary sandbox that reproduces the
/// exact generated paths, so the exclusion rule and the frontmatter/index
/// checks are both proven against real discovery behavior rather than a copy of
/// the logic. The exclusion is intentionally path-based (not link-based) so the
/// fixture works on every platform.
void main() {
  late Directory sandbox;
  late File linterScript;

  setUp(() {
    sandbox = Directory.systemTemp.createTempSync('wiki-lint-');
    linterScript = File(
      '${_locateRepoRoot().path}${Platform.pathSeparator}'
      'scripts${Platform.pathSeparator}lint_wiki.dart',
    );
    expect(
      linterScript.existsSync(),
      isTrue,
      reason: 'The wiki linter must exist at ${linterScript.path}.',
    );
  });

  tearDown(() {
    try {
      sandbox.deleteSync(recursive: true);
    } catch (_) {}
  });

  String write(String relativePath, String body) {
    final file = File(
      '${sandbox.path}${Platform.pathSeparator}'
      '${relativePath.replaceAll('/', Platform.pathSeparator)}',
    );
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(body);
    return relativePath;
  }

  void writeIndex(List<String> lines) {
    write('docs/llms.txt', '${lines.join('\n')}\n');
  }

  const pageBody = '''
---
title: "Sandbox Page"
description: "Fixture page for the wiki linter."
---

# Sandbox Page
''';

  /// A third-party contract exactly where Flutter generates a plugin link tree.
  const pluginContract = '# Third-party plugin contract\n';

  Future<ProcessResult> runLinter() => Process.run(
    Platform.resolvedExecutable,
    [linterScript.path],
    workingDirectory: sandbox.path,
  );

  String combinedOutput(ProcessResult result) =>
      '${result.stdout}${result.stderr}';

  List<String> generatedArtifactPaths() => [
    'client/linux/flutter/ephemeral/.plugin_symlinks/cnativeapi/cxx_impl/AGENTS.md',
    'client/windows/flutter/ephemeral/.plugin_symlinks/cnativeapi/cxx_impl/AGENTS.md',
    'client/macos/Flutter/ephemeral/.symlinks/plugins/some_plugin/AGENTS.md',
  ];

  test(
    'ignores contracts inside generated Flutter dependency link trees',
    () async {
      writeIndex([
        '- [Sandbox Page](docs/technical/real_page.md): Fixture page.',
        '- [AGENTS](./agent/lib/core/AGENTS.md): Rules governing agent/lib/core.',
      ]);
      write('docs/technical/real_page.md', pageBody);
      write('agent/lib/core/AGENTS.md', '# Repository contract\n');
      for (final artifact in generatedArtifactPaths()) {
        // Deliberately absent from the index: generated artifacts are not
        // repository contracts and must not be required to be indexed.
        write(artifact, pluginContract);
      }

      final result = await runLinter();
      final output = combinedOutput(result);

      expect(result.exitCode, 0, reason: output);
      expect(output, contains('SUCCESS'));
      for (final artifact in generatedArtifactPaths()) {
        expect(output, isNot(contains(artifact)));
        expect(output, isNot(contains('.plugin_symlinks/')));
      }
    },
  );

  test('still requires real repository contracts to be indexed', () async {
    writeIndex([
      '- [Sandbox Page](docs/technical/real_page.md): Fixture page.',
    ]);
    write('docs/technical/real_page.md', pageBody);
    write('agent/lib/core/AGENTS.md', '# Repository contract\n');

    final result = await runLinter();

    expect(result.exitCode, 1);
    expect(
      combinedOutput(result),
      contains('Contract file is not indexed in docs/llms.txt'),
    );
  });

  test(
    'keeps contracts discoverable when a path only resembles the exclusion',
    () async {
      // `ephemeral` appears in the path, but this is not a generated link tree,
      // so the contract stays discoverable and must still be indexed.
      writeIndex([
        '- [Sandbox Page](docs/technical/real_page.md): Fixture page.',
      ]);
      write('docs/technical/real_page.md', pageBody);
      write('agent/lib/ephemeral/AGENTS.md', '# Repository contract\n');

      final result = await runLinter();

      expect(result.exitCode, 1);
      expect(
        combinedOutput(result),
        contains('Contract file is not indexed in docs/llms.txt'),
      );
      expect(combinedOutput(result), contains('agent/lib/ephemeral/AGENTS.md'));
    },
  );

  test('still reports a real documentation page without frontmatter', () async {
    writeIndex([
      '- [Sandbox Page](docs/technical/real_page.md): Fixture page.',
      '- [No Frontmatter](docs/technical/no_frontmatter.md): Fixture page.',
    ]);
    write('docs/technical/real_page.md', pageBody);
    write('docs/technical/no_frontmatter.md', '# No Frontmatter\n');

    final result = await runLinter();

    expect(result.exitCode, 1);
    expect(
      combinedOutput(result),
      contains(
        '[docs/technical/no_frontmatter.md] ERROR: '
        'Missing markdown frontmatter.',
      ),
    );
  });

  test('still reports frontmatter without a description', () async {
    writeIndex([
      '- [Sandbox Page](docs/technical/real_page.md): Fixture page.',
      '- [Bare](docs/technical/bare_frontmatter.md): Fixture page.',
    ]);
    write('docs/technical/real_page.md', pageBody);
    write(
      'docs/technical/bare_frontmatter.md',
      '---\ntitle: "Bare"\n---\n\n# Bare\n',
    );

    final result = await runLinter();

    expect(result.exitCode, 1);
    expect(
      combinedOutput(result),
      contains('Missing description in frontmatter.'),
    );
  });

  test('reports a broken link on a real documentation page', () async {
    writeIndex([
      '- [Sandbox Page](docs/technical/real_page.md): Fixture page.',
      '- [Linky](docs/technical/linky.md): Fixture page.',
    ]);
    write('docs/technical/real_page.md', pageBody);
    write(
      'docs/technical/linky.md',
      '---\ntitle: "Linky"\ndescription: "Fixture page."\n---\n\n'
          'See [missing](missing_page.md).\n',
    );

    final result = await runLinter();

    expect(result.exitCode, 1);
    expect(combinedOutput(result), contains('Broken link to'));
  });
}

/// Walks up from the current directory until the repository root that owns
/// `scripts/lint_wiki.dart` is found.
Directory _locateRepoRoot() {
  var directory = Directory.current;
  for (var depth = 0; depth < 6; depth++) {
    final candidate = File(
      '${directory.path}${Platform.pathSeparator}'
      'scripts${Platform.pathSeparator}lint_wiki.dart',
    );
    if (candidate.existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      break;
    }
    directory = parent;
  }
  throw StateError(
    'Could not locate scripts/lint_wiki.dart from ${Directory.current.path}.',
  );
}
