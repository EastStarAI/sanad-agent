/// Local Gateway credential generation, persistence, and lookup
/// (SEC-02 / INV-2, Gate A & B).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:logging/logging.dart';

import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';

class LocalGatewayCredentials {
  static final _logger = Logger('LocalGatewayCredentials');

  /// Canonical relative path under the Sanad Home.
  static const String relativePath = '.local_token';

  /// Owner-only file that binds [relativePath] to one Home identity.
  ///
  /// A Home that was cloned from another Home carries the source token; the
  /// binding is what proves the token was generated for this root, so a copied
  /// token is rotated on the copy's next daemon start instead of letting two
  /// Homes accept the same credential.
  static const String bindingRelativePath = '.local_token.home';

  /// Custom header used for the credential over HTTP and the WebSocket
  /// upgrade. The same value is also accepted as `Authorization: Bearer`.
  static const String headerName = 'x-sanad-local-token';

  /// Returns the persisted credential, generating a fresh one and
  /// writing it through [SanadHomeBootstrap.writeSecret] on first use.
  /// Idempotent and serialized across concurrent processes sharing one Home.
  ///
  /// A missing, foreign, or unreadable Home binding rotates the credential,
  /// which is the documented migration for Homes cloned or restored from
  /// another Home.
  static Future<LocalGatewayCredential> loadOrCreate() async {
    final boundary = SanadHomeBootstrap.identity();
    await boundary.prepare();
    const lockRelativePath = '.local_token.lock';
    final lockFile = File(boundary.child(lockRelativePath));
    if (!lockFile.existsSync()) {
      try {
        lockFile.createSync(exclusive: true);
      } on FileSystemException {
        // Another process won first creation; validate its file below.
      }
    }
    if (!Platform.isWindows) {
      boundary.readSecretBytes(lockRelativePath);
    }

    final lock = lockFile.openSync(mode: FileMode.append);
    final stopwatch = Stopwatch()..start();
    while (true) {
      try {
        await lock.lock(FileLock.exclusive);
        break;
      } on FileSystemException catch (error) {
        if (const {11, 33, 35}.contains(error.osError?.errorCode) &&
            stopwatch.elapsed < const Duration(seconds: 10)) {
          await Future.delayed(const Duration(milliseconds: 25));
          continue;
        }
        lock.closeSync();
        rethrow;
      } catch (_) {
        lock.closeSync();
        rethrow;
      }
    }
    try {
      final expected = sanadHomeIdentity(boundary.canonicalRoot());
      final persisted = _readFrom(boundary);
      if (persisted != null && _readBinding(boundary) == expected) {
        return persisted;
      }

      final generated = _generate();
      await boundary.writeSecretBytes(
        relativePath,
        utf8.encode(generated.value),
      );
      await boundary.writeSecretBytes(
        bindingRelativePath,
        utf8.encode(expected),
      );
      if (persisted != null) {
        // Never log a credential value; only that a rotation happened.
        _logger.warning(
          'Local gateway credential was not bound to this Sanad Home; '
          'rotated it for this Home.',
        );
      }
      return _readFrom(boundary) ?? generated;
    } finally {
      await lock.unlock();
      lock.closeSync();
    }
  }

  /// Returns the persisted credential, or null if none exists. Does
  /// NOT generate one. Used by the desktop client for read-only lookup
  /// before the daemon has started.
  ///
  /// A credential whose binding names a different Home is treated as absent,
  /// so a clone never lends its credential to the Home it was cloned into.
  static LocalGatewayCredential? tryRead() {
    return _readFrom(SanadHomeBootstrap.identity());
  }

  static LocalGatewayCredential? _readFrom(SanadHomeBootstrap boundary) {
    if (!boundary.fileExists(relativePath)) return null;
    try {
      final bytes = boundary.readSecretBytes(relativePath);
      final value = utf8.decode(bytes).trim();
      if (value.isEmpty) return null;
      if (isBoundToAnotherHome(boundary)) return null;
      return LocalGatewayCredential(value);
    } catch (error) {
      _logger.warning('Failed to decode the local token; regenerating.');
      return null;
    }
  }

  /// Whether [boundary]'s credential is explicitly bound to a different Home.
  ///
  /// A missing binding is a legacy or freshly cloned Home, not foreign proof
  /// on its own; the next [loadOrCreate] writes the binding or rotates.
  static bool isBoundToAnotherHome(SanadHomeBootstrap boundary) {
    final binding = _readBinding(boundary);
    if (binding == null) return false;
    try {
      return binding != sanadHomeIdentity(boundary.canonicalRoot());
    } catch (_) {
      return false;
    }
  }

  static String? _readBinding(SanadHomeBootstrap boundary) {
    if (!boundary.fileExists(bindingRelativePath)) return null;
    try {
      final value = utf8
          .decode(boundary.readSecretBytes(bindingRelativePath))
          .trim();
      return value.isEmpty ? null : value;
    } catch (_) {
      return null;
    }
  }

  /// Extracts the credential from an [HttpRequest] headers map. Returns
  /// null if the header is missing or malformed. Never logs the value.
  static LocalGatewayCredential? extractFromHeaders(
    Map<String, String> headers,
    String expected,
  ) {
    if (expected.isEmpty) return null;
    final custom = headers[headerName];
    if (custom != null && custom.trim().isNotEmpty) {
      if (_constantTimeEquals(custom.trim(), expected)) {
        return LocalGatewayCredential(custom.trim());
      }
      return null;
    }
    final auth = headers['authorization'] ?? headers['Authorization'];
    if (auth == null) return null;
    if (auth.length < 7) return null;
    if (auth.substring(0, 7).toLowerCase() != 'bearer ') {
      return null;
    }
    final token = auth.substring(7).trim();
    if (token.isEmpty) return null;
    if (_constantTimeEquals(token, expected)) {
      return LocalGatewayCredential(token);
    }
    return null;
  }

  static LocalGatewayCredential _generate() {
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    return LocalGatewayCredential(base64Url.encode(bytes));
  }

  /// Constant-time comparison on UTF-16 code units. We deliberately
  /// walk the longer value so the running time does not leak the
  /// expected token length.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) {
      // Still walk both to keep the timing of this branch similar.
      // ignore: unused_local_variable
      var diff = a.length ^ b.length;
      final shorter = a.length < b.length ? a.length : b.length;
      for (var i = 0; i < shorter; i++) {
        diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
      }
      return false;
    }
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}

class LocalGatewayCredential {
  final String value;
  const LocalGatewayCredential(this.value);

  @override
  String toString() => 'LocalGatewayCredential(redacted)';

  @override
  bool operator ==(Object other) =>
      other is LocalGatewayCredential && other.value == value;

  @override
  int get hashCode => value.hashCode;
}
