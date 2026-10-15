import 'package:sanad_client/features/conversations/domain/models/thinking_control.dart';
import 'package:sanad_client/features/provider_setup/data/models/model_cache_snapshot_dto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('ModelCacheModelDto thinking control', () {
    test('parses thinking_control and supports_reasoning_output', () {
      final dto = ModelCacheModelDto.fromJson({
        'id': 'gpt-test',
        'name': 'GPT Test',
        'supports_reasoning_output': true,
        'thinking_control': {
          'status': 'supported',
          'kind': 'effort',
          'options': [
            {'id': 'low', 'label': 'Low'},
            {'id': 'medium', 'label': 'Medium'},
          ],
          'capability_revision': 'rev-1',
          'source': 'profile',
        },
      });

      expect(dto.supportsReasoningOutput, isTrue);
      expect(dto.thinkingControl, isNotNull);
      expect(dto.thinkingControl!.status, ThinkingCapabilityStatus.supported);
      expect(dto.thinkingControl!.options.map((option) => option.id), [
        'low',
        'medium',
      ]);
    });

    test('falls back to legacy supports_reasoning flag', () {
      final dto = ModelCacheModelDto.fromJson({
        'value': 'gpt-test',
        'label': 'GPT Test',
        'supports_reasoning': true,
      });

      expect(dto.id, 'gpt-test');
      expect(dto.name, 'GPT Test');
      expect(dto.supportsReasoningOutput, isTrue);
      expect(dto.thinkingControl, isNull);
    });
  });

  group('ModelCacheUpdateEvent', () {
    test('parses terminal updated event from envelope json', () {
      final event = ModelCacheUpdateEvent.fromJson({
        'device_id': 'device-1',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'updated',
          'models': [
            {'id': 'o3'},
          ],
        },
      });

      expect(event.providerInstanceId, 'provider-1');
      expect(event.status, 'updated');
      expect(event.deviceId, 'device-1');
      expect(event.isTerminal, isTrue);
      expect(event.isUpdated, isTrue);
      expect(event.isFailed, isFalse);
    });

    test('parses terminal failed event from envelope json without error payload', () {
      final event = ModelCacheUpdateEvent.fromJson({
        'hardware_id': 'hw-1',
        'event': 'model.cache_updated',
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'failed',
          'error': 'Connection timeout',
        },
      });

      expect(event.providerInstanceId, 'provider-1');
      expect(event.status, 'failed');
      expect(event.deviceId, 'hw-1');
      expect(event.isTerminal, isTrue);
      expect(event.isUpdated, isFalse);
      expect(event.isFailed, isTrue);
      expect(event.toJson().containsKey('error'), isFalse);
    });

    test('parses non-terminal started event', () {
      final event = ModelCacheUpdateEvent.fromJson({
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'started',
        },
      });

      expect(event.providerInstanceId, 'provider-1');
      expect(event.status, 'started');
      expect(event.isTerminal, isFalse);
      expect(event.isUpdated, isFalse);
      expect(event.isFailed, isFalse);
    });
    test('throws FormatException on missing or malformed provider_instance_id', () {
      expect(
        () => ModelCacheUpdateEvent.fromJson({
          'payload': {
            'provider_instance_id': '',
            'status': 'updated',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => ModelCacheUpdateEvent.fromJson({
          'payload': {
            'provider_instance_id': 123,
            'status': 'updated',
          },
        }),
        throwsFormatException,
      );
    });

    test('throws FormatException on missing or unknown status', () {
      expect(
        () => ModelCacheUpdateEvent.fromJson({
          'payload': {
            'provider_instance_id': 'provider-1',
            'status': 'unknown_status',
          },
        }),
        throwsFormatException,
      );
      expect(
        () => ModelCacheUpdateEvent.fromJson({
          'payload': {
            'provider_instance_id': 'provider-1',
          },
        }),
        throwsFormatException,
      );
    });

    test('omits sensitive error payload entirely from event and serialization', () {
      final event = ModelCacheUpdateEvent.fromJson({
        'payload': {
          'provider_instance_id': 'provider-1',
          'status': 'failed',
          'error': {'message': 'Sensitive details', 'code': 500},
        },
      });

      expect(event.providerInstanceId, 'provider-1');
      expect(event.status, 'failed');
      expect(event.isFailed, isTrue);
      expect(event.toJson(), {
        'provider_instance_id': 'provider-1',
        'status': 'failed',
      });
    });
  });
}
