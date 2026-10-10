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
}
