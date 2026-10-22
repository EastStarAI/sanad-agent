/// The Agent half of the CLI relay grammar contract.
///
/// `sanad-client` reads a relayed argv with this CLI's own `args` grammar and
/// approves it against the session it will act on. Two hand-maintained copies of
/// the grammar can diverge silently, and a divergence is an approval for one
/// session and an action on another: an option the Agent reads as taking a value
/// but the relay reads as a flag consumes the next token on one side only, so
/// `session steer --foo B A` resolves `B` there and `A` here.
///
/// `tool/generate_cli_relay_grammar.dart` extracts the real grammar — every
/// command and subcommand parser recursively, plus the global parser — into
/// `test/fixtures/cli_relay_grammar.json`, and this suite fails as soon as the
/// checked-in copy stops matching the CLI.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:test/test.dart';

import '../../tool/canonical_source.dart';
import '../../tool/cli_relay_grammar.dart';
import '../support/isolated_sanad_test_home.dart';

/// The agent package root, resolved independently of the process working
/// directory (other suites change it while files run concurrently).
Uri _agentRoot() => Isolate.resolvePackageUriSync(
  Uri.parse('package:sanad_agent/'),
)!.resolve('../');

File _contractFile() =>
    File.fromUri(_agentRoot().resolve(cliRelayGrammarContractPath));

void main() {
  // Building the runner must never resolve an inherited user Home.
  useIsolatedSanadTestHome();

  test('the checked-in relay grammar contract matches the Agent CLI', () {
    final file = _contractFile();
    final onDisk = file.existsSync() ? file.readAsStringSync() : '';
    expect(
      generatedSourceMatches(
        onDisk: onDisk,
        rendered: CliRelayGrammar.extract().encode(),
      ),
      isTrue,
      reason:
          'The Agent CLI grammar changed. Run: '
          '$cliRelayGrammarRegenerateCommand',
    );
  });

  test('the contract reads back as the same grammar', () {
    final onDisk = _contractFile().readAsStringSync();
    expect(
      CliRelayGrammar.fromJson(jsonDecode(onDisk)),
      CliRelayGrammar.extract(),
      reason:
          'The relay parses this document, so it must be lossless: a shape the '
          'reader cannot reproduce would hide the drift the contract exists to '
          'catch.',
    );
  });

  test('a stale contract is reported by name', () {
    final grammar = CliRelayGrammar.extract();
    final stale = CliRelayGrammar.fromJson({
      'long_value_options': grammar.longValueOptions
          .where((name) => name != 'message')
          .toList(growable: false),
      'long_flags': grammar.longFlags,
      'abbreviations': {
        for (final entry in grammar.abbreviations.entries)
          entry.key: entry.value.toJson(),
      },
    });
    expect(
      grammar.differencesFrom(stale),
      contains('+ long option: message'),
      reason:
          'A value option the contract lost must be named, so the failure says '
          'which option would have been read as a flag by the relay.',
    );
    expect(stale.differencesFrom(grammar), contains('- long option: message'));
  });

  test('the global grammar stays part of the contract', () {
    final grammar = CliRelayGrammar.extract();
    // `args` resolves an option a subcommand does not declare by walking up to
    // the parent parser, so a global name is live inside every command.
    expect(grammar.longValueOptions, containsAll(['prompt', 'session', 'url']));
    expect(grammar.abbreviations['p']?.takesValue, isTrue);
  });
}
