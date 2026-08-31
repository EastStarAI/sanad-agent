/// Shared model option DTO used internally by provider/model runtime services.
///
/// It is intentionally kept separate from the external `capabilities` payload:
/// device capabilities must stay available even when no provider instance is
/// configured yet.
library;

import 'package:sanad_agent/core/provider_thinking/thinking_control_models.dart';

class ModelOption {
  final String value;
  final String label;
  final String? provider;
  final int? contextWindow;
  final bool supportsReasoning;
  final ThinkingControlDescriptor? thinkingControl;
  final Map<String, Object?> modelMetadata;

  ModelOption({
    required this.value,
    required this.label,
    this.provider,
    this.contextWindow,
    this.supportsReasoning = false,
    this.thinkingControl,
    this.modelMetadata = const {},
  });

  /// Whether the model may emit reasoning output regardless of user control.
  bool get supportsReasoningOutput => supportsReasoning;

  ModelOption copyWith({
    String? value,
    String? label,
    String? provider,
    int? contextWindow,
    bool? supportsReasoning,
    ThinkingControlDescriptor? thinkingControl,
    Map<String, Object?>? modelMetadata,
  }) {
    return ModelOption(
      value: value ?? this.value,
      label: label ?? this.label,
      provider: provider ?? this.provider,
      contextWindow: contextWindow ?? this.contextWindow,
      supportsReasoning: supportsReasoning ?? this.supportsReasoning,
      thinkingControl: thinkingControl ?? this.thinkingControl,
      modelMetadata: modelMetadata ?? this.modelMetadata,
    );
  }

  Map<String, dynamic> toJson() => {
    'value': value,
    'label': label,
    if (provider != null) 'provider': provider,
    if (contextWindow != null) 'context_window': contextWindow,
    'supports_reasoning': supportsReasoning,
    'supports_reasoning_output': supportsReasoningOutput,
    if (modelMetadata.isNotEmpty) 'model_metadata': modelMetadata,
    if (thinkingControl != null) 'thinking_control': thinkingControl!.toMap(),
  };

  factory ModelOption.fromJson(Map<String, dynamic> json) {
    return ModelOption(
      value: json['value'] as String,
      label: json['label'] as String,
      provider: json['provider'] as String?,
      contextWindow: json['context_window'] as int?,
      supportsReasoning:
          json['supports_reasoning_output'] as bool? ??
          json['supports_reasoning'] as bool? ??
          false,
      modelMetadata: _modelMetadataFromJson(json['model_metadata']),
      thinkingControl: _thinkingControlFromJson(json['thinking_control']),
    );
  }

  static Map<String, Object?> _modelMetadataFromJson(Object? raw) {
    if (raw is Map<String, Object?>) {
      return Map<String, Object?>.from(raw);
    }
    if (raw is Map) {
      return raw.map((key, value) => MapEntry(key.toString(), value));
    }
    return const {};
  }

  static ThinkingControlDescriptor? _thinkingControlFromJson(Object? raw) {
    if (raw is Map<String, dynamic>) {
      return ThinkingControlDescriptor.fromMap(raw);
    }
    if (raw is Map) {
      return ThinkingControlDescriptor.fromMap(
        raw.map((key, value) => MapEntry(key.toString(), value)),
      );
    }
    return null;
  }
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
  final String thinkingModeSource;

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
    this.thinkingModes = const [],
    this.thinkingModeSource = 'model',
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
      'thinking_mode_source': thinkingModeSource,
      'supports_stop': supportsStop,
      'supports_update_session_name': supportsUpdateSessionName,
      'supports_delete_session': supportsDeleteSession,
      'supports_workspaces': supportsWorkspaces,
      'workspace_required': workspaceRequired,
      'supports_workspace_selection': supportsWorkspaceSelection,
      'supports_tool_permissions': supportsToolPermissions,
      'supports_local_tool_runtime': supportsLocalToolRuntime,
      'supports_slash_commands': supportsSlashCommands,
      'model_selection_scope': modelSelectionScope,
      'thinking_mode_scope': thinkingModeScope,
      'thinking_stream_mode': thinkingStreamMode,
      'workspace_scope': workspaceScope,
      'local_tool_runtime_scope': localToolRuntimeScope,
      'tool_protocol_version': toolProtocolVersion,
      'permission_modes': permissionModes,
      'approval_scopes': approvalScopes,
      'thinking_modes_list': thinkingModeSource == 'model' ? const [] : thinkingModes,
      'slash_commands_list': slashCommands
          .map((command) => command.toJson())
          .toList(),
    },
  };
}
