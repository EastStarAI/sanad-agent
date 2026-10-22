/// Regression coverage for the bundled-skill generator.
///
/// Covers the two Windows-only failures that blocked the `v1.0.18` Agent build:
/// a clean POSIX manifest entry rejected by the platform path context, and
/// embedded content whose bytes depended on the checkout line ending.
library;

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/capabilities/skills/generated_bundled_skills.dart';
import 'package:test/test.dart';

import '../../tool/canonical_source.dart';
import '../../tool/generate_bundled_skills.dart';

/// The agent package root, resolved independently of the process working
/// directory (other suites change it while files run concurrently).
Uri _agentRoot() => Isolate.resolvePackageUriSync(
  Uri.parse('package:sanad_agent/'),
)!.resolve('../');

/// The repository root, which owns the skill sources the manifest names.
Uri _repoRoot() => _agentRoot().resolve('../');

Map<String, dynamic> _manifest() =>
    jsonDecode(
          File.fromUri(
            _agentRoot().resolve('bundled_skills.json'),
          ).readAsStringSync(),
        )
        as Map<String, dynamic>;

void main() {
  group('manifest path validation', () {
    test('accepts every path the committed manifest declares', () {
      final skills = (_manifest()['skills'] as List<dynamic>)
          .cast<Map<String, dynamic>>();
      expect(skills, isNotEmpty);
      for (final row in skills) {
        expect(
          isSafeManifestPath(row['source'] as String),
          isTrue,
          reason: row['source'] as String,
        );
        expect(
          isSafeManifestPath(row['license_file'] as String),
          isTrue,
          reason: '${row['id']}.license_file',
        );
        final executables = row['executable_files'] as List<dynamic>?;
        for (final path in (executables ?? const <dynamic>[]).cast<String>()) {
          expect(isSafeManifestPath(path), isTrue, reason: path);
        }
      }
    });

    test('a clean POSIX entry survives the Windows path context', () {
      const source = '.agents/skills/skill-creator';
      // Reproduces the v1.0.18 failure: the platform context rewrites the
      // separators on Windows, so comparing a normalized manifest entry with
      // its own source text rejected a clean source as `Unsafe skill source`.
      expect(p.windows.normalize(source), isNot(source));
      expect(p.posix.normalize(source), source);
      expect(isSafeManifestPath(source), isTrue);
    });

    test('a manifest entry joins with the platform separator', () {
      final joined = p.joinAll([
        'repo',
        ...p.posix.split('.agents/skills/find-skills'),
      ]);
      expect(p.split(joined), ['repo', '.agents', 'skills', 'find-skills']);
    });

    test('rejects absolute, traversal, backslash, and drive paths', () {
      const unsafe = <String>[
        '',
        '/etc/passwd',
        '../outside',
        '.agents/skills/../../../etc/passwd',
        r'.agents\skills\skill-creator',
        r'\\server\share\skill',
        'C:/Windows/system32',
        'C:skills/x',
        './skill',
        'skills//skill',
        'skills/./skill',
        'skills/skill/',
      ];
      for (final value in unsafe) {
        expect(isSafeManifestPath(value), isFalse, reason: value);
      }
    });
  });

  group('line-ending stability', () {
    test('CRLF content hashes identically to its LF form', () {
      final lf = utf8.encode('line one\nline two\n');
      final crlf = utf8.encode('line one\r\nline two\r\n');
      expect(canonicalContentBytes(crlf), lf);
      expect(
        sha256.convert(canonicalContentBytes(crlf)).toString(),
        sha256.convert(lf).toString(),
      );
      expect(
        sha256.convert(crlf).toString(),
        isNot(sha256.convert(lf).toString()),
      );
    });

    test('binary content is preserved byte for byte', () {
      final png = [0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x00, 0x1a, 0x0a];
      expect(canonicalContentBytes(png), png);
      final latin1 = [0xff, 0x0d, 0x0a, 0xfe];
      expect(canonicalContentBytes(latin1), latin1);
    });

    test('a CRLF checkout of the generated output is not stale', () {
      final generated = File.fromUri(
        _agentRoot().resolve(
          'lib/capabilities/skills/generated_bundled_skills.dart',
        ),
      ).readAsStringSync();
      expect(
        generatedSourceMatches(
          onDisk: generated.replaceAll('\n', '\r\n'),
          rendered: generated,
        ),
        isTrue,
      );
      expect(
        generatedSourceMatches(onDisk: '$generated ', rendered: generated),
        isFalse,
      );
    });

    test('embedded bundle content carries no carriage returns', () {
      expect(bundledSkills, isNotEmpty);
      for (final skill in bundledSkills) {
        for (final file in skill.files) {
          expect(
            file.decode().contains(13),
            isFalse,
            reason: '${skill.id}/${file.path}',
          );
        }
      }
    });

    test('embedded hashes describe the LF form of the repository sources', () {
      final sourceById = {
        for (final row
            in (_manifest()['skills'] as List<dynamic>)
                .cast<Map<String, dynamic>>())
          row['id'] as String: row['source'] as String,
      };
      final repoRoot = _repoRoot();
      var verified = 0;
      for (final skill in bundledSkills) {
        final source = sourceById[skill.id];
        expect(source, isNotNull, reason: skill.id);
        for (final file in skill.files) {
          final bytes = File.fromUri(
            repoRoot.resolve('$source/${file.path}'),
          ).readAsBytesSync();
          expect(
            sha256.convert(canonicalContentBytes(bytes)).toString(),
            file.sha256,
            reason: '${skill.id}/${file.path}',
          );
          verified += 1;
        }
      }
      expect(verified, greaterThan(0));
    });
  });
}
