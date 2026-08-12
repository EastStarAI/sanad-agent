import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;

const _manifestPath = 'bundled_skills.json';
const _outputPath = 'lib/capabilities/skills/generated_bundled_skills.dart';

void main(List<String> arguments) {
  final check = arguments.contains('--check');
  final agentRoot = Directory.current.absolute;
  final repoRoot = agentRoot.parent;
  final manifestFile = File(p.join(agentRoot.path, _manifestPath));
  final manifest = _readManifest(manifestFile, repoRoot);
  final generated = _render(manifest);
  final output = File(p.join(agentRoot.path, _outputPath));

  if (check) {
    if (!output.existsSync() || output.readAsStringSync() != generated) {
      stderr.writeln(
        'Bundled skill output is stale. Run: '
        'fvm dart run tool/generate_bundled_skills.dart',
      );
      exitCode = 1;
      return;
    }
    stdout.writeln(
      'Bundled skills valid: ${manifest.skills.length} skills, '
      '${manifest.files.length} files, ${manifest.revision}',
    );
    return;
  }

  output
    ..createSync(recursive: true)
    ..writeAsStringSync(generated);
  stdout.writeln(
    'Generated ${p.relative(output.path, from: agentRoot.path)}: '
    '${manifest.skills.length} skills, ${manifest.files.length} files.',
  );
}

_Bundle _readManifest(File file, Directory repoRoot) {
  if (!file.existsSync()) {
    throw FormatException('Missing $_manifestPath.');
  }
  final decoded = jsonDecode(file.readAsStringSync());
  if (decoded is! Map<String, dynamic> || decoded['schema_version'] != 1) {
    throw FormatException('Unsupported bundled skill manifest.');
  }
  final rows = decoded['skills'];
  if (rows is! List || rows.isEmpty) {
    throw FormatException('Bundled skills must not be empty.');
  }

  final skills = <_Skill>[];
  final files = <_BundledFile>[];
  final ids = <String>{};
  for (final raw in rows) {
    if (raw is! Map<String, dynamic>) {
      throw FormatException('Each bundled skill must be an object.');
    }
    final id = _required(raw, 'id');
    if (!RegExp(r'^[a-z0-9]+(?:-[a-z0-9]+)*$').hasMatch(id) || !ids.add(id)) {
      throw FormatException('Invalid or duplicate skill id: $id');
    }
    final source = _required(raw, 'source');
    if (p.isAbsolute(source) ||
        p.normalize(source) != source ||
        source.contains('..')) {
      throw FormatException('Unsafe skill source: $source');
    }
    final sourceDir = Directory(p.join(repoRoot.path, source));
    final canonicalRepo = repoRoot.resolveSymbolicLinksSync();
    if (!sourceDir.existsSync() ||
        FileSystemEntity.typeSync(sourceDir.path, followLinks: false) !=
            FileSystemEntityType.directory) {
      throw FormatException('Missing skill source: $source');
    }
    final canonicalSource = sourceDir.resolveSymbolicLinksSync();
    if (!p.isWithin(canonicalRepo, canonicalSource)) {
      throw FormatException('Skill source escapes the repository: $source');
    }
    if (!File(p.join(sourceDir.path, 'SKILL.md')).existsSync()) {
      throw FormatException('Skill $id is missing SKILL.md.');
    }
    final licenseFile = _required(raw, 'license_file');
    if (!File(p.join(sourceDir.path, licenseFile)).existsSync()) {
      throw FormatException('Skill $id is missing $licenseFile.');
    }

    final executableRows = raw['executable_files'] ?? const <dynamic>[];
    if (executableRows is! List) {
      throw FormatException('Skill $id executable_files must be a list.');
    }
    final executablePaths = <String>{};
    for (final value in executableRows) {
      if (value is! String ||
          p.posix.isAbsolute(value) ||
          p.posix.normalize(value) != value ||
          p.posix.split(value).any((part) => part == '..' || part.isEmpty)) {
        throw FormatException('Skill $id has an unsafe executable path.');
      }
      executablePaths.add(value);
    }

    final skillFiles = <_BundledFile>[];
    _walk(sourceDir, sourceDir, id, executablePaths, skillFiles);
    final discoveredPaths = skillFiles.map((file) => file.path).toSet();
    if (!discoveredPaths.containsAll(executablePaths)) {
      throw FormatException('Skill $id declares a missing executable file.');
    }
    skillFiles.sort((a, b) => a.path.compareTo(b.path));
    if (skillFiles.isEmpty) {
      throw FormatException('Skill $id has no files.');
    }
    files.addAll(skillFiles);
    skills.add(
      _Skill(
        id: id,
        source: source,
        upstream: _required(raw, 'upstream'),
        upstreamRevision: _required(raw, 'upstream_revision'),
        license: _required(raw, 'license'),
        licenseFile: licenseFile,
        files: skillFiles,
      ),
    );
  }

  final revisionInput = StringBuffer('schema:1\n');
  for (final skill in skills) {
    revisionInput.writeln(
      '${skill.id}\u0000${skill.upstream}\u0000${skill.upstreamRevision}'
      '\u0000${skill.license}\u0000${skill.licenseFile}',
    );
    for (final file in skill.files) {
      revisionInput.writeln(
        '${file.path}\u0000${file.sha256}\u0000${file.executable ? 1 : 0}',
      );
    }
  }
  final revision = sha256
      .convert(utf8.encode(revisionInput.toString()))
      .toString();
  return _Bundle(skills: skills, files: files, revision: revision);
}

