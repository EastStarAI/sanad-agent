import 'package:logging/logging.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import 'capabilities.dart';

final _logger = Logger('SanadCapabilitiesLoader');

Future<AgentCapabilities> loadSanadCapabilities() async {
  final runtimeService = getIt<LocalWorkspaceRuntimeService>();
  final slashCommands = await runtimeService.searchSlashCommands();
  _logger.fine(
    'Building device capabilities without provider-backed model discovery.',
  );

  return AgentCapabilities(
    displayName: 'Sanad Agent',
    thinkingModes: const [],
    thinkingModeSource: 'model',
    modelSelectionScope: 'message',
    thinkingModeScope: 'message',
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
