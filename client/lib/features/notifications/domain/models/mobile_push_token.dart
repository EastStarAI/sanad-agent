import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:equatable/equatable.dart';

/// The push provider that issued a device token.
///
/// The Client never holds provider credentials; it only names which provider a
/// token belongs to so the relay can choose the delivery path. Android tokens
/// come from FCM, iOS tokens from APNs; the relay resolves the rest.
enum MobilePushProvider {
  fcm('fcm'),
  apns('apns');

  const MobilePushProvider(this.wire);

  final String wire;

  /// Maps a native provider identifier, or `null` for one this build does not
  /// know. An unknown provider is dropped instead of being sent as a token the
  /// relay would have to guess about.
  static MobilePushProvider? fromWire(Object? value) {
    if (value is! String) return null;
    final token = value.trim().toLowerCase();
    for (final provider in MobilePushProvider.values) {
      if (provider.wire == token) return provider;
    }
    return null;
  }
}

/// One device registration token, exactly as the operating system issued it.
///
/// The value is a bearer capability for that single device, so it is treated as
/// sensitive: it is never written to logs, preferences, workspace state, or any
/// Agent payload. [fingerprint] is the only form that may appear in a log line
/// or a diagnostic, and [toString] is redacted so an accidental interpolation
/// cannot leak the value.
class MobilePushToken extends Equatable {
  const MobilePushToken({required this.value, required this.provider});

  /// The opaque token issued by the provider.
  final String value;

  final MobilePushProvider provider;

  /// Whether this token is long enough to be a provider token at all.
  ///
  /// A provider that has not finished registering answers with an empty value;
  /// treating that as a token would revoke or register nothing.
  bool get isValid => value.trim().length >= 16;

  /// A stable, non-reversible short identity for logs and change detection.
  ///
  /// The value itself must never be logged, but the Client still needs to know
  /// whether a rotation produced a different token. SHA-256 keeps that
  /// comparison possible without keeping the token in a readable form.
  String get fingerprint {
    final digest = sha256.convert(utf8.encode(value));
    return digest.toString().substring(0, 16);
  }

  /// The token as it may cross the wire, or `null` when it is unusable.
  String? get wireValue {
    final trimmed = value.trim();
    if (trimmed.length < 16) return null;
    return trimmed;
  }

  @override
  String toString() => 'MobilePushToken(${provider.wire}, $fingerprint)';

  @override
  List<Object?> get props => [value, provider];
}
