import 'dart:convert';
import 'dart:io';

import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_auth_session_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:test/test.dart';

void main() {
  late Directory tempWorkDir;
  late Directory tempSanadHome;

  setUp(() async {
    tempWorkDir = await Directory.systemTemp.createTemp('sanad-codex-work');
    tempSanadHome = await Directory.systemTemp.createTemp('sanad-codex-home');
    setSanadHomeOverride(tempSanadHome.path);
  });

  tearDown(() async {
    setSanadHomeOverride(null);
    try {
      if (tempWorkDir.existsSync()) await tempWorkDir.delete(recursive: true);
    } catch (_) {}
    try {
      if (tempSanadHome.existsSync()) await tempSanadHome.delete(recursive: true);
    } catch (_) {}
  });

  group('openai-codex device-code migration', () {
    test(
      'flow returns access + refresh token and saves to credential store',
      () async {
        final credStore = ProviderCredentialStore(
          storePath: '${tempSanadHome.path}/provider_auth.json',
        );
        final service = ProviderAuthSessionService(
          credStore,
          clientFactory: () => MockClient((request) async {
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
                jsonEncode({
                  'access_token': 'access-999',
                  'refresh_token': 'refresh-111',
                  'expires_in': 3600,
                  'token_type': 'Bearer',
                }),
                200,
              );
            }
            return http.Response('Not Found', 404);
          }),
        );

        final start = await service.start('openai-codex');
        expect(start.flow, equals(AuthFlowKind.deviceCode));
        expect(start.userCode, equals('ABCD-1234'));
        expect(start.verificationUri, isNotNull);

        // Poll until approved.
        AuthSessionPoll? poll;
        for (var i = 0; i < 3; i++) {
          poll = await service.poll(start.sessionId);
          if (poll.status == AuthSessionStatus.approved) break;
        }
        expect(poll, isNotNull);
        expect(poll!.status, equals(AuthSessionStatus.approved));
        expect(poll.record, isNotNull);
        expect(poll.record!.accessToken, equals('access-999'));
        expect(poll.record!.refreshToken, equals('refresh-111'));
        expect(poll.record!.expiresAt, isNotNull);

        final stored = credStore.read('openai-codex');
        expect(stored, isNotNull);
        expect(stored!.accessToken, equals('access-999'));
        expect(stored.refreshToken, equals('refresh-111'));
        expect(stored.status, equals('authenticated'));
      },
    );

    test(
      'credential resolver returns relogin_required for legacy .env token',
      () async {
        final file = File('${tempWorkDir.path}/.env');
        file.writeAsStringSync('CHATGPT_SESSION_TOKEN=legacy-only\n');
        final env = EnvFileService(envPath: file.path);
        final credStore = ProviderCredentialStore(
          storePath: '${tempSanadHome.path}/provider_auth.json',
        );

        final resolver = ProviderCredentialResolver(env, credStore);
        final result = resolver.resolve('openai-codex');
        expect(
          result.status,
          equals(CredentialResolutionStatus.reloginRequired),
        );
        expect(result.credential, isNull);
      },
    );

    test(
      'credential resolver returns ready for stored non-expired session',
      () async {
        final file = File('${tempWorkDir.path}/.env');
        file.writeAsStringSync('ACTIVE_PROVIDER=openai-codex\n');
        final env = EnvFileService(envPath: file.path);
        final credStore = ProviderCredentialStore(
          storePath: '${tempSanadHome.path}/provider_auth.json',
        );
        await credStore.write(
          ProviderAuthRecord(
            providerId: 'openai-codex',
            accessToken: 'fresh-access',
            refreshToken: 'fresh-refresh',
            expiresAt: DateTime.now()
                .add(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          ),
        );

        final resolver = ProviderCredentialResolver(env, credStore);
        final result = resolver.resolve('openai-codex');
        expect(result.status, equals(CredentialResolutionStatus.ready));
        expect(result.credential, equals('fresh-access'));
      },
    );

    test(
      'credential resolver returns relogin_required for expired no refresh',
      () async {
        final file = File('${tempWorkDir.path}/.env');
        file.writeAsStringSync('ACTIVE_PROVIDER=openai-codex\n');
        final env = EnvFileService(envPath: file.path);
        final credStore = ProviderCredentialStore(
          storePath: '${tempSanadHome.path}/provider_auth.json',
        );
        await credStore.write(
          ProviderAuthRecord(
            providerId: 'openai-codex',
            accessToken: 'stale-access',
            expiresAt: DateTime.now()
                .subtract(const Duration(hours: 1))
                .millisecondsSinceEpoch,
          ),
        );

        final resolver = ProviderCredentialResolver(env, credStore);
        final result = resolver.resolve('openai-codex');
        expect(
          result.status,
          equals(CredentialResolutionStatus.reloginRequired),
        );
        expect(result.credential, isNull);
      },
    );
  });
}
