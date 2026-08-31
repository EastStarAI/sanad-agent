/// Applies typed Ollama thinking directives to /api/chat bodies.
library;

import 'native_thinking_directive.dart';

class OllamaThinkingWireCodec {
  OllamaThinkingWireCodec._();

  static void applyThink(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive,
  ) {
    switch (directive) {
      case ThinkingToggleDirective(enabled: true):
        body['think'] = true;
      case ThinkingToggleDirective(enabled: false):
        body['think'] = false;
      case OllamaThinkLevelDirective(:final level):
        body['think'] = level;
      case UseProviderDefault():
      case null:
        break;
      default:
        break;
    }
  }
}
