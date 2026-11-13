import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/application/mobile_push_token_registrar.dart';
import 'package:sanad_client/features/notifications/data/mobile_push_pending_revocation_store.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_message.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_pending_revocation.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_token.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_transport.dart';
import 'package:sanad_client/features/notifications/infrastructure/mobile_push_token_relay.dart';

const MobilePushToken _tokenValue = MobilePushToken(
  value: 'apns-token-0000000000000001',
  provider: MobilePushProvider.apns,
);

const MobilePushToken _rotated = MobilePushToken(
  value: 'apns-token-0000000000000002',
  provider: MobilePushProvider.apns,
);

class _FakeTransport implements MobilePushTransport {
  _FakeTransport({this.supported = true, bool hasToken = true}) : _token = hasToken ? _tokenValue : null;

  final bool supported;
  final StreamController<MobilePushMessage> _displays = StreamController<MobilePushMessage>.broadcast();
  final StreamController<MobilePushMessage> _interactions = StreamController<MobilePushMessage>.broadcast();
  final StreamController<MobilePushToken> _tokens = StreamController<MobilePushToken>.broadcast();

  MobilePushToken? _token;
  int registrations = 0;
  final List<String?> visibleSessions = <String?>[];

  void rotate(MobilePushToken token) {
    _token = token;
    _tokens.add(token);
  }

  @override
  bool get isSupported => supported;

  @override
  Stream<MobilePushMessage> get displays => _displays.stream;

  @override
  Stream<MobilePushMessage> get interactions => _interactions.stream;

  @override
  Stream<MobilePushToken> get tokenRefreshes => _tokens.stream;

  @override
  Future<MobilePushMessage?> takeInitialMessage() async => null;

  @override
  Future<MobilePushToken?> currentToken() async => _token;

  @override
  Future<void> ensureRegistration() async {
    registrations++;
  }

  @override
  Future<void> reportVisibleSession(String? sessionId) async => visibleSessions.add(sessionId);

  @override
  Future<void> dispose() async {}
}

class _FakeRelay implements MobilePushTokenRelay {
  _FakeRelay({bool ready = true}) : _ready = ready;

  final StreamController<bool> _readiness = StreamController<bool>.broadcast();
  final List<MobilePushToken> registered = <MobilePushToken>[];
  final List<MobilePushToken> revoked = <MobilePushToken>[];

  /// Every accepted call in the order the relay saw it.
  final List<String> events = <String>[];

  /// The relay can refuse a withdrawal while it still reports itself ready, so
  /// the "only the acknowledgement clears the record" rule is testable.
  bool rejectsRevocations = false;

  bool _ready;

  @override
  bool get isReady => _ready;

  /// Mirrors the synchronous socket teardown the logout path performs before
  /// the notification pipeline observes the auth transition.
  void disconnect() => _ready = false;

  /// Mirrors a reconnect: the relay becomes ready and reports the transition.
  void connect() {
    _ready = true;
    _readiness.add(true);
  }

  /// Mirrors a socket that was already ready before this pipeline subscribed:
  /// the relay is reachable, but no transition is reported on the stream.
  void attach() => _ready = true;

  @override
  Stream<bool> get readinessChanges => _readiness.stream;

  @override
  Future<bool> register(MobilePushToken token) async {
    if (!_ready) return false;
    registered.add(token);
    events.add('register:${token.value}');
    return true;
  }

  @override
  Future<bool> revoke(MobilePushToken token) async {
    if (!_ready) return false;
    if (rejectsRevocations) return false;
    revoked.add(token);
    events.add('revoke:${token.value}');
    return true;
  }
}

class _MemoryPendingStore implements MobilePushPendingRevocationStore {
  final List<MobilePushPendingRevocation> records = <MobilePushPendingRevocation>[];

  @override
  Future<List<MobilePushPendingRevocation>> read() async => List.of(records);

  @override
  Future<void> write(MobilePushPendingRevocation record) async {
    records.removeWhere((item) => item.token == record.token);
    records.add(record);
  }

  @override
  Future<void> remove(MobilePushToken token) async {
    records.removeWhere((item) => item.token == token);
  }
}

MobilePushTokenRegistrar _registrar(
  _FakeTransport transport,
  _FakeRelay relay, [
  _MemoryPendingStore? store,
]) {
  return MobilePushTokenRegistrar(
    transport: transport,
    relay: relay,
    pendingRevocations: store ?? _MemoryPendingStore(),
  )..start();
}

