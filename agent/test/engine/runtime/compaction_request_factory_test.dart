import 'package:sanad_agent/engine/runtime/compaction_request_factory.dart';
import 'package:test/test.dart';

void main() {
  test(
    'manual compaction uses the provider model limit before estimate fallback',
    () async {
      var providerCalls = 0;
      final window = await CompactionRequestFactory.resolveContextWindowTokens(
        explicitOverride: null,
        configuredOverride: null,
        resolveProviderLimit: () async {
          providerCalls += 1;
          return 400000;
        },
        estimatedRequestTokens: 158781,
      );

      expect(window, 400000);
      expect(providerCalls, 1);
    },
  );

  test('explicit and YAML overrides outrank provider model metadata', () async {
    var providerCalls = 0;
    Future<int> providerLimit() async {
      providerCalls += 1;
      return 400000;
    }

    expect(
      await CompactionRequestFactory.resolveContextWindowTokens(
        explicitOverride: 1000000,
        configuredOverride: 800000,
        resolveProviderLimit: providerLimit,
        estimatedRequestTokens: 1000,
      ),
      1000000,
    );
    expect(
      await CompactionRequestFactory.resolveContextWindowTokens(
        explicitOverride: null,
        configuredOverride: 800000,
        resolveProviderLimit: providerLimit,
        estimatedRequestTokens: 1000,
      ),
      800000,
    );
    expect(providerCalls, 0);
  });

  test(
    'bounded estimate is used only when provider resolution fails',
    () async {
      final window = await CompactionRequestFactory.resolveContextWindowTokens(
        explicitOverride: null,
        configuredOverride: null,
        resolveProviderLimit: () => throw StateError('metadata unavailable'),
        estimatedRequestTokens: 158781,
      );

      expect(window, 128000);
    },
  );
}
