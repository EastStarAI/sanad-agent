import 'package:sanad_client/features/conversations/domain/models/conversation_draft.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_cache_snapshot.dart';
import 'package:sanad_client/features/conversations/domain/models/device_conversation_context.dart';

/// Owns draft read, write, recovery, and clear operations for sessions and New Conversation.
class ConversationDraftCache {
  final Map<String, ConversationDraft> _sessionDrafts = {};
  final DeviceConversationContext Function(String deviceId)? _getContext;
  final void Function(String deviceId, DeviceConversationContext context)? _updateContext;
  final void Function(String deviceId)? _ensureDeviceContext;
  final void Function() _notify;

  ConversationDraftCache({
    DeviceConversationContext Function(String deviceId)? getContext,
    void Function(String deviceId, DeviceConversationContext context)? updateContext,
    void Function(String deviceId)? ensureDeviceContext,
    required void Function() notify,
  })  : _getContext = getContext,
        _updateContext = updateContext,
        _ensureDeviceContext = ensureDeviceContext,
        _notify = notify;

  Map<String, ConversationDraft> get sessionDrafts => Map.unmodifiable(_sessionDrafts);

  void restoreFrom(Map<String, ConversationDraft> drafts) {
    _sessionDrafts
      ..clear()
      ..addAll(drafts);
  }