void _walk(
  Directory root,
  Directory current,
  String skillId,
  Set<String> executablePaths,
  List<_BundledFile> output,
) {
  final entities = current.listSync(followLinks: false)
    ..sort((a, b) => a.path.compareTo(b.path));
  for (final entity in entities) {
    final type = FileSystemEntity.typeSync(entity.path, followLinks: false);
    if (type == FileSystemEntityType.link) {
      throw FormatException('Symlinks are not allowed in bundled skills.');
    }
    if (type == FileSystemEntityType.directory) {
      _walk(root, Directory(entity.path), skillId, executablePaths, output);
      continue;
    }
    if (type != FileSystemEntityType.file) {
      throw FormatException('Unsupported entity in bundled skill.');
    }
    final relative = p.relative(entity.path, from: root.path);
    final posix = p.posix.joinAll(p.split(relative));
    if (p.posix.isAbsolute(posix) ||
        p.posix.normalize(posix) != posix ||
        p.posix.split(posix).any((part) => part == '..')) {
      throw FormatException('Unsafe bundled file path.');
    }
    final bytes = File(entity.path).readAsBytesSync();
    output.add(
      _BundledFile(
        skillId: skillId,
        path: posix,
        sha256: sha256.convert(bytes).toString(),
        executable: executablePaths.contains(posix),
        compressedBase64: base64Encode(ZLibCodec(level: 9).encode(bytes)),
      ),
    );
  }
}

String _render(_Bundle bundle) {
  final out = StringBuffer()
    ..writeln('// This file is generated. Do not edit manually.')
    ..writeln("import 'dart:convert';")
    ..writeln("import 'dart:io';")
    ..writeln()
    ..writeln("const bundledSkillsRevision = '${bundle.revision}';")
    ..writeln('const bundledSkills = <BundledSkill>[');
  for (final skill in bundle.skills) {
    out
      ..writeln('  BundledSkill(')
      ..writeln("    id: ${_literal(skill.id)},")
      ..writeln("    upstream: ${_literal(skill.upstream)},")
      ..writeln("    upstreamRevision: ${_literal(skill.upstreamRevision)},")
      ..writeln("    license: ${_literal(skill.license)},")
      ..writeln('    files: <BundledSkillFile>[');
    for (final file in skill.files) {
      out
        ..writeln('      BundledSkillFile(')
        ..writeln("        path: ${_literal(file.path)},")
        ..writeln("        sha256: ${_literal(file.sha256)},")
        ..writeln('        executable: ${file.executable},')
        ..writeln(
          "        compressedBase64: ${_literal(file.compressedBase64)},",
        )
        ..writeln('      ),');
    }
    out
      ..writeln('    ],')
      ..writeln('  ),');
  }
  out
    ..writeln('];')
    ..writeln()
    ..writeln('class BundledSkill {')
    ..writeln(
      '  const BundledSkill({required this.id, required this.upstream, required this.upstreamRevision, required this.license, required this.files});',
    )
    ..writeln('  final String id;')
    ..writeln('  final String upstream;')
    ..writeln('  final String upstreamRevision;')
    ..writeln('  final String license;')
    ..writeln('  final List<BundledSkillFile> files;')
    ..writeln('}')
    ..writeln()
    ..writeln('class BundledSkillFile {')
    ..writeln(
      '  const BundledSkillFile({required this.path, required this.sha256, required this.executable, required this.compressedBase64});',
    )
    ..writeln('  final String path;')
    ..writeln('  final String sha256;')
    ..writeln('  final bool executable;')
    ..writeln('  final String compressedBase64;')
    ..writeln(
      '  List<int> decode() => ZLibCodec().decode(base64Decode(compressedBase64));',
    )
    ..writeln('}');
  return out.toString();
}

String _required(Map<String, dynamic> row, String key) {
  final value = row[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Bundled skill $key is required.');
  }
  return value.trim();
}

String _literal(String value) => jsonEncode(value);

class _Bundle {
  const _Bundle({
    required this.skills,
    required this.files,
    required this.revision,
  });
  final List<_Skill> skills;
  final List<_BundledFile> files;
  final String revision;
}

class _Skill {
  const _Skill({
    required this.id,
    required this.source,
    required this.upstream,
    required this.upstreamRevision,
    required this.license,
    required this.licenseFile,
    required this.files,
  });
  final String id;
  final String source;
  final String upstream;
  final String upstreamRevision;
  final String license;
  final String licenseFile;
  final List<_BundledFile> files;
}

class _BundledFile {
  const _BundledFile({
    required this.skillId,
    required this.path,
    required this.sha256,
    required this.executable,
    required this.compressedBase64,
  });
  final String skillId;
  final String path;
  final String sha256;
  final bool executable;
  final String compressedBase64;
}
