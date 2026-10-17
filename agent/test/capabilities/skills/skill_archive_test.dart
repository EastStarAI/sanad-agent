import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:sanad_agent/capabilities/skills/skill_archive.dart';
import 'package:test/test.dart';

/// Builds a minimal ustar archive so the reader is tested against real bytes.
List<int> buildTarGz(
  Map<String, String> files, {
  Map<String, String> symlinks = const {},
  Map<String, String> modes = const {},
}) {
  final builder = BytesBuilder();
  void addEntry(String name, List<int> content, String mode, int typeFlag) {
    final header = List<int>.filled(512, 0);
    void write(String value, int start, int length) {
      final bytes = utf8.encode(value);
      for (var i = 0; i < length && i < bytes.length; i++) {
        header[start + i] = bytes[i];
      }
    }

    write(name, 0, 100);
    write(mode, 100, 8);
    write('0000000', 108, 8);
    write('0000000', 116, 8);
    write(content.length.toRadixString(8).padLeft(11, '0'), 124, 12);
    write('00000000000', 136, 12);
    write('        ', 148, 8);
    header[156] = typeFlag;
    write('ustar', 257, 6);
    write('00', 263, 2);

    var checksum = 0;
    for (final byte in header) {
      checksum += byte;
    }
    write(checksum.toRadixString(8).padLeft(6, '0'), 148, 7);
    header[155] = 0x20;

    builder.add(header);
    if (content.isNotEmpty) {
      builder.add(content);
      final padding = (512 - (content.length % 512)) % 512;
      builder.add(List<int>.filled(padding, 0));
    }
  }

  files.forEach((name, content) {
    addEntry(name, utf8.encode(content), modes[name] ?? '0000644', 0x30);
  });
  symlinks.forEach((name, target) {
    addEntry(name, utf8.encode(target), '0000777', 0x32);
  });
  builder.add(List<int>.filled(1024, 0));
  return gzip.encode(builder.takeBytes());
}

void main() {
  test('extracts regular files and preserves the executable bit', () {
    final archive = buildTarGz(
      {
        'owner-repo-sha/SKILL.md': '# hi',
        'owner-repo-sha/scripts/run.sh': 'echo ok',
      },
      modes: {'owner-repo-sha/scripts/run.sh': '0000755'},
    );

    final entries = SkillArchive.decode(archive);

    expect(
      entries.keys,
      containsAll(<String>[
        'owner-repo-sha/SKILL.md',
        'owner-repo-sha/scripts/run.sh',
      ]),
    );
    expect(entries['owner-repo-sha/scripts/run.sh']!.isExecutable, isTrue);
    expect(entries['owner-repo-sha/SKILL.md']!.isExecutable, isFalse);
    expect(utf8.decode(entries['owner-repo-sha/SKILL.md']!.bytes), '# hi');
  });

  test('rejects traversal entries', () {
    final archive = buildTarGz({'../evil.md': 'x'});
    expect(
      () => SkillArchive.decode(archive),
      throwsA(isA<SkillArchiveException>()),
    );
  });

  test('rejects absolute entries', () {
    final archive = buildTarGz({'/etc/evil.md': 'x'});
    expect(
      () => SkillArchive.decode(archive),
      throwsA(isA<SkillArchiveException>()),
    );
  });

  test('rejects symlinks', () {
    final archive = buildTarGz(
      {'skill/SKILL.md': '# hi'},
      symlinks: {'skill/link': '../../etc/passwd'},
    );
    expect(
      () => SkillArchive.decode(archive),
      throwsA(
        isA<SkillArchiveException>().having(
          (error) => error.message,
          'message',
          contains('link'),
        ),
      ),
    );
  });

  test('rejects non-gzip payloads', () {
    expect(
      () => SkillArchive.decode(utf8.encode('not gzip')),
      throwsA(isA<SkillArchiveException>()),
    );
  });

  test('rejects payloads beyond the extraction budget', () {
    final archive = buildTarGz({'a.txt': 'x' * 2048});
    expect(
      () => SkillArchive.decode(archive, maxExtractedBytes: 1024),
      throwsA(isA<SkillArchiveException>()),
    );
  });

  test('normalizes safeRelativePath', () {
    expect(SkillArchive.safeRelativePath('./a/b.md'), 'a/b.md');
    expect(SkillArchive.safeRelativePath('../a.md'), isNull);
    expect(SkillArchive.safeRelativePath('/a.md'), isNull);
  });
}
