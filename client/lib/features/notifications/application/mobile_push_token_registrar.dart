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
/// Six rules hold here, and each one exists because the alternative leaks or
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
/// - **Settle before announcing, per token.** The withdrawal recorded for a token
///   is delivered before that token is announced again, and no registration is
///   announced while its own withdrawal is still owed. The check happens inside
///   the flight immediately before the announcement, not only when the flight
///   starts, because the socket can become reachable while the flight is
///   suspended.
/// - **Never lose a transition.** A readiness or rotation request that arrives
///   while a flight is running makes that flight take another pass before it
///   settles. The readiness stream is `distinct()`, so a transition that is
///   dropped is dropped for good: the withdrawal stays owed, the flight announces
///   the token anyway, and the next reconnect flushes the stale record and
///   withdraws the live binding while the Client still reports `registered`.
/// - **Report only what the relay holds.** [MobilePushRegistrationState.registered]
///   is claimed only for a token the relay accepted and has not been asked to
///   withdraw since, so push is never silently dead behind a state that says it
///   works.
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

  /// The token the relay last acknowledged holding for this account.
  ///
  /// This is the only evidence that a binding exists, so [state] follows it:
  /// `registered` is never claimed for a token the relay did not accept, and a
  /// withdrawal clears it instead of leaving a `registered` claim behind a
  /// binding that has just been retired.
  MobilePushToken? _acknowledged;

  bool _authenticated = false;
  bool _disposed = false;
  Future<void>? _flight;
  bool _queued = false;
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
    // The provider may still be registering at the platform level; a token that
    // arrives later reaches this pipeline through the rotation stream.
    await _transport.ensureRegistration();
    await _requestReconcile();
  }

  /// A provider rotation replaces the token for the same device.
  Future<void> onTokenRotated(MobilePushToken token) async {
    if (_disposed || !token.isValid) return;
    _token = token;
    if (!_authenticated || _state == MobilePushRegistrationState.revoked) {
      // A rotation that arrives while signed out is remembered but not sent: a
      // token registered without an account session belongs to nobody.
      return;
    }
    await _requestReconcile();
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
      _acknowledged = null;
      return;
    }
    _state = MobilePushRegistrationState.revoked;
    // The device intends to stop being a delivery target, so it cannot keep
    // claiming the relay holds this binding while the withdrawal is outstanding.
    _acknowledged = null;
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
    await _requestReconcile();
  }

  /// One serialized pass: settle what is owed, then announce what is current.
  ///
  /// The withdrawal check runs after every suspension in the pass, immediately
  /// before the announcement, so a socket that became reachable while the pass
  /// was waiting still settles the record before the token it names is sent.
  Future<void> _settleThenAnnounce() async {
    if (_disposed || !_authenticated) return;
    final token = _token ?? await _transport.currentToken();
    if (token == null) {
      // The provider may still be registering; the rotation stream delivers it.
      await _transport.ensureRegistration();
      if (_disposed || !_authenticated) return;
      _state = MobilePushRegistrationState.idle;
      _logger.info('push provider has no token yet');
      return;
    }
    final owed = await _flushPendingRevocations();
    if (_disposed || !_authenticated) return;
    if (_state == MobilePushRegistrationState.registered && _acknowledged == token) {
      return;
    }
    if (owed == null || owed.contains(token)) {
      // Either the relay could not take what is owed, or this token's own
      // withdrawal is still pending. Announcing it now would claim a binding the
      // previous session asked the relay to retire, so the next authenticated
      // connection retries instead.
      _state = MobilePushRegistrationState.failed;
      _logger.info(
        'deferred ${token.fingerprint}: a withdrawal for it is settled by the next connection',
      );
      return;
    }
    await _register(token);
  }

  /// Delivers every withdrawal this device still owes, oldest first.
  ///
  /// A relay that is not ready leaves the records untouched, and the next
  /// authenticated connection retries them; a record is cleared only against an
  /// acknowledged withdrawal, so a crash between the emit and the clear repeats
  /// an idempotent revocation instead of losing it.
  ///
  /// Returns the withdrawals still owed afterwards, or `null` when that could not
  /// be established: the relay is not ready, or the store could not be read. A
  /// caller that is about to announce a token treats `null` as "not safe yet",
  /// which is what keeps a registration from overtaking its own withdrawal.
  Future<Set<MobilePushToken>?> _flushPendingRevocations() async {
    if (_disposed || !_relay.isReady) return null;
    final List<MobilePushPendingRevocation> pending;
    try {
      pending = await _pendingRevocations.read();
    } catch (error) {
      _logger.warning('could not read pending device token revocations', error);
      return null;
    }
    final owed = <MobilePushToken>{for (final record in pending) record.token};
    for (final record in pending) {
      if (_disposed) return null;
      if (record.token == _acknowledged) {
        // A registration for this exact token was accepted after the record was
        // written, so the record describes a binding the relay has already
        // replaced. Sending it now would withdraw the live binding; the newer
        // accepted claim on the same binding supersedes the older withdrawal.
        await _settleRevocation(record.token);
        owed.remove(record.token);
        _logger.info('dropped a superseded device token withdrawal (${record.token.fingerprint})');
        continue;
      }
      if (!_relay.isReady) return owed;
      final acknowledged = await _sendRevocation(
        record.token,
        MobilePushRevocationReason.retry,
      );
      if (!acknowledged) return owed;
      _markWithdrawn(record.token);
      await _settleRevocation(record.token);
      owed.remove(record.token);
    }
    return owed;
  }

  /// Records that the relay no longer holds [token].
  ///
  /// The state cannot keep claiming a binding that was just withdrawn, so it
  /// moves off `registered` here rather than after the caller's next step.
  void _markWithdrawn(MobilePushToken token) {
    if (_acknowledged != token) return;
    _acknowledged = null;
    _state = MobilePushRegistrationState.revoked;
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
    final bool accepted;
    try {
      accepted = await _relay.register(token);
    } catch (error) {
      _markNotRegistered();
      _logger.warning('device token registration failed', error);
      return;
    }
    if (!accepted) {
      // A refused registration is not a binding, whatever the retry bookkeeping
      // says; `registered` would be a claim the relay never accepted.
      _markNotRegistered();
      return;
    }
    _acknowledged = token;
    _state = MobilePushRegistrationState.registered;
    if (_authenticated && _token == token) return;
    // The session ended, or the provider rotated away, while the relay was
    // accepting this registration. The relay now holds a binding this device no
    // longer wants, so `registered` would be a lie: drop the claim first (the
    // state must never outlive the intent), then withdraw it. A failed withdrawal
    // stays owed as a record the next authenticated connection settles.
    _logger.info(
      'withdrew ${token.fingerprint}: the binding was superseded while it was accepted',
    );
    _acknowledged = null;
    if (!_authenticated) _token = null;
    _state = _authenticated
        ? MobilePushRegistrationState.idle
        : MobilePushRegistrationState.revoked;
    final acknowledged = await _sendRevocation(
      token,
      MobilePushRevocationReason.sessionRevoked,
    );
    if (acknowledged) {
      await _settleRevocation(token);
    }
  }

  /// Records that the relay holds no binding for this device.
  ///
  /// An ended session keeps the terminal `revoked` state instead of `failed`: a
  /// reconnect retries a failure inside a live session, but there is no session
  /// left to retry in once the withdrawal was requested.
  void _markNotRegistered() {
    _acknowledged = null;
    if (!_authenticated) {
      _token = null;
      _state = MobilePushRegistrationState.revoked;
      return;
    }
    _state = MobilePushRegistrationState.failed;
  }

  /// Serializes passes so a rotation and a reconnect cannot interleave into two
  /// registrations for two different tokens.
  ///
  /// A request that arrives while a pass is running is **not** dropped: it makes
  /// the running flight take another pass before it settles. Dropping it was a
  /// real defect — a readiness transition observed during the authentication
  /// flight left the withdrawal owed, the flight announced the token anyway, and
  /// the next reconnect flushed the stale record and withdrew the live binding.
  /// The readiness stream is `distinct()`, so a dropped transition never repeats.
  Future<void> _requestReconcile() {
    final active = _flight;
    if (active != null) {
      _queued = true;
      return active;
    }
    final flight = _drain().whenComplete(() => _flight = null);
    _flight = flight;
    return flight;
  }

  Future<void> _drain() async {
    do {
      _queued = false;
      await _settleThenAnnounce();
    } while (_queued && !_disposed);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _rotationSubscription?.cancel();
    _rotationSubscription = null;
    await _readinessSubscription?.cancel();
    _readinessSubscription = null;
    _token = null;
    _acknowledged = null;
  }
}
