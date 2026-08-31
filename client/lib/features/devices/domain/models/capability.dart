import 'package:sanad_client/features/conversations/domain/models/slash_command.dart';

enum CapabilityValueScope { session, message, none }

enum ThinkingStreamMode { delta, snapshot, auto }

enum ThinkingModeSource { device, model }

enum WorkspaceScope { session, none }

enum LocalToolRuntimeScope { workspace, device, none }

class Capability {
  final bool supportsModelChange;
  final bool supportsThinkingModeChange;
  final bool supportsVoiceMessage;
  final bool supportsVoiceCall;
  final bool supportsStop;
  final bool supportsWorkplace;
  final bool supportsAttachments;
  final bool supportsUpdateSessionName;
  final bool supportsDeleteSession;
  final bool supportsSlashCommands;
  final bool supportsWorkspaces;
  final bool workspaceRequired;
  final WorkspaceScope workspaceScope;
  final bool supportsWorkspaceSelection;
  final bool supportsLocalToolRuntime;
  final bool supportsToolPermissions;
  final bool supportsToolApprovals;
  final List<String> permissionModes;
  final List<String> permissionCategories;
  final List<String> approvalScopes;
  final LocalToolRuntimeScope localToolRuntimeScope;
  final String? toolProtocolVersion;
  final CapabilityValueScope modelSelectionScope;
  final CapabilityValueScope thinkingModeScope;
  final ThinkingStreamMode thinkingStreamMode;
  final ThinkingModeSource thinkingModeSource;

  final List<String> thinkingModesList;
  final List<String> workplacesList;
  final List<SlashCommand> slashCommandsList;

  const Capability({
    this.supportsModelChange = false,
    this.supportsThinkingModeChange = false,
    this.supportsVoiceMessage = false,
    this.supportsVoiceCall = false,
    this.supportsStop = false,
    this.supportsWorkplace = false,
    this.supportsAttachments = false,
    this.supportsUpdateSessionName = false,
    this.supportsDeleteSession = false,
    this.supportsSlashCommands = false,
    this.supportsWorkspaces = false,
    this.workspaceRequired = false,
    this.workspaceScope = WorkspaceScope.none,
    this.supportsWorkspaceSelection = false,
    this.supportsLocalToolRuntime = false,
    this.supportsToolPermissions = false,
    this.supportsToolApprovals = false,
    this.permissionModes = const [],
    this.permissionCategories = const [],
    this.approvalScopes = const [],
    this.localToolRuntimeScope = LocalToolRuntimeScope.none,
    this.toolProtocolVersion,
    this.modelSelectionScope = CapabilityValueScope.none,
    this.thinkingModeScope = CapabilityValueScope.none,
    this.thinkingStreamMode = ThinkingStreamMode.auto,
    this.thinkingModeSource = ThinkingModeSource.device,
    this.thinkingModesList = const [],
    this.workplacesList = const [],
    this.slashCommandsList = const [],
  });

