/// The Agent CLI grammar contract shared with the `sanad-client` relay.
///
/// The relay reads a forwarded argv with the Agent's `args` grammar before it
/// forwards anything: an approval is scoped to the session the command will act
/// on, and a value that looks like an option must never be re-read as one. That
/// reading is only safe while the caller's option table matches the Agent's, so
/// this library extracts the real grammar from `SanadCommandRunner` — every
/// command and subcommand parser recursively, plus the global parser — and
/// renders the checked-in contract that both sides assert against.
///
/// `package:args` walks up to the parent parser for an option a subcommand does
/// not declare, so a name is live anywhere in an argv once *any* parser declares
/// it. The contract is therefore the union across parsers, and it stays a
/// superset reading: a name every parser rejects is still safe to read as a
/// flag, because the Agent refuses the command before it acts.
///
/// Protocol: `docs/technical/remote_cli_relay_protocol.md`.
library;

import 'dart:collection';
import 'dart:convert';

import 'package:args/args.dart';
import 'package:args/command_runner.dart';
import 'package:sanad_agent/cli/runner/sanad_command_runner.dart';

/// Checked-in contract path, relative to the `agent/` package root.
const String cliRelayGrammarContractPath =
    'test/fixtures/cli_relay_grammar.json';

/// Regenerate command, relative to the workspace root.
const String cliRelayGrammarRegenerateCommand =
    'cd agent && fvm dart run tool/generate_cli_relay_grammar.dart';

/// One long option that consumes a value, in every place it is declared.
class CliRelayOptionDeclaration {
  CliRelayOptionDeclaration({required this.name, required this.parser});

  /// Long option name exactly as `args` matches it, alias included.
  final String name;

  /// Human-readable parser path (`sanad session steer`).
  final String parser;
}

/// One abbreviation and the declarations that use it.
class CliRelayAbbreviation {
  const CliRelayAbbreviation({required this.takesValue, required this.names});

  /// Whether the abbreviation consumes a value.
  ///
  /// The caller is name-agnostic about short options (`-f` names a different
  /// long option on `session steer` and on `session answer`), so one letter must
  /// take a value everywhere it is accepted or nowhere.
  final bool takesValue;

  /// Long names that declare this abbreviation, sorted.
  final List<String> names;

  Map<String, Object?> toJson() => {'takes_value': takesValue, 'names': names};

  @override
  bool operator ==(Object other) =>
      other is CliRelayAbbreviation &&
      other.takesValue == takesValue &&
      _sameNames(other.names, names);

  @override
  int get hashCode => Object.hash(takesValue, Object.hashAll(names));

  static bool _sameNames(List<String> a, List<String> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }
}

/// The relay grammar: every value option, every flag, every abbreviation.
class CliRelayGrammar {
  CliRelayGrammar({
    required Iterable<String> longValueOptions,
    required Iterable<String> longFlags,
    required Map<String, CliRelayAbbreviation> abbreviations,
  }) : longValueOptions = _sorted(longValueOptions),
       longFlags = _sorted(longFlags),
       abbreviations = Map.unmodifiable(SplayTreeMap.of(abbreviations));

  /// Long options that consume a value, aliases included, sorted.
  final List<String> longValueOptions;

  /// Long flags, sorted.
  final List<String> longFlags;

  static List<String> _sorted(Iterable<String> names) =>
      List.unmodifiable(SplayTreeSet<String>()..addAll(names));

  /// Abbreviation letter to its value-taking shape and declaring long names.
  final Map<String, CliRelayAbbreviation> abbreviations;

  /// Extracts the grammar of the real `SanadCommandRunner`.
  ///
  /// Throws a [StateError] naming the parsers involved when one name is both a
  /// value option and a flag, or one abbreviation both takes and omits a value:
  /// either shape would make a caller's reading of the same argv differ from the
  /// Agent's, which is the failure this contract exists to prevent.
  static CliRelayGrammar extract() {
    final runner = SanadCommandRunner(
      stdoutSink: StringBuffer(),
      stderrSink: StringBuffer(),
    );

    final declarations = <CliRelayOptionDeclaration>[];
    final flagDeclarations = <CliRelayOptionDeclaration>[];
    final abbreviations = <String, List<CliRelayOptionDeclaration>>{};
    final takesValue = <String, Set<bool>>{};

    void collectParser(ArgParser parser, String path) {
      if (parser.allowsAnything) return;
      for (final option in parser.options.values) {
        final declaration = CliRelayOptionDeclaration(
          name: option.name,
          parser: path,
        );
        if (option.isFlag) {
          flagDeclarations.add(declaration);
        } else {
          declarations.add(declaration);
          for (final alias in option.aliases) {
            declarations.add(
              CliRelayOptionDeclaration(name: alias, parser: path),
            );
          }
        }
        final abbreviation = option.abbr;
        if (abbreviation == null) continue;
        final takesValueHere = !option.isFlag;
        (takesValue[abbreviation] ??= <bool>{}).add(takesValueHere);
        (abbreviations[abbreviation] ??= <CliRelayOptionDeclaration>[]).add(
          declaration,
        );
      }
    }

    void collectCommand(Command<int> command, String path) {
      collectParser(command.argParser, path);
      for (final entry in command.subcommands.entries) {
        collectCommand(entry.value, '$path ${entry.key}');
      }
    }

    collectParser(runner.argParser, 'sanad');
    for (final entry in runner.commands.entries) {
      collectCommand(entry.value, 'sanad ${entry.key}');
    }

    final flagNames = {for (final flag in flagDeclarations) flag.name};
    final conflicts = <String, List<String>>{};
    for (final declaration in declarations) {
      if (!flagNames.contains(declaration.name)) continue;
      (conflicts[declaration.name] ??= <String>[]).add(declaration.parser);
    }
    if (conflicts.isNotEmpty) {
      final details = conflicts.entries.map((entry) {
        final flagParsers = flagDeclarations
            .where((flag) => flag.name == entry.key)
            .map((flag) => flag.parser)
            .join(', ');
        return '--${entry.key}: value option in ${entry.value.join(', ')}; '
            'flag in $flagParsers';
      }).join('\n');
      throw StateError(
        'CLI relay grammar is ambiguous: one name is both a value option and a '
        'flag, so a caller and the Agent would read the same argv differently.'
        '\n$details',
      );
    }

    for (final entry in takesValue.entries) {
      if (entry.value.length == 1) continue;
      throw StateError(
        'CLI relay grammar is ambiguous: -${entry.key} takes a value in some '
        'parsers and not in others (${abbreviations[entry.key]!.map((d) => d.parser).join(', ')}), '
        'so a caller cannot read a short option without knowing the command.',
      );
    }

    return CliRelayGrammar(
      longValueOptions: declarations.map((declaration) => declaration.name),
      longFlags: flagNames,
      abbreviations: {
        for (final entry in abbreviations.entries)
          entry.key: CliRelayAbbreviation(
            takesValue: takesValue[entry.key]!.single,
            names: _sorted(
              entry.value.map((declaration) => declaration.name),
            ),
          ),
      },
    );
  }

