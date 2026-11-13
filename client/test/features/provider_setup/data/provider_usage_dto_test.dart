import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_usage_dto.dart';

void main() {
  test('parses reset credits with UTC timestamps and keeps the count', () {
    final snapshot = ProviderUsageSnapshotDto.fromJson({
      'provider_instance_id': 'a',
      'provider_template_id': 'openai-codex',
      'source': 'chatgpt_usage_api',
      'fetched_at': '2026-11-13T10:00:00Z',
      'available_resets': 2,
      'reset_credits': [
        {
          'expires_at': '2026-11-15T10:00:00Z',
          'granted_at': '2026-11-01T10:00:00Z',
        },
        {'expires_at': '2026-11-20T10:00:00Z'},
        {'expires_at': 'not-a-date'},
      ],
    });

    expect(snapshot.availableResets, 2);
    expect(snapshot.resetCredits, hasLength(3));
    expect(snapshot.resetCredits[0].expiresAt, DateTime.utc(2026, 11, 15, 10));
    expect(snapshot.resetCredits[0].grantedAt, DateTime.utc(2026, 11, 1, 10));
    expect(snapshot.resetCredits[1].expiresAt, DateTime.utc(2026, 11, 20, 10));
    expect(snapshot.resetCredits[2].expiresAt, isNull);
  });

  test('missing reset_credits yields an empty list', () {
    final snapshot = ProviderUsageSnapshotDto.fromJson({
      'provider_instance_id': 'a',
      'provider_template_id': 'openai-codex',
      'source': 'chatgpt_usage_api',
      'fetched_at': '2026-11-13T10:00:00Z',
      'available_resets': 1,
    });

    expect(snapshot.availableResets, 1);
    expect(snapshot.resetCredits, isEmpty);
  });
}
