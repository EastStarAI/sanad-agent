import 'package:sanad_agent/engine/runtime/compaction_output_reservation.dart';
import 'package:test/test.dart';

void main() {
  group('Task 118b output reservation from route capability', () {
    test('provider metadata wins over models.dev', () {
      expect(
        CompactionOutputReservation.resolve(
          providerModelMetadata: const {
            'top_provider': {'max_completion_tokens': 16384},
          },
          modelsDevEntry: const {
            'limit': {'output': 32000},
          },
        ),
        (16384, 'provider_metadata'),
      );
    });

    test('models.dev limit.output is the next layer', () {
      expect(
        CompactionOutputReservation.resolve(
          providerModelMetadata: const {'context_length': 128000},
          modelsDevEntry: const {
            'limit': {'context': 128000, 'output': 16384},
          },
        ),
        (16384, 'models_dev'),
      );
    });

    test('nothing declared leaves the engine fallback', () {
      expect(
        CompactionOutputReservation.resolve(
          providerModelMetadata: const {'context_length': 128000},
          modelsDevEntry: const {'limit': <String, dynamic>{}},
        ),
        isNull,
      );
    });
  });
}
