import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_oauth_service.dart';
import 'package:sanad_agent/capabilities/mcp/mcp_server_config.dart';
import 'package:test/test.dart';

void main() {
  McpServerConfig config(Uri origin) => McpServerConfig(
    name: 'oauth-server',
    serverUrl: origin.resolve('/mcp').toString(),
    authType: McpAuthType.oauth,
    oauthClientId: 'client-1',
    oauthAuthUrl: origin.resolve('/authorize').toString(),
    oauthTokenUrl: origin.resolve('/token').toString(),
  );

  test(
    'approval validates state, exchanges PKCE code, and never returns tokens',
    () async {
      late Map<String, String> tokenBody;
      final client = MockClient((request) async {
        if (request.url.path == '/token') {
          tokenBody = Uri.splitQueryString(request.body);
          return http.Response(
            jsonEncode({
              'access_token': 'access-secret',
              'refresh_token': 'refresh-secret',
              'expires_in': 3600,
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });
      final service = McpOAuthService(client: client);
      addTearDown(service.dispose);
      final origin = Uri.parse('https://auth.example');

      final started = await service.start(config: config(origin));
      final authorization = Uri.parse(started['authorization_url'] as String);
      expect(started.toString(), isNot(contains('secret')));
      expect(authorization.queryParameters['code_challenge_method'], 'S256');
      expect(authorization.queryParameters['code_verifier'], isNull);

      final callback = Uri.parse(
        authorization.queryParameters['redirect_uri']!,
      );
      final response = await HttpClient()
          .getUrl(
            callback.replace(
              queryParameters: {
                'code': 'approval-code',
                'state': authorization.queryParameters['state']!,
              },
            ),
          )
          .then((request) => request.close());
      await response.drain<void>();

      final status = service.status(started['flow_id'] as String);
      expect(status['status'], 'approved');
      expect(status.toString(), isNot(contains('access-secret')));
      final grant = service.consumeApproved(started['flow_id'] as String);
      expect(grant.accessToken, 'access-secret');
      expect(tokenBody['code_verifier'], isNotEmpty);
      expect(tokenBody['code'], 'approval-code');
    },
  );

  test('state mismatch is terminal error without token exchange', () async {
    var tokenCalls = 0;
    final service = McpOAuthService(
      client: MockClient((request) async {
        tokenCalls++;
        return http.Response('{}', 500);
      }),
    );
    addTearDown(service.dispose);
    final started = await service.start(
      config: config(Uri.parse('https://auth.example')),
    );
    final authorization = Uri.parse(started['authorization_url'] as String);
    final callback = Uri.parse(authorization.queryParameters['redirect_uri']!);

    final response = await HttpClient()
        .getUrl(
          callback.replace(queryParameters: {'code': 'code', 'state': 'wrong'}),
        )
        .then((request) => request.close());
    await response.drain<void>();

    final status = service.status(started['flow_id'] as String);
    expect(status['status'], 'error');
    expect(status['error'], 'OAuth callback validation failed.');
    expect(tokenCalls, 0);
  });

  test(
    'cancellation and expiry close flows with typed terminal status',
    () async {
      var now = DateTime.utc(2026, 1, 1);
      final service = McpOAuthService(
        client: MockClient((request) async => http.Response('{}', 404)),
        flowLifetime: const Duration(minutes: 1),
        clock: () => now,
      );
      addTearDown(service.dispose);
      final first = await service.start(
        config: config(Uri.parse('https://auth.example')),
      );
      expect(
        (await service.cancel(first['flow_id'] as String))['status'],
        'cancelled',
      );

      final second = await service.start(
        config: config(Uri.parse('https://auth.example')),
      );
      now = now.add(const Duration(minutes: 2));
      expect(service.status(second['flow_id'] as String)['status'], 'expired');
    },
  );

  test(
    'refresh rotates access token while preserving an omitted refresh token',
    () async {
      late Map<String, String> body;
      final service = McpOAuthService(
        client: MockClient((request) async {
          body = Uri.splitQueryString(request.body);
          return http.Response(
            jsonEncode({'access_token': 'next-access', 'expires_in': 900}),
            200,
          );
        }),
      );
      addTearDown(service.dispose);

      final grant = await service.refresh(
        config: config(Uri.parse('https://auth.example')),
        refreshToken: 'existing-refresh',
      );
      expect(grant.accessToken, 'next-access');
      expect(grant.refreshToken, 'existing-refresh');
      expect(body['grant_type'], 'refresh_token');
      expect(body['refresh_token'], 'existing-refresh');
    },
  );

  test('discovery and registration failures are redacted', () async {
    final discoveryService = McpOAuthService(
      client: MockClient(
        (request) async => http.Response('server-secret', 500),
      ),
    );
    addTearDown(discoveryService.dispose);
    final discoveryConfig = McpServerConfig(
      name: 'oauth-server',
      serverUrl: 'https://auth.example/mcp',
      authType: McpAuthType.oauth,
      oauthClientId: 'client-1',
    );

    await expectLater(
      discoveryService.start(config: discoveryConfig),
      throwsA(
        predicate((error) => !error.toString().contains('server-secret')),
      ),
    );

    final registrationService = McpOAuthService(
      client: MockClient((request) async {
        if (request.url.path.endsWith('oauth-protected-resource')) {
          return http.Response('{}', 404);
        }
        if (request.url.path.endsWith('oauth-authorization-server')) {
          return http.Response(
            jsonEncode({
              'authorization_endpoint': 'https://auth.example/authorize',
              'token_endpoint': 'https://auth.example/token',
              'registration_endpoint': 'https://auth.example/register',
            }),
            200,
          );
        }
        return http.Response('registration-secret', 500);
      }),
    );
    addTearDown(registrationService.dispose);
    await expectLater(
      registrationService.start(
        config: McpServerConfig(
          name: 'dynamic',
          serverUrl: 'https://auth.example/mcp',
          authType: McpAuthType.oauth,
        ),
      ),
      throwsA(
        predicate(
          (error) =>
              error.toString().contains('dynamic registration failed') &&
              !error.toString().contains('registration-secret'),
        ),
      ),
    );
  });
}
