import 'package:sanad_agent/engine/runtime/compaction_request_factory.dart';
import 'package:test/test.dart';

void main() {
  test(
    'manual compaction uses the provider model limit before estimate fallback',
    () async {
      var providerCalls = 0;
      var unresolvedCalls = 0;
      final window = await CompactionRequestFactory.resolveContextWindowTokens(
        explicitOverride: null,
        resolveProviderLimit: () async {
          providerCalls += 1;
          return 400000;
        },
        estimatedRequestTokens: 158781,
        unresolvedWindow: (legacyFallback) {
          unresolvedCalls += 1;
          return 358000;
        },
      );

      expect(window, 400000);
      expect(providerCalls, 1);
      // The adapter value is already final: it must never be re-capped or
      // replaced by the fallback.
      expect(unresolvedCalls, 0);
    },
  );

  test('an explicit override outranks provider model metadata', () async {
    var providerCalls = 0;
    Future<int> providerLimit() async {
      providerCalls += 1;
      return 400000;
    }

    expect(
      await CompactionRequestFactory.resolveContextWindowTokens(
        explicitOverride: 1000000,
        resolveProviderLimit: providerLimit,
        estimatedRequestTokens: 1000,
        unresolvedWindow: (legacyFallback) => legacyFallback,
      ),
      1000000,
    );
    expect(providerCalls, 0);
  });

  test('the window decision replaces the bounded estimate when the cap is on', () async {
    var unresolvedCalls = 0;
    final window = await CompactionRequestFactory.resolveContextWindowTokens(
      explicitOverride: null,
      resolveProviderLimit: () => throw StateError('metadata unavailable'),
      estimatedRequestTokens: 158781,
      unresolvedWindow: (legacyFallback) {
        unresolvedCalls += 1;
        // The bounded estimate is the cap-disabled fallback, and a policy with a
        // cap answers the window instead.
        expect(legacyFallback, 128000);
        return 358000;
      },
    );

    expect(window, 358000);
    expect(unresolvedCalls, 1);
  });

  test(
    'the bounded estimate is used only when no window decision applies',
    () async {
      final window = await CompactionRequestFactory.resolveContextWindowTokens(
        explicitOverride: null,
        resolveProviderLimit: () => throw StateError('metadata unavailable'),
        estimatedRequestTokens: 158781,
        unresolvedWindow: (legacyFallback) => legacyFallback,
      );

      expect(window, 128000);
    },
  );
}
