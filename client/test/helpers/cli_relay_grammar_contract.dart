import 'dart:convert';
import 'dart:io';

/// Checked-in CLI relay grammar contract, read as the Client sees it.
///
/// `sanad-client` reads a relayed argv with the Agent's `args` grammar, so the
/// Agent CLI — not this package — owns the grammar. The Agent generates the
/// contract from its real `SanadCommandRunner` and proves it in
/// `agent/test/cli/cli_relay_grammar_contract_test.dart`; the Client reads the
/// same file here and proves its own tables agree.
///
/// Protocol: `docs/technical/remote_cli_relay_protocol.md`.
class CliRelayGrammarContract {
  const CliRelayGrammarContract({
    required this.longValueOptions,
    required this.longFlags,
    required this.abbreviations,
  });

  /// Path of the contract, relative to the workspace root.
  static const String workspacePath = 'agent/test/fixtures/cli_relay_grammar.json';

  /// Every long option that consumes a value, aliases included.
  final List<String> longValueOptions;

  /// Every long flag.
  final List<String> longFlags;

  /// Abbreviation letter to its value-taking shape and declaring long names.
  final Map<String, CliRelayGrammarAbbreviation> abbreviations;

  /// Reads the contract from the workspace, independent of the working
  /// directory depth a test runner uses.
  static CliRelayGrammarContract load() {
    var directory = Directory.current;
    for (var depth = 0; depth < 4; depth++) {
      final candidate = File('${directory.path}/$workspacePath');
      if (candidate.existsSync()) {
        return parse(candidate.readAsStringSync(), source: candidate.path);
      }
      final parent = directory.parent;
      if (parent.path == directory.path) break;
      directory = parent;
    }
    throw StateError(
      '$workspacePath was not found from ${Directory.current.path}. The Agent '
      'owns this file and generates it; a Client test never invents it.',
    );
  }

  /// Parses a contract document, validating its shape.
  static CliRelayGrammarContract parse(
    String document, {
    required String source,
  }) {
    final Object? decoded;
    try {
      decoded = jsonDecode(document);
    } on FormatException catch (error) {
      throw FormatException('$source is not JSON: ${error.message}');
    }
    if (decoded is! Map<String, Object?>) {
      throw FormatException('$source must contain a JSON object.');
    }
    final root = decoded;

    List<String> names(String key) {
      final value = root[key];
      if (value is! List || value.any((entry) => entry is! String)) {
        throw FormatException('$source: "$key" must be a list of strings.');
      }
      return value.cast<String>().toList(growable: false);
    }

    final rawAbbreviations = root['abbreviations'];
    if (rawAbbreviations is! Map<String, Object?>) {
      throw FormatException('$source: "abbreviations" must be an object.');
    }
    final abbreviations = <String, CliRelayGrammarAbbreviation>{};
    for (final entry in rawAbbreviations.entries) {
      final shape = entry.value;
      final takesValue = shape is Map<String, Object?> ? shape['takes_value'] : null;
      final shapeNames = shape is Map<String, Object?> ? shape['names'] : null;
      if (takesValue is! bool || shapeNames is! List) {
        throw FormatException(
          '$source: "abbreviations.${entry.key}" must carry a boolean '
          '"takes_value" and a "names" list.',
        );
      }
      if (shapeNames.any((name) => name is! String)) {
        throw FormatException(
          '$source: "abbreviations.${entry.key}.names" must be strings.',
        );
      }
      abbreviations[entry.key] = CliRelayGrammarAbbreviation(
        takesValue: takesValue,
        names: shapeNames.cast<String>().toList(growable: false),
      );
    }

    return CliRelayGrammarContract(
      longValueOptions: names('long_value_options'),
      longFlags: names('long_flags'),
      abbreviations: abbreviations,
    );
  }
}

/// One abbreviation's shape in the contract.
class CliRelayGrammarAbbreviation {
  const CliRelayGrammarAbbreviation({
    required this.takesValue,
    required this.names,
  });

  /// Whether the Agent reads a value for this abbreviation.
  final bool takesValue;

  /// Long option or flag names that declare this abbreviation.
  final List<String> names;
}