void main() {
  group('MobilePushTokenRegistrar', () {
    test('registers the device token only after authentication', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final registrar = _registrar(transport, relay);

      expect(registrar.state, MobilePushRegistrationState.idle);
      expect(relay.registered, isEmpty);

      await registrar.onAuthenticated();

      expect(transport.registrations, 1);
      expect(relay.registered.single.value, _tokenValue.value);
      expect(registrar.state, MobilePushRegistrationState.registered);
    });

    test('a rotation replaces the registered token', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final registrar = _registrar(transport, relay);

      await registrar.onAuthenticated();
      transport.rotate(_rotated);
      await Future<void>.delayed(Duration.zero);

      expect(relay.registered.length, 2);
      expect(relay.registered.last.value, _rotated.value);
      expect(registrar.currentToken?.value, _rotated.value);
    });

    test('a rotation while signed out is held and never registered', () async {
      final transport = _FakeTransport(hasToken: false);
      final relay = _FakeRelay();
      final registrar = _registrar(transport, relay);

      transport.rotate(_rotated);
      await Future<void>.delayed(Duration.zero);

      expect(relay.registered, isEmpty);
      expect(registrar.currentToken?.value, _rotated.value);
    });

    test('revoking while the relay is ready withdraws the token immediately', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final store = _MemoryPendingStore();
      final registrar = _registrar(transport, relay, store);

      await registrar.onAuthenticated();
      await registrar.revoke(reason: MobilePushRevocationReason.logout, deviceId: 'device-1');

      expect(relay.revoked.single.value, _tokenValue.value);
      expect(registrar.state, MobilePushRegistrationState.revoked);
      expect(registrar.currentToken, isNull);
      // The immediate path leaves no record behind: it was acknowledged.
      expect(store.records, isEmpty);

      transport.rotate(_rotated);
      await Future<void>.delayed(Duration.zero);
      // A late rotation after the session ended must not resurrect the device as
      // a delivery target.
      expect(relay.registered.length, 1);
    });

    test('revoking while the socket is down records the withdrawal instead of dropping it', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final store = _MemoryPendingStore();
      final registrar = _registrar(transport, relay, store);

      await registrar.onAuthenticated();
      relay.disconnect();
      await registrar.revoke(reason: MobilePushRevocationReason.logout, deviceId: 'device-1');

      // Nothing reached the relay, and that is exactly why the record exists.
      expect(relay.revoked, isEmpty);
      expect(store.records.single.token.value, _tokenValue.value);
      expect(store.records.single.deviceId, 'device-1');
      expect(registrar.state, MobilePushRegistrationState.revoked);
    });

    test('the durable record covers the logout ordering: teardown, then revoke', () async {
      // The account lifecycle listener is an ancestor of the notification
      // bridge, so the cloud socket is already disconnected when the revocation
      // is requested. Reproducing that sequence here is the ordering proof: the
      // withdrawal must reach the relay on the next authenticated connection.
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final store = _MemoryPendingStore();
      final registrar = _registrar(transport, relay, store);

      await registrar.onAuthenticated();
      relay.disconnect();
      await registrar.revoke(reason: MobilePushRevocationReason.logout, deviceId: 'device-1');
      expect(relay.revoked, isEmpty);

      relay.connect();
      await registrar.onAuthenticated();
      await pumpEventQueue();

      expect(relay.revoked.single.value, _tokenValue.value);
      expect(store.records, isEmpty);
    });

    test('a recorded withdrawal is flushed before the token is registered again', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final store = _MemoryPendingStore();
      final registrar = _registrar(transport, relay, store);

      await registrar.onAuthenticated();
      relay.disconnect();
      await registrar.revoke(reason: MobilePushRevocationReason.logout, deviceId: 'device-1');
      relay.events.clear();

      relay.connect();
      await registrar.onAuthenticated();
      await pumpEventQueue();

      // The same installation token is announced again after the sign-in, so the
      // order is the whole point: retire the stale binding, then claim it.
      expect(relay.events, <String>['revoke:${_tokenValue.value}', 'register:${_tokenValue.value}']);
      expect(registrar.state, MobilePushRegistrationState.registered);
    });

    test('a reconnect flushes the withdrawal without re-registering first', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final store = _MemoryPendingStore();
      final registrar = _registrar(transport, relay, store);

      await registrar.onAuthenticated();
      relay.disconnect();
      await registrar.revoke(reason: MobilePushRevocationReason.sessionRevoked, deviceId: 'device-1');

      // The session is authenticated again but the socket has not returned yet:
      // nothing is registered and the record waits.
      await registrar.onAuthenticated();
      expect(store.records, hasLength(1));
      expect(relay.registered, hasLength(1));

      relay.connect();
      await pumpEventQueue();

      expect(relay.events, <String>['register:${_tokenValue.value}', 'revoke:${_tokenValue.value}', 'register:${_tokenValue.value}']);
      expect(store.records, isEmpty);
      expect(registrar.state, MobilePushRegistrationState.registered);
    });

    test('a rotation settles an owed withdrawal before it announces the new token', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay(ready: false);
      final store = _MemoryPendingStore()
        ..records.add(
          MobilePushPendingRevocation(
            token: _tokenValue,
            deviceId: 'device-1',
            requestedAt: DateTime.utc(2026, 11, 13),
          ),
        );
      final registrar = _registrar(transport, relay, store);

      // The session starts while the socket is still down, so the withdrawal an
      // earlier process left behind cannot be flushed yet.
      await registrar.onAuthenticated();
      expect(store.records, hasLength(1));

      // The socket is reachable and the provider rotates the token in the same
      // window. The withdrawal must still be retired first.
      relay.attach();
      transport.rotate(_rotated);
      await pumpEventQueue();

      expect(
        relay.events,
        <String>['revoke:${_tokenValue.value}', 'register:${_rotated.value}'],
      );
      expect(store.records, isEmpty);
      expect(registrar.state, MobilePushRegistrationState.registered);
    });

    test('a withdrawal the relay will not acknowledge stays recorded', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final store = _MemoryPendingStore();
      final registrar = _registrar(transport, relay, store);

      relay.rejectsRevocations = true;
      await registrar.onAuthenticated();
      relay.disconnect();
      await registrar.revoke(reason: MobilePushRevocationReason.logout, deviceId: 'device-1');
      expect(store.records, hasLength(1));

      relay.connect();
      await registrar.onAuthenticated();
      expect(store.records, hasLength(1), reason: 'an unacknowledged withdrawal is not forgotten');

      relay.rejectsRevocations = false;
      relay.connect();
      await pumpEventQueue();

      expect(store.records, isEmpty);
      expect(relay.revoked.single.value, _tokenValue.value);
    });

    test('account deletion drops the record instead of retrying it', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final store = _MemoryPendingStore();
      final registrar = _registrar(transport, relay, store);

      await registrar.onAuthenticated();
      relay.disconnect();
      await registrar.revoke(reason: MobilePushRevocationReason.accountDeleted, deviceId: 'device-1');

      expect(store.records, isEmpty);
      expect(relay.revoked, isEmpty);
    });

    test('a reconnect re-registers a token the relay may have dropped', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final registrar = _registrar(transport, relay);

      await registrar.onAuthenticated();
      await registrar.revoke(reason: MobilePushRevocationReason.sessionRevoked);
      await registrar.onAuthenticated();

      expect(relay.registered.length, 2);
    });

    test('a provider that has no token yet registers nothing', () async {
      final transport = _FakeTransport(hasToken: false);
      final relay = _FakeRelay();
      final registrar = _registrar(transport, relay);

      await registrar.onAuthenticated();

      expect(relay.registered, isEmpty);
      expect(registrar.state, MobilePushRegistrationState.idle);
    });

    test('a build without a provider never touches the relay', () async {
      final transport = _FakeTransport(supported: false);
      final relay = _FakeRelay();
      final store = _MemoryPendingStore();
      final registrar = _registrar(transport, relay, store);

      expect(registrar.state, MobilePushRegistrationState.unsupported);
      await registrar.onAuthenticated();
      await registrar.revoke(reason: MobilePushRevocationReason.accountDeleted);

      expect(transport.registrations, 0);
      expect(relay.registered, isEmpty);
      expect(store.records, isEmpty);
    });

    test('an unreachable relay leaves the token pending for the next reconnect', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay(ready: false);
      final registrar = _registrar(transport, relay);

      await registrar.onAuthenticated();

      expect(registrar.state, MobilePushRegistrationState.failed);
      expect(relay.registered, isEmpty);
    });

    test('the token is never stringified in the clear', () {
      expect(_tokenValue.toString(), isNot(contains(_tokenValue.value)));
      expect(_tokenValue.toString(), contains(_tokenValue.fingerprint));
      expect(_tokenValue.fingerprint.length, 16);

      final record = MobilePushPendingRevocation(
        token: _tokenValue,
        deviceId: 'device-1',
        requestedAt: DateTime.utc(2026, 11, 13),
      );
      expect(record.toString(), isNot(contains(_tokenValue.value)));
      expect(record.toString(), contains(_tokenValue.fingerprint));
    });
  });
}
