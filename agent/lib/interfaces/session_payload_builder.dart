import 'package:sanad_agent/evolution/models/session_state.dart';

Map<String, dynamic> buildSessionPayload({
  required SessionState session,
  Map<String, dynamic>? sessionMetadata,
  Map<String, dynamic>? metadataOverrides,
  Map<String, dynamic>? thinkingControl,
  Map<String, dynamic>? thinkingCorrection,
}) {
  final persistedMetadata = sessionMetadata == null
      ? <String, dynamic>{}
      : Map<String, dynamic>.from(sessionMetadata);
  final mergedMetadata = {...persistedMetadata, ...?metadataOverrides};
  final workspace = persistedMetadata['workspace'];
  final workspaceMap = workspace is Map
      ? Map<String, dynamic>.from(workspace)
      : null;
  final workspaceId = session.workspaceId?.trim().isNotEmpty == true
      ? session.workspaceId!.trim()
      : persistedMetadata['workspace_id']?.toString();
  final workspaceName =
      workspaceMap?['name']?.toString() ??
      persistedMetadata['workspace_name']?.toString();
  final workspacePath =
      workspaceMap?['path']?.toString() ??
      persistedMetadata['workspace_path']?.toString();
  final workspaceTrustState =
      workspaceMap?['trust_state']?.toString() ??
      persistedMetadata['workspace_trust_state']?.toString();

  final provider = session.providerId?.trim().isNotEmpty == true
      ? session.providerId!.trim()
      : persistedMetadata['provider']?.toString();
  final thinkingMode = session.thinkingMode?.trim().isNotEmpty == true
      ? session.thinkingMode!.trim()
      : persistedMetadata['thinking_mode']?.toString();

  return {
    'id': session.sessionId,
    'session_id': session.sessionId,
    'title': session.title ?? 'Untitled Session',
    'created_at': session.createdAt.toIso8601String(),
    'updated_at': session.updatedAt.toIso8601String(),
    'last_user_message_at': (session.lastUserMessageAt ?? session.createdAt)
        .toIso8601String(),
    'model': session.model,
    if (persistedMetadata['model_display'] != null)
      'model_display': persistedMetadata['model_display'],
    if (provider != null && provider.isNotEmpty) ...{
      'provider_instance_id': provider,
      'model_provider': provider,
      'route_revision': session.routeRevision,
      'route_updated_at': session.routeUpdatedAt.toUtc().toIso8601String(),
    },
    if (thinkingMode != null && thinkingMode.isNotEmpty)
      'thinking_mode': thinkingMode,
    'thinking_control': ?thinkingControl,
    'thinking_correction': ?thinkingCorrection,
    if (mergedMetadata['context_tokens'] != null)
      'context_tokens': mergedMetadata['context_tokens'],
    if (mergedMetadata['context_usage'] is Map)
      'context_usage': mergedMetadata['context_usage'],
    if (workspaceId != null && workspaceId.isNotEmpty)
      'workspace_id': workspaceId,
    if (workspaceName != null && workspaceName.isNotEmpty)
      'workspace_name': workspaceName,
    if (workspacePath != null && workspacePath.isNotEmpty)
      'workspace_path': workspacePath,
    if (workspaceTrustState != null && workspaceTrustState.isNotEmpty)
      'workspace_trust_state': workspaceTrustState,
    if (mergedMetadata.isNotEmpty) 'metadata': mergedMetadata,
  };
}
