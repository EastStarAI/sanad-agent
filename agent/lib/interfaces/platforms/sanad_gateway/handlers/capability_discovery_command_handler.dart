import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import 'support/agent_event_envelope.dart';

/// Handles skills and slash-command discovery.
class CapabilityDiscoveryCommandHandler {
  final LocalWorkspaceRuntimeService _runtimeService;

  CapabilityDiscoveryCommandHandler({
    required LocalWorkspaceRuntimeService runtimeService,
  }) : _runtimeService = runtimeService;

  Future<Map<String, dynamic>> buildSlashCommandsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final query = event.payload['query'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final commands = await _runtimeService.searchSlashCommands(
      query: query,
      workspaceId: workspaceId,
    );

    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.slashCommandsList,
        payload: {
          'request_id': requestId,
          'query': query,
          'workspace_id': workspaceId,
          'commands': commands,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildSkillsEnvelope(CanonicalEvent event) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final includeShadowed =
        event.payload['include_shadowed'] as bool? ?? workspaceId != null;
    final inventory = await _runtimeService.listSkills(
      workspaceId: workspaceId,
      includeShadowed: includeShadowed,
    );

    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.skillsList,
        payload: {
          'request_id': requestId,
          'workspace_id': workspaceId,
          ...inventory,
        },
      ),
    );
  }
}
