import 'package:sanad_client/features/conversations/domain/models/slash_command.dart';

enum CapabilityValueScope { session, message, none }

enum ThinkingStreamMode { delta, snapshot, auto }

enum ThinkingModeSource { device, model }

enum WorkspaceScope { session, none }

enum LocalToolRuntimeScope { workspace, device, none }

class Capability {
  static const int defaultAttachmentMaxFileBytes = 5 * 1024 * 1024;
  static const int defaultAttachmentMaxFilesPerMessage = 4;
  static const int defaultAttachmentMaxTotalBytesPerMessage = 20 * 1024 * 1024;

  /// Largest audio frame the dictation relay contract allows.
  static const int dictationRelayContractMaxFrameBytes = 32768;

  /// Contract ceilings for one hosted relay session (§2). An Agent may declare a
  /// smaller value; the Client never assumes these numbers are what the peer
  /// agreed to.
  static const int dictationRelayContractMaxSessionBytes = 12582912;
  static const int dictationRelayContractMaxSessionSeconds = 300;

  /// The only relay version this Client speaks.
  static const int dictationRelayVersion1 = 1;

  final bool supportsModelChange;
  final bool supportsThinkingModeChange;
  final bool supportsVoiceMessage;
  final bool supportsVoiceCall;

  /// Local (daemon-side) dictation is available on this device. True even when
  /// no model is installed yet: the first mic press installs one.
  final bool supportsDictation;

  /// Machine-readable reason when [supportsDictation] is false.
  final String? dictationUnavailableReason;

  /// Hosted relay contract this Agent accepts (`dictation_relay_v1`).
  ///
  /// Absent means the hosted channel is unavailable for this device: the Client
  /// keeps the local-only outcome and never attempts the relay. A version this
  /// build does not know is refused defensively rather than negotiated.
  final int? dictationRelayVersion;

  /// Largest audio frame the Agent declared for the relay, bounded by the
  /// contract maximum; the Client splits capture to it.
  final int dictationRelayMaxFrameBytes;

  /// The declared session byte bound, clamped to the contract maximum.
  final int dictationRelayMaxSessionBytes;

  /// The declared session duration bound in seconds, clamped to the contract
  /// maximum, so a long utterance cannot outlive the peer's admission window.
  final int dictationRelayMaxSessionSeconds;

  /// This Agent produces origin-correlated voice output (`voice_origin_v1`).
  final bool supportsVoiceOrigin;
  final bool supportsStop;
  final bool supportsWorkplace;
  final bool supportsAttachments;
  final int attachmentMaxFileBytes;
  final int attachmentMaxFilesPerMessage;
  final int attachmentMaxTotalBytesPerMessage;
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
  final Map<String, dynamic>? appearance;

  const Capability({
    this.supportsModelChange = false,
    this.supportsThinkingModeChange = false,
    this.supportsVoiceMessage = false,
    this.supportsVoiceCall = false,
    this.supportsDictation = false,
    this.dictationUnavailableReason,
    this.dictationRelayVersion,
    this.dictationRelayMaxFrameBytes = dictationRelayContractMaxFrameBytes,
    this.dictationRelayMaxSessionBytes = dictationRelayContractMaxSessionBytes,
    this.dictationRelayMaxSessionSeconds =
        dictationRelayContractMaxSessionSeconds,
    this.supportsVoiceOrigin = false,
    this.supportsStop = false,
    this.supportsWorkplace = false,
    this.supportsAttachments = false,
    this.attachmentMaxFileBytes = 0,
    this.attachmentMaxFilesPerMessage = 0,
    this.attachmentMaxTotalBytesPerMessage = 0,
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
    this.appearance,
  });

  factory Capability.fromJson(Map<String, dynamic> json) {
    final caps = json['capabilities'] as Map<String, dynamic>? ?? json;
    final attachmentMedia = caps['attachment_media_v1'];
    final attachmentContract = attachmentMedia is Map
        ? Map<String, dynamic>.from(attachmentMedia)
        : const <String, dynamic>{};
    final attachmentVersion = attachmentContract['version'];
    final explicitAttachmentSupport = caps['supports_attachments'];
    final supportsAttachmentMedia = explicitAttachmentSupport is bool
        ? explicitAttachmentSupport
        : attachmentVersion == 1 && attachmentContract['ordered_references'] == true;
    final maxFileBytes = supportsAttachmentMedia
        ? (attachmentContract['max_file_bytes'] as num?)?.toInt() ?? defaultAttachmentMaxFileBytes
        : 0;
    final maxFilesPerMessage = supportsAttachmentMedia
        ? (attachmentContract['max_files_per_message'] as num?)?.toInt() ?? defaultAttachmentMaxFilesPerMessage
        : 0;
    final maxTotalBytesPerMessage = supportsAttachmentMedia
        ? (attachmentContract['max_total_bytes_per_message'] as num?)?.toInt() ??
              defaultAttachmentMaxTotalBytesPerMessage
        : 0;
    final appearanceMap = json['appearance'] is Map
        ? Map<String, dynamic>.from(json['appearance'] as Map)
        : (caps['appearance'] is Map ? Map<String, dynamic>.from(caps['appearance'] as Map) : null);

    return Capability(
      supportsModelChange: caps['supports_model_change'] ?? false,
      supportsThinkingModeChange: caps['supports_thinking_mode_change'] ?? false,
      supportsVoiceMessage: caps['supports_voice_message'] ?? false,
      supportsVoiceCall: caps['supports_voice_call'] ?? false,
      supportsDictation: caps['supports_dictation'] ?? false,
      dictationUnavailableReason:
          caps['dictation_unavailable_reason'] as String?,
      dictationRelayVersion: _parseDictationRelayVersion(
        caps['dictation_relay_v1'],
      ),
      dictationRelayMaxFrameBytes: _parseDictationRelayMaxFrameBytes(
        caps['dictation_relay_v1'],
      ),
      dictationRelayMaxSessionBytes: _parseDictationRelayMaxSessionBytes(
        caps['dictation_relay_v1'],
      ),
      dictationRelayMaxSessionSeconds: _parseDictationRelayMaxSessionSeconds(
        caps['dictation_relay_v1'],
      ),
      supportsVoiceOrigin: caps['voice_origin_v1'] == true,
      supportsStop: caps['supports_stop'] ?? false,
      supportsWorkplace: caps['supports_workplace'] ?? false,
      supportsAttachments: supportsAttachmentMedia,
      attachmentMaxFileBytes: maxFileBytes,
      attachmentMaxFilesPerMessage: maxFilesPerMessage,
      attachmentMaxTotalBytesPerMessage: maxTotalBytesPerMessage,
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
      appearance: appearanceMap,
    );
  }

