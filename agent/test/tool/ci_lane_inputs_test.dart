// Guards the declared CI lane input sets.
//
// `classify` in `.github/workflows/ci.yml` decides which lanes run from
// `scripts/ci/lane_inputs.txt`. That is a deliberate relaxation of the old
// "any `agent/**` change runs the Agent lanes" rule: `Native dictation` and
// `sanad-dev bootstrap` now run only when a file they actually consume changed.
// The relaxation is only safe while the declared globs really do contain every
// file those lanes execute, so this suite enforces that mechanically instead of
// trusting a hand-maintained list:
//
// 1. The declarations parse, and every declared lane is one the workflow knows.
// 2. Every "run every lane" trigger is still declared - dropping one silently
//    narrows classification for changes that can affect every lane.
// 3. Every declared entrypoint exists, and every entrypoint matches one of its
//    lane's globs.
// 4. The Dart import closure of the `native-stt` entrypoints - resolved through
//    the package config, exactly like the compiler does - is covered by that
//    lane's globs. A new `lib/` file that a smoke test imports therefore fails
//    here instead of silently stopping the lane from running.
// 5. The path dependencies of the `sanad_dev` package are covered by some glob.
//
// `docs/operations/continuous_integration.md` owns the model behind the gating.

import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:test/test.dart';
import 'package:yaml/yaml.dart';

/// This suite runs with the Agent package as its working directory.
const String _repositoryRoot = '..';

/// Lanes the classifier consumes, in addition to the special `all` lane.
const Set<String> _lanes = <String>{'native-stt', 'sanad-dev'};

/// Patterns whose absence would narrow classification for a change that can
/// affect every lane. They are asserted, not derived, because the point is that
/// nobody removes one while narrowing a lane.
const List<String> _requiredAllGlobs = <String>[
  '.github/workflows/*',
  '.github/actions/*',
  'scripts/ci/*',
  '.fvmrc',
  'pubspec.yaml',
  'pubspec.lock',
  '*/pubspec.yaml',
  '*/pubspec.lock',
  'agent/native/*',
  'shared/*',
];

final String _repoRootPath = p.normalize(p.absolute(_repositoryRoot));

void main() {
  final declarations = _readDeclarations();
  final globs = <String, List<String>>{};
  final entries = <String, List<String>>{};
  for (final declaration in declarations) {
    final target = declaration.kind == 'glob' ? globs : entries;
    target.putIfAbsent(declaration.lane, () => <String>[]).add(declaration.value);
  }

  group('declarations', () {
    test('every line declares a known kind and lane', () {
      expect(declarations, isNotEmpty);
      for (final declaration in declarations) {
        expect(
          declaration.kind,
          anyOf('glob', 'entry'),
          reason: 'Unexpected kind on: ${declaration.source}',
        );
        expect(
          <String>{..._lanes, 'all'},
          contains(declaration.lane),
          reason: 'Unexpected lane on: ${declaration.source}',
        );
        expect(
          declaration.value,
          isNotEmpty,
          reason: 'Empty value on: ${declaration.source}',
        );
      }
    });

    test('every non-`all` lane declares globs and entrypoints', () {
      for (final lane in _lanes) {
        expect(
          globs[lane],
          isNotNull,
          reason: '$lane declares no globs, so it could never be selected.',
        );
        expect(
          entries[lane],
          isNotNull,
          reason: '$lane declares no entrypoints, so its closure is unguarded.',
        );
      }
    });

    test('globs use the supported shell subset', () {
      for (final pattern in globs.values.expand((patterns) => patterns)) {
        expect(pattern, isNot(startsWith('/')));
        expect(pattern, isNot(contains('..')));
        for (final unsupported in <String>['[', ']', '{', '}', '\\']) {
          expect(
            pattern,
            isNot(contains(unsupported)),
            reason: 'Unsupported character "$unsupported" in "$pattern".',
          );
        }
      }
    });

    test('the always-run triggers are all still declared', () {
      final declared = globs['all'] ?? const <String>[];
      for (final required in _requiredAllGlobs) {
        expect(
          declared,
          contains(required),
          reason:
              '`$required` must run every lane: a change there can change the '
              'meaning of any lane.',
        );
      }
    });
  });

  group('entrypoints', () {
    test('every declared entrypoint exists in the repository', () {
      for (final entry in entries.values.expand((paths) => paths)) {
        expect(
          File(p.join(_repoRootPath, entry)).existsSync(),
          isTrue,
          reason: 'Declared entrypoint "$entry" does not exist.',
        );
      }
    });

    test('every entrypoint matches one of its own lane globs', () {
      entries.forEach((lane, paths) {
        final patterns = globs[lane] ?? const <String>[];
        for (final path in paths) {
          expect(
            patterns.any((pattern) => _matches(pattern, path)),
            isTrue,
            reason: '"$path" is executed by $lane but no $lane glob covers it.',
          );
        }
      });
    });
  });

  group('native-stt closure', () {
    test('the Dart import closure of the entrypoints is fully covered', () {
      final packages = _packageRoots();
      expect(
        packages,
        isNotEmpty,
        reason:
            'No package configuration was resolved, so the closure cannot be '
            'checked. Run `fvm dart pub get` in agent/ first.',
      );
      final closure = _closure(entries['native-stt']!, packages);
      expect(closure, isNotEmpty);
      final coveredBy = <String>[...?globs['native-stt'], ...?globs['all']];
      final uncovered = closure.where(
        (path) => !coveredBy.any((pattern) => _matches(pattern, path)),
      );
      expect(
        uncovered,
        isEmpty,
        reason:
            'These files are imported by a Native dictation entrypoint but no '
            'declared glob covers them, so a change to them would not run that '
            'lane. Add a `glob native-stt` line in '
            'scripts/ci/lane_inputs.txt:\n${uncovered.join('\n')}',
      );
    });
  });

  group('sanad-dev inputs', () {
    test('every path dependency of the package is covered by some glob', () {
      final pubspec =
          loadYaml(File(p.join(_repoRootPath, 'scripts/sanad_dev/pubspec.yaml'))
              .readAsStringSync()) as YamlMap;
      final paths = <String>{
        for (final section in <String>['dependencies', 'dev_dependencies'])
          if (pubspec[section] is YamlMap)
            for (final dependency in (pubspec[section] as YamlMap).values)
              if (dependency is YamlMap && dependency['path'] is String)
                p.posix.normalize(
                  p.url.join('scripts/sanad_dev', dependency['path'] as String),
                ),
      };
      expect(paths, isNotEmpty);
      final coveredBy = globs.values.expand((patterns) => patterns);
      for (final path in paths) {
        expect(
          coveredBy.any((pattern) => _matches(pattern, path)),
          isTrue,
          reason:
              '`sanad_dev` depends on "$path", so a change there must run the '
              'sanad-dev lane (or every lane).',
        );
      }
    });
  });
}

