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
  final slashCommands = await runtimeService.searchSlashCommands();
  final store =
      appearanceStore ??
      (getIt.isRegistered<AppearanceStore>()
          ? getIt<AppearanceStore>()
          : const AppearanceStore());
  final appearance = await store.readAppearance();
  _logger.fine(
    'Building device capabilities without provider-backed model discovery.',
  );

  final dictationService = dictation ?? getIt<DictationService>();
  final dictationReadiness = dictationService.readiness();

  return AgentCapabilities(
    displayName: 'Sanad Agent',
    thinkingModes: const [],
    thinkingModeSource: 'model',
    supportsDictation: dictationReadiness.isSupported,
    // The Gateway accepts a refusal code only for a device that cannot dictate
    // at all. A supported-but-not-ready device (missing model or native
    // runtime) keeps that typed reason on the live dictation status path, so
    // registration never fails on transient readiness.
    dictationUnavailableReason: dictationReadiness.isSupported
        ? null
        : dictationReadiness.reason,
    // Advertised only when this Agent can dictate: a device that cannot open a
    // session must not invite a relay route it would have to refuse.
    dictationRelay: dictationReadiness.isSupported
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
