/// The Client half of the CLI relay grammar contract.
///
/// `sanad-client` approves a relayed command against the session it will act on,
/// and it reads that session with the Agent's own option grammar. The tables in
/// `client_cli_relay_policy.dart` are a literal copy of the grammar, so this
/// suite is what keeps the copy honest: the Agent generates
/// `agent/test/fixtures/cli_relay_grammar.json` from the real
/// `SanadCommandRunner`, and here the Client proves it reads every entry the
/// same way.
///
/// A silent divergence is an approval for one session and an action on another:
/// `session steer --foo B A` where only one side knows `--foo` takes a value
/// resolves session `B` on one side and `A` on the other.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/client_cli/domain/models/client_cli_relay_policy.dart';

import '../../helpers/cli_relay_grammar_contract.dart';

void main() {
  final contract = CliRelayGrammarContract.load();

  group('CLI relay grammar contract', () {
    test('every value option the Agent accepts consumes its value here', () {
      expect(
        clientCliRelayLongValueOptions,
        unorderedEquals(contract.longValueOptions),
        reason:
            'agent/test/fixtures/cli_relay_grammar.json lists the long options '
            'that take a value. A name the Agent reads as a flag but the relay '
            'reads as a value option (or the reverse) makes both sides resolve '
            'a different argument for the same argv.',
      );
    });

    test('every abbreviation takes a value exactly as the Agent does', () {
      expect(
        clientCliRelayShortOptions.keys,
        unorderedEquals(contract.abbreviations.keys),
        reason: 'the relay must know every abbreviation the Agent accepts.',
      );
      for (final entry in contract.abbreviations.entries) {
        expect(
          clientCliRelayShortOptions[entry.key],
          entry.value.takesValue,
          reason:
              'the Agent reads -${entry.key} '
              '(${entry.value.names.join('/')}) '
              '${entry.value.takesValue ? 'with' : 'without'} a value.',
        );
      }
    });

    test('each abbreviation names a long option the Agent declares', () {
      for (final entry in contract.abbreviations.entries) {
        expect(
          entry.value.names,
          contains(clientCliRelayShortNames[entry.key]),
          reason:
              'the relay resolves -${entry.key} to '
              '--${clientCliRelayShortNames[entry.key]}, so that long form must '
              'be the one the Agent declares for this abbreviation.',
        );
      }
    });

    test('no name is both a flag and a value option', () {
      expect(
        contract.longFlags.toSet().intersection(
          contract.longValueOptions.toSet(),
        ),
        isEmpty,
        reason:
            'one name cannot carry both shapes: the Agent would read a value '
            'where the relay reads a flag, or the reverse.',
      );
    });

    test('the relay never reads a flag name as a value option', () {
      expect(
        clientCliRelayLongValueOptions.intersection(
          contract.longFlags.toSet(),
        ),
        isEmpty,
      );
    });
  });
}