class _Declaration {
  _Declaration(this.kind, this.lane, this.value, this.source);

  final String kind;
  final String lane;
  final String value;
  final String source;
}

List<_Declaration> _readDeclarations() {
  final file = File(p.join(_repoRootPath, 'scripts/ci/lane_inputs.txt'));
  if (!file.existsSync()) {
    throw StateError(
      '${file.path} is missing; the classifier would run every lane, so there '
      'is nothing to guard.',
    );
  }
  final declarations = <_Declaration>[];
  final lines = file.readAsLinesSync();
  for (var index = 0; index < lines.length; index++) {
    final line = lines[index].trim();
    if (line.isEmpty || line.startsWith('#')) continue;
    final fields = line.split(RegExp(r'\s+'));
    if (fields.length < 3) {
      throw FormatException(
        'Line ${index + 1} of scripts/ci/lane_inputs.txt is not '
        '`<kind> <lane> <value>`: $line',
      );
    }
    declarations.add(
      _Declaration(
        fields.first,
        fields[1],
        fields.skip(2).join(' '),
        'line ${index + 1}: $line',
      ),
    );
  }
  return declarations;
}

/// Translates the declared glob subset (`*`, `?`) into a regular expression.
///
/// The classifier matches with bash `case`, where `*` also matches `/`; the
/// translation has to agree or a file could be covered in one place and not the
/// other.
bool _matches(String pattern, String path) {
  final buffer = StringBuffer('^');
  for (final character in pattern.split('')) {
    switch (character) {
      case '*':
        buffer.write('.*');
      case '?':
        buffer.write('.');
      default:
        buffer.write(RegExp.escape(character));
    }
  }
  buffer.write(r'$');
  return RegExp(buffer.toString()).hasMatch(path);
}

/// Absolute directory of every package the Agent can resolve, keyed by name.
Map<String, String> _packageRoots() {
  final config = File('.dart_tool/package_config.json');
  if (!config.existsSync()) return <String, String>{};
  final decoded =
      jsonDecode(config.readAsStringSync()) as Map<String, dynamic>;
  final base = config.absolute.parent.uri;
  final roots = <String, String>{};
  for (final entry in (decoded['packages'] as List<dynamic>)) {
    final package = entry as Map<String, dynamic>;
    final rootUri = Uri.parse(package['rootUri'] as String);
    final resolved = base.resolveUri(rootUri);
    if (resolved.scheme != 'file') continue;
    roots[package['name'] as String] = p.normalize(resolved.toFilePath());
  }
  return roots;
}

/// Repository-relative paths of every file reachable from [entrypoints] through
/// `import`, `export`, and `part` directives, restricted to this repository.
Set<String> _closure(
  List<String> entrypoints,
  Map<String, String> packageRoots,
) {
  final directive = RegExp(
    r'''^\s*(?:import|export|part)\s+['"]([^'"]+)['"]''',
    multiLine: true,
  );
  final seen = <String>{};
  final queue = <File>[
    for (final entry in entrypoints) File(p.join(_repoRootPath, entry)),
  ];
  while (queue.isNotEmpty) {
    final file = queue.removeLast();
    final absolute = p.normalize(file.absolute.path);
    if (!file.existsSync()) continue;
    if (!seen.add(absolute)) continue;
    for (final match in directive.allMatches(file.readAsStringSync())) {
      final target = _resolve(file, match.group(1)!, packageRoots);
      if (target == null) continue;
      if (target != _repoRootPath && !p.isWithin(_repoRootPath, target)) continue;
      queue.add(File(target));
    }
  }
  return seen.map((path) => p.relative(path, from: _repoRootPath).replaceAll(r'\', '/')).toSet();
}

String? _resolve(File from, String uri, Map<String, String> packageRoots) {
  if (uri.startsWith('dart:')) return null;
  if (uri.startsWith('package:')) {
    final rest = uri.substring('package:'.length);
    final separator = rest.indexOf('/');
    if (separator < 0) return null;
    final root = packageRoots[rest.substring(0, separator)];
    if (root == null) return null;
    return p.normalize(p.join(root, 'lib', rest.substring(separator + 1)));
  }
  if (uri.contains(':')) return null;
  return p.normalize(p.join(from.parent.path, uri));
}