  factory Capability.fromJson(Map<String, dynamic> json) {
    final caps = json['capabilities'] as Map<String, dynamic>? ?? json;

    return Capability(
      supportsModelChange: caps['supports_model_change'] ?? false,
      supportsThinkingModeChange: caps['supports_thinking_mode_change'] ?? false,
      supportsVoiceMessage: caps['supports_voice_message'] ?? false,
      supportsVoiceCall: caps['supports_voice_call'] ?? false,
      supportsStop: caps['supports_stop'] ?? false,
      supportsWorkplace: caps['supports_workplace'] ?? false,
      supportsAttachments: caps['supports_attachments'] ?? false,
      supportsUpdateSessionName: caps['supports_update_session_name'] ?? false,
      supportsDeleteSession: caps['supports_delete_session'] ?? false,
      supportsSlashCommands: caps['supports_slash_commands'] ?? false,
      supportsWorkspaces: caps['supports_workspaces'] ?? false,
      workspaceRequired: caps['workspace_required'] ?? false,
      workspaceScope: _parseWorkspaceScope(caps['workspace_scope']),
      supportsWorkspaceSelection: caps['supports_workspace_selection'] ?? false,
      supportsLocalToolRuntime: caps['supports_local_tool_runtime'] ?? false,
      supportsToolPermissions: caps['supports_tool_permissions'] ?? false,
      supportsToolApprovals: caps['supports_tool_approvals'] ?? false,
      permissionModes: List<String>.from(caps['permission_modes'] ?? []),
      permissionCategories: List<String>.from(caps['permission_categories'] ?? []),
      approvalScopes: List<String>.from(caps['approval_scopes'] ?? []),
      localToolRuntimeScope: _parseLocalToolRuntimeScope(caps['local_tool_runtime_scope']),
      toolProtocolVersion: caps['tool_protocol_version']?.toString(),
      modelSelectionScope: _parseScope(caps['model_selection_scope']),
      thinkingModeScope: _parseScope(caps['thinking_mode_scope']),
      thinkingStreamMode: _parseThinkingStreamMode(caps['thinking_stream_mode']),
      thinkingModeSource: _parseThinkingModeSource(caps['thinking_mode_source']),
      thinkingModesList: _parseThinkingModesList(
        source: _parseThinkingModeSource(caps['thinking_mode_source']),
        rawList: caps['thinking_modes_list'],
      ),
      workplacesList: List<String>.from(caps['workplaces_list'] ?? []),
      slashCommandsList: (caps['slash_commands_list'] as List? ?? [])
          .map((e) => SlashCommand.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Capability &&
        other.supportsModelChange == supportsModelChange &&
        other.supportsThinkingModeChange == supportsThinkingModeChange &&
        other.supportsVoiceMessage == supportsVoiceMessage &&
        other.supportsVoiceCall == supportsVoiceCall &&
        other.supportsStop == supportsStop &&
        other.supportsWorkplace == supportsWorkplace &&
        other.supportsAttachments == supportsAttachments &&
        other.supportsUpdateSessionName == supportsUpdateSessionName &&
        other.supportsDeleteSession == supportsDeleteSession &&
        other.supportsSlashCommands == supportsSlashCommands &&
        other.supportsWorkspaces == supportsWorkspaces &&
        other.workspaceRequired == workspaceRequired &&
        other.workspaceScope == workspaceScope &&
        other.supportsWorkspaceSelection == supportsWorkspaceSelection &&
        other.supportsLocalToolRuntime == supportsLocalToolRuntime &&
        other.supportsToolPermissions == supportsToolPermissions &&
        other.supportsToolApprovals == supportsToolApprovals &&
        _listEquals(other.permissionModes, permissionModes) &&
        _listEquals(other.permissionCategories, permissionCategories) &&
        _listEquals(other.approvalScopes, approvalScopes) &&
        other.localToolRuntimeScope == localToolRuntimeScope &&
        other.toolProtocolVersion == toolProtocolVersion &&
        other.modelSelectionScope == modelSelectionScope &&
        other.thinkingModeScope == thinkingModeScope &&
        other.thinkingStreamMode == thinkingStreamMode &&
        other.thinkingModeSource == thinkingModeSource &&
        _listEquals(other.thinkingModesList, thinkingModesList) &&
        _listEquals(other.workplacesList, workplacesList) &&
        _listEquals(other.slashCommandsList, slashCommandsList);
  }

  @override
  int get hashCode => Object.hashAll([
    supportsModelChange,
    supportsThinkingModeChange,
    supportsVoiceMessage,
    supportsVoiceCall,
    supportsStop,
    supportsWorkplace,
    supportsAttachments,
    supportsUpdateSessionName,
    supportsDeleteSession,
    supportsSlashCommands,
    supportsWorkspaces,
    workspaceRequired,
    workspaceScope,
    supportsWorkspaceSelection,
    supportsLocalToolRuntime,
    supportsToolPermissions,
    supportsToolApprovals,
    Object.hashAll(permissionModes),
    Object.hashAll(permissionCategories),
    Object.hashAll(approvalScopes),
    localToolRuntimeScope,
    toolProtocolVersion,
    modelSelectionScope,
    thinkingModeScope,
    thinkingStreamMode,
    thinkingModeSource,
    Object.hashAll(thinkingModesList),
    Object.hashAll(workplacesList),
    Object.hashAll(slashCommandsList),
  ]);

  static bool _listEquals<T>(List<T> a, List<T> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i += 1) {
      if (a[i] != b[i]) return false;
    }
    return true;
  }

  static CapabilityValueScope _parseScope(dynamic raw) {
    switch ((raw ?? '').toString().toLowerCase()) {
      case 'session':
        return CapabilityValueScope.session;
      case 'message':
        return CapabilityValueScope.message;
      default:
        return CapabilityValueScope.none;
    }
  }

  static ThinkingStreamMode _parseThinkingStreamMode(dynamic raw) {
    switch ((raw ?? '').toString().toLowerCase()) {
      case 'delta':
        return ThinkingStreamMode.delta;
      case 'snapshot':
        return ThinkingStreamMode.snapshot;
      default:
        return ThinkingStreamMode.auto;
    }
  }

  static ThinkingModeSource _parseThinkingModeSource(dynamic raw) {
    switch ((raw ?? '').toString().toLowerCase()) {
      case 'model':
        return ThinkingModeSource.model;
      default:
        return ThinkingModeSource.device;
    }
  }

  static List<String> _parseThinkingModesList({
    required ThinkingModeSource source,
    required dynamic rawList,
  }) {
    if (source == ThinkingModeSource.model) {
      return const [];
    }
    return List<String>.from(rawList ?? []);
  }

  /// Whether thinking options must come from the active model snapshot.
  bool get usesModelThinkingControls =>
      thinkingModeSource == ThinkingModeSource.model;

  static WorkspaceScope _parseWorkspaceScope(dynamic raw) {
    switch ((raw ?? '').toString().toLowerCase()) {
      case 'session':
      case 'thread':
        return WorkspaceScope.session;
      default:
        return WorkspaceScope.none;
    }
  }

  static LocalToolRuntimeScope _parseLocalToolRuntimeScope(dynamic raw) {
    switch ((raw ?? '').toString().toLowerCase()) {
      case 'workspace':
        return LocalToolRuntimeScope.workspace;
      case 'device':
        return LocalToolRuntimeScope.device;
      default:
        return LocalToolRuntimeScope.none;
    }
  }
}
