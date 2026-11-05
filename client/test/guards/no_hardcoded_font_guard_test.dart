// Guard: the Client must never hardcode a font family.
//
// Every user-visible text style resolves its family from the active theme, so
// the font selected in Settings applies to all text. Two files own typography:
// the theme (which maps the selected `AppFontFamily` onto a `TextTheme`) and
// `AppTypography` (which resolves the selected family for hand-built styles and
// owns the single monospace constant). Any other `fontFamily:` literal or
// direct `GoogleFonts.<family>(` call is a regression: it silently ignores the
// user's choice.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Files allowed to name a font family or call `GoogleFonts` directly.
const Map<String, String> allowedFontOwners = <String, String>{
  'lib/core/theme/app_themes.dart':
      'maps the selected AppFontFamily onto the theme text styles',
  'lib/core/theme/app_typography.dart':
      'resolves the selected family and owns the monospace constant',
};

/// Generated localization output is not authored source.
const String generatedSourcePrefix = 'lib/l10n/';

/// A literal family: `fontFamily: 'monospace'`.
final RegExp hardcodedFamilyLiteral = RegExp('''fontFamily\\s*:\\s*['"]''');

/// A direct Google Fonts family call: `GoogleFonts.inter(`.
final RegExp directGoogleFontsCall = RegExp(r'GoogleFonts\s*\.');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final packageRoot = _findPackageRoot();
  final libRoot = Directory('${packageRoot.path}/lib');

  test('no font family is hardcoded outside the theme and the typography helper', () {
    final sourceFiles = libRoot
        .listSync(recursive: true)
        .whereType<File>()
        .where((file) => file.path.endsWith('.dart'))
        .toList();
    expect(
      sourceFiles,
      isNotEmpty,
      reason: 'No Dart source file was found under ${libRoot.path}.',
    );

    final offenders = <String>[];
    for (final file in sourceFiles) {
      final relativePath = _relativePath(packageRoot, file);
      if (relativePath.startsWith(generatedSourcePrefix)) continue;
      if (allowedFontOwners.containsKey(relativePath)) continue;

      final lines = file.readAsLinesSync();
      for (var index = 0; index < lines.length; index++) {
        final line = lines[index];
        if (hardcodedFamilyLiteral.hasMatch(line)) {
          offenders.add(
            '$relativePath:${index + 1} hardcodes a font family '
            '(use AppTypography.text or AppTypography.mono)',
          );
        }
        if (directGoogleFontsCall.hasMatch(line)) {
          offenders.add(
            '$relativePath:${index + 1} calls GoogleFonts directly '
            '(use AppTypography.text or AppTypography.mono)',
          );
        }
      }
    }

    expect(
      offenders,
      isEmpty,
      reason:
          'The font selected in Settings must apply to every text style. '
          'Found:\n${offenders.join('\n')}',
    );
  });

  test('the allowlist names only existing owning files', () {
    for (final path in allowedFontOwners.keys) {
      expect(
        File('${packageRoot.path}/$path').existsSync(),
        isTrue,
        reason: 'Allowlisted typography owner $path no longer exists; '
            'remove the stale entry.',
      );
    }
  });

  test('the guard detects a newly hardcoded family and ignores inherited ones', () {
    // Offending shapes.
    expect(hardcodedFamilyLiteral.hasMatch("fontFamily: 'monospace',"), isTrue);
    expect(hardcodedFamilyLiteral.hasMatch('fontFamily: "Georgia",'), isTrue);
    expect(directGoogleFontsCall.hasMatch('style: GoogleFonts.inter(),'), isTrue);
    expect(directGoogleFontsCall.hasMatch('GoogleFonts .roboto('), isTrue);

    // Allowed shapes: the family comes from the theme or a variable.
    expect(hardcodedFamilyLiteral.hasMatch('fontFamily: selected?.fontFamily,'), isFalse);
    expect(hardcodedFamilyLiteral.hasMatch('fontFamily: fontFamily,'), isFalse);
    expect(hardcodedFamilyLiteral.hasMatch('l10n.fontFamily,'), isFalse);
    expect(directGoogleFontsCall.hasMatch('AppTypography.mono(),'), isFalse);
  });

  test('the default font is bundled for offline use on every platform', () {
    final pubspec = File('${packageRoot.path}/pubspec.yaml').readAsStringSync();
    final fontsBlock = pubspec.substring(pubspec.indexOf('\n  fonts:'));

    expect(
      fontsBlock,
      contains('family: Cairo'),
      reason: 'The Cairo default font must ship as a Flutter asset family.',
    );
    for (final weight in const [400, 500, 600, 700]) {
      expect(
        fontsBlock,
        contains('weight: $weight'),
        reason: 'Cairo weight $weight is used by the Client theme and widgets.',
      );
    }
    for (final variant in const ['Regular', 'Medium', 'SemiBold', 'Bold']) {
      final asset = 'assets/fonts/Cairo-$variant.ttf';
      expect(fontsBlock, contains(asset));
      expect(
        File('${packageRoot.path}/$asset').existsSync(),
        isTrue,
        reason: 'Bundled font $asset is missing from the repository.',
      );
    }
  });

  test('the bundled Cairo asset is readable through the asset bundle', () async {
    final bytes = await rootBundle.load('assets/fonts/Cairo-Regular.ttf');
    expect(bytes.lengthInBytes, greaterThan(0));
  });
}

String _relativePath(Directory packageRoot, File file) =>
    file.path.substring(packageRoot.path.length + 1);

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
