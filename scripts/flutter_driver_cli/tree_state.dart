import 'dart:io';

import 'models.dart';

/// Direction-agnostic fingerprint of an inspected widget tree.
///
/// The signature is a change-detection channel, not a security boundary: it
/// lets a caller prove that an action changed the rendered tree without
/// re-sending the tree itself. Text leaves participate only through the
/// aggregate fingerprint so no field value or message body is echoed back.
String uiTreeSignature(List<UiElement> elements) {
  final buffer = StringBuffer();
  for (final element in elements) {
    buffer
      ..write(element.type)
      ..write('\u0001')
      ..write(element.key ?? '')
      ..write('\u0001')
      ..write(element.text ?? '')
      ..write('\u0001')
      ..write(element.enabled?.toString() ?? '')
      ..write('\u0001')
      ..write(element.selected?.toString() ?? '')
      ..write('\u0001')
      ..write(element.bounds?.toString() ?? '')
      ..write('\u0002');
  }
  return _fnv1a64Hex(buffer.toString(), seed: 0x00000100000001b3);
}

/// Finds the single element identified by an exact key, or null.
UiElement? uiElementByKey(List<UiElement> elements, String key) {
  for (final element in elements) {
    if (element.key == key) return element;
  }
  return null;
}

/// Monotonic snapshot generation shared by every `sanad-dev ui` process that
/// targets the same Client VM Service endpoint.
///
/// Each invocation is a short-lived native process, so the counter lives in a
/// small owner-scoped file keyed by the endpoint authority. The file carries no
/// argument, token, or payload data.
class UiTreeGenerationStore {
  UiTreeGenerationStore(this.file);

  /// Default location for the generation counter of [vmUrl].
  ///
  /// Callers must pass the *resolved* VM Service URL rather than the raw
  /// argument, so an invocation without an explicit endpoint still lands on its
  /// own counter instead of a shared "unbound" one. Only the endpoint authority
  /// participates in the key; the VM Service authentication token in the URL
  /// path never reaches the filesystem.
  factory UiTreeGenerationStore.forVmServiceUrl(
    String? vmUrl, {
    Directory? root,
  }) {
    final normalized = vmUrl?.trim() ?? '';
    final uri = normalized.isEmpty ? null : Uri.tryParse(normalized);
    final authority = uri == null || uri.host.isEmpty
        ? 'unbound'
        : '${uri.host}-${uri.hasPort ? uri.port : 0}';
    final safeAuthority = authority.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final base = root ?? Directory('${Directory.systemTemp.path}/sanad-dev-ui');
    return UiTreeGenerationStore(
      File('${base.path}/$safeAuthority.generation'),
    );
  }

  /// Age after which another invocation's staging file is considered abandoned.
  static const Duration staleStagingAge = Duration(minutes: 10);

  final File file;

  /// Increments and returns the next generation without throwing.
  ///
  /// The read-modify-write runs under an advisory OS lock on a sibling `.lock`
  /// file, so concurrent invocations cannot both observe the same value. When
  /// the lock or the temp directory is unavailable, generation reporting
  /// degrades to a best-effort monotonic value instead of failing the action.
  int next() {
    RandomAccessFile? lock;
    try {
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      _pruneStaleStaging(file.parent);
      lock = File('${file.path}.lock').openSync(mode: FileMode.write);
      lock.lockSync(FileLock.exclusive);
      final value = peek() + 1;
      final staging = File('${file.path}.$pid.tmp');
      staging.writeAsStringSync('$value', flush: true);
      staging.renameSync(file.path);
      return value;
    } catch (_) {
      // A read-only or unavailable temp directory must never fail an action;
      // generation reporting degrades to the best-effort value observed here.
      return peek() + 1;
    } finally {
      try {
        lock?.unlockSync();
      } catch (_) {}
      try {
        lock?.closeSync();
      } catch (_) {}
    }
  }

  /// Returns the last recorded generation, or 0 when none exists yet.
  int peek() {
    try {
      if (!file.existsSync()) return 0;
      return int.tryParse(file.readAsStringSync().trim()) ?? 0;
    } catch (_) {
      return 0;
    }
  }
}

/// Deletes staging files a crashed invocation left behind.
///
/// A live invocation's `.<pid>.tmp` staging file is never touched: only staging
/// files older than [UiTreeGenerationStore.staleStagingAge] are pruned, so two
/// concurrent processes can never delete each other's in-flight write.
void _pruneStaleStaging(Directory directory) {
  try {
    final cutoff = DateTime.now().subtract(
      UiTreeGenerationStore.staleStagingAge,
    );
    for (final entity in directory.listSync()) {
      if (entity is! File || !entity.path.endsWith('.tmp')) continue;
      try {
        if (entity.lastModifiedSync().isAfter(cutoff)) continue;
        entity.deleteSync();
      } catch (_) {}
    }
  } catch (_) {}
}

String _fnv1a64Hex(String value, {required int seed}) {
  var hash = seed;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
