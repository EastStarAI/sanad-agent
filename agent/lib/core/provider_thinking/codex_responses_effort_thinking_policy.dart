/// Codex Responses API reasoning effort policy (Task 43 Gate E).
library;

import 'native_thinking_directive.dart';
import 'openai_effort_thinking_policy_base.dart';

class CodexResponsesEffortThinkingPolicy
    extends OpenAiEffortThinkingPolicyBase {
  const CodexResponsesEffortThinkingPolicy();

  static const policyIdentifier = 'codex_responses_effort';

  @override
  String get policyId => policyIdentifier;

  @override
  NativeThinkingDirective buildDirective(String effort) {
    return ResponsesReasoningDirective(effort: effort);
  }
}
