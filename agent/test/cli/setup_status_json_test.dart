import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';

import '../support/compiled_agent_cli.dart';

/// `sanad setup status --json` must reach `SetupStatusCommand` from the real
/// binary, not the legacy wizard (issue 339 review 2).
///
/// The binary wires `onSetup` for the bare interactive wizard; a subcommand that
/// delegated to it ignored `--json` and printed the wizard banner plus plain
/// text. This proves the end-to-end shape against an isolated Home.
void main() {
  late Directory artifactDirectory;
  late Directory caseDirectory;
  late CompiledAgentCli cli;

  setUpAll(() async {
    artifactDirectory = await Directory.systemTemp.createTemp(
      'sanad-setup-status-json-artifact-',
    );
  });

  tearDownAll(() async {
    try {
      await artifactDirectory.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    caseDirectory = await Directory.systemTemp.createTemp(
      'sanad-setup-status-json-',
    );
    cli = CompiledAgentCli(artifactDirectory);
  });

  tearDown(() async {
    try {
      await caseDirectory.delete(recursive: true);
    } catch (_) {}
  });

  Future<ProcessResult> run(List<String> args) {
    final home = Directory(p.join(caseDirectory.path, 'home'))..createSync();
    final state = Directory(p.join(caseDirectory.path, 'state'))..createSync();
    // Both roots are passed explicitly to the child (`SANAD_HOME` and
    // `SANAD_STATE_HOME`); it never inherits the caller's user state.
    return cli.run(args, home: home, stateHome: state);
  }

  test('setup status --json emits one machine-readable envelope', () async {
    final result = await run(['setup', 'status', '--json']);

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final stdout = result.stdout.toString().trim();
    expect(stdout, startsWith('{'), reason: 'expected JSON, got: $stdout');
    final decoded = jsonDecode(stdout) as Map<String, dynamic>;

    // Stable shape: every additive nullable field is present as null.
    expect(decoded['has_provider'], isFalse);
    expect(decoded['runtime_ready'], isFalse);
    expect(decoded.containsKey('active_provider'), isTrue);
    expect(decoded['active_provider'], isNull);
    expect(decoded.containsKey('active_model'), isTrue);
    expect(decoded['active_model'], isNull);
    expect(decoded['reason'], isA<String>());
    expect(decoded.containsKey('discovery_error'), isTrue);
    expect(decoded['discovery_error'], isNull);
    // The legacy wizard banner must not appear in JSON mode.
    expect(stdout.contains('AI Provider Instances'), isFalse);
  }, timeout: cliTestTimeout);

  test('setup status keeps its human form without --json', () async {
    final result = await run(['setup', 'status']);

    expect(result.exitCode, 0, reason: '${result.stdout}${result.stderr}');
    final stdout = result.stdout.toString();
    expect(stdout, contains('Provider Setup Status:'));
    expect(stdout, contains('runtime_ready:'));
  }, timeout: cliTestTimeout);
}
