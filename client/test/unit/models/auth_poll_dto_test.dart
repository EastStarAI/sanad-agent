import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/auth_session_dto.dart';

void main() {
  test('AuthPollDto reads RFC 8628 slow_down interval', () {
    final poll = AuthPollDto.fromJson({
      'status': 'pending',
      'interval': 10,
    });
    expect(poll.status, AuthPollStatus.pending);
    expect(poll.interval, 10);
  });
}
