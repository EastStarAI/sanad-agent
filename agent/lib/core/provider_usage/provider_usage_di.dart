/// DI wiring for the provider usage subsystem (Task 55 Gate A).
///
/// Builds the [ProviderUsageRegistry] with the ChatGPT adapter registered. New
/// adapters for future API-key providers plug in here without touching the
/// model surface, the protocol bridge, or the client.
library;

import 'provider_usage_adapter.dart';
import 'chatgpt_usage_adapter.dart';
import 'http_provider_usage_client.dart';
import 'opencode_go_usage_adapter.dart';

/// Builds and returns the daemon-wide [ProviderUsageRegistry] with all v1
/// adapters registered. Called once during DI setup.
ProviderUsageRegistry buildProviderUsageRegistry() {
  final registry = ProviderUsageRegistry();
  registry.register(ChatGptUsageAdapter());
  registry.register(OpenCodeGoUsageAdapter());
  return registry;
}

/// Default production HTTP client factory.
ProviderUsageHttpClient defaultProductionHttpClient() =>
    defaultHttpClientFactory();
