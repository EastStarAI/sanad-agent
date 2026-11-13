import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_transport.dart';
import 'package:sanad_client/features/notifications/infrastructure/mobile_push_token_relay.dart';

/// Why a token stopped being valid for the account.
///
/// The reason is used for a content-free log line only; the relay needs no
/// explanation, because the revocation itself is the instruction.
enum MobilePushRevocationReason {
  logout,
  sessionRevoked,
  accountDeleted,
}

/// What this Client currently claims about its device token.
enum MobilePushRegistrationState {
  /// No account session, or nothing attempted yet.
  idle,

  /// The token is known and its registration is in flight.
  registering,

  /// The relay holds this token for the authenticated account.
  registered,

  /// The token was withdrawn because the account session ended.
  revoked,

  /// The last attempt could not reach the relay; a reconnect retries.
  failed,

  /// This build has no push provider.
  unsupported,
}

/// Owns the device token for the lifetime of an account session.
///
/// Four rules hold here, and each one exists because the alternative leaks or
/// misroutes a credential:
///
/// - **Register after authentication.** A token registered without an account
///   session belongs to nobody; the relay resolves the account from the
///   authenticated socket, so registration follows sign-in.
/// - **Refresh on rotation.** A provider may replace a token at any time, and a
///   stale token delivers nothing. A rotation re-registers immediately.
/// - **Revoke at the end of the session.** Logout, a revoked session, and
///   account deletion all withdraw the token, so a device that signed out is not
///   a delivery target.
/// - **Never leak the value.** The token is held in memory only: it is never
///   written to preferences, a workspace file, an Agent payload, or a log line.
///   [MobilePushToken.fingerprint] is the only form that may be logged.
class MobilePushTokenRegistrar {
  MobilePushTokenRegistrar({
    required MobilePushTransport transport,
    required MobilePushTokenRelay relay,
  })  : _transport = transport,
        _relay = relay {
    if (!transport.isSupported) {
      _state = MobilePushRegistrationState.unsupported;
    }
  }

  final MobilePushTransport _transport;
  final MobilePushTokenRelay _relay;

  static final Logger _logger = Logger('notifications.push.registrar');

  MobilePushRegistrationState _state = MobilePushRegistrationState.idle;
  MobilePushToken? _token;
  bool _authenticated = false;
  bool _disposed = false;
  Future<void>? _flight;
  StreamSubscription<MobilePushToken>? _rotationSubscription;
  StreamSubscription<bool>? _readinessSubscription;

  MobilePushRegistrationState get state => _state;

  /// The token this process currently holds, in memory only.
  MobilePushToken? get currentToken => _token;

  /// Whether a push provider is wired into this build.
  bool get isSupported => _transport.isSupported;

  /// Starts consuming rotations and readiness transitions.
  void start() {
    if (_disposed || !_transport.isSupported) return;
    _rotationSubscription ??= _transport.tokenRefreshes.listen(
      (token) => unawaited(onTokenRotated(token)),
      onError: (Object error) => _logger.warning('push token rotation stream error', error),
    );
    _readinessSubscription ??= _relay.readinessChanges.listen(
      (ready) => unawaited(_onReadinessChanged(ready)),
      onError: (Object error) => _logger.warning('push relay readiness stream error', error),
    );
  }

  /// Called once the account session exists: asks the platform for a token and
  /// announces it.
  Future<void> onAuthenticated() async {
    if (_disposed || !_transport.isSupported) return;
    _authenticated = true;
    if (_state == MobilePushRegistrationState.revoked) {
      _state = MobilePushRegistrationState.idle;
    }
    await _run(() async {
      await _transport.ensureRegistration();
      final token = await _transport.currentToken();
      if (token == null) {
        // The provider may still be registering; the rotation stream delivers it.
        _state = MobilePushRegistrationState.idle;
        _logger.info('push provider has no token yet');
        return;
      }
      await _register(token);
    });
  }

  /// A provider rotation replaces the token for the same device.
  Future<void> onTokenRotated(MobilePushToken token) async {
    if (_disposed || !token.isValid) return;
    if (!_authenticated || _state == MobilePushRegistrationState.revoked) {
      // A rotation that arrives while signed out is remembered but not sent: a
      // token registered without an account session belongs to nobody.
      _token = token;
      return;
    }
    await _run(() => _register(token));
  }

  /// Ends the claim this device holds for the account.
  Future<void> revoke({required MobilePushRevocationReason reason}) async {
    _authenticated = false;
    final token = _token ?? await _transport.currentToken();
    _token = null;
    if (!_transport.isSupported) return;
    _state = MobilePushRegistrationState.revoked;
    if (token == null) return;
    try {
      await _relay.revoke(token);
    } catch (error) {
      _logger.warning('could not revoke the device token (${reason.name})', error);
    }
    _logger.info('withdrew ${token.provider.wire} device token ${token.fingerprint} (${reason.name})');
  }

  Future<void> _onReadinessChanged(bool ready) async {
    if (!ready || _disposed || !_authenticated) return;
    final token = _token ?? await _transport.currentToken();
    if (token == null) {
      await _transport.ensureRegistration();
      return;
    }
    if (_state == MobilePushRegistrationState.registered) return;
    await _run(() => _register(token));
  }

  Future<void> _register(MobilePushToken token) async {
    _token = token;
    _state = MobilePushRegistrationState.registering;
    try {
      final accepted = await _relay.register(token);
      _state = accepted
          ? MobilePushRegistrationState.registered
          : MobilePushRegistrationState.failed;
    } catch (error) {
      _state = MobilePushRegistrationState.failed;
      _logger.warning('device token registration failed', error);
    }
  }

  /// Serializes attempts so a rotation and a reconnect cannot interleave into
  /// two registrations for two different tokens.
  Future<void> _run(Future<void> Function() action) {
    final active = _flight;
    if (active != null) return active;
    final flight = action().whenComplete(() => _flight = null);
    _flight = flight;
    return flight;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _rotationSubscription?.cancel();
    _rotationSubscription = null;
    await _readinessSubscription?.cancel();
    _readinessSubscription = null;
    _token = null;
  }
}
