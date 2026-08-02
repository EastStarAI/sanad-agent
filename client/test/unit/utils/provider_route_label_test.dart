import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/presentation/utils/provider_route_label.dart';

void main() {
  Session session({
    String? providerId = 'provider-old',
    Map<String, dynamic>? metadata,
  }) {
    return Session(
      id: 'session-1',
      title: 'Session',
      createdAt: DateTime.utc(2026, 8, 2),
      updatedAt: DateTime.utc(2026, 8, 2),
      modelProvider: providerId,
      metadata: metadata ?? const {'provider_display_name': 'Old Provider'},
    );
  }

  test(
    'uses session display metadata when it belongs to the active provider',
    () {
      expect(
        resolveProviderDisplayName(
          session: session(),
          providerId: 'provider-old',
          providerDisplayNames: const {'provider-old': 'Mapped Old Provider'},
        ),
        'Old Provider',
      );
    },
  );

  test('staged provider supersedes stale session display metadata', () {
    expect(
      resolveProviderDisplayName(
        session: session(),
        providerId: 'provider-new',
        providerDisplayNames: const {'provider-new': 'New Provider'},
      ),
      'New Provider',
    );
  });

  test('never exposes an unmapped provider UUID', () {
    expect(
      resolveProviderDisplayName(
        session: session(providerId: null, metadata: const {}),
        providerId: '6982859f-48cb-4025-9821-1326b7d332bf',
        providerDisplayNames: const {},
      ),
      isNull,
    );
  });
}
