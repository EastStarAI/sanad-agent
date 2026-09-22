import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/infrastructure/auth_callback_binding_native.dart';

void main() {
  group('Development iOS callback selection', () {
    test('requires iOS Debug and exact Development environment', () {
      const redirect = 'sanad://oauth/ios-development';
      expect(
        shouldUseDevelopmentIosAuth(
          isIos: true,
          isDebug: true,
          environment: 'dev',
          redirect: redirect,
        ),
        isTrue,
      );
      for (final rejected in [
        (isIos: false, isDebug: true, environment: 'dev', redirect: redirect),
        (isIos: true, isDebug: false, environment: 'dev', redirect: redirect),
        (isIos: true, isDebug: true, environment: 'prod', redirect: redirect),
        (isIos: true, isDebug: true, environment: 'stg', redirect: redirect),
        (isIos: true, isDebug: true, environment: 'development', redirect: redirect),
        (isIos: true, isDebug: true, environment: 'dev', redirect: ''),
      ]) {
        expect(
          shouldUseDevelopmentIosAuth(
            isIos: rejected.isIos,
            isDebug: rejected.isDebug,
            environment: rejected.environment,
            redirect: rejected.redirect,
          ),
          isFalse,
        );
      }
    });
  });

  group('mobile claimed HTTPS callback matching', () {
    final expected = Uri.parse(
      'https://app.sanad.eaststarai.com/oauth/ios',
    );

    test('accepts only the exact HTTPS origin path', () {
      expect(
        isValidMobileAuthRedirect(
          expected,
          allowDevelopmentCustomScheme: false,
        ),
        isTrue,
      );
      expect(
        isExpectedMobileAuthCallback(
          expected.replace(
            queryParameters: {'code': 'code', 'state': 'state'},
          ),
          expected,
        ),
        isTrue,
      );
      expect(
        isExpectedMobileAuthCallback(
          Uri.parse('sanad://oauth/ios?code=code&state=state'),
          expected,
        ),
        isFalse,
      );
      expect(
        isExpectedMobileAuthCallback(
          Uri.parse(
            'https://attacker.example/oauth/ios?code=code&state=state',
          ),
          expected,
        ),
        isFalse,
      );
      expect(
        isExpectedMobileAuthCallback(
          Uri.parse(
            'https://portal.sanad.eaststarai.com/oauth/android'
            '?code=code&state=state',
          ),
          expected,
        ),
        isFalse,
      );
      expect(
        isExpectedMobileAuthCallback(
          Uri.parse(
            'https://app.sanad.eaststarai.com/oauth/ios'
            '?code=code&state=state#fragment',
          ),
          expected,
        ),
        isFalse,
      );
    });
    test('development custom scheme is explicit and exact', () {
      final expected = Uri.parse('sanad://oauth/ios-development');
      expect(
        isValidMobileAuthRedirect(
          expected,
          allowDevelopmentCustomScheme: true,
        ),
        isTrue,
      );
      expect(
        isValidMobileAuthRedirect(
          expected,
          allowDevelopmentCustomScheme: false,
        ),
        isFalse,
      );
      expect(
        isValidMobileAuthRedirect(
          Uri.parse('sanad://oauth/ios-production'),
          allowDevelopmentCustomScheme: true,
        ),
        isFalse,
      );
      expect(
        isExpectedMobileAuthCallback(
          Uri.parse(
            'sanad://oauth/ios-development?code=code&state=state',
          ),
          expected,
        ),
        isTrue,
      );
      expect(
        isExpectedMobileAuthCallback(
          Uri.parse('sanad://oauth/ios?code=code&state=state'),
          expected,
        ),
        isFalse,
      );
    });
  });

  test('desktop callback rejects wrong path and replay', () async {
    final binding = await createDesktopLoopbackAuthCallbackBinding();
    final redirect = Uri.parse(binding.redirectUri);
    final http = HttpClient();
    try {
      final wrongRequest = await http.getUrl(
        redirect.replace(
          path: '/wrong',
          queryParameters: {
            'code': 'wrong-code',
            'state': 'transaction-1',
          },
        ),
      );
      final wrongResponse = await wrongRequest.close();
      expect(wrongResponse.statusCode, HttpStatus.notFound);

      final resultFuture = binding.waitForResult(const Duration(seconds: 2));
      final validRequest = await http.getUrl(
        redirect.replace(
          queryParameters: {
            'code': 'one-time-code',
            'state': 'transaction-1',
          },
        ),
      );
      final validResponse = await validRequest.close();
      expect(validResponse.statusCode, HttpStatus.ok);
      expect(
        validResponse.headers.value(HttpHeaders.cacheControlHeader),
        'no-store',
      );
      expect(validResponse.headers.value('Referrer-Policy'), 'no-referrer');
      expect(
        validResponse.headers.value('Content-Security-Policy'),
        allOf(
          contains("default-src 'none'"),
          contains('img-src data:'),
          contains('https://fonts.googleapis.com'),
          contains('https://fonts.gstatic.com'),
        ),
      );
      final successPage = await validResponse.transform(utf8.decoder).join();
      expect(successPage, contains('Authentication Complete'));
      expect(successPage, contains('rel="icon"'));
      expect(successPage, contains('data:image/svg+xml;base64,'));
      expect(successPage, contains('success-container'));
      expect(successPage, contains('Return to Sanad App'));
      expect(successPage, contains('Sanad Portal • Secure Sync Completed'));
      expect(successPage, contains('window.close()'));
      final result = await resultFuture;
      expect(result.code, 'one-time-code');
      expect(result.state, 'transaction-1');

      final replayRequest = await http.getUrl(
        redirect.replace(
          queryParameters: {
            'code': 'one-time-code',
            'state': 'transaction-1',
          },
        ),
      );
      final replayResponse = await replayRequest.close();
      expect(replayResponse.statusCode, HttpStatus.badRequest);
    } finally {
      http.close(force: true);
      await binding.dispose();
    }
  });
}
