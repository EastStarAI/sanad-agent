import 'dart:io';

import '../constants.dart';
import '../sanad_home/test_runtime_isolation.dart';
import 'agent_secret_store_contract.dart';
import 'secret_vault_policy.dart';

/// The environment variable a spawner uses to declare this runtime's secret
/// namespace.
///
/// `sanad-dev` sets `dev` for a linked Worktree Home, where no packaged Agent
/// has ever written an item. Nothing else sets it, and a runtime never infers a
/// namespace from how its binary was built: inference is what would move a Home
/// that already holds another identity's items.
const runtimeKindEnvironmentVariable = 'SANAD_RUNTIME_KIND';

/// The explicit backend override, `file` or `os`, for a development or test
/// runtime. It is refused for the production namespace and refused for `os`
/// under the Dart test runtime.
const secretStoreEnvironmentVariable = 'SANAD_SECRET_STORE';

/// Which runtime's secret namespace an [AgentSecretStore] addresses.
///
/// Every Home is already keyed by its own canonical path, so two Homes can never
/// collide. This enum separates two *runtimes* on the **same** Home, which is
/// the only case where macOS compares code identities on one item: the packaged
/// Agent owns `ai.eaststar.sanad.agent`, and a development runtime owns
/// `.dev` instead of reading items whose access control names another binary.
enum SecretStoreKind {
  /// The production namespace. Its service is byte-identical to the constant
  /// every earlier release used, so no existing item moves or is re-created.
  app('app', ''),

  /// A linked-worktree development runtime.
  dev('dev', '.dev'),

  /// The deterministic test runtime (Dart tests and `SANAD_E2E_TEST_MODE`).
  test('test', '.test');

  const SecretStoreKind(this.wireName, this.serviceSuffix);

  /// The non-secret name diagnostics, `/health` and the declaration use.
  final String wireName;

  /// The suffix that turns the production service into this kind's service.
  final String serviceSuffix;

  bool get isApp => this == SecretStoreKind.app;

  /// The macOS Keychain service, and the Linux Secret Service item label base.
  ///
  /// It is the only string that changes between kinds, which is why the account
  /// (`sha256(canonicalRoot):key`) can stay identical and keep every pre-existing
  /// item reachable from the namespace that created it.
  String get service => '$agentVaultKeychainService$serviceSuffix';

  /// The Secret Service `runtime` attribute, or `null` for [app].
  ///
  /// Items created before this namespace existed carry no `runtime` attribute,
  /// so the production filter must not add one: it would stop matching them.
  /// A non-production filter that requires the attribute can therefore never
  /// match a production item, and vice versa, by attribute absence.
  String? get secretServiceRuntime => isApp ? null : wireName;

  /// The Windows DPAPI filename prefix inside the Home.
  ///
  /// The hashed part stays `sha256(scope:key)` for every kind, so an existing
  /// `agent_vault_<hash>.bin` remains discoverable without a migration.
  String get vaultFileNamePrefix =>
      isApp ? 'agent_vault_' : 'agent_vault_${wireName}_';

  /// The owner-only file backend's data file for this kind.
  String get credentialDataFileName =>
      isApp ? 'agent_credentials.json' : 'agent_credentials.$wireName.json';

  /// The owner-only file backend's lock file for this kind.
  String get credentialLockFileName =>
      isApp ? 'agent_credentials.lock' : 'agent_credentials.$wireName.lock';

  /// Parses a declared value, or `null` when it is not a known kind.
  static SecretStoreKind? parse(String value) => switch (value) {
    'app' => SecretStoreKind.app,
    'dev' => SecretStoreKind.dev,
    'test' => SecretStoreKind.test,
    _ => null,
  };
}

/// Why this process resolves the namespace it does. Every value names the
/// concrete observation, so a diagnostic never has to guess.
enum SecretStoreKindEvidence {
  /// `SANAD_RUNTIME_KIND=app|dev|test` was declared by the spawner.
  declaredByEnvironment,

  /// `SANAD_RUNTIME_KIND` was present but unrecognized. The value is ignored and
  /// the production namespace is kept, because moving a Home on a typo would
  /// hide the items it already holds.
  declaredUnknown,

  /// The Dart test runtime or a `SANAD_E2E_TEST_MODE` process.
  testRuntime,

  /// No declaration: the packaged Agent, or a source run that did not declare a
  /// Worktree Home.
  packaged;

  /// Stable, non-secret reason code.
  String get code => switch (this) {
    SecretStoreKindEvidence.declaredByEnvironment => 'declared_runtime_kind',
    SecretStoreKindEvidence.declaredUnknown => 'declared_unknown_runtime_kind',
    SecretStoreKindEvidence.testRuntime => 'test_runtime',
    SecretStoreKindEvidence.packaged => 'packaged_runtime',
  };
}

