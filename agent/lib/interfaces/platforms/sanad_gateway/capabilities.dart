/// Shared model option DTO used internally by provider/model runtime services.
///
/// It is intentionally kept separate from the external `capabilities` payload:
/// device capabilities must stay available even when no provider instance is
/// configured yet.
class ModelOption {
  final String value;
  final String label;
  final String? provider;
  final int? contextWindow;
  final bool supportsReasoning;

  ModelOption({
    required this.value,
    required this.label,
    this.provider,
    this.contextWindow,
    this.supportsReasoning = false,
  });

  Map<String, dynamic> toJson() => {
    'value': value,
    'label': label,
    if (provider != null) 'provider': provider,
    if (contextWindow != null) 'context_window': contextWindow,
    'supports_reasoning': supportsReasoning,
  };
}

class SlashCommandOption {
  final String command;
  final String description;

  const SlashCommandOption({required this.command, required this.description});

  Map<String, dynamic> toJson() => {
    'command': command,
    'description': description,
  };
}

/// Defines the capabilities of the Sanad Agent following Protocol v1.
class AgentCapabilities {
  final String displayName;
  final String protocolVersion;
  final String bridgeVersion;

  final List<String> thinkingModes;

  final bool supportsModelChange;
  final bool supportsThinkingModeChange;
  final bool supportsStop;
  final bool supportsUpdateSessionName;
  final bool supportsDeleteSession;
  final bool supportsWorkspaces;
  final bool workspaceRequired;
  final bool supportsWorkspaceSelection;
  final bool supportsToolPermissions;
  final bool supportsLocalToolRuntime;
  final bool supportsSlashCommands;

  final String modelSelectionScope;
  final String thinkingModeScope;
  final String thinkingStreamMode;
  final String workspaceScope;
  final String localToolRuntimeScope;
  final String toolProtocolVersion;
  final List<String> permissionModes;
  final List<String> approvalScopes;
  final List<SlashCommandOption> slashCommands;

  AgentCapabilities({
    required this.displayName,
    this.protocolVersion = 'v1',
    this.bridgeVersion = '1.0.0',
    this.thinkingModes = const ['balanced'],
    this.supportsModelChange = true,
    this.supportsThinkingModeChange = true,
    this.supportsStop = true,
    this.supportsUpdateSessionName = true,
    this.supportsDeleteSession = true,
    this.supportsWorkspaces = true,
    this.workspaceRequired = false,
    this.supportsWorkspaceSelection = true,
    this.supportsToolPermissions = true,
    this.supportsLocalToolRuntime = true,
    this.supportsSlashCommands = true,
    this.modelSelectionScope = 'session',
    this.thinkingModeScope = 'session',
    this.thinkingStreamMode = 'delta',
    this.workspaceScope = 'session',
    this.localToolRuntimeScope = 'workspace',
    this.toolProtocolVersion = 'tools.v2',
    this.permissionModes = const ['default'],
    this.approvalScopes = const ['once', 'session', 'workspace'],
    this.slashCommands = const [],
  });

  Map<String, dynamic> toJson() => {
    'display_name': displayName,
    'protocol_version': protocolVersion,
    'bridge_version': bridgeVersion,
    'capabilities': {
      'supports_model_change': supportsModelChange,
      'supports_thinking_mode_change': supportsThinkingModeChange,
      'supports_stop': supportsStop,
      'supports_update_session_name': supportsUpdateSessionName,
      'supports_delete_session': supportsDeleteSession,
      'supports_workspaces': supportsWorkspaces,
      'workspace_required': workspaceRequired,
      'supports_workspace_selection': supportsWorkspaceSelection,
      'supports_tool_permissions': supportsToolPermissions,
      'supports_local_tool_runtime': supportsLocalToolRuntime,
      'supports_slash_commands': supportsSlashCommands,
      'delivery_presence_v1': true,
      'model_selection_scope': modelSelectionScope,
      'thinking_mode_scope': thinkingModeScope,
      'thinking_stream_mode': thinkingStreamMode,
      'workspace_scope': workspaceScope,
      'local_tool_runtime_scope': localToolRuntimeScope,
      'tool_protocol_version': toolProtocolVersion,
      'permission_modes': permissionModes,
      'approval_scopes': approvalScopes,
      'thinking_modes_list': thinkingModes,
      'slash_commands_list': slashCommands
          .map((command) => command.toJson())
          .toList(),
    },
  };
}
