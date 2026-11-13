import 'dart:async';

import 'package:logging/logging.dart';
import 'package:sanad_client/features/notifications/data/mobile_push_pending_revocation_store.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_pending_revocation.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_transport.dart';
import 'package:sanad_client/features/notifications/infrastructure/mobile_push_token_relay.dart';

/// Why a token stopped being valid for the account.
///
/// The reason is used for a content-free log line only; the relay needs no
/// explanation, because the revocation itself is the instruction. [retry] names
/// a withdrawal that outlived the session which requested it.
enum MobilePushRevocationReason {
  logout,
  sessionRevoked,
  accountDeleted,
  retry,
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
/// Five rules hold here, and each one exists because the alternative leaks or
/// misroutes a credential:
///
/// - **Register after authentication.** A token registered without an account
///   session belongs to nobody; the relay resolves the account from the
///   authenticated socket, so registration follows sign-in.
/// - **Refresh on rotation.** A provider may replace a token at any time, and a
///   stale token delivers nothing. A rotation re-registers immediately.
/// - **Withdraw durably.** Ending a session is an ordering race: the account
///   lifecycle tears the cloud socket down before this pipeline sees the same
///   auth transition, so the revocation is recorded first and delivered as soon
///   as an authenticated socket exists. A withdrawal is never dependent on the
///   socket being ready at the moment the session ends.
/// - **Flush before registering.** Every authenticated connection settles the
///   withdrawals still owed before it announces the current token, so a token
///   that is being retired is never re-registered ahead of its own revocation.
/// - **Never leak the value.** The token is held in memory, and the only form
///   that is ever persisted is the pending withdrawal described above, which is
///   deleted when the relay acknowledges it. It is never logged, written to a
///   workspace file, or sent to an Agent; [MobilePushToken.fingerprint] is the
///   only form that may be logged.
class MobilePushTokenRegistrar {
  MobilePushTokenRegistrar({
    required MobilePushTransport transport,
    required MobilePushTokenRelay relay,
    required MobilePushPendingRevocationStore pendingRevocations,
  })  : _transport = transport,
        _relay = relay,
        _pendingRevocations = pendingRevocations {
    if (!transport.isSupported) {
      _state = MobilePushRegistrationState.unsupported;
    }
  }

  final MobilePushTransport _transport;
  final MobilePushTokenRelay _relay;
  final MobilePushPendingRevocationStore _pendingRevocations;

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

  /// Called once the account session exists: settles what an earlier session
  /// could not deliver, then asks the platform for a token and announces it.
  Future<void> onAuthenticated() async {
    if (_disposed || !_transport.isSupported) return;
    _authenticated = true;
    if (_state == MobilePushRegistrationState.revoked) {
      _state = MobilePushRegistrationState.idle;
    }
    await _run(() async {
      // A withdrawal owed by an earlier session is settled first: registering an
      // about-to-be-revoked token would leave the device reachable for a moment
      // after the relay was told to stop delivering to it.
      await _flushPendingRevocations();
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
    await _run(() => _settleThenRegister(token));
  }

  /// Ends the claim this device holds for the account.
  ///
  /// The record is written before the attempt, so a revocation survives the
  /// socket teardown that normally precedes it, and it is cleared only when the
  /// relay acknowledges the withdrawal. Account deletion is the one exception:
  /// the binding dies with the account, so retrying would revoke nothing.
  Future<void> revoke({
    required MobilePushRevocationReason reason,
    String deviceId = '',
  }) async {
    _authenticated = false;
    final token = _token ?? await _transport.currentToken();
    if (!_transport.isSupported) {
      _token = null;
      return;
    }
    _state = MobilePushRegistrationState.revoked;
    if (token == null) {
      _token = null;
      return;
    }
    try {
      if (reason == MobilePushRevocationReason.accountDeleted) {
        // The account is gone, and a provider token is a per-installation
        // capability rather than an account credential, so there is nothing a
        // later session could usefully withdraw and nothing to retry.
        await _pendingRevocations.remove(token);
      } else {
        await _pendingRevocations.write(
          MobilePushPendingRevocation(
            token: token,
            deviceId: deviceId,
            requestedAt: DateTime.now().toUtc(),
          ),
        );
      }
    } catch (error) {
      _logger.warning('could not record the pending device token revocation', error);
    }
    _token = null;
    final acknowledged = await _sendRevocation(token, reason);
    if (acknowledged) {
      await _settleRevocation(token);
    }
    _logger.info(
      'withdrew ${token.provider.wire} device token ${token.fingerprint} '
      '(${reason.name}${acknowledged ? '' : ', pending the next session'})',
    );
  }

  Future<void> _onReadinessChanged(bool ready) async {
    if (!ready || _disposed || !_authenticated) return;
    await _run(() async {
      // Same order as a fresh authentication: settle first, announce second.
      await _flushPendingRevocations();
      final token = _token ?? await _transport.currentToken();
      if (token == null) {
        await _transport.ensureRegistration();
        return;
      }
      if (_state == MobilePushRegistrationState.registered) return;
      await _register(token);
    });
  }

  /// Delivers every withdrawal this device still owes, oldest first.
  ///
  /// A relay that is not ready leaves the records untouched, and the next
  /// authenticated connection retries them; a record is cleared only against an
  /// acknowledged withdrawal, so a crash between the emit and the clear repeats
  /// an idempotent revocation instead of losing it.
  Future<void> _flushPendingRevocations() async {
    if (_disposed || !_relay.isReady) return;
    final List<MobilePushPendingRevocation> pending;
    try {
      pending = await _pendingRevocations.read();
    } catch (error) {
      _logger.warning('could not read pending device token revocations', error);
      return;
    }
    for (final record in pending) {
      if (_disposed || !_relay.isReady) return;
      final acknowledged = await _sendRevocation(
        record.token,
        MobilePushRevocationReason.retry,
      );
      if (!acknowledged) return;
      await _settleRevocation(record.token);
    }
  }

  Future<bool> _sendRevocation(
    MobilePushToken token,
    MobilePushRevocationReason reason,
  ) async {
    try {
      return await _relay.revoke(token);
    } catch (error) {
      _logger.warning('could not revoke the device token (${reason.name})', error);
      return false;
    }
  }

  Future<void> _settleRevocation(MobilePushToken token) async {
    try {
      await _pendingRevocations.remove(token);
    } catch (error) {
      _logger.warning('could not clear the pending device token revocation', error);
    }
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

  /// Settles every withdrawal this device owes, then announces [token].
  ///
  /// A rotation can arrive on its own schedule, so this is the path that keeps
  /// the ordering rule true even when the readiness transition has already
  /// happened: no token is announced while an older binding is still to be
  /// retired.
  Future<void> _settleThenRegister(MobilePushToken token) async {
    await _flushPendingRevocations();
    await _register(token);
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
