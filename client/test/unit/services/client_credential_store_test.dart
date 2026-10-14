import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/infrastructure/client_credential_store.dart';

void main() {
  group('InMemoryClientCredentialStore', () {
    late InMemoryClientCredentialStore store;

    setUp(() {
      store = InMemoryClientCredentialStore();
    });

    test('starts empty and returns null', () async {
      expect(await store.readCredentials(), isNull);
    });

    test('writes and reads back credential pair', () async {
      await store.writeCredentials(
        accessToken: 'access-123',
        refreshToken: 'refresh-456',
      );

      final creds = await store.readCredentials();
      expect(creds, isNotNull);
      expect(creds!.$1, equals('access-123'));
      expect(creds.$2, equals('refresh-456'));
    });

    test('clears credentials cleanly', () async {
      await store.writeCredentials(
        accessToken: 'access-123',
        refreshToken: 'refresh-456',
      );
      await store.clearCredentials();

      expect(await store.readCredentials(), isNull);
    });

    test('rejects empty or whitespace-only tokens', () async {
      expect(
        () => store.writeCredentials(
          accessToken: '',
          refreshToken: 'refresh-456',
        ),
        throwsArgumentError,
      );

      expect(
        () => store.writeCredentials(
          accessToken: '   ',
          refreshToken: 'refresh-456',
        ),
        throwsArgumentError,
      );

      expect(
        () => store.writeCredentials(
          accessToken: 'access-123',
          refreshToken: '',
        ),
        throwsArgumentError,
      );

      expect(
        () => store.writeCredentials(
          accessToken: 'access-123',
          refreshToken: '   ',
        ),
        throwsArgumentError,
      );
    });

    test('trims whitespace on write', () async {
      await store.writeCredentials(
        accessToken: '  trimmed-access  ',
        refreshToken: '  trimmed-refresh  ',
      );

      final creds = await store.readCredentials();
      expect(creds!.$1, equals('trimmed-access'));
      expect(creds.$2, equals('trimmed-refresh'));
    });
  });
}
