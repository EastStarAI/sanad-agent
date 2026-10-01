import 'package:test/test.dart';
import 'package:sanad_agent/core/models/model_metadata.dart';

void main() {
  group('ModelMetadata.getLimitForModel', () {
    test('resolves Gemma 4 models with and without hyphens to 256k', () {
      expect(ModelMetadata.getLimitForModel('gemma-4'), 256000);
      expect(ModelMetadata.getLimitForModel('gemma4'), 256000);
      expect(ModelMetadata.getLimitForModel('gemma4:e2b'), 256000);
      expect(ModelMetadata.getLimitForModel('gemma-4-31b-it'), 256000);
    });

    test('resolves Gemma 3 models to 131k', () {
      expect(ModelMetadata.getLimitForModel('gemma-3'), 131072);
      expect(ModelMetadata.getLimitForModel('gemma3'), 131072);
      expect(ModelMetadata.getLimitForModel('gemma3:4b'), 131072);
    });

    test('resolves Gemma 2 models to 8k without polluting Gemma 4', () {
      expect(ModelMetadata.getLimitForModel('gemma-2'), 8192);
      expect(ModelMetadata.getLimitForModel('gemma2'), 8192);
      expect(ModelMetadata.getLimitForModel('gemma2:9b'), 8192);
    });

    test('resolves Llama and Qwen models with tags and version dots', () {
      expect(ModelMetadata.getLimitForModel('llama3.1:8b'), 131072);
      expect(ModelMetadata.getLimitForModel('llama3.2:3b'), 131072);
      expect(ModelMetadata.getLimitForModel('qwen2.5:7b'), 131072);
      expect(ModelMetadata.getLimitForModel('qwen3-coder:30b'), 262144);
    });

    test('normalizes separators for punctuation variations', () {
      expect(ModelMetadata.getLimitForModel('deepseek_v3'), 128000);
      expect(ModelMetadata.getLimitForModel('deepseek-v3'), 128000);
      expect(ModelMetadata.getLimitForModel('gemma_4:e2b'), 256000);
    });

    test('returns null for truly unknown model', () {
      expect(ModelMetadata.getLimitForModel('completely-unknown-custom-model'), isNull);
    });
  });
}
