import 'dart:convert';

import 'package:crypto/crypto.dart';

/// A privacy-safe display reference derived from authenticated Client identity.
///
/// The reference is intentionally not reversible and must never be used for
/// authorization, routing, persistence ownership, or protocol correlation.
String? clientDisplayReference({
  String? clientInstanceId,
  String? clientSessionId,
}) {
  final instance = _bounded(clientInstanceId)?.toLowerCase();
  final session = _bounded(clientSessionId);
  final source = instance != null
      ? 'sanad-client-instance-v1:$instance'
      : session != null
      ? 'sanad-client-session-v1:$session'
      : null;
  if (source == null) return null;

  final bytes = sha256.convert(utf8.encode(source)).bytes;
  return _encodeCrockfordBase32(bytes, outputLength: 8);
}

String? _bounded(String? value) {
  final normalized = value?.trim() ?? '';
  if (normalized.isEmpty || normalized.length > 128) return null;
  return normalized;
}

const _crockfordAlphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';

String _encodeCrockfordBase32(List<int> bytes, {required int outputLength}) {
  var buffer = 0;
  var bits = 0;
  final result = StringBuffer();
  for (final byte in bytes) {
    buffer = (buffer << 8) | byte;
    bits += 8;
    while (bits >= 5 && result.length < outputLength) {
      bits -= 5;
      result.write(_crockfordAlphabet[(buffer >> bits) & 31]);
    }
    if (result.length == outputLength) break;
  }
  return result.toString();
}