  ConversationDraft? sessionDraft(String deviceId, String sessionId) =>
      _sessionDrafts[DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId)];

  void setSessionDraft(String deviceId, String sessionId, ConversationDraft draft) {
    _sessionDrafts[DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId)] = draft;
    _notify();
  }

  void markSessionDraftAwaitingAcceptance(
    String deviceId,
    String sessionId,
    String requestId,
  ) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(
      deviceId,
      sessionId,
    );
    final draft = _sessionDrafts[key];
    if (draft == null) return;
    _sessionDrafts[key] = draft.copyWith(pendingRequestId: requestId);
    _notify();
  }

  void clearSessionDraft(String deviceId, String sessionId) {
    if (_sessionDrafts.remove(DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId)) != null) {
      _notify();
    }
  }

  void removeSessionDraft(String deviceId, String sessionId) {
    _sessionDrafts.remove(DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId));
  }

  bool clearMatchingPendingDraft(
    String deviceId,
    String sessionId,
    String? requestId,
  ) {
    if (requestId == null) return false;
    final draftKey = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final draft = _sessionDrafts[draftKey];
    if (draft?.pendingRequestId == requestId) {
      _sessionDrafts.remove(draftKey);
      return true;
    }
    final ctx = _getContext?.call(deviceId);
    if (ctx != null && ctx.newConversationDraftPendingRequestId == requestId) {
      _updateContext?.call(deviceId, ctx.copyWith(clearNewConversationDraft: true));
      return true;
    }
    return false;
  }

  bool prependStopRecovery(
    String deviceId,
    String sessionId, {
    required String stopRequestId,
    required Iterable<String> texts,
  }) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key] ?? ConversationDraft.empty();
    if (current.appliedStopRecoveryIds.contains(stopRequestId)) return false;
    final recovered = texts.map((text) => text.trim()).where((text) => text.isNotEmpty).join('\n');
    final nextText = [recovered, current.text].where((text) => text.isNotEmpty).join('\n');
    _sessionDrafts[key] = current.copyWith(
      text: nextText,
      appliedStopRecoveryIds: {...current.appliedStopRecoveryIds, stopRequestId},
      pendingStopRecoveryIds: {...current.pendingStopRecoveryIds}..remove(stopRequestId),
      updatedAt: DateTime.now().toUtc(),
    );
    _notify();
    return true;
  }

  void markStopRecoveryPending(
    String deviceId,
    String sessionId,
    String stopRequestId, {
    String? ownerToken,
  }) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key] ?? ConversationDraft.empty();
    _sessionDrafts[key] = current.copyWith(
      pendingStopRecoveryIds: {...current.pendingStopRecoveryIds, stopRequestId},
      stopRecoveryOwnerTokens: ownerToken == null
          ? current.stopRecoveryOwnerTokens
          : {...current.stopRecoveryOwnerTokens, stopRequestId: ownerToken},
      updatedAt: DateTime.now().toUtc(),
    );
    _notify();
  }

  void unmarkStopRecoveryPending(String deviceId, String sessionId, String stopRequestId) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key];
    if (current == null || !current.pendingStopRecoveryIds.contains(stopRequestId)) return;
    _sessionDrafts[key] = current.copyWith(
      pendingStopRecoveryIds: {...current.pendingStopRecoveryIds}..remove(stopRequestId),
      stopRecoveryOwnerTokens: {...current.stopRecoveryOwnerTokens}..remove(stopRequestId),
      updatedAt: DateTime.now().toUtc(),
    );
    _notify();
  }

  void clearStopRecoveryOwnerToken(
    String deviceId,
    String sessionId,
    String stopRequestId,
  ) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key];
    if (current == null || !current.stopRecoveryOwnerTokens.containsKey(stopRequestId)) return;
    _sessionDrafts[key] = current.copyWith(
      stopRecoveryOwnerTokens: {...current.stopRecoveryOwnerTokens}..remove(stopRequestId),
      updatedAt: DateTime.now().toUtc(),
    );
    _notify();
  }

  void setStopRecoveryClaim(
    String deviceId,
    String sessionId,
    String stopRequestId,
    String claimId,
  ) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key] ?? ConversationDraft.empty();
    _sessionDrafts[key] = current.copyWith(
      stopRecoveryClaimIds: {...current.stopRecoveryClaimIds, stopRequestId: claimId},
      updatedAt: DateTime.now().toUtc(),
    );
    _notify();
  }

  void clearStopRecoveryClaim(String deviceId, String sessionId, String stopRequestId) {
    final key = DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId);
    final current = _sessionDrafts[key];
    if (current == null || !current.stopRecoveryClaimIds.containsKey(stopRequestId)) return;
    _sessionDrafts[key] = current.copyWith(
      stopRecoveryClaimIds: {...current.stopRecoveryClaimIds}..remove(stopRequestId),
      updatedAt: DateTime.now().toUtc(),
    );
    _notify();
  }

  /// Move a New Conversation draft binding to a newly created session identity.
  /// Called once the daemon confirms session creation, before clearing the new
  /// draft after canonical acceptance.
  void transferNewConversationDraftToSession(
    String deviceId,
    String sessionId,
  ) {
    final ctx = _getContext?.call(deviceId) ?? DeviceConversationContext.empty();
    final draft = ConversationDraft(
      text: ctx.newConversationDraftText,
      workspaceId: ctx.newConversationDraftWorkspaceId,
      providerId: ctx.newConversationDraftProviderId,
      model: ctx.newConversationDraftModel,
      thinkingMode: ctx.newConversationDraftThinkingMode,
      permissionMode: ctx.newConversationDraftPermissionMode,
      pendingRequestId: ctx.newConversationDraftPendingRequestId,
      updatedAt: ctx.newConversationDraftUpdatedAt,
    );
    if (!draft.isEmpty) {
      _sessionDrafts[DeviceConversationCacheSnapshot.sessionDraftKey(deviceId, sessionId)] = draft;
    }
    _updateContext?.call(deviceId, ctx.copyWith(clearNewConversationDraft: true));
    _notify();
  }

  void setNewConversationDraft(
    String deviceId, {
    String? text,
    String? workspaceId,
    String? providerId,
    String? model,
    String? thinkingMode,
    String? permissionMode,
    bool clearWorkspace = false,
    bool clearProvider = false,
    bool clearModel = false,
    bool clearThinkingMode = false,
    bool clearPermissionMode = false,
    bool clearPendingRequest = false,
  }) {
    _ensureDeviceContext?.call(deviceId);
    final ctx = _getContext?.call(deviceId) ?? DeviceConversationContext.empty();
    _updateContext?.call(
      deviceId,
      ctx.copyWith(
        newConversationDraftText: text,
        newConversationDraftWorkspaceId: workspaceId,
        newConversationDraftProviderId: providerId,
        newConversationDraftModel: model,
        newConversationDraftThinkingMode: thinkingMode,
        newConversationDraftPermissionMode: permissionMode,
        newConversationDraftUpdatedAt: DateTime.now().toUtc(),
        clearNewConversationDraftWorkspace: clearWorkspace,
        clearNewConversationDraftProvider: clearProvider,
        clearNewConversationDraftModel: clearModel,
        clearNewConversationDraftThinkingMode: clearThinkingMode,
        clearNewConversationDraftPermissionMode: clearPermissionMode,
        clearNewConversationDraftPendingRequest: clearPendingRequest,
      ),
    );
    _notify();
  }

  void markNewConversationDraftAwaitingAcceptance(
    String deviceId,
    String requestId,
  ) {
    _ensureDeviceContext?.call(deviceId);
    final context = _getContext?.call(deviceId) ?? DeviceConversationContext.empty();
    _updateContext?.call(
      deviceId,
      context.copyWith(
        newConversationDraftPendingRequestId: requestId,
      ),
    );
    _notify();
  }

  void clearNewConversationDraft(String deviceId) {
    _ensureDeviceContext?.call(deviceId);
    final ctx = _getContext?.call(deviceId) ?? DeviceConversationContext.empty();
    if (ctx.newConversationDraftText.isEmpty &&
        ctx.newConversationDraftWorkspaceId == null &&
        ctx.newConversationDraftProviderId == null &&
        ctx.newConversationDraftModel == null &&
        ctx.newConversationDraftThinkingMode == null &&
        ctx.newConversationDraftPermissionMode == null &&
        ctx.newConversationDraftPendingRequestId == null) {
      return;
    }
    _updateContext?.call(deviceId, ctx.copyWith(clearNewConversationDraft: true));
    _notify();
  }

  void clearDevice(String deviceId) {
    _sessionDrafts.removeWhere((key, _) => key.startsWith('$deviceId|'));
  }
}
