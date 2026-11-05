import 'dart:async';

import 'package:sanad_client/features/provider_setup/data/models/provider_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_instance_dto.dart';
import 'package:sanad_client/features/provider_setup/data/models/provider_template_dto.dart';

/// Copy reported when a credential was stored but its connection could not be
/// proven. The typed cause travels beside it in
/// `ProviderSetupState.verificationFailure` and is what the user actually reads.
const String unverifiedApiKeyMessage =
    'The API key was saved, but its connection could not be verified.';

/// Flattens a transport/setup failure into a bounded setup message.
///
/// The parallel provider snapshot aggregates failures into `ParallelWaitError`;
/// surface the first underlying failure so diagnostics stay specific.
String friendlySetupError(Object error, String fallback) {
  Object candidate = error;
  if (candidate is ParallelWaitError) {
    final errors = candidate.errors as (AsyncError?, AsyncError?, AsyncError?);
    final first = errors.$1 ?? errors.$2 ?? errors.$3;
    if (first != null) candidate = first.error;
  }
  if (candidate is ArgumentError) {
    return candidate.message?.toString() ?? fallback;
  }
  return fallback;
}

/// Projects templates plus configured instances onto the picker catalog.
///
/// Owned outside the cubit so the setup state machine only orchestrates, and so
/// the "one configured instance per template" rule has a single implementation.
List<ProviderDto> mapProvidersToCatalog(
  List<ProviderTemplateDto> templates,
  List<ProviderInstanceDto> instances,
) {
  return templates.map((template) {
    final configuredInstance = instances
        .where((instance) => instance.templateId == template.name)
        .firstOrNull;
    return ProviderDto(
      id: template.name,
      name: template.name,
      displayName: template.displayName,
      description: template.description,
      defaultBaseUrl: template.defaultBaseUrl,
      keyEnv: template.keyEnv,
      envModelName: template.envModelName,
      envBaseUrlName: template.envBaseUrlName,
      authType: template.authType,
      authFlow: template.authFlow,
      apiMode: template.apiMode,
      docsUrl: template.docsUrl,
      supportsModelFetch: template.supportsModelFetch,
      disconnectable: template.disconnectable,
      fallbackModels: template.fallbackModels,
      aliases: template.aliases,
      configured: configuredInstance != null,
      authenticated: configuredInstance?.status == 'ready',
      isCurrent: configuredInstance?.isDefault ?? false,
      models: configuredInstance?.defaultModel != null
          ? [configuredInstance!.defaultModel!]
          : const [],
      selectedModel: configuredInstance?.defaultModel,
      authStatus: configuredInstance?.status ?? 'missing',
    );
  }).toList();
}
