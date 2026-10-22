import 'dart:io';

import 'package:sanad_agent/capabilities/secrets/user_secret_vault.dart';
import 'package:sanad_agent/core/auth/agent_secret_namespaces.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/sanad_home_bootstrap.dart';
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';

void main() {
  late Directory home;
  late MemoryAgentSecretStore store;

  setUp(() async {
    home = Directory(
      Directory.systemTemp
          .createTempSync('sanad-user-secrets')
          .resolveSymbolicLinksSync(),
    );
    setSanadHomeOverride(home.path);
    await SanadHomeBootstrap.identity().prepare();
    store = MemoryAgentSecretStore();
  });

  tearDown(() async {
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    home.deleteSync(recursive: true);
  });

  test(
    'custom namespace commits verified entries under custom: and its own index',
    () async {
      final vaults = await SecretVaults.open(store: store);
      await vaults.put(vaults.custom, {'DEMO_TOKEN': 'dummy-value-1'});

      expect(
        store.values[AgentSecretNamespaces.customKey('DEMO_TOKEN')],
        'dummy-value-1',
      );
      expect(
        store.values[AgentSecretNamespaces.customIndexKey],
        '["DEMO_TOKEN"]',
      );
      expect(
        store.values.containsKey(AgentSecretNamespaces.providerIndexKey),
        isFalse,
      );

      final reopened = await SecretVaults.openDetached(store: store);
      expect(reopened.custom.read('DEMO_TOKEN'), 'dummy-value-1');
      expect(reopened.providers.ids, isEmpty);
      // A namespace without a plaintext predecessor never creates or looks for one.
      expect(
        home.listSync().map((e) => e.path.split('/').last),
        isNot(contains(startsWith('custom'))),
      );
    },
  );

  test(
    'UserSecretVault stores, resolves only requested names, and removes',
    () async {
      final vaults = await SecretVaults.open(store: store);
      final secrets = UserSecretVault(vaults: () => vaults);

      await secrets.store({'DEMO_A': 'dummy-a', 'DEMO_B': 'dummy-b'});
      expect(secrets.names(), ['DEMO_A', 'DEMO_B']);

      final resolved = secrets.resolve(['DEMO_B', 'DEMO_MISSING']);
      expect(resolved.values, {'DEMO_B': 'dummy-b'});
      expect(resolved.missing, ['DEMO_MISSING']);

      expect(await secrets.remove(['DEMO_A', 'DEMO_MISSING']), ['DEMO_A']);
      expect(secrets.names(), ['DEMO_B']);
      expect(
        store.values.containsKey(AgentSecretNamespaces.customKey('DEMO_A')),
        isFalse,
      );
    },
  );

  test(
    'names must be environment names that are not protected or Sanad credentials',
    () {
      expect(UserSecretVault.nameRejection('DEMO_TOKEN'), isNull);
      expect(UserSecretVault.nameRejection('_private1'), isNull);
      for (final name in ['', '1ABC', 'A-B', 'A B', 'a:b', 'X' * 65]) {
        expect(
          UserSecretVault.nameRejection(name),
          'invalid_name',
          reason: name,
        );
      }
      for (final name in [
        'PATH',
        'path',
        'LD_PRELOAD',
        'DYLD_X',
        'SANAD_HOME',
        'OPENAI_API_KEY',
        'LLM_API_KEY',
      ]) {
        expect(
          UserSecretVault.nameRejection(name),
          'reserved_name',
          reason: name,
        );
      }
    },
  );

  test(
    'an unavailable vault rejects writes and reports itself unavailable',
    () async {
      store.available = false;
      final vaults = await SecretVaults.open(store: store);
      final secrets = UserSecretVault(vaults: () => vaults);
      expect(secrets.available, isFalse);
      await expectLater(
        secrets.store({'DEMO_A': 'dummy-a'}),
        throwsA(anything),
      );

      final none = UserSecretVault(vaults: () => null);
      expect(none.available, isFalse);
      expect(none.names(), isEmpty);
    },
  );

  test('output redactor replaces every injected value, longest first', () {
    final redactor = SecretOutputRedactor({
      'DEMO_A': 'dummy-abc',
      'DEMO_B': 'dummy-abcdef',
    });
    expect(
      redactor.redact('x dummy-abcdef y dummy-abc z'),
      'x [REDACTED:DEMO_B] y [REDACTED:DEMO_A] z',
    );
    expect(const SecretOutputRedactor.none().redact('dummy-abc'), 'dummy-abc');
  });
}
