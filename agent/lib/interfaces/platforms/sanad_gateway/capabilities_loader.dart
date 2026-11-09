import 'package:logging/logging.dart';
import 'package:sanad_agent/core/appearance/appearance_store.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/infrastructure/stt/dictation_service.dart';
import 'package:sanad_agent/infrastructure/stt/hosted_dictation_channel.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import 'capabilities.dart';

final _logger = Logger('SanadCapabilitiesLoader');

Future<AgentCapabilities> loadSanadCapabilities({
  AppearanceStore? appearanceStore,
  DictationService? dictation,
}) async {
  final runtimeService = getIt<LocalWorkspaceRuntimeService>();
  final slashCommands = await _searchSlashCommands(runtimeService);
  final store =
      appearanceStore ??
      (getIt.isRegistered<AppearanceStore>()
          ? getIt<AppearanceStore>()
          : const AppearanceStore());
  final appearance = await store.readAppearance();
  _logger.fine(
    'Building device capabilities without provider-backed model discovery.',
  );

  // A capability advertisement is optional context for registration, so a
  // missing or failing source degrades that one capability instead of aborting
  // the whole registration: an unadvertised dictation relay is the correct
  // fail-closed outcome, while an unregistered device loses everything.
  final dictationService =
      dictation ??
      (getIt.isRegistered<DictationService>()
          ? getIt<DictationService>()
          : null);
  final dictationReadiness = dictationService?.readiness();

  return AgentCapabilities(
    displayName: 'Sanad Agent',
    thinkingModes: const [],
    thinkingModeSource: 'model',
    supportsDictation: dictationReadiness?.isSupported ?? false,
    // The Gateway accepts a refusal code only for a device that cannot dictate
    // at all. A supported-but-not-ready device (missing model or native
    // runtime) keeps that typed reason on the live dictation status path, so
    // registration never fails on transient readiness.
    dictationUnavailableReason: dictationReadiness == null ||
            dictationReadiness.isSupported
        ? null
        : dictationReadiness.reason,
    // Advertised only when this Agent can dictate: a device that cannot open a
    // session must not invite a relay route it would have to refuse.
    dictationRelay: dictationReadiness != null && dictationReadiness.isSupported
        ? const DictationRelayLimits().toCapability()
        : null,
    modelSelectionScope: 'message',
    thinkingModeScope: 'message',
    appearance: appearance,
    slashCommands: slashCommands
        .map(
          (command) => SlashCommandOption(
            command: command['command'] as String,
            description: command['description'] as String,
          ),
        )
        .toList(growable: false),
  );
}

/// Slash commands are a discovery convenience: a runtime that cannot enumerate
/// them must not cost the device its registration.
Future<List<Map<String, dynamic>>> _searchSlashCommands(
  LocalWorkspaceRuntimeService runtimeService,
) async {
  try {
    return await runtimeService.searchSlashCommands();
  } on Object catch (error) {
    _logger.warning(
      'Slash command discovery failed; advertising none: ${error.runtimeType}',
    );
    return const [];
  }
}
