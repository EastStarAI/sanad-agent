import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/infrastructure/portal_auth_client.dart';

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
