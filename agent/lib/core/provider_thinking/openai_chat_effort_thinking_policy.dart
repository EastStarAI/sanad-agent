/// OpenAI Chat Completions reasoning effort policy (Task 43 Gate E).
library;

import 'native_thinking_directive.dart';
import 'openai_effort_thinking_policy_base.dart';

class OpenAiChatEffortThinkingPolicy extends OpenAiEffortThinkingPolicyBase {
  const OpenAiChatEffortThinkingPolicy();

  @override
  String get policyId => 'openai_chat_effort';

  @override
  NativeThinkingDirective buildDirective(String effort) {
    return OpenAiEffortDirective(effort);
  }
}
