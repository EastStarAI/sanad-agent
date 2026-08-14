import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/authenticated_command_origin.dart';
import 'package:test/test.dart';

void main() {
  group('AuthenticatedCommandOrigin', () {
    test('formats only allowlisted bounded metadata', () {
      final origin = AuthenticatedCommandOrigin.fromEnvelope({
        'origin_client': {
          'version': 1,
          'client_session_id': 'session-public-1',
          'client_instance_id': '11111111-1111-4111-8111-111111111111',
          'client_kind': 'desktop',
          'platform_family': 'macos',
          'display_name': 'Private Computer',
          'email': 'owner@example.com',
          'hostname': 'private-host',
          'ip': '192.0.2.1',
          'token': 'secret-token',
        },
        'payload': {'message': 'secret command'},
      });

      expect(origin.safeDisplay, 'authenticated desktop client on macos');
      expect(origin.safeDisplay, isNot(contains('session-public')));
      expect(origin.safeDisplay, isNot(contains('11111111')));
      expect(origin.safeDisplay, isNot(contains('Private Computer')));
      expect(origin.safeDisplay, isNot(contains('@')));
      expect(origin.safeDisplay, isNot(contains('private-host')));
      expect(origin.safeDisplay, isNot(contains('192.0.2.1')));
      expect(origin.safeDisplay, isNot(contains('secret')));
    });

    test('falls back for missing, malformed, and unknown versions', () {
      final fixtures = <Map<String, dynamic>>[
        {},
        {'origin_client': 'not-a-map'},
        {
          'origin_client': {'version': 99, 'client_kind': 'desktop'},
        },
        {
          'origin_client': {
            'version': 1,
            'client_kind': 'desktop\nforged',
            'platform_family': 'custom-platform',
            'client_session_id': 'x' * 1000,
            'client_instance_id': 'control\u0000character',
          },
        },
      ];

      for (final fixture in fixtures) {
        expect(
          AuthenticatedCommandOrigin.fromEnvelope(fixture).safeDisplay,
          'authenticated client',
        );
      }
    });
  });
}