  /// Reads a contract document, validating its shape.
  static CliRelayGrammar fromJson(Object? json) {
    if (json is! Map<String, Object?>) {
      throw const FormatException('The relay grammar must be a JSON object.');
    }
    List<String> names(String key) {
      final value = json[key];
      if (value is! List || value.any((entry) => entry is! String)) {
        throw FormatException('"$key" must be a list of strings.');
      }
      return value.cast<String>().toList(growable: false);
    }

    final rawAbbreviations = json['abbreviations'];
    if (rawAbbreviations is! Map<String, Object?>) {
      throw const FormatException('"abbreviations" must be a JSON object.');
    }
    final abbreviations = <String, CliRelayAbbreviation>{};
    for (final entry in rawAbbreviations.entries) {
      final shape = entry.value;
      if (shape is! Map<String, Object?> || shape['takes_value'] is! bool) {
        throw FormatException(
          '"abbreviations.${entry.key}" must be an object with a boolean '
          '"takes_value".',
        );
      }
      final shapeNames = shape['names'];
      if (shapeNames is! List || shapeNames.any((name) => name is! String)) {
        throw FormatException(
          '"abbreviations.${entry.key}.names" must be a list of strings.',
        );
      }
      abbreviations[entry.key] = CliRelayAbbreviation(
        takesValue: shape['takes_value']! as bool,
        names: shapeNames.cast<String>().toList(growable: false),
      );
    }

    return CliRelayGrammar(
      longValueOptions: names('long_value_options'),
      longFlags: names('long_flags'),
      abbreviations: abbreviations,
    );
  }

  /// Ordered document for [encode].
  Map<String, Object?> toJson() => {
    'generated_by': cliRelayGrammarRegenerateCommand,
    'long_value_options': longValueOptions.toList(growable: false),
    'long_flags': longFlags.toList(growable: false),
    'abbreviations': {
      for (final entry in abbreviations.entries)
        entry.key: entry.value.toJson(),
    },
  };

  /// Canonical `LF`-only text with a trailing newline.
  String encode() =>
      '${const JsonEncoder.withIndent('  ').convert(toJson())}\n';

  /// Names this contract has that [other] does not, per section.
  ///
  /// Used by the generator's `--check` mode and the contract test to explain a
  /// mismatch instead of only reporting it.
  List<String> differencesFrom(CliRelayGrammar other) {
    final differences = <String>[];
    void compare(String section, Set<String> mine, Set<String> theirs) {
      for (final name in mine.difference(theirs)) {
        differences.add('+ $section: $name');
      }
      for (final name in theirs.difference(mine)) {
        differences.add('- $section: $name');
      }
    }

    compare(
      'long option',
      longValueOptions.toSet(),
      other.longValueOptions.toSet(),
    );
    compare('flag', longFlags.toSet(), other.longFlags.toSet());
    compare(
      'abbreviation',
      abbreviations.keys.toSet(),
      other.abbreviations.keys.toSet(),
    );
    for (final entry in abbreviations.entries) {
      final otherShape = other.abbreviations[entry.key];
      if (otherShape == null || otherShape == entry.value) continue;
      if (otherShape.takesValue != entry.value.takesValue) {
        differences.add(
          '~ abbreviation -${entry.key}: takes a value '
          '${otherShape.takesValue}, now ${entry.value.takesValue}',
        );
      }
      if (CliRelayAbbreviation._sameNames(
        otherShape.names,
        entry.value.names,
      )) {
        continue;
      }
      differences.add(
        '~ abbreviation -${entry.key}: names '
        '${otherShape.names.join('/')}, now ${entry.value.names.join('/')}',
      );
    }
    return differences;
  }

  @override
  bool operator ==(Object other) =>
      other is CliRelayGrammar && other.encode() == encode(); // canonical rendering is the contract

  @override
  int get hashCode => encode().hashCode;
}
