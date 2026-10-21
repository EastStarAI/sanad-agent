import 'package:equatable/equatable.dart';

/// A persisted draft for one conversation identity.
///
/// Drafts are keyed differently for existing sessions vs the New Conversation
/// surface:
/// - Existing session: `deviceId + sessionId`.
/// - New Conversation: a per-device standalone key (see
///   [ConversationDraft.isNewConversation]).
///
/// Autosave is debounced and flushed on lifecycle pause/close. The draft text
/// is preserved through a failed send and is only cleared once the daemon emits
/// the canonical `user_message` acceptance matching the outgoing request.
class ConversationDraft extends Equatable {
  /// Free text the user has typed.
  final String text;

  /// Optional workspace for a New Conversation draft. Ignored for existing
  /// sessions, whose workspace is fixed after creation.
  final String? workspaceId;

  final String? providerId;
  final String? model;
  final String? thinkingMode;
  final String? permissionMode;

  /// Request whose canonical `user_message` acceptance may clear this draft.
  /// A different acceptance must never discard text the user is still editing.
  final String? pendingRequestId;
  final Set<String> appliedStopRecoveryIds;
  final Set<String> pendingStopRecoveryIds;
  final Map<String, String> stopRecoveryClaimIds;
  final Map<String, String> stopRecoveryOwnerTokens;

  /// Wall-clock time of the last edit; used for tie-breaking and flush order.
  final DateTime updatedAt;

  const ConversationDraft({
    required this.text,
    required this.workspaceId,
    required this.providerId,
    required this.model,
    required this.thinkingMode,
    required this.permissionMode,
    this.pendingRequestId,
    this.appliedStopRecoveryIds = const {},
    this.pendingStopRecoveryIds = const {},
    this.stopRecoveryClaimIds = const {},
    this.stopRecoveryOwnerTokens = const {},
    required this.updatedAt,
  });

  factory ConversationDraft.empty() => ConversationDraft(
    text: '',
    workspaceId: null,
    providerId: null,
    model: null,
    thinkingMode: null,
    permissionMode: null,
    pendingRequestId: null,
    appliedStopRecoveryIds: const {},
    pendingStopRecoveryIds: const {},
    stopRecoveryClaimIds: const {},
    stopRecoveryOwnerTokens: const {},
    updatedAt: DateTime.fromMillisecondsSinceEpoch(0, isUtc: true),
  );

  /// Provider and model form one route. A pair with either side missing is
  /// not a route and must never be persisted, copied, or restored as one.
  static bool isCompleteRoute(String? providerId, String? model) =>
      providerId?.trim().isNotEmpty == true && model?.trim().isNotEmpty == true;

  bool get hasCompleteRoute => isCompleteRoute(providerId, model);

  bool get isEmpty =>
      text.trim().isEmpty &&
      workspaceId == null &&
      providerId == null &&
      model == null &&
      thinkingMode == null &&
      permissionMode == null &&
      pendingRequestId == null &&
      appliedStopRecoveryIds.isEmpty &&
      pendingStopRecoveryIds.isEmpty &&
      stopRecoveryClaimIds.isEmpty &&
      stopRecoveryOwnerTokens.isEmpty;

  ConversationDraft copyWith({
    String? text,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
    String? permissionMode,
    String? pendingRequestId,
    DateTime? updatedAt,
    bool clearWorkspace = false,
    bool clearProvider = false,
    bool clearModel = false,
    bool clearThinking = false,
    bool clearPermission = false,
    bool clearPendingRequest = false,
    Set<String>? appliedStopRecoveryIds,
    Set<String>? pendingStopRecoveryIds,
    Map<String, String>? stopRecoveryClaimIds,
    Map<String, String>? stopRecoveryOwnerTokens,
  }) {
    return ConversationDraft(
      text: text ?? this.text,
      workspaceId: clearWorkspace ? null : (workspaceId ?? this.workspaceId),
      providerId: clearProvider ? null : (providerId ?? this.providerId),
      model: clearModel ? null : (model ?? this.model),
      thinkingMode: clearThinking ? null : (thinkingMode ?? this.thinkingMode),
      permissionMode: clearPermission ? null : (permissionMode ?? this.permissionMode),
      pendingRequestId: clearPendingRequest ? null : (pendingRequestId ?? this.pendingRequestId),
      appliedStopRecoveryIds: appliedStopRecoveryIds ?? this.appliedStopRecoveryIds,
      pendingStopRecoveryIds: pendingStopRecoveryIds ?? this.pendingStopRecoveryIds,
      stopRecoveryClaimIds: stopRecoveryClaimIds ?? this.stopRecoveryClaimIds,
      stopRecoveryOwnerTokens: stopRecoveryOwnerTokens ?? this.stopRecoveryOwnerTokens,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }

  @override
  List<Object?> get props => [
    text,
    workspaceId,
    providerId,
    model,
    thinkingMode,
    permissionMode,
    pendingRequestId,
    appliedStopRecoveryIds,
    pendingStopRecoveryIds,
    stopRecoveryClaimIds,
    stopRecoveryOwnerTokens,
    updatedAt,
  ];
}
