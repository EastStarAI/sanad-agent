import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/devices/data/daemon/agent_runtime_archive.dart';

/// The `agent-runtime` bundle is untrusted input. Validation must run before any
/// write, and extraction must write only `native/<tag>/<library>` from the
/// validated tag plus a basename — never from a member-supplied path.
void main() {
  const tag = 'macos-arm64';

  List<int> bundleOf(List<ArchiveFile> files) {
    final archive = Archive();
    for (final file in files) {
      archive.addFile(file);
    }
    return GZipEncoder().encode(TarEncoder().encode(archive));
  }

  ArchiveFile library(String name, [String payload = 'binary']) =>
      ArchiveFile('native/$tag/$name', payload.length, payload.codeUnits);

  test('accepts library members and the tar directory entries', () {
    final rejection = AgentRuntimeArchive.rejectionFor(
      ['native/', 'native/$tag/', 'native/$tag/libx.dylib'],
      tag: tag,
    );

    expect(rejection, isNull);
  });

  test('rejects traversal, absolute, nested, duplicate and model members', () {
    final cases = <(String, List<String>)>[
      ('unexpected_member', ['native/$tag/../../evil.dylib']),
      ('unexpected_member', ['/native/$tag/libx.dylib']),
      (
        'duplicate_member',
        ['native/$tag/libx.dylib', 'native/$tag/libx.dylib'],
      ),
      ('unexpected_member', ['native/other-tag/libx.dylib']),
      ('unexpected_member', ['native/$tag/model.gguf']),
      ('unexpected_member', ['native/$tag/.hidden.dylib']),
    ];

    for (final (reason, names) in cases) {
      expect(
        AgentRuntimeArchive.rejectionFor(names, tag: tag),
        reason,
        reason: names.join(', '),
      );
    }
  });

  test('refuses an archive with no file members', () {
    expect(
      AgentRuntimeArchive.rejectionFor(['native/', 'native/$tag/'], tag: tag),
      'empty_archive',
    );
  });

  test('rejects more members than the bound allows', () {
    final names = [
      for (var index = 0; index <= AgentRuntimeArchive.maxMembers; index++)
        'native/$tag/lib$index.so',
    ];

    expect(
      AgentRuntimeArchive.rejectionFor(names, tag: tag),
      'too_many_members',
    );
  });

  test('extracts validated libraries under the derived tag', () async {
    final directory = await Directory.systemTemp.createTemp('agent-runtime-');
    addTearDown(() => directory.delete(recursive: true));
    final bytes = bundleOf([
      library('libx.dylib', 'alpha'),
      library('liby.dylib', 'beta'),
    ]);

    final rejection = await AgentRuntimeArchive.extract(
      bytes: bytes,
      tag: tag,
      into: directory,
    );

    expect(rejection, isNull);
    expect(
      await File('${directory.path}/native/$tag/libx.dylib').readAsString(),
      'alpha',
    );
    expect(
      await File('${directory.path}/native/$tag/liby.dylib').readAsString(),
      'beta',
    );
  });

  test('writes nothing when the archive is refused', () async {
    final directory = await Directory.systemTemp.createTemp('agent-runtime-');
    addTearDown(() => directory.delete(recursive: true));
    final bytes = bundleOf([
      ArchiveFile('native/$tag/../escape.dll', 4, 'evil'.codeUnits),
    ]);

    final rejection = await AgentRuntimeArchive.extract(
      bytes: bytes,
      tag: tag,
      into: directory,
    );

    expect(rejection, isNotNull);
    expect(
      await Directory('${directory.path}/native').exists(),
      isFalse,
      reason: 'Nothing may be written before validation succeeds.',
    );
  });

  test('reports invalid archive bytes without touching the destination', () async {
    final directory = await Directory.systemTemp.createTemp('agent-runtime-');
    addTearDown(() => directory.delete(recursive: true));

    final rejection = await AgentRuntimeArchive.extract(
      bytes: const [1, 2, 3, 4],
      tag: tag,
      into: directory,
    );

    expect(rejection, 'invalid_archive');
    expect(await directory.list().isEmpty, isTrue);
  });
}
