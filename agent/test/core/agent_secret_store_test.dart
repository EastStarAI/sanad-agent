import 'dart:io';

import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:test/test.dart';
import 'package:uuid/uuid.dart';

void main() {
  group('Linux Secret Service', () {
    final missingExecutable =
        '/definitely-missing-sanad-secret-tool-${const Uuid().v4()}';

    LinuxSecretServiceAgentSecretStore createStore() {
      return LinuxSecretServiceAgentSecretStore(
        scope: 'test-scope',
        run: (arguments) => Process.run(missingExecutable, arguments),
        start: (arguments) => Process.start(missingExecutable, arguments),
      );
    }

    test('normalizes a missing secret-tool executable for every operation', () {
      final store = createStore();
      final unavailable = throwsA(isA<AgentSecretStoreUnavailable>());

      expect(store.read('entry'), unavailable);
      expect(store.write('entry', 'secret'), unavailable);
      expect(store.delete('entry'), unavailable);
    });
  });

  test('Windows DPAPI round trip stores ciphertext only', () async {
    final tempDir = await Directory.systemTemp.createTemp('sanad-dpapi-test');
    setSanadHomeOverride(tempDir.path);
    final store = WindowsDpapiAgentSecretStore(scope: const Uuid().v4());
    try {
      expect(await store.read('entry'), isNull);
      await store.write('entry', 'synthetic-secret-value');
      expect(await store.read('entry'), 'synthetic-secret-value');
      final files = await tempDir
          .list()
          .where((entity) => entity is File)
          .toList();
      expect(files, hasLength(1));
      expect(
        String.fromCharCodes(await File(files.single.path).readAsBytes()),
        isNot(contains('synthetic-secret-value')),
      );
      await store.delete('entry');
      expect(await store.read('entry'), isNull);
    } finally {
      setSanadHomeOverride(null);
      await tempDir.delete(recursive: true);
    }
  }, skip: !Platform.isWindows);

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
