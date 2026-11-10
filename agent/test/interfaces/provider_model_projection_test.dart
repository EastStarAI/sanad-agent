import 'package:sanad_agent/interfaces/platforms/sanad_gateway/handlers/provider_model_projection.dart';
import 'package:test/test.dart';

void main() {
  test('the snapshot relays one effective window and no raw evidence', () {
    final projected = ProviderModelProjection.normalizeCachedModels(
      [
        {
          'value': 'deepseek-v4.1-flash',
          'label': 'Deepseek V4.1 Flash',
          'context_window': 358000,
          'context_window_raw': 1000000,
          'model_metadata': {'object': 'model'},
        },
      ],
      templateId: 'opencode-go',
      protocol: 'openai',
    );

    final entry = projected.single as Map<String, dynamic>;
    expect(entry['context_window'], 358000);
    expect(entry.containsKey('context_window_raw'), isFalse);
    expect(entry.containsKey('model_metadata'), isFalse);
    // The existing normalizations are untouched.
    expect(entry['id'], 'deepseek-v4.1-flash');
    expect(entry['name'], 'Deepseek V4.1 Flash');
  });
}
