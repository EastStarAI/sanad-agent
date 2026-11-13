import 'package:equatable/equatable.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';

/// A withdrawal this Client still owes the relay.
///
/// Ending a session is a race the withdrawal must not lose. The account
/// lifecycle listener is an ancestor of the notification bridge, so it tears the
/// cloud socket down before the bridge observes the same auth transition; by
/// then the socket reports itself disconnected and an event emitted on it would
/// be dropped. A token that outlives its session keeps delivering to a device the
/// user signed out of, so the withdrawal is written down first and sent on the
/// next authenticated connection, ahead of any new registration.
///
/// The record holds the token value because a revocation is addressed by the
/// token itself. It is therefore the single persisted form of the token: it is
/// deleted the moment the relay acknowledges the revocation, it is bounded in
/// count, and it is never logged, never sent to an Agent, and never part of
/// workspace state. [fingerprint] is still the only form that may be logged.
/// [deviceId] is correlation only: neither event carries it, and the relay
/// resolves the account from the authenticated socket.
class MobilePushPendingRevocation extends Equatable {
  const MobilePushPendingRevocation({
    required this.token,
    required this.deviceId,
    required this.requestedAt,
  });

  /// The token whose binding must be withdrawn.
  final MobilePushToken token;

  /// The installation that asked for the withdrawal; empty when unknown.
  final String deviceId;

  /// When the session ended, for diagnostics and for bounding the store.
  final DateTime requestedAt;

  /// The only form of the token that may appear in a log line.
  String get fingerprint => token.fingerprint;

  @override
  String toString() =>
      'MobilePushPendingRevocation(${token.provider.wire}, $fingerprint, '
      '${requestedAt.toUtc().toIso8601String()})';

  @override
  List<Object?> get props => [token, deviceId, requestedAt];
}
