import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/auth/infrastructure/colocated_auth_coupling_client.dart';

void main() {
  test('desktop exposes only the non-secret enrollment request identity', () async {
    final client = ColocatedAuthCouplingClient(
      isDesktop: true,
      requestOverride: (method) async {
        expect(method, 'POST');
        return {
          'status': 'pending',
          'enrollment_request_id': 'public-request-identity-1234567890',
          'expires_in': 120,
        };
      },
    );

    final request = await client.start();

    expect(request?.requestId, 'public-request-identity-1234567890');
    expect(request?.expiresIn, 120);
  });

  test('client waits through pending until the same Agent request completes', () async {
    var polls = 0;
    final client = ColocatedAuthCouplingClient(
      isDesktop: true,
      delay: (_) async {},
      requestOverride: (method) async {
        if (method == 'POST') {
          return {
            'status': 'pending',
            'enrollment_request_id': 'public-request-identity-1234567890',
            'expires_in': 120,
          };
        }
        polls += 1;
        return {
          'status': polls == 1 ? 'pending' : 'completed',
          'enrollment_request_id': 'public-request-identity-1234567890',
        };
      },
    );
    final request = await client.start();

    await client.waitForCompletion(request!);

    expect(polls, 2);
  });

  test('mobile never probes the Local Gateway', () async {
    var requests = 0;
    final client = ColocatedAuthCouplingClient(
      isDesktop: false,
      requestOverride: (_) async {
        requests += 1;
        return {};
      },
    );

    expect(await client.start(), isNull);
    expect(requests, 0);
  });

  test('changed Agent request identity fails closed', () async {
    final client = ColocatedAuthCouplingClient(
      isDesktop: true,
      requestOverride: (_) async => {
        'status': 'completed',
        'enrollment_request_id': 'different-request-identity-123456789',
      },
    );

    await expectLater(
      client.waitForCompletion(
        const ColocatedEnrollmentRequest(
          requestId: 'expected-request-identity-1234567890',
          expiresIn: 30,
        ),
      ),
      throwsStateError,
    );
  });
}
