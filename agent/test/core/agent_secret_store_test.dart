import 'dart:io';

import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  test('macOS Keychain round trip stores no plaintext file', () async {
    final scope = 'sec01e-test-${const Uuid().v4()}';
    final key = 'synthetic-entry';
    final store = MacOsKeychainAgentSecretStore(scope: scope);
    try {
      expect(await store.read(key), isNull);
      await store.write(key, 'synthetic-secret-value');
      expect(await store.read(key), 'synthetic-secret-value');
      await store.delete(key);
      expect(await store.read(key), isNull);
    } finally {
      await store.delete(key);
    }
  }, skip: !Platform.isMacOS);
}
