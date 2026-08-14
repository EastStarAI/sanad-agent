import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/infrastructure/portal_auth_client.dart';
import 'package:sanad_client/features/auth/domain/client_instance_identity.dart';

void main() {
  test('creates only an S256 registered client transaction', () async {
    late String path;
    late Map<String, dynamic> payload;
    final client = PortalAuthClient(
      postOverride: (requestedPath, data) async {
        path = requestedPath;
        payload = data;
        return {
          'transaction_id': 'transaction-1',
          'authorization_url': 'https://portal.test/authorize',
          'expires_in': 300,
        };
      },
    );

    final result = await client.createClientTransaction(
      clientId: 'sanad_flutter_desktop',
      redirectUri: 'http://127.0.0.1:49152/oauth/callback',
      codeChallenge: 'challenge-value',
    );

    expect(path, '/auth/client/transactions');
    expect(payload, {
      'client_id': 'sanad_flutter_desktop',
      'redirect_uri': 'http://127.0.0.1:49152/oauth/callback',
      'code_challenge': 'challenge-value',
      'code_challenge_method': 'S256',
    });
    expect(payload, isNot(contains('polling_token')));
    expect(result.transactionId, 'transaction-1');
  });

  test('adds only co-located enrollment request identity to PKCE start', () async {
    late Map<String, dynamic> payload;
    final client = PortalAuthClient(
      postOverride: (_, data) async {
        payload = data;
        return {
          'transaction_id': 'transaction-1',
          'authorization_url': 'https://portal.test/authorize',
          'expires_in': 300,
        };
      },
    );

    await client.createClientTransaction(
      clientId: 'sanad_flutter_desktop',
      redirectUri: 'http://127.0.0.1:49152/oauth/callback',
      codeChallenge: 'challenge-value',
      enrollmentRequestId: 'public-agent-request-1234567890',
    );

    expect(
      payload['enrollment_request_id'],
      'public-agent-request-1234567890',
    );
    expect(payload, isNot(contains('device_code')));
    expect(payload, isNot(contains('device_credential')));
    expect(payload, isNot(contains('access_token')));
  });

  test('binds minimal instance metadata only at PKCE transaction start', () async {
    late Map<String, dynamic> payload;
    final client = PortalAuthClient(
      postOverride: (_, data) async {
        payload = data;
        return {
          'transaction_id': 'transaction-1',
          'authorization_url': 'https://portal.test/authorize',
          'expires_in': 300,
        };
      },
    );

    await client.createClientTransaction(
      clientId: 'sanad_flutter_desktop',
      redirectUri: 'http://127.0.0.1:49152/oauth/callback',
      codeChallenge: 'challenge-value',
      clientInstanceId: '11111111-1111-4111-8111-111111111111',
      metadata: const ClientDisplayMetadata(
        clientKind: 'desktop',
        platformFamily: 'macos',
        osFamily: 'macos',
        appVersion: '1.2.3',
      ),
    );

    expect(payload['client_instance_id'], '11111111-1111-4111-8111-111111111111');
    expect(payload['metadata'], {
      'client_kind': 'desktop',
      'platform_family': 'macos',
      'os_family': 'macos',
      'app_version': '1.2.3',
    });
    expect(payload['capabilities'], [
      'account_sessions_v1',
      'delivery_presence_v1',
    ]);
    expect(payload, isNot(contains('hostname')));
  });

  test('redeems the one-time code with the same verifier contract', () async {
    late Map<String, dynamic> payload;
    final client = PortalAuthClient(
      postOverride: (path, data) async {
        expect(path, '/auth/client/token');
        payload = data;
        return {
          'access_token': 'synthetic-access',
          'refresh_token': 'synthetic-refresh',
          'token_type': 'bearer',
        };
      },
    );

    final result = await client.redeemAuthorizationCode(
      clientId: 'sanad_flutter_desktop',
      redirectUri: 'http://127.0.0.1:49152/oauth/callback',
      code: 'one-time-code',
      codeVerifier: 'locally-owned-verifier',
    );

    expect(payload, {
      'grant_type': 'authorization_code',
      'client_id': 'sanad_flutter_desktop',
      'redirect_uri': 'http://127.0.0.1:49152/oauth/callback',
      'code': 'one-time-code',
      'code_verifier': 'locally-owned-verifier',
    });
    expect(result.accessToken, 'synthetic-access');
  });
}
