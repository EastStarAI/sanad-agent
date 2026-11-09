import 'dart:async';
import 'dart:io';

import 'package:sanad_agent/core/auth/secret_vault.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_resolver.dart';
import 'package:sanad_agent/core/provider_runtime/provider_credential_store.dart';
import 'package:test/test.dart';

/// Pins the credential resolver's vault-readiness contract.
///
/// A daemon opens its Agent vault without waiting for the operating-system
/// store, so "the store has not answered yet" must never be reported as "this
/// provider has no key": that answer tells a person their credential is gone.
void main() {
  late Directory root;
  late EnvFileService env;
  late ProviderCredentialStore credStore;

  setUp(() async {
    root = await Directory.systemTemp.createTemp('sanad-resolver-vault-');
    final envFile = File('${root.path}/.env')
      ..writeAsStringSync('ACTIVE_PROVIDER=openai\n');
    env = EnvFileService(envPath: envFile.path);
    credStore = ProviderCredentialStore(
      storePath: '${root.path}/provider_auth.json',
    );
  });

  tearDown(() async {
    if (await root.exists()) await root.delete(recursive: true);
  });

  ProviderCredentialResolver resolverWith(_FakeVaultReadiness readiness) =>
      ProviderCredentialResolver(
        env,
        credStore,
        vaultReadiness: () => readiness,
      );

  test('an opening vault reports vault_not_ready, not a missing key', () {
    final resolver = resolverWith(_FakeVaultReadiness(ready: false));

    final result = resolver.resolve('openai');

    expect(result.status, CredentialResolutionStatus.missing);
    expect(result.reason, vaultNotReadyReason);
    expect(result.reason, contains('vault_not_ready'));
    expect(result.reason, isNot(contains('No API key configured')));
  });

  test('a settled vault reports the real missing-key answer', () {
    final resolver = resolverWith(_FakeVaultReadiness(ready: true));

    expect(resolver.resolve('openai').reason, contains('No API key configured'));
  });

  test('a provider that needs no credential never waits on the vault', () {
    final resolver = resolverWith(_FakeVaultReadiness(ready: false));

    final local = resolver.resolve('ollama');

    expect(local.status, CredentialResolutionStatus.ready);
    expect(local.credential, '');
  });

  test('a configured key is ready even while the vault is opening', () {
    final envFile = File('${root.path}/.env')
      ..writeAsStringSync('ACTIVE_PROVIDER=openai\nOPENAI_API_KEY=sk-configured\n');
    final resolver = ProviderCredentialResolver(
      EnvFileService(envPath: envFile.path),
      credStore,
      vaultReadiness: () => _FakeVaultReadiness(ready: false),
    );

    final result = resolver.resolve('openai');

    expect(result.status, CredentialResolutionStatus.ready);
    expect(result.credential, 'sk-configured');
  });

  test('resolveAwaitingVault waits for the open within its deadline', () async {
    final readiness = _FakeVaultReadiness(ready: false);
    final resolver = resolverWith(readiness);
    unawaited(
      Future<void>.delayed(
        const Duration(milliseconds: 10),
        readiness.markReady,
      ),
    );

    final result = await resolver.resolveAwaitingVault(
      'openai',
      deadline: const Duration(seconds: 2),
    );

    expect(readiness.isReady, isTrue);
    expect(result.reason, contains('No API key configured'));
  });

  test('resolveAwaitingVault gives up at its deadline and says so', () async {
    final resolver = resolverWith(_FakeVaultReadiness(ready: false));

    final result = await resolver.resolveAwaitingVault(
      'openai',
      deadline: const Duration(milliseconds: 20),
    );

    expect(result.reason, vaultNotReadyReason);
  });

  test('a resolver with no vault keeps its previous answers', () {
    final resolver = ProviderCredentialResolver(env, credStore);

    expect(resolver.resolve('openai').reason, contains('No API key configured'));
  });
}

/// A vault whose readiness a test controls, so no operating-system store is
/// touched and no real dialog can appear.
final class _FakeVaultReadiness implements SecretVaultReadiness {
  _FakeVaultReadiness({required this.ready});

  bool ready;
  final Completer<void> _settled = Completer<void>();

  void markReady() {
    ready = true;
    if (!_settled.isCompleted) _settled.complete();
  }

  @override
  bool get isReady => ready;

  @override
  Future<bool> readyWithin(Duration deadline) async {
    if (ready) return true;
    try {
      await _settled.future.timeout(deadline);
    } on TimeoutException {
      return false;
    }
    return ready;
  }
}
