import 'dart:convert';
import 'dart:io';

import 'package:test/test.dart';

/// The publisher gate is the only thing that keeps a release from publishing a
/// trust target its own build cannot verify, because runtime parsing is
/// deliberately forward-compatible. These tests drive the real command entry
/// point, so dropping a gate call fails here instead of in a release run.
void main() {
  late Directory fixture;
  late Directory home;
  late Directory stateRoot;
  late Map<String, dynamic> contract;
  late String marketingVersion;

  setUp(() async {
    fixture = await Directory.systemTemp.createTemp('sanad-release-gate-');
    // The tool reads no Home, but a Dart child process must never inherit the
    // caller's identity and state roots.
    home = await Directory('${fixture.path}/home').create();
    stateRoot = await Directory('${fixture.path}/state').create();
    contract =
        jsonDecode(
              File(
                '${Directory.current.parent.path}/release/release-contract.json',
              ).readAsStringSync(),
            )
            as Map<String, dynamic>;
    marketingVersion = contract['version']! as String;
    for (final path in [
      'release/release-contract.json',
      'agent/pubspec.yaml',
      'client/pubspec.yaml',
    ]) {
      final source = File('${Directory.current.parent.path}/$path');
      await File(
        '${fixture.path}/$path',
      ).create(recursive: true).then((file) => source.copy(file.path));
    }
  });

  tearDown(() async {
    if (fixture.existsSync()) await fixture.delete(recursive: true);
  });

  Future<ProcessResult> releaseTool(List<String> arguments) => Process.run(
    Platform.resolvedExecutable,
    ['run', 'tool/release_tool.dart', ...arguments],
    workingDirectory: Directory.current.path,
    environment: {'SANAD_HOME': home.path, 'SANAD_STATE_HOME': stateRoot.path},
  );

  /// A contract row this build has no policy for. The contract carries no
  /// hashes or URLs; those belong to the manifest form below.
  Map<String, dynamic> futureArtifact() => {
    'component': 'agent-launcher',
    'platform': 'macos',
    'architecture': 'x64',
    'format': 'executable',
    'filename': 'sanad-agent-launcher-$marketingVersion-macos-x64',
    'public': true,
    'signature_type': 'github-attestation',
  };

  Map<String, dynamic> manifestWith(List<Map<String, dynamic>> artifacts) => {
    'schema_version': 1,
    'version': '1.1.0',
    'build_number': 2,
    'tag': 'v1.1.0',
    'commit': '1234567890abcdef',
    'channel': 'stable',
    'repository': 'EastStarAI/sanad-agent',
    'artifacts': artifacts,
  };

  Map<String, dynamic> knownAgent() => {
    'component': 'agent',
    'platform': 'linux',
    'architecture': 'x64',
    'format': 'executable',
    'filename': 'sanad-agent-1.1.0-linux-x64',
    'url':
        'https://github.com/EastStarAI/sanad-agent/releases/download/'
        'v1.1.0/sanad-agent-1.1.0-linux-x64',
    'sha256': 'a' * 64,
    'size': 3,
    'public': true,
    'signature_type': 'github-attestation',
  };

  Future<File> writeManifest(Map<String, dynamic> json) async {
    final file = File('${fixture.path}/release-manifest.json');
    await file.writeAsString(jsonEncode(json));
    return file;
  }

  test('validate-contract accepts the real contract', () async {
    final result = await releaseTool([
      'validate-contract',
      '--repo-root',
      fixture.path,
    ]);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('Release contract valid:'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test(
    'validate-contract refuses a published target without a policy',
    () async {
      (contract['artifacts']! as List).add(futureArtifact());
      await File(
        '${fixture.path}/release/release-contract.json',
      ).writeAsString(jsonEncode(contract));

      final result = await releaseTool([
        'validate-contract',
        '--repo-root',
        fixture.path,
      ]);

      expect(result.exitCode, 2, reason: '${result.stdout}');
      expect(
        result.stderr,
        contains('Unsupported release trust target: agent-launcher/macos.'),
      );
    },
    timeout: const Timeout(Duration(minutes: 2)),
  );

  test('verify-manifest accepts a manifest of known targets', () async {
    final file = await writeManifest(manifestWith([knownAgent()]));

    final result = await releaseTool([
      'verify-manifest',
      '--manifest',
      file.path,
    ]);

    expect(result.exitCode, 0, reason: '${result.stderr}');
    expect(result.stdout, contains('Release manifest valid: v1.1.0'));
  }, timeout: const Timeout(Duration(minutes: 2)));

  test('verify-manifest refuses a manifest with an unknown target', () async {
    final unknown = {
      ...futureArtifact(),
      'filename': 'sanad-agent-launcher-1.1.0-macos-x64',
      'url':
          'https://github.com/EastStarAI/sanad-agent/releases/download/'
          'v1.1.0/sanad-agent-launcher-1.1.0-macos-x64',
      'sha256': 'b' * 64,
      'size': 3,
    };
    final file = await writeManifest(manifestWith([knownAgent(), unknown]));

    final result = await releaseTool([
      'verify-manifest',
      '--manifest',
      file.path,
    ]);

    expect(result.exitCode, 2, reason: '${result.stdout}');
    expect(
      result.stderr,
      contains('Unsupported release trust target(s): agent-launcher:macos.'),
    );
  }, timeout: const Timeout(Duration(minutes: 2)));

  // `generate-manifest` runs `validate-contract` before it assembles anything, so
  // a contract-level unknown target cannot reach its assembly step through the
  // CLI. The gate call after assembly is the belt-and-braces guard, and this
  // guard fails if a refactor drops either wiring.
  test('the manifest commands gate the manifest they assemble', () {
    final source = File('tool/release_tool.dart').readAsStringSync();
    int entry(String name) => source.indexOf('Future<void> $name(');
    int end(int start) => source.indexOf('\nFuture<', start + 1);
    final gates = <int>[
      for (
        var index = source.indexOf('requireKnownTrustTargets()');
        index != -1;
        index = source.indexOf('requireKnownTrustTargets()', index + 1)
      )
        index,
    ];

    expect(gates, hasLength(2));
    for (final command in ['_generateManifest', '_verifyManifest']) {
      final start = entry(command);
      expect(start, greaterThan(-1), reason: command);
      expect(
        gates.where((gate) => gate > start && gate < end(start)),
        hasLength(1),
        reason: '$command must call requireKnownTrustTargets()',
      );
    }
  });
}
