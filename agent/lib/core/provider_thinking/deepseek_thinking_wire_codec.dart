/// Applies typed DeepSeek thinking directives to Chat Completions wire bodies.
library;

import 'native_thinking_directive.dart';
import 'toggle_effort_thinking_wire_codec.dart';

class DeepSeekThinkingWireCodec {
  DeepSeekThinkingWireCodec._();

  static void applyChatCompletions(
    Map<String, dynamic> body,
    NativeThinkingDirective? directive,
  ) {
    ToggleEffortThinkingWireCodec.applyChatCompletions(
      body,
      directive,
      enableThinkingWithEffort: true,
    );
  }
}
