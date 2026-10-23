// Plan 138 — SRP size ratchet for the Agent package.
//
// A non-generated `lib/` source file over 1000 lines fails this guard unless it
// is allowlisted below at its current size, and an allowlisted file may only
// shrink. Split the file, or move whole lines into their real owner; never
// raise a recorded number. Remove the entry once its file is under the limit.

import 'dart:io';

import 'package:test/test.dart';

/// Maximum line count for a production file that has no allowlist entry.
const int productionLineLimit = 1000;

/// Allowlisted production files and the largest line count each may have.
///
/// Numbers only go down. The split that shrinks a file lowers its number in
/// the same pull request, and a file that drops under [productionLineLimit]
/// loses its entry.
const Map<String, int> allowlistedFiles = <String, int>{
  'lib/cli/client/local_gateway_cli_client.dart': 1247,
  'lib/cli/oneshot/oneshot_runner.dart': 1496,
  'lib/core/setup/linux_service_manager.dart': 1079,
  'lib/engine/adapters/base_anthropic_adapter.dart': 1260,
  'lib/engine/adapters/base_openai_adapter.dart': 1515,
  'lib/engine/agent_runner.dart': 2025,
  'lib/engine/context/context_compaction_engine.dart': 2026,
  'lib/engine/runtime/tool_execution_coordinator.dart': 1116,
  'lib/evolution/db/compaction_boundary_repository.dart': 1173,
  'lib/evolution/db/runtime/session_execution_state_coordinator.dart': 1227,
  'lib/evolution/scheduling/schedule_model.dart': 1264,
  'lib/interfaces/platforms/sanad_gateway/handlers/provider_command_handler.dart':
      1122,
  'lib/interfaces/platforms/sanad_gateway/server_sanad_gateway_platform.dart':
      1010,
  'lib/interfaces/runtime/session_run_orchestrator.dart': 1847,
  'lib/interfaces/runtime/session_turn_executor.dart': 1004,
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
          'These allowlist entries no longer name a scanned Agent lib file. '
          'Remove them so the ratchet has no dead entries: '
          '${stale.join(', ')}',
    );
  });

  test('generated sources are excluded from the ratchet', () {
    for (final generatedPath in <String>[
      'lib/core/models/message.g.dart',
      'lib/core/models/agent_response.freezed.dart',
      'lib/core/provider_thinking/generated_model_capability_defaults.dart',
      'lib/generated_bundled_assets.dart',
    ]) {
      expect(
        isGeneratedSource(generatedPath),
        isTrue,
        reason: '$generatedPath must be treated as generated output',
      );
    }

    for (final handwrittenPath in <String>[
      'lib/engine/agent_runner.dart',
      'lib/core/config.dart',
      'lib/tool/generator.dart',
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
bool isGeneratedSource(String path) {
  final fileName = path.split('/').last;
  return fileName.endsWith('.g.dart') ||
      fileName.endsWith('.freezed.dart') ||
      fileName.startsWith('generated_');
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
      'Split each file by responsibility, or move lines into the owner that '
      'already implements them, until it fits the limit.',
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
    'Could not locate the Agent package root from ${Directory.current.path}. '
    'Run this guard from the Agent package root.',
  );
}
