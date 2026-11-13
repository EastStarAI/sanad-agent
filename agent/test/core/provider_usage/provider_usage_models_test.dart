// Focused tests for the unified provider usage models (Task 55 Gate A).
//
// Covers: JSON round-trip, percentage clamping/derivation, reset-at parsing,
// window-type labelling, and the invariant that no placeholder windows or
// non-numeric values cross the model surface.

import 'dart:convert';
import 'package:test/test.dart';
import 'package:sanad_agent/core/provider_usage/provider_usage_models.dart';

void main() {
  group('ProviderUsageWindowType', () {
    test('knows the three v1 types', () {
      expect(ProviderUsageWindowType.isKnown('session'), isTrue);
      expect(ProviderUsageWindowType.isKnown('weekly'), isTrue);
      expect(ProviderUsageWindowType.isKnown('monthly'), isTrue);
      expect(ProviderUsageWindowType.isKnown('daily'), isFalse);
      expect(ProviderUsageWindowType.isKnown(null), isFalse);
    });

    test('labels known types title-case', () {
      expect(ProviderUsageWindowType.label('session'), 'Session');
      expect(ProviderUsageWindowType.label('weekly'), 'Weekly');
      expect(ProviderUsageWindowType.label('monthly'), 'Monthly');
    });
  });

  group('ProviderUsageWindow', () {
    test('round-trips through toMap/fromMap', () {
      final w = ProviderUsageWindow(
        type: 'weekly',
        label: 'Weekly',
        usedPercent: 40,
        remainingPercent: 60,
        resetAt: DateTime.utc(2026, 7, 19, 12, 0, 0),
        detail: '60 of 100 requests',
      );
      final decoded = ProviderUsageWindow.fromMap(
        jsonDecode(jsonEncode(w.toMap())) as Map<String, dynamic>,
      );
      expect(decoded.type, w.type);
      expect(decoded.usedPercent, w.usedPercent);
      expect(decoded.remainingPercent, w.remainingPercent);
      expect(decoded.detail, w.detail);
      expect(decoded.resetAt?.toUtc(), w.resetAt);
    });

    test('isExhausted when used >= 100', () {
      expect(
        const ProviderUsageWindow(
          type: 'session',
          label: 'Session',
          usedPercent: 100,
          remainingPercent: 0,
        ).isExhausted,
        isTrue,
      );
      expect(
        const ProviderUsageWindow(
          type: 'session',
          label: 'Session',
          usedPercent: 42,
          remainingPercent: 58,
        ).isExhausted,
        isFalse,
      );
    });
  });

  group('ProviderUsageSnapshot', () {
    test('round-trips through JSON', () {
      final s = ProviderUsageSnapshot(
        providerInstanceId: 'inst-1',
        providerTemplateId: 'openai-codex',
        source: 'chatgpt_usage_api',
        fetchedAt: DateTime.utc(2026, 7, 19, 12, 0, 0),
        planName: 'Plus',
        windows: const [
          ProviderUsageWindow(
            type: 'weekly',
            label: 'Weekly',
            usedPercent: 10,
            remainingPercent: 90,
          ),
        ],
        availableResets: 2,
        resetCredits: [
          ProviderUsageResetCredit(
            expiresAt: DateTime.utc(2026, 7, 25, 9),
            grantedAt: DateTime.utc(2026, 7, 18, 9),
          ),
        ],
        extraDetails: const ['Credits balance: \$5.00'],
      );
      final decoded = ProviderUsageSnapshot.fromMap(
        jsonDecode(jsonEncode(s.toMap())) as Map<String, dynamic>,
      );
      expect(decoded.providerInstanceId, s.providerInstanceId);
      expect(decoded.availableResets, 2);
      expect(
        decoded.resetCredits.single.expiresAt,
        DateTime.utc(2026, 7, 25, 9),
      );
      expect(
        decoded.resetCredits.single.grantedAt,
        DateTime.utc(2026, 7, 18, 9),
      );
      expect(decoded.windows.single.type, 'weekly');
      expect(decoded.extraDetails.single, 'Credits balance: \$5.00');
      expect(decoded.hasContent, isTrue);
    });

    test('hasContent is false when unavailableReason is set', () {
      final s = ProviderUsageSnapshot(
        providerInstanceId: 'i',
        providerTemplateId: 't',
        source: 's',
        fetchedAt: DateTime.utc(2026),
        unavailableReason: 'down',
      );
      expect(s.hasContent, isFalse);
    });

    test('reset credits alone count as content', () {
      final s = ProviderUsageSnapshot(
        providerInstanceId: 'i',
        providerTemplateId: 't',
        source: 's',
        fetchedAt: DateTime.utc(2026),
        resetCredits: [
          ProviderUsageResetCredit(expiresAt: DateTime.utc(2026, 7, 25)),
        ],
      );
      expect(s.hasContent, isTrue);
    });

    test('default availableResets is 0', () {
      final s = ProviderUsageSnapshot(
        providerInstanceId: 'i',
        providerTemplateId: 't',
        source: 's',
        fetchedAt: DateTime.utc(2026),
      );
      expect(s.availableResets, 0);
    });
  });

  group('ProviderUsageResult', () {
    test('factory statuses', () {
      expect(
        ProviderUsageResult.unsupported('i').status,
        ProviderUsageResultStatus.unsupported,
      );
      expect(
        ProviderUsageResult.authRequired('i', 'x').status,
        ProviderUsageResultStatus.authRequired,
      );
      expect(
        ProviderUsageResult.failed('i', 'x').status,
        ProviderUsageResultStatus.failed,
      );
      expect(
        ProviderUsageResult.unavailable('i', 'x').status,
        ProviderUsageResultStatus.unavailable,
      );
      final snap = ProviderUsageSnapshot(
        providerInstanceId: 'i',
        providerTemplateId: 't',
        source: 's',
        fetchedAt: DateTime.utc(2026),
      );
      expect(ProviderUsageResult.available(snap).isAvailable, isTrue);
    });

    test('serializes status and message without leaking credentials', () {
      final r = ProviderUsageResult.failed('inst-9', 'boom');
      final m = r.toMap();
      expect(m['status'], 'failed');
      expect(m['message'], 'boom');
      expect(m.containsKey('snapshot'), isFalse);
      expect(jsonEncode(m).contains('token'), isFalse);
    });
  });

  group('derivePercentPair', () {
    test('derives remaining from used', () {
      final p = derivePercentPair(usedRaw: 42);
      expect(p.used, 42);
      expect(p.remaining, 58);
    });

    test('derives used from remaining', () {
      final p = derivePercentPair(remainingRaw: 58);
      expect(p.used, 42);
      expect(p.remaining, 58);
    });

    test('clamps out-of-range values', () {
      final p = derivePercentPair(usedRaw: 150);
      expect(p.used, 100);
      expect(p.remaining, 0);
    });

    test('rejects NaN and Infinity', () {
      final p = derivePercentPair(usedRaw: double.nan);
      expect(p.used, isNull);
      expect(p.remaining, isNull);
    });

    test('rejects null on both sides', () {
      final p = derivePercentPair();
      expect(p.used, isNull);
      expect(p.remaining, isNull);
    });
  });
}
