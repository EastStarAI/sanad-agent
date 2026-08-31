import 'package:sanad_agent/core/provider_thinking/ollama_thinking_probe.dart';
import 'package:test/test.dart';

void main() {
  test('parses thinking capability from /api/show fixture', () {
    final metadata = OllamaThinkingProbe.metadataFromShowResponse({
      'capabilities': ['completion', 'tools', 'thinking'],
      'parameters': 'think',
    });

    expect(
      OllamaThinkingProbe.hasThinkingCapability(metadata),
      isTrue,
    );
  });

  test('returns unsupported when thinking capability is absent', () {
    final metadata = OllamaThinkingProbe.metadataFromShowResponse({
      'capabilities': ['completion', 'tools'],
    });

    expect(
      OllamaThinkingProbe.hasThinkingCapability(metadata),
      isFalse,
    );
  });

  test('returns null when probe evidence is missing', () {
    expect(OllamaThinkingProbe.hasThinkingCapability(const {}), isNull);
  });

  test('capability detection ignores model name and uses show fixture only', () {
    final withThinking = OllamaThinkingProbe.metadataFromShowResponse({
      'model': 'custom-local-model',
      'capabilities': ['completion', 'thinking'],
    });
    final withoutThinking = OllamaThinkingProbe.metadataFromShowResponse({
      'model': 'gpt-oss:20b',
      'capabilities': ['completion'],
    });

    expect(OllamaThinkingProbe.hasThinkingCapability(withThinking), isTrue);
    expect(OllamaThinkingProbe.hasThinkingCapability(withoutThinking), isFalse);
  });
}
