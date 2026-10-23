/// Writes the checked-in CLI relay grammar contract.
///
/// Usage (from `agent/`):
///
/// * `fvm dart run tool/generate_cli_relay_grammar.dart` — regenerate;
/// * `fvm dart run tool/generate_cli_relay_grammar.dart --check` — fail when the
///   checked-in contract no longer matches the Agent CLI grammar.
///
/// The contract is the cross-package source of truth for how a relayed argv is
/// read: `agent/test/cli/cli_relay_grammar_contract_test.dart` proves it matches
/// the real `SanadCommandRunner`, and the Client's relay policy test proves
/// `sanad-client` reads short and long options the same way.
library;

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;

import 'canonical_source.dart';
import 'cli_relay_grammar.dart';

void main(List<String> arguments) {
  final check = arguments.contains('--check');
  final contractFile = File(
    p.join(Directory.current.path, cliRelayGrammarContractPath),
  );

  final CliRelayGrammar grammar;
  try {
    grammar = CliRelayGrammar.extract();
  } on StateError catch (error) {
    stderr.writeln(error.message);
    exitCode = 1;
    return;
  }

  final rendered = grammar.encode();
  final onDisk = contractFile.existsSync()
      ? contractFile.readAsStringSync()
      : '';

  if (check) {
    if (generatedSourceMatches(onDisk: onDisk, rendered: rendered)) {
      stdout.writeln(
        'CLI relay grammar valid: ${grammar.longValueOptions.length} value '
        'options, ${grammar.longFlags.length} flags, '
        '${grammar.abbreviations.length} abbreviations',
      );
      return;
    }
    stderr.writeln(
      'CLI relay grammar is stale: $cliRelayGrammarContractPath does not '
      'match the Agent CLI.',
    );
    _printDifferences(onDisk: onDisk, rendered: grammar);
    stderr.writeln('Run: $cliRelayGrammarRegenerateCommand');
    exitCode = 1;
    return;
  }

  if (generatedSourceMatches(onDisk: onDisk, rendered: rendered)) {
    stdout.writeln('CLI relay grammar unchanged: $cliRelayGrammarContractPath');
    return;
  }

  contractFile.parent.createSync(recursive: true);
  contractFile.writeAsStringSync(rendered);
  stdout.writeln('Wrote $cliRelayGrammarContractPath');
}

/// Explains a mismatch instead of only reporting it.
void _printDifferences({
  required String onDisk,
  required CliRelayGrammar rendered,
}) {
  final CliRelayGrammar previous;
  try {
    previous = CliRelayGrammar.fromJson(jsonDecode(onDisk));
  } on FormatException catch (error) {
    stderr.writeln('The checked-in contract is unreadable: ${error.message}');
    return;
  }
  final differences = rendered.differencesFrom(previous);
  if (differences.isEmpty) {
    stderr.writeln('Only the document formatting differs.');
    return;
  }
  stderr.writeln(differences.map((line) => '  $line').join('\n'));
}
