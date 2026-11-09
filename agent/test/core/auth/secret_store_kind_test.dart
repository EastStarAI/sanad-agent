import 'package:sanad_agent/core/auth/agent_secret_store.dart';
import 'package:test/test.dart';

/// The namespace decision is explicit-evidence only.
///
/// These tests pin the two halves of that rule: the production namespace is
/// byte-identical to what every shipped release used, and nothing — not the
/// binary path, not the test runtime, not a malformed declaration — can move a
/// Home that already holds production items onto another service.
void main() {
  group('namespace identity', () {
    test('the production kind keeps the shipped service and file names', () {
      expect(SecretStoreKind.app.service, agentVaultKeychainService);
      expect(SecretStoreKind.app.service, 'ai.eaststar.sanad.agent');
      expect(SecretStoreKind.app.serviceSuffix, '');
      expect(SecretStoreKind.app.isApp, isTrue);

      // A production item carries no `runtime` attribute and no name prefix, so
      // the Linux filter and the Windows file name still find it.
      expect(SecretStoreKind.app.secretServiceRuntime, isNull);
      expect(SecretStoreKind.app.vaultFileNamePrefix, 'agent_vault_');
      expect(
        SecretStoreKind.app.credentialDataFileName,
        'agent_credentials.json',
      );
      expect(
        SecretStoreKind.app.credentialLockFileName,
        'agent_credentials.lock',
      );
    });

    test('a non-production kind never addresses the production service', () {
      final services = <String>{SecretStoreKind.app.service};
      for (final kind in [SecretStoreKind.dev, SecretStoreKind.test]) {
        expect(kind.isApp, isFalse);
        expect(kind.service, startsWith('$agentVaultKeychainService.'));
        expect(services.contains(kind.service), isFalse);
        expect(kind.secretServiceRuntime, kind.wireName);
        expect(kind.vaultFileNamePrefix, 'agent_vault_${kind.wireName}_');
        expect(
          kind.credentialDataFileName,
          'agent_credentials.${kind.wireName}.json',
        );
        expect(
          kind.credentialLockFileName,
          'agent_credentials.${kind.wireName}.lock',
        );
        services.add(kind.service);
      }
      expect(services, hasLength(3));
    });
  });

  group('resolution', () {
    test('nothing declared keeps the production namespace', () {
      final warnings = <String>[];
      final resolution = resolveSecretStoreKind(
        environment: const {},
        resolvedExecutable:
            '/Applications/Sanad.app/Contents/MacOS/Sanad Agent',
        isTestRuntime: false,
        warn: warnings.add,
      );

      expect(resolution.kind, SecretStoreKind.app);
      expect(resolution.evidence, SecretStoreKindEvidence.packaged);
      expect(resolution.code, 'packaged_runtime');
      expect(resolution.declaredValue, isNull);
      expect(resolution.compiledSourceArtifact, isFalse);
      expect(warnings, isEmpty);
    });

    test('a declared kind wins over the test runtime', () {
      final resolution = resolveSecretStoreKind(
        environment: const {'SANAD_RUNTIME_KIND': 'dev'},
        isTestRuntime: true,
      );

      expect(resolution.kind, SecretStoreKind.dev);
      expect(
        resolution.evidence,
        SecretStoreKindEvidence.declaredByEnvironment,
      );
      expect(resolution.code, 'declared_runtime_kind');
      expect(resolution.declaredValue, 'dev');
    });

    test('the declaration is trimmed and lower-cased before parsing', () {
      final resolution = resolveSecretStoreKind(
        environment: const {'SANAD_RUNTIME_KIND': ' TEST '},
        isTestRuntime: false,
      );

      expect(resolution.kind, SecretStoreKind.test);
      expect(resolution.declaredValue, 'test');
    });

    test('a blank declaration is no declaration', () {
      final resolution = resolveSecretStoreKind(
        environment: const {'SANAD_RUNTIME_KIND': '   '},
        isTestRuntime: false,
      );

      expect(resolution.kind, SecretStoreKind.app);
      expect(resolution.evidence, SecretStoreKindEvidence.packaged);
      expect(resolution.declaredValue, isNull);
    });

    test('an unrecognized declaration keeps production and warns', () {
      final warnings = <String>[];
      final resolution = resolveSecretStoreKind(
        environment: const {'SANAD_RUNTIME_KIND': 'prod'},
        isTestRuntime: false,
        warn: warnings.add,
      );

      // A typo must never hide the items a Home already holds.
      expect(resolution.kind, SecretStoreKind.app);
      expect(resolution.evidence, SecretStoreKindEvidence.declaredUnknown);
      expect(resolution.code, 'declared_unknown_runtime_kind');
      expect(resolution.declaredValue, 'prod');
      expect(warnings, hasLength(1));
      expect(warnings.single, contains('SANAD_RUNTIME_KIND="prod"'));
      expect(warnings.single, contains('production secret namespace'));
    });

    test('the test runtime takes the test namespace', () {
      final resolution = resolveSecretStoreKind(
        environment: const {},
        isTestRuntime: true,
      );

      expect(resolution.kind, SecretStoreKind.test);
      expect(resolution.evidence, SecretStoreKindEvidence.testRuntime);
      expect(resolution.code, 'test_runtime');
    });

    test(
      'a compiled source artifact is reported without moving the namespace',
      () {
        final resolution = resolveSecretStoreKind(
          environment: const {},
          resolvedExecutable:
              '/w/sanad-agent/.sanad-dev/bin/4b3e1ec9/sanad_agent',
          isTestRuntime: false,
        );

        expect(resolution.compiledSourceArtifact, isTrue);
        expect(resolution.kind, SecretStoreKind.app);
      },
    );
  });

  group('compiled source artifact detection', () {
    test('recognizes the sanad-dev cache on every separator style', () {
      expect(
        isCompiledSourceArtifactExecutable(
          '/w/sanad-agent/.sanad-dev/bin/4b3e1ec9/sanad_agent',
        ),
        isTrue,
      );
      expect(
        isCompiledSourceArtifactExecutable(
          r'C:\w\sanad-agent\.sanad-dev\bin\4b3e1ec9\sanad_agent.exe',
        ),
        isTrue,
      );
    });

    test('ignores a packaged, JIT or unrelated binary', () {
      expect(
        isCompiledSourceArtifactExecutable(
          '/Applications/Sanad.app/Contents/MacOS/Sanad Agent',
        ),
        isFalse,
      );
      expect(
        isCompiledSourceArtifactExecutable('/opt/flutter/bin/dart'),
        isFalse,
      );
      expect(
        isCompiledSourceArtifactExecutable('.sanad-dev/bin/x/dart'),
        isFalse,
      );
    });
  });

  group('backend override', () {
    test('an unset variable means no override', () {
      expect(readSecretStoreBackendOverride(const {}), isNull);
      expect(
        readSecretStoreBackendOverride(const {'SANAD_SECRET_STORE': '  '}),
        isNull,
      );
    });

    test('file and os are recognized regardless of case', () {
      expect(
        readSecretStoreBackendOverride(const {'SANAD_SECRET_STORE': 'file'}),
        SecretStoreBackendOverride.file,
      );
      expect(
        readSecretStoreBackendOverride(const {'SANAD_SECRET_STORE': ' OS '}),
        SecretStoreBackendOverride.os,
      );
    });

    test('an unrecognized value fails closed with a reason code', () {
      expect(
        () => readSecretStoreBackendOverride(const {
          'SANAD_SECRET_STORE': 'plaintext',
        }),
        throwsA(
          isA<AgentSecretStoreUnavailable>().having(
            (error) => error.reasonCode,
            'reasonCode',
            AgentSecretStoreUnavailableReason.invalidStoreSelection,
          ),
        ),
      );
    });
  });
}
