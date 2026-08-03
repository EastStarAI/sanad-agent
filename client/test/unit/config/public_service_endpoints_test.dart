import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/core/config/public_service_endpoints.dart';

void main() {
  test('defaults hosted profiles to public production services', () {
    for (final environment in ['dev', 'stg', 'prod', 'unknown']) {
      expect(
        PublicServiceEndpoints.backendFor(environment),
        'https://api.sanad.eaststarai.com',
      );
      expect(
        PublicServiceEndpoints.portalFor(environment),
        'https://portal.sanad.eaststarai.com',
      );
    }
  });

  test('keeps the explicit local profile on loopback services', () {
    expect(
      PublicServiceEndpoints.backendFor('local'),
      'http://127.0.0.1:8001',
    );
    expect(
      PublicServiceEndpoints.portalFor('local'),
      'http://127.0.0.1:8083',
    );
  });
}
