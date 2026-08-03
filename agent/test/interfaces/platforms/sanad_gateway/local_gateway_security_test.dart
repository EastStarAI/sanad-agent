import 'dart:io';

import 'package:test/test.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_security.dart';

void main() {
  group('LocalGatewaySecurity', () {
    final token = const LocalGatewayCredential('expected-token-xyz');
    final security = LocalGatewaySecurity(
      config: const LocalGatewaySecurityConfig(
        allowedPort: 58085,
        preauthBudgetPerPeer: 2,
        allowedOrigins: {'https://client.local'},
        allowedHosts: {'127.0.0.1', 'localhost'},
      ),
      expectedToken: token,
    );
    Map<String, String> authorizedHeaders({String host = '127.0.0.1:58085'}) =>
        {LocalGatewayCredentials.headerName: token.value, 'host': host};

    test('accepts a native request with the correct token and Host', () {
      final result = security.verify(
        headers: authorizedHeaders(),
        remoteAddress: InternetAddress('127.0.0.1'),
        origin: null,
      );
      expect(result.isOk, isTrue);
    });

    test('rejects a request with no credential', () {
      final result = security.verify(
        headers: const {},
        remoteAddress: InternetAddress('127.0.0.1'),
      );
      expect(result.outcome, equals(LocalGatewayAuthOutcome.missingCredential));
    });

    test('rejects a request with a wrong credential', () {
      final result = security.verify(
        headers: {
          LocalGatewayCredentials.headerName: 'wrong',
          'host': '127.0.0.1:58085',
        },
        remoteAddress: InternetAddress('127.0.0.1'),
      );
      expect(result.outcome, equals(LocalGatewayAuthOutcome.invalidCredential));
    });

    test('accepts Authorization: Bearer with the expected token', () {
      final result = security.verify(
        headers: {
          'Authorization': 'Bearer ${token.value}',
          'Host': 'localhost:58085',
        },
        remoteAddress: InternetAddress('127.0.0.1'),
      );
      expect(result.isOk, isTrue);
    });

    test('rejects an unknown Origin from a loopback client', () {
      final result = security.verify(
        headers: authorizedHeaders(),
        remoteAddress: InternetAddress('127.0.0.1'),
        origin: 'https://attacker.example',
      );
      expect(result.outcome, equals(LocalGatewayAuthOutcome.originRejected));
    });

    test('accepts an allowed Origin from a loopback client', () {
      final result = security.verify(
        headers: authorizedHeaders(),
        remoteAddress: InternetAddress('127.0.0.1'),
        origin: 'https://client.local',
      );
      expect(result.isOk, isTrue);
    });

    test('rejects origin authorities containing URL components', () {
      for (final origin in [
        'https://client.local/path',
        'https://client.local?query=yes',
        'https://user@client.local',
        'https://client.local#fragment',
      ]) {
        final result = security.verify(
          headers: authorizedHeaders(),
          remoteAddress: InternetAddress('127.0.0.1'),
          origin: origin,
        );
        expect(result.outcome, LocalGatewayAuthOutcome.originRejected);
      }
    });

    test('does not treat wildcard as an allowed Origin', () {
      final wildcard = LocalGatewaySecurity(
        config: const LocalGatewaySecurityConfig(
          allowedPort: 58085,
          allowedOrigins: {'*'},
        ),
        expectedToken: token,
      );
      final result = wildcard.evaluateOrigin(origin: 'https://client.local');
      expect(result.ok, isFalse);
    });

    test('rejects a hostile Origin from a non-loopback client', () {
      final result = security.verify(
        headers: authorizedHeaders(),
        remoteAddress: InternetAddress('10.0.0.5'),
        origin: 'https://attacker.example',
      );
      expect(result.outcome, equals(LocalGatewayAuthOutcome.peerRejected));
    });

    test('rejects a request with a missing Host', () {
      final result = security.verify(
        headers: {LocalGatewayCredentials.headerName: token.value},
        remoteAddress: InternetAddress('127.0.0.1'),
      );
      expect(result.outcome, LocalGatewayAuthOutcome.hostRejected);
    });

    test('rejects a non-loopback Host even with the correct token', () {
      final result = security.verify(
        headers: authorizedHeaders(host: 'attacker.example'),
        remoteAddress: InternetAddress('127.0.0.1'),
      );
      expect(result.outcome, LocalGatewayAuthOutcome.hostRejected);
    });

    test('rejects a loopback Host on the wrong port', () {
      final result = security.verify(
        headers: authorizedHeaders(host: '127.0.0.1:58086'),
        remoteAddress: InternetAddress('127.0.0.1'),
      );
      expect(result.outcome, LocalGatewayAuthOutcome.hostRejected);
    });

    test('rejects a non-loopback peer even with the correct token', () {
      final result = security.verify(
        headers: authorizedHeaders(),
        remoteAddress: InternetAddress('10.0.0.5'),
      );
      expect(result.outcome, LocalGatewayAuthOutcome.peerRejected);
    });

    test('rejects an unlisted loopback Origin', () {
      final result = security.verify(
        headers: authorizedHeaders(),
        remoteAddress: InternetAddress('127.0.0.1'),
        origin: 'http://localhost:3000',
      );
      expect(result.outcome, LocalGatewayAuthOutcome.originRejected);
    });

    test('rejects an empty configured credential', () {
      expect(
        () => LocalGatewaySecurity(
          config: const LocalGatewaySecurityConfig(allowedPort: 58085),
          expectedToken: const LocalGatewayCredential(''),
        ),
        throwsArgumentError,
      );
    });

    test('tryReserveUpgrade honors the per-peer budget', () {
      var now = DateTime(2026, 1, 1, 0, 0, 0);
      final dedicated = LocalGatewaySecurity(
        config: const LocalGatewaySecurityConfig(
          allowedPort: 58085,
          preauthBudgetPerPeer: 2,
          preauthCoolDown: Duration(seconds: 30),
        ),
        expectedToken: const LocalGatewayCredential('expected-token-xyz'),
        now: () => now,
      );
      expect(dedicated.tryReserveUpgrade('198.51.100.10'), isTrue);
      expect(dedicated.tryReserveUpgrade('198.51.100.10'), isTrue);
      expect(dedicated.tryReserveUpgrade('198.51.100.10'), isFalse);
      // Advance past the cool-down so the next reserve is allowed.
      now = now.add(const Duration(seconds: 31));
      dedicated.releaseUpgrade('198.51.100.10');
      dedicated.releaseUpgrade('198.51.100.10');
      expect(dedicated.tryReserveUpgrade('198.51.100.10'), isTrue);
    });
  });
}
