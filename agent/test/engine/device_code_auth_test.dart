import 'dart:convert';
import 'package:test/test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/setup/setup_helpers.dart';

void main() {
  group('runCodexDeviceCodeFlow', () {
    test(
      'should succeed and return access token when auth flow is complete',
      () async {
        int requestCount = 0;
        final mockClient = MockClient((request) async {
          requestCount++;
          final path = request.url.path;

          if (path == '/api/accounts/deviceauth/usercode') {
            return http.Response(
              jsonEncode({
                'user_code': 'ABCD-1234',
                'device_auth_id': 'auth-id-123',
                'interval': 1,
              }),
              200,
            );
          } else if (path == '/api/accounts/deviceauth/token') {
            return http.Response(
              jsonEncode({
                'authorization_code': 'auth-code-789',
                'code_verifier': 'verifier-456',
              }),
              200,
            );
          } else if (path == '/oauth/token') {
            return http.Response(
              jsonEncode({'access_token': 'secret-access-token-999'}),
              200,
            );
          }

          return http.Response('Not Found', 404);
        });

        final token = await runCodexDeviceCodeFlow(
          clientOverride: mockClient,
          waitForPoll: (_) async {},
        );

        expect(token, equals('secret-access-token-999'));
        expect(requestCount, equals(3));
      },
    );

    test(
      'should succeed and handle interval when returned as String',
      () async {
        int requestCount = 0;
        final mockClient = MockClient((request) async {
          requestCount++;
          final path = request.url.path;

          if (path == '/api/accounts/deviceauth/usercode') {
            return http.Response(
              jsonEncode({
                'user_code': 'ABCD-1234',
                'device_auth_id': 'auth-id-123',
                'interval': '1',
              }),
              200,
            );
          } else if (path == '/api/accounts/deviceauth/token') {
            return http.Response(
              jsonEncode({
                'authorization_code': 'auth-code-789',
                'code_verifier': 'verifier-456',
              }),
              200,
            );
          } else if (path == '/oauth/token') {
            return http.Response(
              jsonEncode({'access_token': 'secret-access-token-999'}),
              200,
            );
          }

          return http.Response('Not Found', 404);
        });

        final token = await runCodexDeviceCodeFlow(
          clientOverride: mockClient,
          waitForPoll: (_) async {},
        );

        expect(token, equals('secret-access-token-999'));
        expect(requestCount, equals(3));
      },
    );

    test(
      'should succeed and handle interval when returned as double/num',
      () async {
        int requestCount = 0;
        final mockClient = MockClient((request) async {
          requestCount++;
          final path = request.url.path;

          if (path == '/api/accounts/deviceauth/usercode') {
            return http.Response(
              jsonEncode({
                'user_code': 'ABCD-1234',
                'device_auth_id': 'auth-id-123',
                'interval': 1.0,
              }),
              200,
            );
          } else if (path == '/api/accounts/deviceauth/token') {
            return http.Response(
              jsonEncode({
                'authorization_code': 'auth-code-789',
                'code_verifier': 'verifier-456',
              }),
              200,
            );
          } else if (path == '/oauth/token') {
            return http.Response(
              jsonEncode({'access_token': 'secret-access-token-999'}),
              200,
            );
          }

          return http.Response('Not Found', 404);
        });

        final token = await runCodexDeviceCodeFlow(
          clientOverride: mockClient,
          waitForPoll: (_) async {},
        );

        expect(token, equals('secret-access-token-999'));
        expect(requestCount, equals(3));
      },
    );

    test('should return null when initial usercode request fails', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Internal Server Error', 500);
      });

      final token = await runCodexDeviceCodeFlow(
        clientOverride: mockClient,
        waitForPoll: (_) async {},
      );

      expect(token, isNull);
    });

    test('should return null when token exchange fails', () async {
      final mockClient = MockClient((request) async {
        final path = request.url.path;

        if (path == '/api/accounts/deviceauth/usercode') {
          return http.Response(
            jsonEncode({
              'user_code': 'ABCD-1234',
              'device_auth_id': 'auth-id-123',
              'interval': 1,
            }),
            200,
          );
        } else if (path == '/api/accounts/deviceauth/token') {
          return http.Response(
            jsonEncode({
              'authorization_code': 'auth-code-789',
              'code_verifier': 'verifier-456',
            }),
            200,
          );
        } else if (path == '/oauth/token') {
          return http.Response('Bad Request', 400);
        }

        return http.Response('Not Found', 404);
      });

      final token = await runCodexDeviceCodeFlow(
        clientOverride: mockClient,
        waitForPoll: (_) async {},
      );

      expect(token, isNull);
    });
  });
}
