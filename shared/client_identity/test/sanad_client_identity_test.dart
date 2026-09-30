import 'package:sanad_client_identity/sanad_client_identity.dart';
import 'package:test/test.dart';

void main() {
  group('clientDisplayReference', () {
    test('is stable, bounded, and instance-first', () {
      final reference = clientDisplayReference(
        clientInstanceId: '11111111-1111-4111-8111-111111111111',
        clientSessionId: 'session-a',
      );

      expect(reference, hasLength(8));
      expect(reference, matches(RegExp(r'^[0-9A-HJKMNP-TV-Z]{8}$')));
      expect(
        clientDisplayReference(
          clientInstanceId: '11111111-1111-4111-8111-111111111111',
          clientSessionId: 'session-b',
        ),
        reference,
      );
      expect(
        clientDisplayReference(
          clientInstanceId: 'AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA',
        ),
        clientDisplayReference(
          clientInstanceId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa',
        ),
      );
    });

    test('distinguishes Client instances', () {
      expect(
        clientDisplayReference(
          clientInstanceId: '11111111-1111-4111-8111-111111111111',
        ),
        isNot(
          clientDisplayReference(
            clientInstanceId: '22222222-2222-4222-8222-222222222222',
          ),
        ),
      );
    });

    test('uses a namespaced session fallback', () {
      final instanceReference = clientDisplayReference(
        clientInstanceId: 'shared-value',
      );
      final sessionReference = clientDisplayReference(
        clientSessionId: 'shared-value',
      );

      expect(sessionReference, isNotNull);
      expect(sessionReference, isNot(instanceReference));
    });

    test('rejects absent and unbounded sources', () {
      expect(clientDisplayReference(), isNull);
      expect(clientDisplayReference(clientInstanceId: 'x' * 129), isNull);
    });
  });
}