/// The resolved namespace for this process.
final class SecretStoreKindResolution {
  const SecretStoreKindResolution(
    this.kind,
    this.evidence, {
    this.declaredValue,
    this.compiledSourceArtifact = false,
  });

  final SecretStoreKind kind;
  final SecretStoreKindEvidence evidence;

  /// The declared value, present when one was read from the environment.
  final String? declaredValue;

  /// Whether this process is a locally compiled source artifact rather than the
  /// packaged Agent or a JIT run. Its macOS code identity changes on every
  /// build, so a Keychain grant never survives a rebuild.
  final bool compiledSourceArtifact;

  /// Stable, non-secret reason code for logs and `/health`.
  String get code => evidence.code;
}

/// Whether this process must keep secrets out of the OS credential vault.
///
/// The Dart test runner and the deterministic E2E runtime use the owner-only
/// file store inside the selected Home, so no test reads or writes the real
/// Keychain, DPAPI or Secret Service.
bool isSecretStoreTestRuntime({bool? override}) =>
    override ?? (isDartTestRuntime() || isSanadE2eTestMode());

/// Whether [executable] is a binary `sanad-dev` compiled from this checkout.
///
/// Such a binary is ad-hoc signed, so its identity is new on every build; its
/// fixed cache location is the one piece of evidence that identifies it without
/// running anything.
bool isCompiledSourceArtifactExecutable(String executable) =>
    executable.replaceAll('\\', '/').contains('/.sanad-dev/bin/');

/// Resolves this runtime's secret namespace from explicit evidence only.
///
/// Order: a declared [runtimeKindEnvironmentVariable], then the test runtime,
/// then the packaged default. A source run with no declaration keeps [app], so
/// a Home that already holds production items is never moved by how the binary
/// happened to be built.
SecretStoreKindResolution resolveSecretStoreKind({
  Map<String, String>? environment,
  String? resolvedExecutable,
  bool? isTestRuntime,
  void Function(String message)? warn,
}) {
  final source = environment ?? Platform.environment;
  final executable = resolvedExecutable ?? Platform.resolvedExecutable;
  final compiledSourceArtifact = isCompiledSourceArtifactExecutable(executable);
  final declared = source[runtimeKindEnvironmentVariable]?.trim().toLowerCase();
  if (declared != null && declared.isNotEmpty) {
    final kind = SecretStoreKind.parse(declared);
    if (kind != null) {
      return SecretStoreKindResolution(
        kind,
        SecretStoreKindEvidence.declaredByEnvironment,
        declaredValue: declared,
        compiledSourceArtifact: compiledSourceArtifact,
      );
    }
    warn?.call(
      'Ignoring unrecognized $runtimeKindEnvironmentVariable="$declared"; '
      'expected app, dev or test. This runtime keeps the production secret '
      'namespace so no existing item is bypassed.',
    );
    return SecretStoreKindResolution(
      SecretStoreKind.app,
      SecretStoreKindEvidence.declaredUnknown,
      declaredValue: declared,
      compiledSourceArtifact: compiledSourceArtifact,
    );
  }
  if (isSecretStoreTestRuntime(override: isTestRuntime)) {
    return SecretStoreKindResolution(
      SecretStoreKind.test,
      SecretStoreKindEvidence.testRuntime,
      compiledSourceArtifact: compiledSourceArtifact,
    );
  }
  return SecretStoreKindResolution(
    SecretStoreKind.app,
    SecretStoreKindEvidence.packaged,
    compiledSourceArtifact: compiledSourceArtifact,
  );
}

/// The backend a caller explicitly selected for this process.
enum SecretStoreBackendOverride { file, os }

/// Reads [secretStoreEnvironmentVariable], or `null` when it is not set.
///
/// An unrecognized value fails closed with a reason code instead of silently
/// choosing a backend: the two backends differ in whether a secret is encrypted
/// at rest, so a typo must never decide it.
SecretStoreBackendOverride? readSecretStoreBackendOverride(
  Map<String, String>? environment,
) {
  final raw =
      (environment ?? Platform.environment)[secretStoreEnvironmentVariable];
  final value = raw?.trim().toLowerCase() ?? '';
  if (value.isEmpty) return null;
  return switch (value) {
    'file' => SecretStoreBackendOverride.file,
    'os' => SecretStoreBackendOverride.os,
    _ => throw AgentSecretStoreUnavailable(
      '$secretStoreEnvironmentVariable="$raw" is not a supported value; use '
      '"file" or "os".',
      reasonCode: AgentSecretStoreUnavailableReason.invalidStoreSelection,
    ),
  };
}
