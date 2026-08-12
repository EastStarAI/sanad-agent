import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_authentication_exchange_notifier.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/local_gateway_credentials.dart';
import 'package:test/test.dart';

void main() {
  const credential = LocalGatewayCredential('synthetic-local-credential');

  test(
    'retries and requires an explicit credential-free acknowledgement',
    () async {
      final requests = <http.Request>[];
      var attempt = 0;
      final notifier = LocalAuthenticationExchangeNotifier(
        clientFactory: () => MockClient((request) async {
          requests.add(request);
          attempt++;
          if (attempt == 1) return http.Response('{}', 503);
          return http.Response('{"success":true}', 200);
        }),
        credentialLoader: () async => credential,
        delay: (_) async {},
        retryDelay: Duration.zero,
      );

      final outcome = await notifier.notify('http://127.0.0.1:59182');

      expect(outcome, LocalAuthenticationExchangeOutcome.notified);
      expect(requests, hasLength(2));
      for (final request in requests) {
        expect(request.method, 'POST');
        expect(
          request.url.toString(),
          'http://127.0.0.1:59182/authentication-exchange',
        );
        expect(
          request.headers[LocalGatewayCredentials.headerName],
          credential.value,
        );
        expect(request.body, isEmpty);
      }
    },
  );

  test(
    'reports a reachable daemon that never acknowledges the exchange',
    () async {
      var calls = 0;
      final notifier = LocalAuthenticationExchangeNotifier(
        clientFactory: () => MockClient((request) async {
          calls++;
          return http.Response('{"success":false}', 200);
        }),
        credentialLoader: () async => credential,
        delay: (_) async {},
        maximumAttempts: 2,
        retryDelay: Duration.zero,
      );

      final outcome = await notifier.notify('http://127.0.0.1:59182');

      expect(outcome, LocalAuthenticationExchangeOutcome.daemonRejected);
      expect(calls, 2);
    },
  );

  test('keeps a stopped daemon as an expected unavailable outcome', () async {
    final methods = <String>[];
    final notifier = LocalAuthenticationExchangeNotifier(
      clientFactory: () => MockClient((request) async {
        methods.add(request.method);
        throw http.ClientException('connection refused', request.url);
      }),
      credentialLoader: () async => credential,
      delay: (_) async {},
      maximumAttempts: 2,
      retryDelay: Duration.zero,
    );

    final outcome = await notifier.notify('http://127.0.0.1:59182');

    expect(outcome, LocalAuthenticationExchangeOutcome.daemonUnavailable);
    expect(methods, ['POST', 'POST', 'GET']);
  });
}
