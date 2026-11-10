import 'package:sanad_agent/core/config.dart';
import 'package:test/test.dart';

ModelAwareRuntimePolicy _policy({
  Map<String, int> userLimits = const {},
  int? maxLimit,
  BuiltinModelPolicyDefaults<int>? builtins,
}) => ModelAwareRuntimePolicy(
  contextModelLimits: userLimits,
  maxLimit: maxLimit,
  builtinContextModelLimits:
      builtins ?? ContextWindowPolicy.builtinModelLimits,
  compaction: const ModelAwareCompactionPolicy(
    threshold: 0.90,
    targetRatio: 0.10,
    models: {},
  ),
);

ProviderContextWindow _catalog(int tokens) => ProviderContextWindow(
  tokens: tokens,
  source: ContextWindowSource.providerCatalog,
);

ProviderContextWindow _provider(int tokens) => ProviderContextWindow(
  tokens: tokens,
  source: ContextWindowSource.providerMetadata,
);

ContextWindowResolution _resolve(
  ModelAwareRuntimePolicy policy,
  String modelId, {
  ProviderContextWindow? evidence,
  int legacyFallback = 4000,
  bool local = false,
}) => policy.resolveContextWindow(
  modelId: modelId,
  providerEvidence: evidence,
  unknownCloudFallback: legacyFallback,
  localProvider: local,
);

