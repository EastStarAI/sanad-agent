import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/sanad_home/test_runtime_isolation.dart';
import 'package:sanad_agent/evolution/db/agent_state_database.dart';
import 'package:test/test.dart';

import '../../support/memory_agent_secret_store.dart';

/// G0: Home owners refuse to open from a Dart test unless the test isolated
/// its state explicitly, and never open the OS user's real default Home.
///
/// Every refusal below happens before any filesystem access, so a test run
/// with an inherited real Home stays safe even while the rule is under test.
void main() {
  final inheritedStateHome = Platform.environment['SANAD_STATE_HOME'];
  final skipUnisolated =
      inheritedStateHome != null && inheritedStateHome.isNotEmpty
      ? 'SANAD_STATE_HOME is inherited, so this runner is already isolated.'
      : null;

  late Directory temp;

  setUp(() {
    temp = Directory.systemTemp.createTempSync('sanad-g0-guard-');
  });

  tearDown(() async {
    await SecretVaults.closeAll();
    setSanadHomeOverride(null);
    setSanadStateHomeOverride(null);
    if (temp.existsSync()) temp.deleteSync(recursive: true);
  });

  test('the Dart test runtime is detected', () {
    expect(isDartTestRuntime(), isTrue);
  });

  group('without explicit isolation', () {
    test('AgentStateDatabase() refuses', () {
      expect(AgentStateDatabase.new, throwsStateError);
    });

    test('AgentStateDatabase.atPath refuses even a temporary path', () {
      expect(() => AgentStateDatabase.atPath(temp.path), throwsStateError);
      expect(File(p.join(temp.path, 'state.db')).existsSync(), isFalse);
    });

    test('SecretVaults.open refuses', () async {
      await expectLater(
        SecretVaults.open(store: MemoryAgentSecretStore()),
        throwsStateError,
      );
    });

    test('SecretVaults.openDetached refuses', () async {
      await expectLater(
        SecretVaults.openDetached(store: MemoryAgentSecretStore()),
        throwsStateError,
      );
    });

    test('the default secret-store factory refuses', () {
      expect(createAgentSecretStore, throwsStateError);
    });
  }, skip: skipUnisolated);

  group('with explicit isolation', () {
    setUp(() {
      selectSanadHome(temp.path);
    });

    test('the real default Home is still refused', () {
      final realHome = defaultSanadHome()!;
      expect(
        () => rejectUnisolatedTestHomeAccess('open', path: realHome),
        throwsStateError,
      );
      // Lexically different spellings of the same root are refused too.
      expect(
        () => rejectUnisolatedTestHomeAccess(
          'open',
          path: p.join(realHome, '..', p.basename(realHome)),
        ),
        throwsStateError,
      );
    });

    test('a temporary Home opens the state database and the vault', () async {
      final state = AgentStateDatabase.atPath(temp.path);
      addTearDown(state.dispose);
      expect(File(p.join(temp.path, 'state.db')).existsSync(), isTrue);

      final vaults = await SecretVaults.open(store: MemoryAgentSecretStore());
      expect(vaults.available, isTrue);
    });

    test('the default secret-store factory never selects the OS vault', () {
      expect(createAgentSecretStore(), isA<LinuxOwnerFileAgentSecretStore>());
    });
  });
}
