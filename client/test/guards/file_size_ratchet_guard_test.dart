// Plan 113b — SRP size ratchet for the Client package.
//
// A non-generated `lib/` source file over 1000 lines fails this guard unless it
// is allowlisted below at its current size, and an allowlisted file may only
// shrink. Split the file, or move whole widgets into their own library; never
// raise a recorded number. Remove the entry once its file is under the limit.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Maximum line count for a production file that has no allowlist entry.
const int productionLineLimit = 1000;

/// Allowlisted production files and the largest line count each may have.
///
/// Numbers only go down. The split that shrinks a file lowers its number in
/// the same pull request, and a file that drops under [productionLineLimit]
/// loses its entry.
const Map<String, int> allowlistedFiles = <String, int>{
  'lib/driver_main.dart': 1035,
  'lib/features/conversations/data/transport/conversation_commands.dart': 1106,
  'lib/features/conversations/domain/stores/device_conversation_store.dart':
      1058,
  'lib/features/conversations/presentation/bloc/session_cubit.dart': 1227,
  'lib/features/conversations/presentation/bloc/session_messages_cubit.dart':
      1571,
  'lib/features/conversations/presentation/screens/brain_activity_view.dart':
      1687,
  'lib/features/mcp/presentation/screens/add_mcp_server_screen.dart': 1178,
  'lib/features/mcp/presentation/screens/mcp_server_management_screen.dart':
      1055,
  'lib/features/provider_setup/presentation/bloc/provider_setup_cubit.dart':
      1119,
};

void main() {
  final packageRoot = _findPackageRoot();
  final libRoot = Directory('${packageRoot.path}/lib');

  test('non-generated lib files stay inside the size ratchet', () {
    final productionFiles = _productionFiles(libRoot);
    expect(
      productionFiles,
      isNotEmpty,
      reason: 'No Dart production file was found under ${libRoot.path}.',
    );

    final offenders = <String>[];
    for (final file in productionFiles) {
      final relativePath = _relativePath(packageRoot, file);
      final lineCount = file.readAsLinesSync().length;
      final allowlistedAt = allowlistedFiles[relativePath];

      if (allowlistedAt == null) {
        if (lineCount > productionLineLimit) {
          offenders.add(
            '$relativePath — $lineCount lines, no allowlist entry '
            '(limit $productionLineLimit)',
          );
        }
        continue;
      }

      if (lineCount > allowlistedAt) {
        offenders.add(
          '$relativePath — $lineCount lines, allowlisted at $allowlistedAt',
        );
      }
    }

    expect(offenders, isEmpty, reason: _offenderMessage(offenders));
  });

  test('every allowlist entry names an existing non-generated lib file', () {
    final known = _productionFiles(
      libRoot,
    ).map((file) => _relativePath(packageRoot, file)).toSet();

    final stale = allowlistedFiles.keys.where((path) => !known.contains(path));
    expect(
      stale,
      isEmpty,
      reason:
          'These allowlist entries no longer name a scanned Client lib file. '
          'Remove them so the ratchet has no dead entries: '
          '${stale.join(', ')}',
    );
  });

  test('generated sources are excluded from the ratchet', () {
    for (final generatedPath in <String>[
      'lib/features/conversations/domain/models/message.g.dart',
      'lib/features/conversations/domain/models/message.freezed.dart',
      'lib/features/provider_setup/generated_provider_templates.dart',
      'lib/l10n/app_localizations.dart',
      'lib/l10n/app_localizations_ar.dart',
    ]) {
      expect(
        isGeneratedSource(generatedPath),
        isTrue,
        reason: '$generatedPath must be treated as generated output',
      );
    }

    for (final handwrittenPath in <String>[
      'lib/driver_main.dart',
      'lib/features/settings/presentation/widgets/settings_pages/general_page.dart',
      'lib/utils/toast_utils.dart',
    ]) {
      expect(
        isGeneratedSource(handwrittenPath),
        isFalse,
        reason: '$handwrittenPath must stay inside the ratchet',
      );
    }
  });
}

/// Whether [path] is generated output the ratchet must not police.
///
/// `gen_l10n` writes `lib/l10n/app_localizations*.dart` on every build; those
/// files are gitignored generated output and grow with the translation catalog.
bool isGeneratedSource(String path) {
  final fileName = path.split('/').last;
  return fileName.endsWith('.g.dart') ||
      fileName.endsWith('.freezed.dart') ||
      fileName.startsWith('generated_') ||
      fileName.startsWith('app_localizations');
}

Iterable<File> _productionFiles(Directory libRoot) {
  if (!libRoot.existsSync()) {
    fail('Production source directory ${libRoot.path} does not exist.');
  }

  return libRoot
      .listSync(recursive: true)
      .whereType<File>()
      .where((file) => file.path.endsWith('.dart'))
      .where((file) => !isGeneratedSource(file.uri.pathSegments.last));
}

String _relativePath(Directory packageRoot, File file) {
  final rootPath = packageRoot.absolute.path;
  final filePath = file.absolute.path;
  return filePath.startsWith('$rootPath/')
      ? filePath.substring(rootPath.length + 1)
      : filePath;
}

String _offenderMessage(List<String> offenders) {
  if (offenders.isEmpty) return '';

  final buffer = StringBuffer()
    ..writeln('SRP size ratchet failed for ${offenders.length} file(s):');
  for (final offender in offenders) {
    buffer.writeln('  - $offender');
  }
  buffer
    ..writeln('')
    ..writeln(
      'Split each file by responsibility, or move the widgets into the owner '
      'that already renders them, until it fits the limit.',
    )
    ..writeln(
      'Never raise the recorded number and never add an allowlist entry to '
      'absorb new growth: the allowlist only shrinks.',
    );
  return buffer.toString();
}

Directory _findPackageRoot() {
  var directory = Directory.current;
  for (var depth = 0; depth < 4; depth++) {
    final hasPubspec = File('${directory.path}/pubspec.yaml').existsSync();
    final hasLib = Directory('${directory.path}/lib').existsSync();
    if (hasPubspec && hasLib) return directory;

    final parent = directory.parent;
    if (parent.path == directory.path) break;
    directory = parent;
  }

  fail(
    'Could not locate the Client package root from ${Directory.current.path}. '
    'Run this guard from the Client package root.',
  );
}