void main() {
  group('built-in defaults and the user merge', () {
    test('built-in per-model defaults apply with no config.yaml at all', () {
      final policy = _policy();

      final sol = _resolve(policy, 'gpt-6.1-sol');
      expect(sol.tokens, 258000);
      expect(sol.source, ContextWindowSource.builtInDefault);
      expect(sol.cap, ContextWindowPolicy.builtInMaxLimit);
      expect(sol.wasCapped, isFalse);

      final flash = _resolve(policy, 'deepseek-v4.1-flash');
      expect(flash.tokens, 358000);
      expect(flash.source, ContextWindowSource.builtInDefault);
    });

    test('merges key by key and a user entry wins only for its own key', () {
      final policy = _policy(userLimits: {'gpt-6.1-sol': 300000});

      expect(policy.mergedContextModelLimits, {
        'gpt-6.1-sol': 300000,
        'deepseek-v4.1-flash': 358000,
      });

      final overridden = _resolve(policy, 'gpt-6.1-sol');
      expect(overridden.tokens, 300000);
      expect(overridden.source, ContextWindowSource.userOverride);

      final untouched = _resolve(policy, 'deepseek-v4.1-flash');
      expect(untouched.tokens, 358000);
      expect(untouched.source, ContextWindowSource.builtInDefault);
    });

    test('normalizes the model id before matching a built-in default', () {
      final resolution = _resolve(_policy(), ' GPT-6.1-SOL ');
      expect(resolution.tokens, 258000);
      expect(resolution.source, ContextWindowSource.builtInDefault);
      expect(resolution.modelId, 'gpt-6.1-sol');
    });

    test('a built-in default also matches a vendor-prefixed model id', () {
      for (final modelId in const [
        'deepseek/deepseek-v4.1-flash',
        'openrouter/deepseek/deepseek-v4.1-flash',
      ]) {
        final resolution = _resolve(_policy(), modelId);
        expect(
          resolution.tokens,
          358000,
          reason: 'built-in defaults follow model identity, not route spelling',
        );
        expect(resolution.source, ContextWindowSource.builtInDefault);
      }
    });

    test('a user key stays an exact normalized match', () {
      final policy = _policy(userLimits: {'deepseek-v4.1-flash': 900000});

      // The exact key wins uncapped.
      expect(_resolve(policy, 'deepseek-v4.1-flash').tokens, 900000);
      // The vendor-prefixed spelling does not inherit a user key; the built-in
      // default still answers for it.
      final prefixed = _resolve(policy, 'deepseek/deepseek-v4.1-flash');
      expect(prefixed.tokens, 358000);
      expect(prefixed.source, ContextWindowSource.builtInDefault);
    });

    test('the mechanism is not context-specific', () {
      const defaults = BuiltinModelPolicyDefaults<CompactionPolicy>(
        section: 'compaction.models',
        entries: {
          'model-a': BuiltinPolicyDefault<CompactionPolicy>(
            value: CompactionPolicy(threshold: 0.5, targetRatio: 0.05),
            reason: 'test',
            date: '2026-11-10',
          ),
        },
      );
      const userOverride = CompactionPolicy(threshold: 0.7, targetRatio: 0.2);

      final merged = defaults.mergedOver({'model-a': userOverride});
      expect(merged['model-a'], same(userOverride));
      expect(defaults.valueFor('vendor/model-a')?.threshold, 0.5);
      expect(defaults.entryFor('vendor/model-a')?.date, '2026-11-10');
    });
  });

  group('cap resolution', () {
    test('a user per-model value is applied as-is and never capped', () {
      final policy = _policy(userLimits: {'custom-model': 1000000});

      final resolution = _resolve(policy, 'custom-model', evidence: _catalog(64000));
      expect(resolution.tokens, 1000000);
      expect(resolution.source, ContextWindowSource.userOverride);
      expect(resolution.cappedFrom, isNull);
      expect(resolution.cap, 358000);
    });

    test('the cap lowers a catalog value', () {
      final resolution = _resolve(_policy(), 'future-model', evidence: _catalog(444000));

      expect(resolution.tokens, 358000);
      expect(resolution.source, ContextWindowSource.providerCatalog);
      expect(resolution.base, 444000);
      expect(resolution.cappedFrom, 444000);
      expect(resolution.wasCapped, isTrue);
    });

    test('the cap lowers a live/provider or models.dev value', () {
      final resolution = _resolve(_policy(), 'future-model', evidence: _provider(1000000));

      expect(resolution.tokens, 358000);
      expect(resolution.source, ContextWindowSource.providerMetadata);
      expect(resolution.cappedFrom, 1000000);
    });

    test('the cap lowers a built-in per-model default', () {
      const builtins = BuiltinModelPolicyDefaults<int>(
        section: 'context.modelLimits',
        entries: {
          'big-model': BuiltinPolicyDefault<int>(
            value: 500000,
            reason: 'test',
            date: '2026-11-10',
          ),
        },
      );
      final resolution = _resolve(
        _policy(builtins: builtins),
        'big-model',
        evidence: _catalog(900000),
      );

      // The built-in layer outranks provider evidence, then the cap applies.
      expect(resolution.tokens, 358000);
      expect(resolution.source, ContextWindowSource.builtInDefault);
      expect(resolution.cappedFrom, 500000);
    });

    test('a user maxLimit replaces the built-in cap', () {
      final policy = _policy(maxLimit: 200000);

      expect(policy.effectiveContextMaxLimit, 200000);
      final builtIn = _resolve(policy, 'gpt-6.1-sol');
      expect(builtIn.tokens, 200000);
      expect(builtIn.cappedFrom, 258000);

      final providerValue = _resolve(policy, 'future-model', evidence: _provider(300000));
      expect(providerValue.tokens, 200000);
      expect(providerValue.cappedFrom, 300000);
    });

    test('values below the cap are untouched', () {
      final resolution = _resolve(_policy(), 'future-model', evidence: _catalog(196000));

      expect(resolution.tokens, 196000);
      expect(resolution.cappedFrom, isNull);
      expect(resolution.wasCapped, isFalse);
    });

    test('maxLimit 0 disables the cap everywhere', () {
      final policy = _policy(maxLimit: 0);

      expect(policy.effectiveContextMaxLimit, 0);
      expect(_resolve(policy, 'future-model', evidence: _provider(444000)).tokens, 444000);
      expect(_resolve(policy, 'gpt-6.1-sol').tokens, 258000);
      expect(_resolve(policy, 'future-model', evidence: _catalog(1050000)).tokens, 1050000);
    });
  });

  group('unknown windows', () {
    test('a cloud route with no window from any source uses the cap', () {
      final resolution = _resolve(_policy(), 'future-model');

      expect(resolution.tokens, 358000);
      expect(resolution.source, ContextWindowSource.cloudCap);
      expect(resolution.base, isNull);
    });

    test('a cloud route with the cap disabled keeps the legacy fallback', () {
      final resolution = _resolve(
        _policy(maxLimit: 0),
        'future-model',
        legacyFallback: 4000,
      );

      expect(resolution.tokens, 4000);
      expect(resolution.source, ContextWindowSource.legacyFallback);
    });

    test('a local route with no window uses the local fallback', () {
      expect(ContextWindowPolicy.localFallbackLimit, 16000);

      final resolution = _resolve(_policy(), 'tiny-local-model', local: true);
      expect(resolution.tokens, 16000);
      expect(resolution.source, ContextWindowSource.localFallback);
      expect(resolution.cappedFrom, isNull);
    });

    test('the local fallback is still subject to the cap', () {
      final resolution = _resolve(
        _policy(maxLimit: ContextWindowPolicy.minimumMaxLimit),
        'tiny-local-model',
        local: true,
      );

      expect(resolution.tokens, ContextWindowPolicy.minimumMaxLimit);
      expect(resolution.cappedFrom, 16000);
      expect(resolution.source, ContextWindowSource.localFallback);
    });

    test('a local route with the cap disabled keeps the local fallback', () {
      final resolution = _resolve(_policy(maxLimit: 0), 'tiny-local-model', local: true);

      expect(resolution.tokens, 16000);
      expect(resolution.source, ContextWindowSource.localFallback);
    });

    test('local probe evidence outranks the local fallback', () {
      final resolution = _resolve(
        _policy(),
        'tiny-local-model',
        evidence: _provider(8000),
        local: true,
      );

      expect(resolution.tokens, 8000);
      expect(resolution.source, ContextWindowSource.providerMetadata);
    });
  });

  group('provenance', () {
    test('describe names the layer and whether the cap lowered the value', () {
      expect(
        _resolve(_policy(), 'gpt-6.1-sol').describe(),
        '258000 tokens (built-in)',
      );
      expect(
        _resolve(_policy(), 'future-model', evidence: _catalog(1000000)).describe(),
        '358000 tokens (catalog; capped from 1000000)',
      );
      expect(
        _resolve(_policy(), 'future-model').describe(),
        '358000 tokens (unknown-cloud-cap)',
      );
      expect(
        _resolve(_policy(), 'tiny-local-model', local: true).describe(),
        '16000 tokens (unknown-local-fallback)',
      );
      expect(
        _resolve(
          _policy(userLimits: {'custom-model': 1000000}),
          'custom-model',
        ).describe(),
        '1000000 tokens (user)',
      );
    });
  });
}
