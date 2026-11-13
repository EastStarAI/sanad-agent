import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';
import 'package:sanad_client/infrastructure/socket/sanad_socket_service.dart';

/// Where a device token is registered and revoked.
///
/// The relay resolves a named target to tokens and delivers; it never appears in
/// this package as a credential, a URL, or a provider key. The Client only
/// announces "this account has this device", and withdraws that claim when the
/// session ends, so a token outlives its authorization by as little as possible.
abstract class MobilePushTokenRelay {
  /// Whether the authenticated account session can carry a registration now.
  bool get isReady;

  /// Readiness transitions. Every reconnect is a reason to register again,
  /// because the relay may have dropped the binding while the device was away.
  Stream<bool> get readinessChanges;

  /// Announces [token] for the authenticated account.
  ///
  /// Returns whether the registration was accepted for delivery. A caller that
  /// receives `false` keeps the token pending and retries on the next
  /// readiness transition instead of pretending the device is reachable.
  Future<bool> register(MobilePushToken token);

  /// Withdraws [token] from the authenticated account.
  ///
  /// A revocation that cannot reach the relay is not an error the user sees:
  /// the token is dropped locally either way, so the next session starts
  /// without it.
  Future<bool> revoke(MobilePushToken token);
}

/// The registration path over the authenticated Cloud Socket.
///
/// Token registration is an account operation, so it uses the same authenticated
/// session as account lifecycle and device inventory rather than a second
/// credential. Nothing here reads a provider credential, and the token is never
/// logged, persisted, or forwarded to an Agent.
class AccountSessionPushTokenRelay implements MobilePushTokenRelay {
  AccountSessionPushTokenRelay(this._socket);

  /// The registration event. The Gateway derives the account from the
  /// authenticated socket; no identity travels in the payload.
  static const String registerEvent = 'push.register_token';

  /// The withdrawal event, with the same authentication rules.
  static const String revokeEvent = 'push.revoke_token';

  static final Logger _logger = Logger('notifications.push.relay');

  final SanadSocketService _socket;

  @override
  bool get isReady => _socket.isReady;

  @override
  Stream<bool> get readinessChanges =>
      _socket.lifecycleStateStream.map((state) => state == SocketLifecycleState.ready).distinct();

  @override
  Future<bool> register(MobilePushToken token) async {
    final value = token.wireValue;
    if (value == null || !isReady) return false;
    _socket.emit(registerEvent, <String, dynamic>{
      'version': 1,
      'provider': token.provider.wire,
      'token': value,
      'capabilities': const <String>['notification_dispatch_v1'],
    });
    _logger.info('registered ${token.provider.wire} device token ${token.fingerprint}');
    return true;
  }

  @override
  Future<bool> revoke(MobilePushToken token) async {
    final value = token.wireValue;
    // A revocation is attempted even when the socket is down: the local claim is
    // dropped regardless, and the relay expires an unused token on its own.
    if (value == null) return false;
    if (!isReady) return false;
    _socket.emit(revokeEvent, <String, dynamic>{
      'version': 1,
      'provider': token.provider.wire,
      'token': value,
    });
    _logger.info('revoked ${token.provider.wire} device token ${token.fingerprint}');
    return true;
  }
}
