import 'dart:io';

import 'package:archive/archive.dart';

/// Validation and extraction of the signed `agent-runtime` bundle.
///
/// The bundle is the release contract's `agent-runtime` archive: a gzip tar whose
/// members are **exactly** `native/<platform>-<architecture>/<library>` for one
/// target (see `docs/technical/native_stt_runtime_platforms.md`). The target tag
/// is derived from the selected artifact's own metadata, so this file never keeps
/// a platform/architecture catalog of its own.
///
/// Untrusted input is never trusted to name a destination: every member is
/// validated first, and files are written from the validated tag plus a basename,
/// so traversal, absolute paths, dot names, links, and model payloads cannot
/// escape or pollute the installed tree even if the archive lies about them.
class AgentRuntimeArchive {
  const AgentRuntimeArchive._();

  /// Upper bound on members, so a malicious bundle cannot exhaust the disk.
  static const int maxMembers = 512;

  /// Archive formats this contract produces.
  static const String format = 'tar.gz';

  static const Set<String> _forbiddenExtensions = {
    '.bin',
    '.gguf',
    '.ggml',
    '.onnx',
    '.pt',
    '.safetensors',
    '.zip',
    '.tar',
    '.gz',
  };

  /// The installed directory name for an artifact, for example `macos-arm64`.
  static String tagFor({required String platform, required String architecture}) =>
      '$platform-$architecture';

  /// Returns a rejection reason, or null when every member is acceptable.
  ///
  /// A caller that gets a reason must not extract anything. Tar writers include
  /// the `native/` and `native/<tag>/` directory entries; those carry no files and
  /// are the only names accepted outside the `<library>` shape.
  static String? rejectionFor(List<String> names, {required String tag}) {
    final members = [
      for (final name in names)
        if (name != 'native/' && name != 'native/$tag/') name,
    ];
    if (members.isEmpty) return 'empty_archive';
    if (members.length > maxMembers) return 'too_many_members';
    final prefix = 'native/$tag/';
    final seen = <String>{};
    for (final name in members) {
      if (!name.startsWith(prefix)) return 'unexpected_member';
      final base = name.substring(prefix.length);
      if (base.isEmpty || base.contains('/') || base.contains('\\')) {
        return 'unexpected_member';
      }
      if (base == '.' || base == '..' || base.startsWith('.')) {
        return 'unexpected_member';
      }
      if (base.contains(':')) return 'unexpected_member';
      if (!_isLibraryName(base)) return 'unexpected_member';
      if (!seen.add(base)) return 'duplicate_member';
    }
    return null;
  }

  /// True for a native library file name only (`libx.dylib`, `x.dll`,
  /// `libx.so`, `libx.so.1`). Models and payload data are never libraries.
  static bool _isLibraryName(String name) {
    final lower = name.toLowerCase();
    for (final extension in _forbiddenExtensions) {
      if (lower.endsWith(extension)) return false;
    }
    if (lower.endsWith('.dylib') || lower.endsWith('.dll')) return true;
    if (lower.endsWith('.so')) return true;
    return RegExp(r'\.so\.\d+$').hasMatch(lower);
  }

  /// Validates and extracts [bytes] into [into].
  ///
  /// Returns the rejection reason when the archive is refused; nothing is written
  /// in that case. [into] receives `native/<tag>/<library>` files only.
  static Future<String?> extract({
    required List<int> bytes,
    required String tag,
    required Directory into,
  }) async {
    final Archive archive;
    try {
      archive = TarDecoder().decodeBytes(GZipDecoder().decodeBytes(bytes));
    } on Object {
      return 'invalid_archive';
    }
    final rejection = rejectionFor(
      archive.files
          .where((file) => file.isFile)
          .map((file) => file.name)
          .toList(growable: false),
      tag: tag,
    );
    if (rejection != null) return rejection;

    final root = Directory('${into.path}/native/$tag');
    await root.create(recursive: true);
    for (final file in archive.files.where((file) => file.isFile)) {
      final base = file.name.substring('native/$tag/'.length);
      final target = File('${root.path}/$base');
      await target.parent.create(recursive: true);
      await target.writeAsBytes(file.content, flush: true);
      if (await FileSystemEntity.type(target.path, followLinks: false) !=
          FileSystemEntityType.file) {
        return 'unexpected_member';
      }
    }
    return null;
  }
}
