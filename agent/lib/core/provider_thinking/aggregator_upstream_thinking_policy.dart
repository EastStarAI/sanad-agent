/// Aggregator thinking policy that delegates to upstream model policies.
library;

import 'aggregator_upstream_catalog.dart';
import 'anthropic_thinking_policy.dart';
import 'deepseek_thinking_policy.dart';
import 'google_thinking_policy.dart';
import 'kimi_thinking_policy.dart';
import 'native_thinking_directive.dart';
import 'openai_chat_effort_thinking_policy.dart';
import 'provider_thinking_policy.dart';
import 'thinking_control_models.dart';
import 'thinking_policy_context.dart';
import 'unknown_thinking_policy.dart';
import 'zai_thinking_policy.dart';

class AggregatorUpstreamThinkingPolicy implements ProviderThinkingPolicy {
  AggregatorUpstreamThinkingPolicy({
    OpenAiChatEffortThinkingPolicy? openAi,
    AnthropicThinkingPolicy? anthropic,
    GoogleThinkingPolicy? google,
    DeepSeekThinkingPolicy? deepSeek,
    KimiThinkingPolicy? kimi,
    ZaiThinkingPolicy? zai,
    UnknownThinkingPolicy? unknown,
  }) : openAi = openAi ?? const OpenAiChatEffortThinkingPolicy(),
       anthropic = anthropic ?? const AnthropicThinkingPolicy(),
       google = google ?? const GoogleThinkingPolicy(),
       deepSeek = deepSeek ?? const DeepSeekThinkingPolicy(),
       kimi = kimi ?? const KimiThinkingPolicy(),
       zai = zai ?? const ZaiThinkingPolicy(),
       unknown = unknown ?? UnknownThinkingPolicy();

  final OpenAiChatEffortThinkingPolicy openAi;
  final AnthropicThinkingPolicy anthropic;
  final GoogleThinkingPolicy google;
  final DeepSeekThinkingPolicy deepSeek;
  final KimiThinkingPolicy kimi;
  final ZaiThinkingPolicy zai;
  final UnknownThinkingPolicy unknown;

  @override
  String get policyId => 'aggregator_upstream';

  ProviderThinkingPolicy _delegateFor(String modelId) {
    return switch (AggregatorUpstreamCatalog.upstreamPolicyIdForModel(
      modelId,
    )) {
      'anthropic_thinking' => anthropic,
      'google_thinking' => google,
      'deepseek_thinking' => deepSeek,
      'kimi_thinking' => kimi,
      'zai_thinking' => zai,
      'openai_chat_effort' => openAi,
      _ => unknown,
    };
  }

  @override
  ThinkingControlDescriptor resolveCapability(ThinkingPolicyContext context) {
    return _delegateFor(context.modelId).resolveCapability(context);
  }

  @override
  NativeThinkingDirective resolveDirective(
    ThinkingPolicyContext context,
    String? selectionId,
  ) {
    return _delegateFor(context.modelId).resolveDirective(context, selectionId);
  }
}
