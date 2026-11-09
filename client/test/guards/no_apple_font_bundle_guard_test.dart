// Guard: the Client must never bundle an Apple-provided font.
//
// Apple rejects iOS builds that embed its own typefaces (ITMS-91182: the SF Pro
// font that `flutter_sficon` shipped as `sficons.ttf`), and the restriction is
// enforced from 2027-10-01. The Client draws its send arrow with
// `CupertinoIcons`, whose font is authored by the Flutter team, so no Apple font
// is needed anywhere in the tree. This guard fails closed on every surface that
// can smuggle one back in:
//
//   * `pubspec.yaml` — a direct dependency on an Apple-font package;
//   * `pubspec.lock` — the resolved graph, which also catches a transitive pull;
//   * `assets/` names and refreshed `build/**` manifests — a font file or asset
//     entry that a dependency or a builder bundles silently.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Packages that ship an Apple-provided font, and the font they carry.
const Map<String, String> bannedAppleFontPackages = <String, String>{
  'flutter_sficon':
      'Apple SF Pro, bundled as packages/flutter_sficon/lib/fonts/sficons.ttf',
};

/// Lowercased tokens that identify an Apple-provided font file or asset entry.
const List<String> appleFontTokens = <String>[
  'sficons',
  'sfpro',
  'sf-pro',
  'sf pro',
  'sfcompact',
  'sf-compact',
  'sfmono',
  'sf-mono',
];

/// Matches a package key in `pubspec.yaml` or `pubspec.lock`.
RegExp packageDeclaration(String package) =>
    RegExp('^\\s+${RegExp.escape(package)}\\s*:', multiLine: true);

/// Every line of [text] that names an Apple-provided font.
List<String> appleFontEvidence(String text) {
  final evidence = <String>[];
  for (final line in const LineSplitter().convert(text)) {
    final normalized = line.toLowerCase();
    if (appleFontTokens.any(normalized.contains)) {
      evidence.add(line.trim());
    }
  }
  return evidence;
}

/// Bundled manifest files that list every asset the app can draw from.
bool _isAssetManifest(FileSystemEntity entity) {
  if (entity is! File) return false;
  final name = entity.uri.pathSegments.last;
  return name.startsWith('AssetManifest') || name.startsWith('FontManifest');
}

void main() {
  final packageRoot = _findPackageRoot();

  test('no dependency ships an Apple-provided font', () {
    final pubspec = File('${packageRoot.path}/pubspec.yaml').readAsStringSync();

    for (final package in bannedAppleFontPackages.keys) {
      expect(
        packageDeclaration(package).hasMatch(pubspec),
        isFalse,
        reason:
            '`$package` bundles ${bannedAppleFontPackages[package]} and fails '
            'ITMS-91182. Draw the icon with `CupertinoIcons` (or another '
            'Flutter-authored icon font) instead.',
      );
    }
  });

  test('the resolved dependency graph has no Apple-font package', () {
    final lock = File('${packageRoot.path}/pubspec.lock').readAsStringSync();

    for (final package in bannedAppleFontPackages.keys) {
      expect(
        packageDeclaration(package).hasMatch(lock),
        isFalse,
        reason:
            '`$package` is still resolved in pubspec.lock, either directly or '
            'through a transitive dependency; remove the dependency instead of '
            'perpetuating the lock entry.',
      );
    }
  });

  test('no bundled asset or build manifest carries an Apple-provided font', () {
    final offenders = <String>[];

    final assetNames = Directory('${packageRoot.path}/assets')
        .listSync(recursive: true)
        .whereType<File>()
        .map((file) => file.path);
    for (final path in assetNames) {
      offenders.addAll(appleFontEvidence(path));
    }

    final buildRoot = Directory('${packageRoot.path}/build');
    if (buildRoot.existsSync()) {
      final manifests = buildRoot
          .listSync(recursive: true)
          .where(_isAssetManifest)
          .cast<File>();
      for (final manifest in manifests) {
        final content = latin1.decode(manifest.readAsBytesSync());
        offenders.addAll(
          appleFontEvidence(content).map(
            (line) => '${manifest.path.substring(packageRoot.path.length + 1)}: $line',
          ),
        );
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'No Apple-provided font may be bundled (ITMS-91182). Found:\n'
          '${offenders.join('\n')}\n'
          'A build directory that predates this change must be refreshed before '
          'the manifests describe the current dependency set.',
    );
  });

  test('the guard recognizes a smuggled Apple font and ignores Flutter fonts', () {
    const manifest = '[\n'
        '  "packages/flutter_sficon/lib/fonts/sficons.ttf",\n'
        '  "fonts/SFProText-Regular.otf",\n'
        '  "assets/fonts/Cairo-Regular.ttf"\n'
        ']';

    expect(appleFontEvidence(manifest), hasLength(2));
    expect(appleFontEvidence(manifest).first, contains('sficons.ttf'));
    expect(appleFontEvidence(manifest).last, contains('SFProText-Regular.otf'));
    expect(
      appleFontEvidence('["packages/flutter_sficon/lib/fonts/sficons.ttf"]'),
      isNotEmpty,
      reason: 'A single-line manifest must still be rejected.',
    );
    expect(appleFontEvidence('packages/cupertino_icons/assets/CupertinoIcons.ttf'), isEmpty);
    expect(appleFontEvidence('assets/fonts/Cairo-SemiBold.ttf'), isEmpty);
    expect(packageDeclaration('flutter_sficon').hasMatch('  flutter_sficon:'), isTrue);
    expect(packageDeclaration('flutter_sficon').hasMatch('  flutter_sficon_extra:'), isFalse);
  });
}

Directory _findPackageRoot() {
  var directory = Directory.current;
  while (true) {
    if (File('${directory.path}/pubspec.yaml').existsSync() &&
        Directory('${directory.path}/lib').existsSync()) {
      return directory;
    }
    final parent = directory.parent;
    if (parent.path == directory.path) {
      throw StateError('Could not locate the Client package root.');
    }
    directory = parent;
  }
}
