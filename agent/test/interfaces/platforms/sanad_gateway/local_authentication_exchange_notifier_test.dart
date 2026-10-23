import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_identity.dart';
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

  test(
    'the default loader never rotates the credential it would present',
    () async {
      // Regression for login/logout: this notifier runs beside a daemon that may
      // be an older release still serving the same Home. The default credential
      // loader must be read-only, or the exchange rotates `.local_token` under
      // that daemon and every desktop Client is rejected until it restarts.
      final home = Directory.systemTemp.createTempSync('sanad-login-home-');
      addTearDown(() {
        setSanadHomeOverride(null);
        setSanadStateHomeOverride(null);
        if (home.existsSync()) home.deleteSync(recursive: true);
      });
      setSanadHomeOverride(home.path);
      setSanadStateHomeOverride(home.path);
      await SanadHomeBootstrap.prepareAll();

      final tokenFile = File(
        SanadHomeBootstrap.resolveChild(LocalGatewayCredentials.relativePath),
      )..writeAsStringSync('credential-of-another-home');
      final bindingFile = File(
        SanadHomeBootstrap.resolveChild(
          LocalGatewayCredentials.bindingRelativePath,
        ),
      )..writeAsStringSync(sanadHomeIdentity(p.join(home.path, 'other')));
      final foreignBinding = bindingFile.readAsStringSync();

      var contactedDaemon = false;
      final notifier = LocalAuthenticationExchangeNotifier(
        clientFactory: () => MockClient((request) async {
          contactedDaemon = true;
          return http.Response('{"success":true}', 200);
        }),
        delay: (_) async {},
        retryDelay: Duration.zero,
      );

      final outcome = await notifier.notify('http://127.0.0.1:59182');

      expect(outcome, LocalAuthenticationExchangeOutcome.daemonUnavailable);
      expect(contactedDaemon, isFalse);
      expect(tokenFile.readAsStringSync(), 'credential-of-another-home');
      expect(bindingFile.readAsStringSync(), foreignBinding);
    },
  );
}
