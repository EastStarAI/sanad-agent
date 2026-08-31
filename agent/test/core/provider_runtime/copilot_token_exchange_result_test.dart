import 'package:sanad_agent/core/provider_runtime/copilot_token_exchange_result.dart';
import 'package:test/test.dart';

void main() {
  final now = DateTime.utc(2026, 8, 30, 12);

  group('CopilotTokenExchangeResult.fromExchangeResponse', () {
    test('parses token, expires_at seconds, and endpoints.api', () {
      final result = CopilotTokenExchangeResult.fromExchangeResponse({
        'token': 'tid=abc;exp=1;sku=copilot_individual',
        'expires_at': 1788080400,
        'endpoints': {'api': 'https://api.githubcopilot.com'},
      }, now: now);

      expect(result.token, equals('tid=abc;exp=1;sku=copilot_individual'));
      expect(result.expiresAt, equals(1788080400 * 1000));
      expect(result.accountEndpoint, equals('https://api.githubcopilot.com'));
    });

    test('treats millisecond expires_at as already in epoch ms', () {
      final result = CopilotTokenExchangeResult.fromExchangeResponse({
        'token': 'tid=abc;exp=1',
        'expires_at': 1788080400000,
      }, now: now);

      expect(result.expiresAt, equals(1788080400000));
    });

    test('defaults missing expires_at to 1800 seconds from now', () {
      final result = CopilotTokenExchangeResult.fromExchangeResponse({
        'token': 'tid=abc;exp=1',
      }, now: now);

      expect(
        result.expiresAt,
        equals(now.add(const Duration(seconds: 1800)).millisecondsSinceEpoch),
      );
    });

    test(
      'derives account endpoint from proxy-ep when endpoints.api is absent',
      () {
        final result = CopilotTokenExchangeResult.fromExchangeResponse({
          'token': 'tid=abc;exp=1;proxy-ep=proxy.enterprise.githubcopilot.com;sku=copilot',
        }, now: now);

        expect(
          result.accountEndpoint,
          equals('https://api.enterprise.githubcopilot.com'),
        );
      },
    );

    test('rejects empty token without echoing any payload', () {
      expect(
        () => CopilotTokenExchangeResult.fromExchangeResponse({
          'token': '   ',
          'expires_at': 1,
        }, now: now),
        throwsA(
          isA<FormatException>().having(
            (e) => e.message,
            'message',
            isNot(contains('tid=')),
          ),
        ),
      );
    });

    test('toString never includes the token', () {
      final result = CopilotTokenExchangeResult.fromExchangeResponse({
        'token': 'tid=secret-value;exp=1',
        'expires_at': 1788080400,
      }, now: now);

      expect(result.toString(), isNot(contains('secret-value')));
      expect(result.toString(), contains('hasEndpoint=false'));
    });
  });

  group('Copilot account endpoint allowlist', () {
    test('accepts githubcopilot.com and githubusercontent proxy hosts', () {
      expect(isAllowedCopilotApiHost('api.githubcopilot.com'), isTrue);
      expect(
        isAllowedCopilotApiHost('copilot-proxy.githubusercontent.com'),
        isTrue,
      );
      expect(
        isAllowedCopilotApiHost('api.enterprise.githubcopilot.com'),
        isTrue,
      );
    });

    test('rejects SSRF targets and non-HTTPS URLs', () {
      expect(isAllowedCopilotApiHost('evil.example'), isFalse);
      expect(isAllowedCopilotApiHost('127.0.0.1'), isFalse);
      expect(isAllowedCopilotApiHost('localhost'), isFalse);
      expect(
        resolveCopilotAccountEndpoint(
          token: 'tid=x;proxy-ep=http://127.0.0.1:8080',
        ),
        isNull,
      );
      expect(
        resolveCopilotAccountEndpoint(
          token: 'tid=x',
          endpointsApi: 'https://evil.example/api',
        ),
        isNull,
      );
      expect(
        resolveCopilotAccountEndpoint(
          token: 'tid=x;proxy-ep=proxy.evil.example',
        ),
        isNull,
      );
      expect(
        resolveCopilotAccountEndpoint(
          token: 'tid=x',
          endpointsApi: 'http://api.githubcopilot.com',
        ),
        isNull,
      );
      expect(
        resolveCopilotAccountEndpoint(
          token: 'tid=x',
          endpointsApi: 'https://user:pass@api.githubcopilot.com',
        ),
        isNull,
      );
    });

    test('does not follow proxy-ep after a rejected endpoints.api', () {
      expect(
        resolveCopilotAccountEndpoint(
          token: 'tid=x;proxy-ep=proxy.enterprise.githubcopilot.com',
          endpointsApi: 'https://evil.example',
        ),
        isNull,
      );
    });

    test('allows a trusted GHE tenant host and rejects others', () {
      expect(
        isAllowedCopilotApiHost(
          'acme.ghe.com',
          trustedEnterpriseDomain: 'acme.ghe.com',
        ),
        isTrue,
      );
      expect(
        isAllowedCopilotApiHost(
          'api.acme.ghe.com',
          trustedEnterpriseDomain: 'acme.ghe.com',
        ),
        isTrue,
      );
      expect(isAllowedCopilotApiHost('acme.ghe.com'), isFalse);
      expect(
        isAllowedCopilotApiHost(
          'evil.ghe.com',
          trustedEnterpriseDomain: 'acme.ghe.com',
        ),
        isFalse,
      );
    });
  });
}
