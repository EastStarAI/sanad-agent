import 'package:logging/logging.dart';
import 'package:sanad_agent/core/appearance/appearance_store.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import 'capabilities.dart';

final _logger = Logger('SanadCapabilitiesLoader');

Future<AgentCapabilities> loadSanadCapabilities({
  AppearanceStore? appearanceStore,
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

  return AgentCapabilities(
    displayName: 'Sanad Agent',
    thinkingModes: const ['fast', 'balanced', 'deep'],
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
