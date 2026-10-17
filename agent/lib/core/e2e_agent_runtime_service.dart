import 'dart:io';

import '../engine/adapters/e2e_fixture_adapter.dart';
import '../engine/adapters/llm_adapter.dart';
import 'agent_runtime_service.dart';
import 'provider_runtime/provider_protocol_constants.dart';

/// Test-only route owner that keeps daemon-backed E2E traffic on the complete
/// agent runtime path while replacing external provider I/O deterministically.
class E2eAgentRuntimeService extends AgentRuntimeService {
  E2eAgentRuntimeService(super.config, super.instanceRepository);

  late final LLMAdapter _adapter = E2eFixtureAdapter(
    toolResultMediaCapability:
        Platform.environment['SANAD_E2E_TEXT_ONLY_TOOL_RESULTS'] == 'true'
        ? ToolResultMediaCapability.textOnly
        : ToolResultMediaCapability.imageToolResults,
  );

  @override
  RouteSignature resolveSignature({String? providerId, String? modelId}) {
    return RouteSignature(
      providerInstanceId: E2eFixtureAdapter.providerId,
      templateId: kCustomProviderTemplateId,
      protocol: ProviderProtocol.openaiCompatible,
      normalizedBaseUrl: 'http://127.0.0.1/e2e',
      modelId: E2eFixtureAdapter.modelId,
      configRevision: 1,
      credentialRevision: 1,
    );
  }

  @override
  LLMAdapter adapterFor(RouteSignature signature) => _adapter;
}
