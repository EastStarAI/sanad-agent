import 'dart:convert';
import 'package:test/test.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';

void main() {
  String createMockJwt(Map<String, dynamic> claims) {
    final header = base64Url.encode(
      utf8.encode(jsonEncode({'alg': 'HS256', 'typ': 'JWT'})),
    );
    final payload = base64Url
        .encode(utf8.encode(jsonEncode(claims)))
        .replaceAll('=', '');
    final signature = 'mockSignature';
    return '$header.$payload.$signature';
  }

  group('decodeJwtClaims', () {
    test('decodes valid JWT claims successfully', () {
      final claims = {'email': 'test@example.com', 'name': 'John Doe'};
      final jwt = createMockJwt(claims);

      final decoded = decodeJwtClaims(jwt);
      expect(decoded['email'], equals('test@example.com'));
      expect(decoded['name'], equals('John Doe'));
    });

    test('returns empty map for invalid JWT format', () {
      expect(decodeJwtClaims('invalidToken'), isEmpty);
      expect(decodeJwtClaims('a.b'), isEmpty);
      expect(decodeJwtClaims('a.b.c.d'), isEmpty);
    });

    test('returns empty map for non-JSON payload', () {
      final jwt = 'header.notBase64UrlPayload.signature';
      expect(decodeJwtClaims(jwt), isEmpty);
    });

    test('extracts trimmed display identity using the documented priority', () {
      final jwt = createMockJwt({
        'email': '  user@example.com  ',
        'preferred_username': 'ignored-user',
        'name': '  User Name  ',
      });

      final identity = extractOAuthAccountIdentity(jwt);

      expect(identity.accountLabel, 'user@example.com');
      expect(identity.accountName, 'User Name');
    });

    test('ignores blank and non-string identity claims', () {
      final jwt = createMockJwt({
        'email': '   ',
        'preferred_username': 42,
        'upn': 'user@tenant.example',
        'name': false,
      });

      final identity = extractOAuthAccountIdentity(jwt);

      expect(identity.accountLabel, 'user@tenant.example');
      expect(identity.accountName, isNull);
    });
  });

  group('SecretRecord lazy-decoding', () {
    test(
      'lazily decodes accountLabel and accountName from id_token when missing',
      () {
        final claims = {'email': 'lazy@example.com', 'name': 'Lazy User'};
        final jwt = createMockJwt(claims);

        final json = {
          'instance_id': 'inst-1',
          'auth_method': ProviderAuthMethod.deviceCode,
          'id_token': jwt,
          'access_token': 'some-access-token',
          'status': 'authenticated',
        };

        final record = SecretRecord.fromJson(json);
        expect(record.accountLabel, equals('lazy@example.com'));
        expect(record.accountName, equals('Lazy User'));
      },
    );

    test(
      'lazily decodes accountLabel and accountName from access_token as fallback',
      () {
        final claims = {
          'preferred_username': 'fallbackUser',
          'name': 'Fallback Name',
        };
        final jwt = createMockJwt(claims);

        final json = {
          'instance_id': 'inst-2',
          'auth_method': ProviderAuthMethod.deviceCode,
          'access_token': jwt,
          'status': 'authenticated',
        };

        final record = SecretRecord.fromJson(json);
        expect(record.accountLabel, equals('fallbackUser'));
        expect(record.accountName, equals('Fallback Name'));
      },
    );

    test('preserves existing account_label and account_name from json', () {
      final json = {
        'instance_id': 'inst-3',
        'auth_method': ProviderAuthMethod.deviceCode,
        'account_label': 'already_saved@example.com',
        'account_name': 'Saved Name',
        'access_token': 'token',
        'status': 'authenticated',
      };

      final record = SecretRecord.fromJson(json);
      expect(record.accountLabel, equals('already_saved@example.com'));
      expect(record.accountName, equals('Saved Name'));
    });

    test('does not decode for api_key auth method', () {
      final claims = {'email': 'api@example.com', 'name': 'API User'};
      final jwt = createMockJwt(claims);

      final json = {
        'instance_id': 'inst-4',
        'auth_method': ProviderAuthMethod.apiKey,
        'api_key': jwt,
      };

      final record = SecretRecord.fromJson(json);
      expect(record.accountLabel, isNull);
      expect(record.accountName, isNull);
    });
  });

  group('SecretSummary mapping', () {
    test('carries accountName from SecretRecord', () {
      final record = SecretRecord(
        instanceId: 'inst-5',
        authMethod: ProviderAuthMethod.deviceCode,
        accountLabel: 'user@example.com',
        accountName: 'User Name',
      );

      final summary = SecretSummary.fromRecord(record, 'inst-5');
      expect(summary.accountLabel, equals('user@example.com'));
      expect(summary.accountName, equals('User Name'));

      final map = summary.toMap();
      expect(map['account_label'], equals('user@example.com'));
      expect(map['account_name'], equals('User Name'));
    });
  });
}
