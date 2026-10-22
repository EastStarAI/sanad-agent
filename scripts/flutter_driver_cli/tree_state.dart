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
  /// Only the endpoint authority participates in the key; the VM Service
  /// authentication token in the URL path never reaches the filesystem.
  factory UiTreeGenerationStore.forVmServiceUrl(
    String? vmUrl, {
    Directory? root,
  }) {
    final uri = vmUrl == null ? null : Uri.tryParse(vmUrl.trim());
    final authority = uri == null || uri.host.isEmpty
        ? 'unbound'
        : '${uri.host}-${uri.hasPort ? uri.port : 0}';
    final safeAuthority = authority.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final base = root ?? Directory('${Directory.systemTemp.path}/sanad-dev-ui');
    return UiTreeGenerationStore(
      File('${base.path}/$safeAuthority.generation'),
    );
  }

  final File file;

  /// Increments and returns the next generation without throwing.
  int next() {
    final value = peek() + 1;
    try {
      if (!file.parent.existsSync()) {
        file.parent.createSync(recursive: true);
      }
      final staging = File('${file.path}.${pid}.tmp');
      staging.writeAsStringSync('$value', flush: true);
      staging.renameSync(file.path);
    } catch (_) {
      // A read-only or unavailable temp directory must never fail an action;
      // generation reporting degrades to the best-effort value observed here.
    }
    return value;
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

String _fnv1a64Hex(String value, {required int seed}) {
  var hash = seed;
  for (final unit in value.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x100000001b3) & 0x7FFFFFFFFFFFFFFF;
  }
  return hash.toRadixString(16).padLeft(16, '0');
}
