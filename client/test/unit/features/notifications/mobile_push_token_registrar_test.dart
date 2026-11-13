import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/notifications/application/mobile_push_token_registrar.dart';
import 'package:sanad_client/features/notifications/domain/models/mobile_push_message.dart';
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
  _FakeRelay({this.ready = true});

  final bool ready;
  final StreamController<bool> _readiness = StreamController<bool>.broadcast();
  final List<MobilePushToken> registered = <MobilePushToken>[];
  final List<MobilePushToken> revoked = <MobilePushToken>[];

  void setReady(bool value) => _readiness.add(value);

  @override
  bool get isReady => ready;

  @override
  Stream<bool> get readinessChanges => _readiness.stream;

  @override
  Future<bool> register(MobilePushToken token) async {
    if (!ready) return false;
    registered.add(token);
    return true;
  }

  @override
  Future<bool> revoke(MobilePushToken token) async {
    revoked.add(token);
    return ready;
  }
}

void main() {
  group('MobilePushTokenRegistrar', () {
    test('registers the device token only after authentication', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final registrar = MobilePushTokenRegistrar(transport: transport, relay: relay)..start();

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
      final registrar = MobilePushTokenRegistrar(transport: transport, relay: relay)..start();

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
      final registrar = MobilePushTokenRegistrar(transport: transport, relay: relay)..start();

      transport.rotate(_rotated);
      await Future<void>.delayed(Duration.zero);

      expect(relay.registered, isEmpty);
      expect(registrar.currentToken?.value, _rotated.value);
    });

    test('revoking withdraws the token and stops further registrations', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final registrar = MobilePushTokenRegistrar(transport: transport, relay: relay)..start();

      await registrar.onAuthenticated();
      await registrar.revoke(reason: MobilePushRevocationReason.logout);

      expect(relay.revoked.single.value, _tokenValue.value);
      expect(registrar.state, MobilePushRegistrationState.revoked);
      expect(registrar.currentToken, isNull);

      transport.rotate(_rotated);
      await Future<void>.delayed(Duration.zero);
      // A late rotation after the session ended must not resurrect the device as
      // a delivery target.
      expect(relay.registered.length, 1);
    });

    test('a reconnect re-registers a token the relay may have dropped', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay();
      final registrar = MobilePushTokenRegistrar(transport: transport, relay: relay)..start();

      await registrar.onAuthenticated();
      await registrar.revoke(reason: MobilePushRevocationReason.sessionRevoked);
      await registrar.onAuthenticated();

      expect(relay.registered.length, 2);
    });

    test('a provider that has no token yet registers nothing', () async {
      final transport = _FakeTransport(hasToken: false);
      final relay = _FakeRelay();
      final registrar = MobilePushTokenRegistrar(transport: transport, relay: relay)..start();

      await registrar.onAuthenticated();

      expect(relay.registered, isEmpty);
      expect(registrar.state, MobilePushRegistrationState.idle);
    });

    test('a build without a provider never touches the relay', () async {
      final transport = _FakeTransport(supported: false);
      final relay = _FakeRelay();
      final registrar = MobilePushTokenRegistrar(transport: transport, relay: relay)..start();

      expect(registrar.state, MobilePushRegistrationState.unsupported);
      await registrar.onAuthenticated();
      await registrar.revoke(reason: MobilePushRevocationReason.accountDeleted);

      expect(transport.registrations, 0);
      expect(relay.registered, isEmpty);
    });

    test('an unreachable relay leaves the token pending for the next reconnect', () async {
      final transport = _FakeTransport();
      final relay = _FakeRelay(ready: false);
      final registrar = MobilePushTokenRegistrar(transport: transport, relay: relay)..start();

      await registrar.onAuthenticated();

      expect(registrar.state, MobilePushRegistrationState.failed);
      expect(relay.registered, isEmpty);
    });

    test('the token is never stringified in the clear', () {
      expect(_tokenValue.toString(), isNot(contains(_tokenValue.value)));
      expect(_tokenValue.toString(), contains(_tokenValue.fingerprint));
      expect(_tokenValue.fingerprint.length, 16);
    });
  });
}
