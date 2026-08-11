import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/domain/user_display_name.dart';

void main() {
  test('prefers the human-facing profile name', () {
    expect(
      resolveUserDisplayName(
        username: 'ahmedattia',
        displayName: ' Ahmed Attia ',
      ),
      'Ahmed Attia',
    );
  });

  test('falls back to username for legacy or empty profiles', () {
    expect(resolveUserDisplayName(username: 'ahmedattia'), 'ahmedattia');
    expect(
      resolveUserDisplayName(username: 'ahmedattia', displayName: '  '),
      'ahmedattia',
    );
  });
}
