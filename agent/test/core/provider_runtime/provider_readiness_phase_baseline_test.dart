import 'dart:io';

import 'package:sanad_agent/core/constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_catalog_service.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance.dart';
import 'package:sanad_agent/core/provider_runtime/provider_instance_repository.dart';
import 'package:sanad_agent/core/provider_runtime/provider_protocol_constants.dart';
import 'package:sanad_agent/core/provider_runtime/provider_readiness_service.dart';
import 'package:sanad_agent/core/provider_runtime/secret_record.dart';
import 'package:sanad_agent/core/provider_runtime/secret_store.dart';
import 'package:sanad_agent/core/provider_runtime/secure_file_secret_store.dart';
import 'package:test/test.dart';

/// Plan 97g P08/G0 baseline: decompose the provider-readiness phase functions
/// (catalog build -> instance query -> credential resolution -> readiness) and
/// prove that the *pure computation* of a configured, ready provider is fast and
/// synchronous. This is an explicit **in-memory CPU-only microbenchmark** on a
/// non-wired (in-memory) repository and an unwarmed secret read is NOT included:
/// it excludes real DB/credential-storage I/O and any network/daemon startup, so
/// it is evidence that the readiness *logic* is cheap, not a full startup
/// measurement. The client false-absence (P09) is a UI wiring/state issue to fix
/// at the loading-layer rather than a server-side bottleneck to mask.
/// Windows-host; other platforms final.
///
/// Sample sizes match the 97a measurement protocol (>=30 samples) and bounds are
/// loose sanity tolerances, not acceptance numbers. Full startup resolution
/// (real repo + storage + daemon) is tracked under P08 budgets separately.
void main() {
  late Directory tempDir;
  late ProviderInstanceRepository repo;
  late SecretStore secretStore;
  late ProviderReadinessService service;
  final catalog = ProviderCatalogService();

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('sanad-97g-phase');
    setSanadHomeOverride(tempDir.path);
    repo = ProviderInstanceRepository.inMemory();
    secretStore = SecureFileSecretStore(
      storePath: '${tempDir.path}/secrets.json',
    );
    service = ProviderReadinessService(repo, secretStore);

    repo.createInstance(
      ProviderInstance(
        id: 'inst-ready',
        templateId: 'openrouter',
        displayName: 'OpenRouter',
        protocol: ProviderProtocol.openaiCompatible,
        authMethod: ProviderAuthMethod.apiKey,
        defaultModel: 'mistralai/mistral-large-2512',
        status: InstanceStatus.ready,
        isDefault: true,
        configRevision: 1,
        credentialRevision: 1,
        createdAt: DateTime.now(),
        updatedAt: DateTime.now(),
      ),
    );
  });

  tearDown(() {
    setSanadHomeOverride(null);
    if (tempDir.existsSync()) tempDir.deleteSync(recursive: true);
  });

  int percentile(List<int> sorted, double p) {
    if (sorted.isEmpty) return 0;
    final idx = (sorted.length * p).ceil();
    return sorted[idx.clamp(0, sorted.length - 1) - 1];
  }

  test(
    'readiness phases are fast and synchronous for a configured ready provider',
    () async {
      // Warm the async credential write once (not sampled).
      await secretStore.write(
        'inst-ready',
        SecretRecord(
          instanceId: 'inst-ready',
          apiKey: 'sk-or-baseline',
          authMethod: ProviderAuthMethod.apiKey,
        ),
      );

      const N = 30;
      final catalogSamples = <int>[];
      final dbListSamples = <int>[];
      final setupStatusSamples = <int>[];
      final runtimeCheckSamples = <int>[];

      for (var i = 0; i < N; i++) {
        final sw = Stopwatch()..start();
        final catalogMaps = catalog.catalogMaps();
        sw.stop();
        catalogSamples.add(sw.elapsedMicroseconds);
        expect(catalogMaps, isNotEmpty);

        sw
          ..reset()
          ..start();
        final found = repo.findDefault();
        sw.stop();
        dbListSamples.add(sw.elapsedMicroseconds);
        expect(found, isNotNull);

        sw
          ..reset()
          ..start();
        final setup = service.setupStatus();
        sw.stop();
        setupStatusSamples.add(sw.elapsedMicroseconds);
        expect(setup.hasProvider, isTrue);

        sw
          ..reset()
          ..start();
        final ready = service.runtimeCheck();
        sw.stop();
        runtimeCheckSamples.add(sw.elapsedMicroseconds);
        expect(ready.runtimeReady, isTrue);
        expect(ready.activeProvider, 'inst-ready');
      }

      final sortedRuntime = [...runtimeCheckSamples]..sort();
      final runtimeP50 = percentile(sortedRuntime, 0.5);
      final runtimeP95 = percentile(sortedRuntime, 0.95);

      final sortedSetup = [...setupStatusSamples]..sort();
      final setupP50 = percentile(sortedSetup, 0.5);

      final sortedCatalog = [...catalogSamples]..sort();
      final sortedDb = [...dbListSamples]..sort();

      final catalogP50 = percentile(sortedCatalog, 0.5);
      final dbP50 = percentile(sortedDb, 0.5);

      // These are P08 phase baselines (30 samples, microseconds; 1000us = 1ms),
      // in-memory CPU-only: no real DB/secret-store I/O or network is sampled.
      // Bounds are loose sanity tolerances only; full startup resolution is
      // tracked under the P08 acceptance budgets in the QA ledger separately.
      expect(runtimeP50, lessThan(25000));
      expect(runtimeP95, lessThan(100000));

      // Record the baseline ledger (bounded, no secrets).
      // ignore: avoid_print
      print(
        '97g P08 phase baseline (30 samples, us): catalog p50=$catalogP50 '
        'p95=${percentile(sortedCatalog, 0.95)}; db-default p50=$dbP50 '
        'p95=${percentile(sortedDb, 0.95)}; setupStatus p50=$setupP50 '
        'p95=${percentile(sortedSetup, 0.95)}; runtimeCheck p50=$runtimeP50 '
        'p95=$runtimeP95',
      );
    },
  );
}
