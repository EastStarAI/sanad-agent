import 'package:sanad_client/features/conversations/domain/models/session.dart';
import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ThinkingControlDescriptorDto', () {
    test('parses supported, unsupported, and unknown statuses', () {
      final supported = ThinkingControlDescriptorDto.fromJson({
        'status': 'supported',
        'kind': 'effort',
        'options': [
          {'id': 'low', 'label': 'Low'},
        ],
      });
      final unsupported = ThinkingControlDescriptorDto.fromJson({
        'status': 'unsupported',
      });
      final unknown = ThinkingControlDescriptorDto.fromJson({
        'status': 'unknown',
      });
      final invalid = ThinkingControlDescriptorDto.fromJson({
        'status': 'unexpected',
      });

      expect(supported.status, ThinkingCapabilityStatus.supported);
      expect(supported.kind, ThinkingControlKind.effort);
      expect(unsupported.status, ThinkingCapabilityStatus.unsupported);
      expect(unknown.status, ThinkingCapabilityStatus.unknown);
      expect(invalid.status, ThinkingCapabilityStatus.unknown);
    });
  });

  group('Session thinking_control parsing', () {
    test('parses route thinking_control from session payload', () {
      final session = Session.fromJson({
        'id': 'session-1',
        'title': 'Test',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
        'thinking_control': {
          'status': 'supported',
          'kind': 'effort',
          'options': [
            {'id': 'low', 'label': 'Low'},
          ],
          'capability_revision': 'rev-1',
          'source': 'profile',
        },
      });

      expect(session.thinkingControl?.status, ThinkingCapabilityStatus.supported);
      expect(session.thinkingControl?.capabilityRevision, 'rev-1');
    });

    test('omits thinking_control on old agent payloads', () {
      final session = Session.fromJson({
        'id': 'session-1',
        'title': 'Test',
        'created_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:00:00Z',
        'thinking_mode': 'balanced',
      });

      expect(session.thinkingControl, isNull);
      expect(session.thinkingMode, 'balanced');
    });
  });
}
