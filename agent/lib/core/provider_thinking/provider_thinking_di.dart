/// DI wiring for provider thinking policies (Task 43 Gate A).
library;

import 'codex_responses_effort_thinking_policy.dart';
import 'models_dev_thinking_evidence.dart';
import 'ollama_live_thinking_policy.dart';
import 'openai_chat_effort_thinking_policy.dart';
import 'provider_thinking_policy.dart';
import 'thinking_capability_assembler.dart';
import 'unknown_thinking_policy.dart';

/// Thinking policy ids a provider template may name.
///
/// Only `ollama_live`, `openai_chat_effort` and `codex_responses_effort` are
/// capability authorities, and only from provider-reported item metadata.
/// The remaining ids are wire-dialect labels that select a request codec;
/// unlisted routes fall back to [UnknownThinkingPolicy].
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
  registry.register(const OllamaLiveThinkingPolicy());
  return registry;
}

ThinkingCapabilityAssembler buildDefaultThinkingCapabilityAssembler({
  ModelsDevEntryLookup? modelsDevLookup,
}) {
  return ThinkingCapabilityAssembler(
    buildProviderThinkingRegistry(),
    null,
    modelsDevLookup,
  );
}
