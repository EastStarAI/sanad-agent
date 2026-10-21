import 'package:sanad_agent/core/di.dart';
import 'package:sanad_agent/interfaces/models/gateway_event.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

/// Resolves session title, workspace association, and related metadata
/// from inbound gateway events and stored session configurations.
class SessionMetadataResolver {
  const SessionMetadataResolver({
    LocalWorkspaceRuntimeService? workspaceService,
  }) : _workspaceService = workspaceService;

  final LocalWorkspaceRuntimeService? _workspaceService;

  LocalWorkspaceRuntimeService get _effectiveWorkspaceService =>
      _workspaceService ?? getIt<LocalWorkspaceRuntimeService>();

  /// Resolves an initial session title and placeholder flag from the event.
  ({String title, bool isPlaceholder}) resolveInitialSessionTitle(
    GatewayEvent event,
  ) {
    final payload = event.metadata['payload'];
    final payloadMap = payload is Map<String, dynamic>
        ? payload
        : payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    final explicitTitle = payloadMap['title']?.toString().trim();
    if (explicitTitle != null && explicitTitle.isNotEmpty) {
      return (
        title: explicitTitle,
        isPlaceholder: payloadMap['title_is_placeholder'] == true,
      );
    }

    final goal = event.message.content?.trim();
    if (goal != null && goal.isNotEmpty) {
      final snippet = goal.split('\n').first;
      final title = snippet.length > 60
          ? '${snippet.substring(0, 57).trim()}...'
          : snippet;
      return (title: title, isPlaceholder: true);
    }

    return (title: 'Chat', isPlaceholder: true);
  }

  /// Extracts the workspace ID from an inbound event or fallback.
  String? resolveWorkspaceId(GatewayEvent event, {String? fallback}) {
    final directWorkspaceId = event.turnRequest?.workspaceId?.trim();
    if (directWorkspaceId != null && directWorkspaceId.isNotEmpty) {
      return directWorkspaceId;
    }

    final payload = event.metadata['payload'];
    final payloadMap = payload is Map<String, dynamic>
        ? payload
        : payload is Map
        ? Map<String, dynamic>.from(payload)
        : const <String, dynamic>{};
    final payloadWorkspaceId = payloadMap['workspace_id']?.toString().trim();
    if (payloadWorkspaceId != null && payloadWorkspaceId.isNotEmpty) {
      return payloadWorkspaceId;
    }

    final normalizedFallback = fallback?.trim();
    if (normalizedFallback == null || normalizedFallback.isEmpty) {
      return null;
    }
    return normalizedFallback;
  }

  /// Builds a workspace metadata map from the workspace runtime service.
  Future<Map<String, dynamic>> buildWorkspaceSessionMetadata(
    String? workspaceId,
  ) async {
    final normalizedWorkspaceId = workspaceId?.trim();
    if (normalizedWorkspaceId == null || normalizedWorkspaceId.isEmpty) {
      return const {};
    }

    final metadata = <String, dynamic>{'workspace_id': normalizedWorkspaceId};
    final workspace = await _effectiveWorkspaceService
        .describeWorkspace(normalizedWorkspaceId);
    if (workspace == null) {
      return metadata;
    }

    metadata['workspace'] = workspace;
    final resolvedWorkspaceId = workspace['id']?.toString();
    if (resolvedWorkspaceId != null && resolvedWorkspaceId.isNotEmpty) {
      metadata['workspace_id'] = resolvedWorkspaceId;
    }
    final workspaceName = workspace['name']?.toString();
    final workspacePath = workspace['path']?.toString();
    if (workspaceName != null && workspaceName.isNotEmpty) {
      metadata['workspace_name'] = workspaceName;
    }
    if (workspacePath != null && workspacePath.isNotEmpty) {
      metadata['workspace_path'] = workspacePath;
    }
    return metadata;
  }

  /// Extracts the workspace ID from a session metadata map.
  String? workspaceIdFromMetadata(
    Map<String, dynamic> metadata, {
    String? fallback,
  }) {
    final fromWorkspace = metadata['workspace'];
    if (fromWorkspace is Map) {
      final workspaceId = fromWorkspace['id']?.toString().trim();
      if (workspaceId != null && workspaceId.isNotEmpty) {
        return workspaceId;
      }
    }

    final topLevel = metadata['workspace_id']?.toString().trim();
    if (topLevel != null && topLevel.isNotEmpty) {
      return topLevel;
    }

    final normalizedFallback = fallback?.trim();
    if (normalizedFallback == null || normalizedFallback.isEmpty) {
      return null;
    }
    return normalizedFallback;
  }
}
