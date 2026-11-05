import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';

void main() {
  Map<String, dynamic> baseJson() => {
    'id': 'inst-1',
    'template_id': 'opencode-go',
    'display_name': 'OpenCode Go',
    'protocol': 'openai_compatible',
    'auth_method': 'api_key',
    'status': 'draft',
    'is_default': true,
    'config_revision': 1,
    'credential_revision': 1,
  };

  test('an instance carries the daemon discovery projection', () {
    final dto = ProviderInstanceDto.fromJson({
      ...baseJson(),
      'discovery_error': {
        'kind': 'auth',
        'status_code': 401,
        'message': 'Invalid credential (HTTP 401)',
        'endpoint': 'https://opencode.ai/zen/go/v1/models',
      },
      'model_cache': {'source': 'fallback', 'verified': false},
    });

    expect(dto.status, 'draft');
    expect(dto.discoveryError, isNotNull);
    expect(dto.discoveryError!.kind, 'auth');
    expect(dto.discoveryError!.statusCode, 401);
    expect(dto.discoveryError!.isAuthFailure, isTrue);
    expect(
      dto.discoveryError!.endpoint,
      'https://opencode.ai/zen/go/v1/models',
    );
    expect(dto.modelCache!.source, 'fallback');
    expect(dto.modelCache!.verified, isFalse);
    expect(dto.modelCache!.isUnverifiedFallback, isTrue);
  });

  test('an older daemon without the fields still parses', () {
    final dto = ProviderInstanceDto.fromJson(baseJson());

    expect(dto.discoveryError, isNull);
    expect(dto.modelCache, isNull);
  });

  test('a malformed projection degrades to null instead of throwing', () {
    final dto = ProviderInstanceDto.fromJson({
      ...baseJson(),
      'discovery_error': 'not-a-map',
      'model_cache': <String, dynamic>{},
    });

    expect(dto.discoveryError, isNull);
    expect(dto.modelCache, isNull);
  });

  test('the projection round-trips through toJson', () {
    final dto = ProviderInstanceDto.fromJson({
      ...baseJson(),
      'discovery_error': {
        'kind': 'http',
        'status_code': 429,
        'message': 'Rate limited (HTTP 429)',
      },
      'model_cache': {'source': 'live', 'verified': true},
    });

    final json = dto.toJson();

    expect((json['discovery_error'] as Map)['status_code'], 429);
    expect((json['model_cache'] as Map)['verified'], isTrue);
  });
}
