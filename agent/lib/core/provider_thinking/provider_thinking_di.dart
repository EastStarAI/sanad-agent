/// DI wiring for provider thinking policies (Task 43 Gate A).
library;

import 'aggregator_upstream_thinking_policy.dart';
import 'deepseek_thinking_policy.dart';
import 'google_thinking_policy.dart';
import 'kimi_thinking_policy.dart';
import 'nim_thinking_policy.dart';
import 'ollama_live_thinking_policy.dart';
import 'codex_responses_effort_thinking_policy.dart';
import 'anthropic_thinking_policy.dart';
import 'openai_chat_effort_thinking_policy.dart';
import 'provider_thinking_policy.dart';
import 'unknown_thinking_policy.dart';
import 'zai_thinking_policy.dart';
import 'thinking_capability_assembler.dart';

/// First-release thinking policy ids locked in Task 43 Gate R0.
/// Unlisted routes fail closed through [UnknownThinkingPolicy].
const reservedThinkingPolicyIds = [
  'unknown',
  'openai_chat_effort',
  'codex_responses_effort',
  'anthropic_thinking',
  'aggregator_upstream',
  'google_thinking',
  'deepseek_thinking',
  'ollama_live',
  'kimi_thinking',
  'zai_thinking',
  'nim_thinking',
];

ProviderThinkingRegistry buildProviderThinkingRegistry() {
  final fallback = UnknownThinkingPolicy();
  final registry = ProviderThinkingRegistry(fallbackPolicy: fallback);
  registry.register(fallback);
  registry.register(const OpenAiChatEffortThinkingPolicy());
  registry.register(const CodexResponsesEffortThinkingPolicy());
  registry.register(const AnthropicThinkingPolicy());
  registry.register(AggregatorUpstreamThinkingPolicy());
  registry.register(const GoogleThinkingPolicy());
  registry.register(const DeepSeekThinkingPolicy());
  registry.register(const OllamaLiveThinkingPolicy());
  registry.register(const KimiThinkingPolicy());
  registry.register(const ZaiThinkingPolicy());
  registry.register(const NimThinkingPolicy());
  return registry;
}

ThinkingCapabilityAssembler buildDefaultThinkingCapabilityAssembler() {
  return ThinkingCapabilityAssembler(buildProviderThinkingRegistry());
}
