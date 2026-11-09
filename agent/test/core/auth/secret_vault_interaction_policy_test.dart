import 'dart:io';

import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:test/test.dart';

/// Pins the two decisions that keep the Agent vault usable: who may start a
/// macOS authorization dialog, and what a closed vault must never degrade to.
void main() {
  tearDown(SecretVaultPolicy.reset);

  group('Keychain status mapping', () {
    test(
      'an interaction status becomes interaction_forbidden without a human',
      () {
        for (final status in const [-25308, -25315]) {
          final failure = MacOsKeychainAgentSecretStore.classifyStatus(
            status,
            interactionAllowed: false,
          );
          expect(
            failure,
            isNotNull,
            reason: 'status $status must not be silent',
          );
          expect(
            failure!.reasonCode,
            AgentSecretStoreUnavailableReason.interactionForbidden,
          );
          expect(failure.message, contains('stays closed'));
        }
      },
    );

    test('an interaction status becomes interaction_required with a human', () {
      for (final status in const [-25308, -25315]) {
        final failure = MacOsKeychainAgentSecretStore.classifyStatus(
          status,
          interactionAllowed: true,
        );
        expect(
          failure?.reasonCode,
          AgentSecretStoreUnavailableReason.interactionRequired,
          reason: 'status $status',
        );
      }
    });

    test('errSecUserCanceled reports a dismissed authorization', () {
      final failure = MacOsKeychainAgentSecretStore.classifyStatus(
        -128,
        interactionAllowed: true,
      );
      expect(
        failure?.reasonCode,
        AgentSecretStoreUnavailableReason.authorizationCanceled,
      );
      expect(failure!.message, contains('dismissed'));
      expect(failure.message, isNot(contains('no human')));
    });

    test('errSecAuthFailed reports a rejected authorization', () {
      final failure = MacOsKeychainAgentSecretStore.classifyStatus(
        -25293,
        interactionAllowed: true,
      );
      expect(
        failure?.reasonCode,
        AgentSecretStoreUnavailableReason.authorizationDenied,
      );
      expect(failure!.message, contains('does not accept the binary'));
    });

    test('an unrelated status is not an authorization failure', () {
      for (final status in const [-25300, -25291, 0, -34018]) {
        expect(
          MacOsKeychainAgentSecretStore.classifyStatus(
            status,
            interactionAllowed: true,
          ),
          isNull,
          reason: 'status $status',
        );
      }
    });

    test('no mapped message carries a value placeholder', () {
      for (final status in const [-25308, -25315, -25293, -128]) {
        for (final allowed in const [true, false]) {
          final message =
              MacOsKeychainAgentSecretStore.classifyStatus(
                status,
                interactionAllowed: allowed,
              )?.message ??
              '';
          expect(message, isNotEmpty);
          expect(message, isNot(contains('secret=')));
          expect(message, isNot(contains('token')));
        }
      }
    });
  });

  group('No-human-present detection', () {
    test('an interactive terminal keeps the prompt', () {
      final decision = detectSecretVaultInteraction(
        const ['models', 'list'],
        environment: const {},
        stdinIsTerminal: true,
        stdoutIsTerminal: true,
      );
      expect(decision.allowsPrompt, isTrue);
      expect(decision.code, 'interactive_terminal');
    });

    test('machine output flags forbid the prompt', () {
      for (final flag in const ['--json', '--quiet', '-q']) {
        final decision = detectSecretVaultInteraction(
          ['models', 'list', flag],
          environment: const {},
          stdinIsTerminal: true,
          stdoutIsTerminal: true,
        );
        expect(decision.allowsPrompt, isFalse, reason: flag);
        expect(decision.code, 'machine_output');
      }
    });

    test('a supervised child forbids the prompt', () {
      final decision = detectSecretVaultInteraction(
        const ['daemon', '--child-process'],
        environment: const {},
        stdinIsTerminal: true,
        stdoutIsTerminal: true,
      );
      expect(decision.allowsPrompt, isFalse);
      expect(decision.code, 'supervised_child');
    });

    test('a closed stdin or stdout forbids the prompt', () {
      for (final shape in const [
        (stdin: false, stdout: true),
        (stdin: true, stdout: false),
        (stdin: false, stdout: false),
      ]) {
        final decision = detectSecretVaultInteraction(
          const ['providers', 'list'],
          environment: const {},
          stdinIsTerminal: shape.stdin,
          stdoutIsTerminal: shape.stdout,
        );
        expect(decision.allowsPrompt, isFalse);
        expect(decision.code, 'no_terminal');
      }
    });

    test('a spawner declaration wins over the stdio shape', () {
      final declaredForbidden = detectSecretVaultInteraction(
        const ['models', 'list'],
        environment: const {
          SecretVaultPolicy.interactionEnvironmentVariable: 'forbid',
        },
        stdinIsTerminal: true,
        stdoutIsTerminal: true,
      );
      expect(declaredForbidden.allowsPrompt, isFalse);
      expect(declaredForbidden.code, 'declared_non_interactive');

      final declaredAllowed = detectSecretVaultInteraction(
        const ['models', 'list', '--json'],
        environment: const {
          SecretVaultPolicy.interactionEnvironmentVariable: 'allow',
        },
        stdinIsTerminal: false,
        stdoutIsTerminal: false,
      );
      expect(declaredAllowed.allowsPrompt, isTrue);
      expect(declaredAllowed.code, 'declared_interactive');
    });

    test('the daemon entry decision never allows the prompt', () {
      expect(SecretVaultPolicy.daemonEntryDecision.allowsPrompt, isFalse);
      expect(SecretVaultPolicy.daemonEntryDecision.code, 'daemon_background');
    });
  });

  group('Pending-authorization notice', () {
    late StringBuffer sink;

    setUp(() {
      sink = StringBuffer();
      SecretVaultNotice.sink = sink;
    });

    tearDown(SecretVaultNotice.reset);

    test('a daemon entry never announces a wait', () {
      // The store consults this before every query, so a daemon query cannot
      // print a notice no dialog backs.
      SecretVaultPolicy.apply(
        SecretVaultPolicy.daemonEntryDecision,
        vaultSkipped: false,
      );

      expect(SecretVaultNotice.announcePendingAuthorization(), isFalse);
      expect(sink.toString(), isEmpty);
      expect(SecretVaultNotice.printed, isFalse);
    });

    test('every forbidding evidence prints nothing', () {
      for (final evidence in const [
        SecretVaultInteractionEvidence.machineOutputFlag,
        SecretVaultInteractionEvidence.supervisedChild,
        SecretVaultInteractionEvidence.noTerminal,
        SecretVaultInteractionEvidence.declaredByEnvironment,
        SecretVaultInteractionEvidence.daemonBackground,
      ]) {
        SecretVaultNotice.reset();
        sink.clear();
        SecretVaultPolicy.apply(
          SecretVaultInteractionDecision(
            SecretVaultInteraction.forbidden,
            evidence,
          ),
          vaultSkipped: false,
        );

        expect(
          SecretVaultNotice.announcePendingAuthorization(),
          isFalse,
          reason: evidence.name,
        );
        expect(sink.toString(), isEmpty, reason: evidence.name);
      }
    });

    test('a refused query in a forbidding process prints nothing', () async {
      SecretVaultPolicy.apply(
        SecretVaultPolicy.daemonEntryDecision,
        vaultSkipped: false,
      );
      final store = _RefusingStore();

      await expectLater(
        store.read('providers:index'),
        throwsA(
          isA<AgentSecretStoreUnavailable>().having(
            (error) => error.reasonCode,
            'reasonCode',
            AgentSecretStoreUnavailableReason.interactionForbidden,
          ),
        ),
      );
      expect(
        sink.toString(),
        isEmpty,
        reason:
            'a background query is refused immediately; announcing a wait would '
            'describe a dialog that never appears',
      );
      expect(SecretVaultNotice.printed, isFalse);
    });

    test('an interactive grant prints the notice exactly once', () {
      SecretVaultPolicy.apply(
        const SecretVaultInteractionDecision(
          SecretVaultInteraction.allowed,
          SecretVaultInteractionEvidence.interactiveTerminal,
        ),
        vaultSkipped: false,
      );

      expect(SecretVaultNotice.announcePendingAuthorization(), isTrue);
      expect(SecretVaultNotice.announcePendingAuthorization(), isFalse);
      expect(
        sink.toString().trim().split('\n'),
        hasLength(1),
        reason: 'one notice per process, never one per query',
      );
      expect(sink.toString(), contains(agentVaultKeychainService));
      expect(sink.toString(), isNot(contains('secret=')));
    });
  });

  group('Plaintext fallback guard', () {
    late Directory root;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sanad-fallback-guard-');
    });

    tearDown(() async {
      if (await root.exists()) await root.delete(recursive: true);
    });

    test('a vault-free process cannot write a provider secret', () async {
      SecretVaultPolicy.apply(
        const SecretVaultInteractionDecision(
          SecretVaultInteraction.forbidden,
          SecretVaultInteractionEvidence.noTerminal,
        ),
        vaultSkipped: true,
      );
      final store = SecureFileSecretStore(
        storePath: '${root.path}/provider_secrets.json',
      );

      await expectLater(
        store.write(
          'instance-1',
          const SecretRecord(
            instanceId: 'instance-1',
            apiKey: 'sk-plain-0001',
            authMethod: ProviderAuthMethod.apiKey,
          ),
        ),
        throwsA(
          isA<AgentSecretStoreUnavailable>().having(
            (error) => error.reasonCode,
            'reasonCode',
            AgentSecretStoreUnavailableReason.plaintextFallbackBlocked,
          ),
        ),
      );
      expect(
        File('${root.path}/provider_secrets.json').existsSync(),
        isFalse,
        reason: 'a blocked write must leave no plaintext file behind',
      );
      expect(store.read('instance-1'), isNull);
    });

    test('a vault-free process cannot delete through the plaintext store', () {
      SecretVaultPolicy.apply(
        const SecretVaultInteractionDecision(
          SecretVaultInteraction.forbidden,
          SecretVaultInteractionEvidence.machineOutputFlag,
        ),
        vaultSkipped: true,
      );
      final store = SecureFileSecretStore(
        storePath: '${root.path}/provider_secrets.json',
      );

      expect(
        store.remove('instance-1'),
        throwsA(isA<AgentSecretStoreUnavailable>()),
      );
      expect(
        store.pruneOrphans(const {'instance-2'}),
        throwsA(isA<AgentSecretStoreUnavailable>()),
      );
    });

    test(
      'the same store still writes when the process opened the vault',
      () async {
        SecretVaultPolicy.apply(
          const SecretVaultInteractionDecision(
            SecretVaultInteraction.allowed,
            SecretVaultInteractionEvidence.interactiveTerminal,
          ),
          vaultSkipped: false,
        );
        final store = SecureFileSecretStore(
          storePath: '${root.path}/provider_secrets.json',
        );

        await store.write(
          'instance-1',
          const SecretRecord(
            instanceId: 'instance-1',
            apiKey: 'sk-plain-0002',
            authMethod: ProviderAuthMethod.apiKey,
          ),
        );
        expect(store.read('instance-1')?.apiKey, 'sk-plain-0002');
      },
    );
  });

  group('Vault open clears the skip decision', () {
    late Directory root;
    late Directory home;

    setUp(() async {
      root = await Directory.systemTemp.createTemp('sanad-vault-open-');
      home = Directory('${root.path}/home')..createSync(recursive: true);
      selectSanadHome(home.path);
      setSanadStateHomeOverride(home.path);
      // A `run` process is classified before it knows which runtime it uses.
      SecretVaultPolicy.apply(
        const SecretVaultInteractionDecision(
          SecretVaultInteraction.forbidden,
          SecretVaultInteractionEvidence.noTerminal,
        ),
        vaultSkipped: true,
      );
    });

    tearDown(() async {
      await SecretVaults.closeAll();
      setSanadHomeOverride(null);
      setSanadStateHomeOverride(null);
      if (await root.exists()) await root.delete(recursive: true);
    });

    test(
      'a run that skipped the vault can write once its runtime opens it',
      () async {
        final store = SecureFileSecretStore(
          storePath: '${root.path}/provider_secrets.json',
        );
        const record = SecretRecord(
          instanceId: 'instance-1',
          apiKey: 'sk-vault-0001',
          authMethod: ProviderAuthMethod.apiKey,
        );
        // The guard is armed before the open, exactly as it is for a command
        // that never opens the vault.
        await expectLater(
          store.write('instance-1', record),
          throwsA(
            isA<AgentSecretStoreUnavailable>().having(
              (error) => error.reasonCode,
              'reasonCode',
              AgentSecretStoreUnavailableReason.plaintextFallbackBlocked,
            ),
          ),
        );
        expect(SecretVaultPolicy.vaultSkipped, isTrue);

        // This is the only thing `run --standalone` does before it reads a
        // provider key (`StandaloneCliTurnClient.start`).
        await SecretVaults.open();

        expect(
          SecretVaultPolicy.vaultSkipped,
          isFalse,
          reason:
              'a process with an open vault does have credential access, so '
              'its secure-store writes must not be refused',
        );
        await store.write('instance-1', record);
        expect(store.read('instance-1')?.apiKey, 'sk-vault-0001');
      },
    );

    test('the decision stays cleared when the vault is already open', () async {
      await SecretVaults.open();
      // A late classification must not re-arm the guard for a process that
      // already holds an open vault.
      SecretVaultPolicy.apply(
        const SecretVaultInteractionDecision(
          SecretVaultInteraction.forbidden,
          SecretVaultInteractionEvidence.noTerminal,
        ),
        vaultSkipped: true,
      );
      expect(SecretVaultPolicy.vaultSkipped, isTrue);

      await SecretVaults.open();

      expect(SecretVaultPolicy.vaultSkipped, isFalse);
    });
  });

  group('Never-prompt authentication context', () {    test(
      'builds an LAContext whose interactionNotAllowed reads back as set',
      () {
        expect(
          MacOsKeychainAgentSecretStore.buildsNeverPromptAuthenticationContext(),
          isTrue,
          reason:
              'the Objective-C FFI path must build and configure the context '
              'without touching the Keychain',
        );
        // Building it again proves the framework is loaded once, not that a
        // second process-wide switch is applied.
        expect(
          MacOsKeychainAgentSecretStore.buildsNeverPromptAuthenticationContext(),
          isTrue,
        );
      },
      skip: Platform.isMacOS
          ? false
          : 'LocalAuthentication is a macOS framework.',
    );
  });
}

/// A store that applies the same two steps as the macOS backend before its first
/// query: consult [SecretVaultNotice], then refuse an item that demands an
/// interaction this process may not show.
///
/// It keeps the notice decision testable on every operating system without a
/// real Keychain, DPAPI, or Secret Service call.
final class _RefusingStore implements AgentSecretStore {
  static const _error = AgentSecretStoreUnavailable(
    'The Agent vault item demands an interactive authorization and this '
    'process has no human to answer it.',
    reasonCode: AgentSecretStoreUnavailableReason.interactionForbidden,
  );

  @override
  Future<String?> read(String key) async {
    SecretVaultNotice.announcePendingAuthorization();
    throw _error;
  }

  @override
  Future<void> write(String key, String value) async => throw _error;

  @override
  Future<void> delete(String key) async => throw _error;
}
