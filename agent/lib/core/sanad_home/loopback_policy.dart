/// Loopback policy for the local daemon HTTP/WebSocket surface
/// (SEC-02 / INV-1, Gate B).
library;

import 'dart:io';

class LoopbackPolicy {
  /// Returns true if [host] is a loopback hostname or address. The empty
  /// string is rejected; `0.0.0.0` and `::` are wildcard addresses and
  /// are rejected; only literal loopback values pass.
  static Future<bool> isLoopbackHostAsync(String host) async {
    final trimmed = host.trim().toLowerCase();
    if (trimmed.isEmpty) return false;
    if (trimmed == 'localhost' ||
        trimmed == 'ip6-localhost' ||
        trimmed == 'ip6-loopback') {
      return true;
    }
    if (trimmed == '0.0.0.0' || trimmed == '::') {
      return false;
    }
    try {
      final addresses = await InternetAddress.lookup(trimmed);
      if (addresses.isEmpty) return false;
      for (final address in addresses) {
        if (address.isLoopback) {
          return true;
        }
      }
      return false;
    } catch (_) {
      return false;
    }
  }

  /// Synchronous variant for the common literal-name case. The only
  /// names it accepts are `localhost`, `127.0.0.0/8` (numeric
  /// `127.x.x.x`), and `::1`. Wildcard `0.0.0.0` and `::` are
  /// rejected because they are not loopback. Numeric lookups for
  /// other forms are also rejected to keep the call synchronous;
  /// callers that need DNS resolution must use [isLoopbackHostAsync].
  static bool isLoopbackHost(String host) {
    final trimmed = host.trim().toLowerCase();
    if (trimmed.isEmpty) return false;
    if (trimmed == 'localhost' ||
        trimmed == 'ip6-localhost' ||
        trimmed == 'ip6-loopback') {
      return true;
    }
    if (trimmed == '0.0.0.0' || trimmed == '::') {
      return false;
    }
    // 127.0.0.0/8 is reserved as loopback.
    if (trimmed.startsWith('127.')) {
      // Reject any non-numeric or partially-formed suffix.
      final suffix = trimmed.substring(4);
      final parts = suffix.split('.');
      if (parts.length != 3) return false;
      for (final part in parts) {
        final n = int.tryParse(part);
        if (n == null || n < 0 || n > 255) return false;
      }
      return true;
    }
    if (trimmed == '::1') return true;
    return false;
  }

  /// Returns true if [address] represents a real loopback interface
  /// (matches the local peer, not a Host header).
  static bool isLoopbackAddress(InternetAddress? address) {
    if (address == null) return false;
    return address.isLoopback;
  }

  /// Asserts that the configured bind host is loopback. Throws
  /// [LocalGatewayBindViolation] otherwise.
  static void assertLoopbackBind(String host) {
    if (!isLoopbackHost(host)) {
      throw LocalGatewayBindViolation(host);
    }
  }
}

class LocalGatewayBindViolation implements Exception {
  final String host;
  const LocalGatewayBindViolation(this.host);

  @override
  String toString() =>
      'LocalGatewayBindViolation: refusing to bind to non-loopback host.';
}