  /// Whether the hosted dictation relay is usable for this device.
  bool get supportsDictationRelay =>
      supportsDictation &&
      dictationRelayVersion == dictationRelayVersion1;

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is Capability &&
        other.supportsModelChange == supportsModelChange &&
        other.supportsThinkingModeChange == supportsThinkingModeChange &&
        other.supportsVoiceMessage == supportsVoiceMessage &&
        other.supportsVoiceCall == supportsVoiceCall &&
        other.supportsDictation == supportsDictation &&
        other.dictationUnavailableReason == dictationUnavailableReason &&
        other.dictationRelayVersion == dictationRelayVersion &&
        other.dictationRelayMaxFrameBytes == dictationRelayMaxFrameBytes &&
        other.dictationRelayMaxSessionBytes == dictationRelayMaxSessionBytes &&
        other.dictationRelayMaxSessionSeconds ==
            dictationRelayMaxSessionSeconds &&
        other.supportsVoiceOrigin == supportsVoiceOrigin &&
        other.supportsStop == supportsStop &&
        other.supportsWorkplace == supportsWorkplace &&
        other.supportsAttachments == supportsAttachments &&
        other.attachmentMaxFileBytes == attachmentMaxFileBytes &&
        other.attachmentMaxFilesPerMessage == attachmentMaxFilesPerMessage &&
        other.attachmentMaxTotalBytesPerMessage == attachmentMaxTotalBytesPerMessage &&
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
    supportsDictation,
    dictationUnavailableReason,
    dictationRelayVersion,
    dictationRelayMaxFrameBytes,
    dictationRelayMaxSessionBytes,
    dictationRelayMaxSessionSeconds,
    supportsVoiceOrigin,
    supportsStop,
    supportsWorkplace,
    supportsAttachments,
    attachmentMaxFileBytes,
    attachmentMaxFilesPerMessage,
    attachmentMaxTotalBytesPerMessage,
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

  /// `dictation_relay_v1.version`, present and equal to 1 only.
  ///
  /// A missing block, a wrong type, or a version this build does not speak all
  /// resolve to null, so the hosted channel is treated as unavailable instead of
  /// negotiated. Malformed recognized capability is rejected at the producer
  /// boundary; the Client still refuses defensively.
  static int? _parseDictationRelayVersion(dynamic raw) {
    if (raw is! Map) return null;
    final version = raw['version'];
    if (version is int && version == dictationRelayVersion1) return version;
    if (version == '$dictationRelayVersion1') return dictationRelayVersion1;
    return null;
  }

  /// The declared frame bound, clamped to the contract maximum.
  static int _parseDictationRelayMaxFrameBytes(dynamic raw) {
    final declared = raw is Map ? (raw['max_frame_bytes'] as num?)?.toInt() : null;
    if (declared == null || declared <= 0) {
      return dictationRelayContractMaxFrameBytes;
    }
    return declared < dictationRelayContractMaxFrameBytes
        ? declared
        : dictationRelayContractMaxFrameBytes;
  }

  /// The declared session byte bound, clamped to the contract maximum.
  static int _parseDictationRelayMaxSessionBytes(dynamic raw) {
    final declared = raw is Map ? (raw['max_session_bytes'] as num?)?.toInt() : null;
    if (declared == null || declared <= 0) {
      return dictationRelayContractMaxSessionBytes;
    }
    return declared < dictationRelayContractMaxSessionBytes
        ? declared
        : dictationRelayContractMaxSessionBytes;
  }

  /// The declared session duration bound, clamped to the contract maximum.
  static int _parseDictationRelayMaxSessionSeconds(dynamic raw) {
    final declared =
        raw is Map ? (raw['max_session_seconds'] as num?)?.toInt() : null;
    if (declared == null || declared <= 0) {
      return dictationRelayContractMaxSessionSeconds;
    }
    return declared < dictationRelayContractMaxSessionSeconds
        ? declared
        : dictationRelayContractMaxSessionSeconds;
  }

  static CapabilityValueScope _parseScope(dynamic raw) {    switch ((raw ?? '').toString().toLowerCase()) {
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
  bool get usesModelThinkingControls => thinkingModeSource == ThinkingModeSource.model;

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
