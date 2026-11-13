// Plan 174f — localization guard for the notification surfaces.
//
// Every string a user reads in this feature is authored in `client/lib/l10n`,
// translated in both locales, and referenced by key. This guard fails on the
// three ways that invariant usually breaks: a hard-coded widget string, an
// Arabic literal in Dart source, and a referenced key that one locale does not
// author.
//
// It reads the repository files directly, so it also runs for a change that
// forgets to regenerate the localization Dart.

import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Files whose user-facing text must come from the localization system.
///
/// The device header belongs here because it renders this feature's context —
/// the device a notification is about — and it used to mix localized and
/// hard-coded copy inside one row.
const List<String> _guardedFiles = <String>[
  'client/lib/features/notifications/presentation/notification_copy_source.dart',
  'client/lib/features/notifications/presentation/bloc/notification_settings_state.dart',
  'client/lib/features/settings/presentation/widgets/settings_pages/notifications_page.dart',
  'client/lib/features/conversations/presentation/widgets/sidebar/sidebar_device_header_bar.dart',
];

/// Directories scanned as a whole, in addition to [_guardedFiles].
const List<String> _guardedDirectories = <String>[
  'client/lib/features/notifications',
];

final RegExp _localizationReference = RegExp(r'(?:l10n|_localizations)\.([a-zA-Z][a-zA-Z0-9]*)');
final RegExp _hardCodedText = RegExp(r'''(?:Text|Semantics)\(\s*(?:'|")''');
final RegExp _arabicText = RegExp(r'[\u0600-\u06FF]');

void main() {
  late Map<String, dynamic> english;
  late Map<String, dynamic> arabic;

  setUpAll(() {
    english = _readArb('client/lib/l10n/app_en.arb');
    arabic = _readArb('client/lib/l10n/app_ar.arb');
  });

  test('every notification surface references localization keys only', () {
    final sources = _guardedSources();
    expect(sources, isNotEmpty);

    for (final entry in sources.entries) {
      expect(
        _hardCodedText.hasMatch(entry.value),
        isFalse,
        reason: '${entry.key} passes a string literal to Text(...); author it in the ARB files',
      );
      expect(
        _arabicText.hasMatch(entry.value),
        isFalse,
        reason: '${entry.key} contains an Arabic literal; the ARB files own translated text',
      );
    }
  });

  test('every referenced localization key is authored in both locales', () {
    final referenced = <String>{};
    for (final source in _guardedSources().values) {
      for (final match in _localizationReference.allMatches(_withoutImports(source))) {
        referenced.add(match.group(1)!);
      }
    }

    expect(referenced, isNotEmpty);
    final missingEnglish = referenced.difference(_messageKeys(english));
    final missingArabic = referenced.difference(_messageKeys(arabic));

    expect(missingEnglish, isEmpty, reason: 'these keys are referenced but not authored in app_en.arb');
    expect(missingArabic, isEmpty, reason: 'these keys are referenced but not authored in app_ar.arb');
  });

  test('the notification key set is translated in Arabic', () {
    final notificationKeys = _messageKeys(english)
        .where((key) => key.startsWith('notification'))
        .toSet();
    expect(notificationKeys, isNotEmpty);

    for (final key in notificationKeys) {
      final value = arabic[key];
      expect(value, isA<String>(), reason: '$key is missing from app_ar.arb');
      expect(
        _arabicText.hasMatch(value! as String),
        isTrue,
        reason: '$key is not translated in app_ar.arb',
      );
    }
  });
}

/// Drops import and export lines, so a package path such as
/// `package:sanad_client/l10n/app_localizations.dart` is not read as a key.
String _withoutImports(String source) => source
    .split('\n')
    .where((line) {
      final trimmed = line.trimLeft();
      return !trimmed.startsWith('import ') &&
          !trimmed.startsWith('export ') &&
          !trimmed.startsWith('part ');
    })
    .join('\n');

/// Keyed by repository-relative path, so a failure names the file.
Map<String, String> _guardedSources() {
  final sources = <String, String>{};
  for (final path in _guardedFiles) {
    final file = _locate(path);
    if (!file.existsSync()) continue;
    sources[path] = file.readAsStringSync();
  }
  for (final directory in _guardedDirectories) {
    final root = _locateDirectory(directory);
    if (root == null) continue;
    for (final entity in root.listSync(recursive: true)) {
      if (entity is! File || !entity.path.endsWith('.dart')) continue;
      sources[_relative(entity.path)] = entity.readAsStringSync();
    }
  }
  return sources;
}

String _relative(String path) {
  final marker = 'features/';
  final index = path.indexOf(marker);
  return index == -1 ? path : path.substring(index - 'client/lib/'.length);
}

Map<String, dynamic> _readArb(String relativePath) =>
    jsonDecode(_locate(relativePath).readAsStringSync()) as Map<String, dynamic>;

/// Finds a repository-relative file from either the package root or the
/// repository root, so the suite does not depend on the caller's directory.
File _locate(String relativePath) {
  var directory = Directory.current;
  for (var depth = 0; depth < 8; depth += 1) {
    final candidate = File('${directory.path}/$relativePath');
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  fail('Could not find $relativePath above ${Directory.current.path}.');
}

Set<String> _messageKeys(Map<String, dynamic> arb) => <String>{
      for (final key in arb.keys)
        if (!key.startsWith('@')) key,
    };

/// The same lookup as [_locate], for a directory.
Directory? _locateDirectory(String relativePath) {
  var directory = Directory.current;
  for (var depth = 0; depth < 8; depth += 1) {
    final candidate = Directory('${directory.path}/$relativePath');
    if (candidate.existsSync()) return candidate;
    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }
  return null;
}
