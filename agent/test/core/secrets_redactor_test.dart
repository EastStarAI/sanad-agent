import 'package:test/test.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';

void main() {
  const redactor = SecretsRedactor();

  group('SecretsRedactor.redact — key prefixes', () {
    test('redacts OpenAI sk- keys', () {
      const input = 'Request failed: invalid key sk-proj-AbCdEf1234567890';
      final out = redactor.redact(input);
      expect(out.contains('sk-proj-AbCdEf1234567890'), isFalse);
      expect(out, contains('sk-***'));
    });

    test('redacts NVIDIA nvapi- keys', () {
      const input = 'nvapi-1234567890abcdefghijklmnopqrstuvwxyz';
      final out = redactor.redact(input);
      expect(
        out.contains('nvapi-1234567890abcdefghijklmnopqrstuvwxyz'),
        isFalse,
      );
      expect(out, contains('nvapi-***'));
    });

    test('preserves short non-secret text', () {
      expect(redactor.redact('hello world'), equals('hello world'));
    });

    test('empty string is unchanged', () {
      expect(redactor.redact(''), isEmpty);
    });
  });

  group('SecretsRedactor.redact — Authorization headers', () {
    test('redacts Bearer tokens', () {
      const input =
          'Authorization: Bearer eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.payload.sig';
      final out = redactor.redact(input);
      expect(out.contains('eyJhbGci'), isFalse);
      expect(out, contains('***'));
    });

    test('redacts x-api-key header', () {
      const input = 'x-api-key: my-super-secret-key-value-here1234';
      final out = redactor.redact(input);
      expect(out.contains('my-super-secret-key-value-here1234'), isFalse);
      expect(out, contains('x-api-key: ***'));
    });

    test('redacts Authorization header value', () {
      const input = 'Authorization: some-opaque-token-1234567890';
      final out = redactor.redact(input);
      expect(out.contains('some-opaque-token-1234567890'), isFalse);
    });
  });

  group('SecretsRedactor.redact — assignments', () {
    test('redacts api_key=value', () {
      const input = 'api_key=ABCDEFGHIJKLMNOP123456';
      final out = redactor.redact(input);
      expect(out.contains('ABCDEFGHIJKLMNOP123456'), isFalse);
      expect(out, contains('api_key: ***'));
    });

    test('redacts "token":"value" JSON field', () {
      const input = '{"token": "abc123def456ghi789", "ok": true}';
      final out = redactor.redact(input);
      expect(out.contains('abc123def456ghi789'), isFalse);
      expect(out, contains('"token": "***"'));
    });

    test('redacts "api_key":"value" JSON field', () {
      const input = '{"api_key":"sk-secretvalue1234", "model":"gpt-4o"}';
      final out = redactor.redact(input);
      expect(out.contains('sk-secretvalue1234'), isFalse);
    });
  });

  group('SecretsRedactor.redact — self-identifying cloud credentials', () {
    test('redacts an AWS access key id', () {
      const input = 'aws s3 sync failed with AKIAIOSFODNN7EXAMPLE';
      final out = redactor.redact(input);
      expect(out.contains('AKIAIOSFODNN7EXAMPLE'), isFalse);
      expect(out, contains('AKIA***'));
      expect(out, contains('s3 sync failed'));
    });

    test('redacts an STS temporary access key id', () {
      const input = 'ASIAY34FZKBOKMUTVV7A';
      final out = redactor.redact(input);
      expect(out.contains('ASIAY34FZKBOKMUTVV7A'), isFalse);
      expect(out, contains('ASIA***'));
    });

    test('redacts GitHub and GitLab tokens', () {
      const github = 'push rejected: ghp_16C7e42F292c6912E7710c838347Ae178B4a';
      const fineGrained =
          'github_pat_11ABCDEFG0123456789_abcdefghijklmnopqrstuvwxyz';
      const gitlab = 'glpat-ABCDEFGHIJKLMNOPQRST';

      for (final input in [github, fineGrained, gitlab]) {
        final out = redactor.redact(input);
        expect(
          out.contains(input.split(': ').last),
          isFalse,
          reason: 'the token body must not survive: $input',
        );
        expect(out, contains('***'));
      }

      expect(redactor.redact(github), contains('ghp_***'));
      expect(redactor.redact(gitlab), contains('glpat-***'));
    });

    test('keeps ordinary prose that merely looks key-like', () {
      const input = 'The AKIA preview in the docs is a placeholder, not a key.';
      expect(redactor.redact(input), input);
    });
  });

  group('SecretsRedactor.redact — flag-separated credentials', () {
    test('redacts a short --password=value', () {
      const input = 'Running: mysql --user=root --password=hunt4 -e "select 1"';
      final out = redactor.redact(input);
      expect(out.contains('hunt4'), isFalse);
      expect(out, contains('mysql'));
      expect(out, contains('--user=root'));
    });

    test('redacts a space-separated --token value', () {
      const input = 'curl --token abc123 https://api.example.test/v1';
      final out = redactor.redact(input);
      expect(out.contains('abc123'), isFalse);
      expect(out, contains('curl'));
      expect(out, contains('https://api.example.test/v1'));
    });

    test('redacts a space-separated --api-key value', () {
      const input = 'tool --api-key sk-live-9f8e7d6c5b';
      final out = redactor.redact(input);
      expect(out.contains('sk-live-9f8e7d6c5b'), isFalse);
    });

    test('keeps a named flag without a value', () {
      const input = 'Pass --force to overwrite, and read the token docs first.';
      expect(redactor.redact(input), input);
    });
  });

  group('SecretsRedactor.redact — preserves provider context', () {
    test('keeps model names and status text', () {
      const input =
          'Unknown Model, please check the model code. model=gpt-4o status=404';
      final out = redactor.redact(input);
      expect(out, contains('Unknown Model'));
      expect(out, contains('gpt-4o'));
      expect(out, contains('404'));
    });

    test('scrubs a key embedded inside a provider error body', () {
      const input =
          '401 Unauthorized. Provided key sk-live-AbCdEfGhIjKlMnOpQrStUv was rejected.';
      final out = redactor.redact(input);
      expect(out.contains('sk-live-AbCdEfGhIjKlMnOpQrStUv'), isFalse);
      expect(out, contains('401'));
      expect(out, contains('Unauthorized'));
    });
  });

  group('SecretsRedactor.redactValue — structured payloads', () {
    test('redacts nested maps and lists without changing structure', () {
      final out =
          redactor.redactValue({
                'message': 'Bearer abc.def.ghi',
                'headers': {'x-api-key': 'super-secret-value-123456'},
                'items': [
                  {'token': 'abc123def456ghi789'},
                  'api_key=ABCDEFGHIJKLMNOP123456',
                ],
                'ok': true,
              })
              as Map<String, dynamic>;

      expect(out['message'], equals('Bearer ***'));
      expect(out['headers']['x-api-key'], equals('***'));
      expect(out['items'][0]['token'], equals('***'));
      expect(out['items'][1], equals('api_key: ***'));
      expect(out['ok'], isTrue);
    });

    test('redacts a nested secrets map without echoing values', () {
      final out =
          redactor.redactValue({
                'command': 'save_mcp_server',
                'payload': {
                  'config': {'name': 'docs', 'url': 'https://example.test/mcp'},
                  'secrets': {'bearer_token': 'super-secret-value'},
                },
              })
              as Map<String, dynamic>;

      expect(out['payload']['secrets'], equals('***'));
      expect(out.toString(), isNot(contains('super-secret-value')));
      expect(out['payload']['config']['name'], 'docs');
    });

    test('redactForLog never interpolates nested secret values', () {
      const canary = 'g6-canary-bearer-9f3a7c2e1b88';
      final logged = redactor.redactForLog({
        'command': 'save_mcp_server',
        'payload': {
          'secrets': {'bearer_token': canary},
          'config': {'name': 'docs'},
        },
      });
      expect(logged, isNot(contains(canary)));
      expect(logged, contains('***'));
      expect(logged, contains('docs'));
    });
  });
}
