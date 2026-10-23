import 'package:sanad_agent/capabilities/models/local_tool_spec.dart';
import 'package:sanad_agent/capabilities/permissions/permission_manager.dart';
import 'package:sanad_agent/capabilities/tools/base_tool.dart';
import 'package:sanad_agent/capabilities/tools/runtime/spec_backed_tool.dart';
import 'package:sanad_agent/core/config.dart';
import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/models/agent_turn_request.dart';
import 'package:sanad_agent/interfaces/runtime/platform_runtime_bridge.dart';

/// Platform tool builders for `LocalRuntimeCatalog`.
///
/// Platform tools enter the turn only as explicit turn-scoped specifications and
/// keep their platform source/target metadata. Every platform call still passes
/// `PermissionManager` before the runtime bridge, and tools the local runtime
/// already owns (shell, and computer use when enabled) are excluded so one
/// capability never has two execution paths.
List<BaseTool> buildPlatformTools({
  required AgentTurnRequest request,
  required PlatformRuntimeBridge platformRuntimeBridge,
  required PermissionManager permissionManager,
}) {
  final hasConfig = getIt.isRegistered<Config>();
  final computerUse = hasConfig && getIt<Config>().computerUse;
  final excludedTools = {
    'shell_execute',
    if (computerUse) ...{
      'system_screenshot',
      'system_mouse',
      'system_keyboard',
    },
  };

  return request.platformTools
      .map(_platformSpecFromPayload)
      .whereType<LocalToolSpec>()
      .where((spec) => !excludedTools.contains(spec.name))
      .map(
        (spec) => CallbackTool(
          toolSpec: spec,
          onExecute: (args, {context}) async {
            final toolContext =
                context ??
                ToolContext(
                  sessionId: request.sessionId,
                  metadata: request.toMetadata(),
                );
            await permissionManager.ensureAuthorized(
              tool: spec,
              arguments: args,
              context: toolContext,
            );
            return platformRuntimeBridge.executePlatformTool(
              sessionId: toolContext.sessionId,
              payload: {
                'tool_name': spec.name,
                'tool_input': args,
                'tool': spec.toJson(),
                'workspace_id': request.effectiveWorkspaceId,
                'session_id': request.sessionId,
              },
            );
          },
        ),
      )
      .toList(growable: false);
}

LocalToolSpec? _platformSpecFromPayload(Map<String, dynamic> payload) {
  final name = payload['name']?.toString().trim();
  if (name == null || name.isEmpty) {
    return null;
  }

  final displayName =
      payload['display_name']?.toString().trim().isNotEmpty == true
      ? payload['display_name'].toString().trim()
      : name;
  final description =
      payload['description']?.toString().trim().isNotEmpty == true
      ? payload['description'].toString().trim()
      : 'Platform-provided tool exposed by the connected client.';
  final inputSchema = payload['input_schema'] is Map<String, dynamic>
      ? Map<String, dynamic>.from(
          payload['input_schema'] as Map<String, dynamic>,
        )
      : payload['input_schema'] is Map
      ? Map<String, dynamic>.from(payload['input_schema'] as Map)
      : const {
          'type': 'object',
          'properties': <String, dynamic>{},
          'additionalProperties': true,
        };
  final approval = payload['approval'] is Map<String, dynamic>
      ? Map<String, dynamic>.from(payload['approval'] as Map<String, dynamic>)
      : payload['approval'] is Map
      ? Map<String, dynamic>.from(payload['approval'] as Map)
      : <String, dynamic>{};
  final availability = payload['availability'] is Map<String, dynamic>
      ? Map<String, dynamic>.from(
          payload['availability'] as Map<String, dynamic>,
        )
      : payload['availability'] is Map
      ? Map<String, dynamic>.from(payload['availability'] as Map)
      : const {'status': 'available'};

  return LocalToolSpec(
    name: name,
    displayName: displayName,
    description: description,
    inputSchema: inputSchema,
    source: {
      'type': 'platform',
      'owner': 'platform',
      'id': payload['platform_id']?.toString() ?? 'connected-client',
    },
    category: payload['category']?.toString() ?? 'platform',
    workspaceRequired: payload['workspace_required'] == true,
    approval: {
      'mode': approval['mode']?.toString() ?? 'default',
      'sensitive': approval['sensitive'] == true,
      'scope': approval['scope']?.toString() ?? 'session',
      'permission_class':
          approval['permission_class']?.toString() ??
          payload['permission_class']?.toString() ??
          'platform',
    },
    execution: {
      'target': 'platform',
      if (payload['execution'] is Map)
        ...Map<String, dynamic>.from(payload['execution'] as Map),
    },
    availability: availability,
    serverName: payload['server_name']?.toString(),
  );
}
