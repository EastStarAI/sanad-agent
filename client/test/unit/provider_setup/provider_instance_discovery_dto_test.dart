import 'package:flutter_test/flutter_test.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_test_result_dto.dart';

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

  group('provider.instance.test_result', () {
    test('a passed probe reports models, model, and latency', () {
      final dto = ProviderInstanceTestResultDto.fromJson({
        'success': true,
        'models_count': 12,
        'probe_state': 'passed',
        'model': 'gpt-4o',
        'latency_ms': 840,
      });

      expect(dto.success, isTrue);
      expect(dto.probePassed, isTrue);
      expect(dto.probeSkipped, isFalse);
      expect(dto.probeWarned, isFalse);
      expect(dto.latencySeconds, '0.8');
      expect(dto.failure, isNull);
      expect(dto.warning, isNull);
    });

    test('a skipped probe is a partial success without a failure', () {
      final dto = ProviderInstanceTestResultDto.fromJson({
        'success': true,
        'models_count': 3,
        'probe_state': 'skipped',
      });

      expect(dto.success, isTrue);
      expect(dto.probeSkipped, isTrue);
      expect(dto.model, isNull);
      expect(dto.failure, isNull);
    });

    test('a warning carries a non-blocking cause with its model', () {
      final dto = ProviderInstanceTestResultDto.fromJson({
        'success': true,
        'models_count': 12,
        'probe_state': 'warning',
        'model': 'gpt-4o',
        'warning': {
          'kind': 'model_rejected',
          'model': 'gpt-4o',
          'cause': {
            'kind': 'http',
            'status_code': 400,
            'message': 'Provider rejected the request (HTTP 400)',
            'definitive': false,
          },
        },
      });

      expect(dto.success, isTrue);
      expect(dto.probeWarned, isTrue);
      expect(dto.failure, isNull);
      expect(dto.warning!.kind, 'model_rejected');
      expect(dto.warning!.isModelRejected, isTrue);
      expect(dto.warning!.model, 'gpt-4o');
      expect(dto.warning!.cause!.statusCode, 400);
      expect(dto.warning!.cause!.definitive, isFalse);
    });

    test('a failed probe carries a definitive failure', () {
      final dto = ProviderInstanceTestResultDto.fromJson({
        'success': false,
        'models_count': 12,
        'probe_state': 'failed',
        'model': 'gpt-4o',
        'failure': {
          'kind': 'invalid_credential',
          'status_code': 401,
          'message': 'Invalid credential (HTTP 401)',
          'definitive': true,
        },
      });

      expect(dto.success, isFalse);
      expect(dto.failure!.definitive, isTrue);
      expect(dto.warning, isNull);
    });

    test('an older daemon payload defaults to a discovery-only outcome', () {
      final dto = ProviderInstanceTestResultDto.fromJson({
        'success': true,
        'models_count': 2,
      });

      expect(dto.probeState, 'not_run');
      expect(dto.probePassed, isFalse);
      expect(dto.probeSkipped, isFalse);
      expect(dto.probeWarned, isFalse);
      expect(dto.failure, isNull);
    });
  });
}
