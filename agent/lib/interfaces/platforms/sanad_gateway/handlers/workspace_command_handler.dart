import 'package:sanad_agent/capabilities/permissions/command_authority.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import 'support/agent_event_envelope.dart';
import 'support/managed_command_admission.dart';

/// Handles workspace browsing, creation, removal, relocation, folder
/// mutations, and workspace security policy queries/mutations.
class WorkspaceCommandHandler {
  final LocalWorkspaceRuntimeService _runtimeService;
  final WorkspacePolicyStore? _policyStore;
  final ManagedCommandAdmission _admission;

  WorkspaceCommandHandler({
    required LocalWorkspaceRuntimeService runtimeService,
    WorkspacePolicyStore? policyStore,
    DeviceCommandAdmission? admission,
  }) : _runtimeService = runtimeService,
       _policyStore = policyStore,
       _admission = ManagedCommandAdmission(admission);

  Future<Map<String, dynamic>> buildWorkspacesEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _admission.rejectManagedRemote(event, requestId);
    if (rejected != null) return rejected;
    final workspaces = await _runtimeService.listWorkspaces();

    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.workspacesList,
        payload: {'request_id': requestId, 'workspaces': workspaces},
      ),
    );
  }

  Future<Map<String, dynamic>> buildCreateWorkspaceEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _admission.rejectManagedRemote(event, requestId);
    if (rejected != null) return rejected;
    try {
      final workspace = await _runtimeService.createWorkspace(
        name: event.payload['name'] as String? ?? '',
        path: event.payload['path'] as String?,
        description: event.payload['description'] as String?,
        managedRemote: _admission.isManagedRemote(event),
      );
      return buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceCreated,
          sessionId: event.sessionId,
          payload: {'request_id': requestId, 'workspace': workspace},
        ),
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
        requestId: requestId,
        action: 'create workspace',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildRenameWorkspaceEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _admission.rejectManagedRemote(event, requestId);
    if (rejected != null) return rejected;
    try {
      final workspace = await _runtimeService.renameWorkspace(
        workspaceId: requiredCommandString(event, 'workspace_id'),
        displayName: requiredCommandString(event, 'display_name'),
      );
      return buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceRenamed,
          payload: {'request_id': requestId, 'workspace': workspace},
        ),
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
        requestId: requestId,
        action: 'rename workspace',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildRemoveWorkspaceEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _admission.rejectManagedRemote(event, requestId);
    if (rejected != null) return rejected;
    try {
      final workspaceId = await _runtimeService.removeWorkspace(
        workspaceId: requiredCommandString(event, 'workspace_id'),
        managedRemote: _admission.isManagedRemote(event),
      );
      return buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceRemoved,
          payload: {'request_id': requestId, 'workspace_id': workspaceId},
        ),
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
        requestId: requestId,
        action: 'remove workspace',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildRelocateWorkspaceEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _admission.rejectManagedRemote(event, requestId);
    if (rejected != null) return rejected;
    try {
      final managedRemote = _admission.isManagedRemote(event);
      if (managedRemote) {
        final previewOrError = await _managedConfirmationStep(
          event: event,
          requestId: requestId,
          operation: CanonicalEventTypes.relocateWorkspace,
          previewType: CanonicalEventTypes.relocateWorkspacePreview,
          preview: () => _runtimeService.previewRelocateWorkspace(
            workspaceId: requiredCommandString(event, 'workspace_id'),
            newPath: requiredCommandString(event, 'new_path'),
          ),
        );
        if (previewOrError != null) return previewOrError;
      }
      final workspace = await _runtimeService.relocateWorkspace(
        workspaceId: requiredCommandString(event, 'workspace_id'),
        newPath: requiredCommandString(event, 'new_path'),
        managedRemote: managedRemote,
        expectedFingerprint: event.payload['confirmation_fingerprint']
            ?.toString(),
      );
      return buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceRelocated,
          payload: {'request_id': requestId, 'workspace': workspace},
        ),
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
        requestId: requestId,
        action: 'change workspace path',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildWorkspaceTreeEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _admission.rejectManagedRemote(event, requestId);
    if (rejected != null) return rejected;
    try {
      final tree = await _runtimeService.browseWorkspaceTree(
        workspaceId: event.payload['workspace_id'] as String?,
        path: event.payload['path'] as String?,
        managedRemote: _admission.isManagedRemote(event),
      );
      return buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceTree,
          payload: {'request_id': requestId, ...tree},
        ),
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
        requestId: requestId,
        action: 'browse workspace',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildCreateFolderEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _admission.rejectManagedRemote(event, requestId);
    if (rejected != null) return rejected;
    try {
      final path = await _runtimeService.createFolder(
        parentPath: requiredCommandString(event, 'parent_path'),
        name: requiredCommandString(event, 'name'),
        managedRemote: _admission.isManagedRemote(event),
      );
      return _folderMutationSuccess(
        type: CanonicalEventTypes.folderCreated,
        requestId: requestId,
        path: path,
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
        requestId: requestId,
        action: 'create folder',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildRenameFolderEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _admission.rejectManagedRemote(event, requestId);
    if (rejected != null) return rejected;
    try {
      final path = await _runtimeService.renameFolder(
        path: requiredCommandString(event, 'path'),
        newName: requiredCommandString(event, 'new_name'),
        managedRemote: _admission.isManagedRemote(event),
      );
      return _folderMutationSuccess(
        type: CanonicalEventTypes.folderRenamed,
        requestId: requestId,
        path: path,
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
        requestId: requestId,
        action: 'rename folder',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildDeleteFolderEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _admission.rejectManagedRemote(event, requestId);
    if (rejected != null) return rejected;
    try {
      final managedRemote = _admission.isManagedRemote(event);
      final path = requiredCommandString(event, 'path');
      if (managedRemote) {
        final previewOrError = await _managedConfirmationStep(
          event: event,
          requestId: requestId,
          operation: CanonicalEventTypes.deleteFolder,
          previewType: CanonicalEventTypes.deleteFolderPreview,
          preview: () =>
              _runtimeService.previewDeleteFolder(path, managedRemote: true),
        );
        if (previewOrError != null) return previewOrError;
      }
      final deletedPath = await _runtimeService.deleteFolder(
        path,
        managedRemote: managedRemote,
        expectedFingerprint: event.payload['confirmation_fingerprint']
            ?.toString(),
      );
      return _folderMutationSuccess(
        type: CanonicalEventTypes.folderDeleted,
        requestId: requestId,
        path: deletedPath,
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
        requestId: requestId,
        action: 'delete folder',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>?> _managedConfirmationStep({
    required CanonicalEvent event,
    required String? requestId,
    required String operation,
    required String previewType,
    required Future<WorkspaceMutationPreview> Function() preview,
  }) async {
    final token = event.payload['confirmation_token']?.toString().trim() ?? '';
    if (token.isEmpty) {
      final snapshot = await preview();
      final ticket = _admission.issueConfirmation(
        deviceId: _admission.envelopeDeviceId(event) ?? '',
        operation: operation,
        fingerprint: snapshot.fingerprint,
      );
      _admission.admitCorrelation(
        envelopeDeviceId: _admission.envelopeDeviceId(event),
        requestId: requestId,
      );
      return buildAgentEventEnvelope(
        CanonicalEvent(
          type: previewType,
          payload: snapshot.toPayload(
            requestId: requestId,
            confirmationToken: ticket.token,
            expiresAt: ticket.expiresAt,
          ),
        ),
      );
    }
    final consumed = _admission.consumeConfirmation(
      token: token,
      operation: operation,
      fingerprint: event.payload['confirmation_fingerprint']?.toString(),
    );
    if (consumed.allowed) {
      _admission.admitCorrelation(
        envelopeDeviceId: _admission.envelopeDeviceId(event),
        requestId: requestId,
      );
      return null;
    }
    return buildCommandMutationErrorEnvelope(
      requestId: requestId,
      action: 'confirm workspace mutation',
      error: WorkspaceCommandException(consumed.code!, consumed.message!),
    );
  }

  Map<String, dynamic> _folderMutationSuccess({
    required String type,
    required String? requestId,
    required String path,
  }) {
    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: type,
        payload: {'request_id': requestId, 'path': path},
      ),
    );
  }

  Future<Map<String, dynamic>> buildWorkspaceGetPolicyEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final authority = CommandAuthority.fromStamped(
      event.payload[CommandAuthority.payloadKey],
    );
    try {
      final workspaceId = await _policyWorkspaceId(event.payload);
      if (workspaceId == null) {
        return _policyError(
          requestId,
          'invalid_request',
          'workspace_id or a registered workspace_path is required',
        );
      }
      final policy = await _policyStore!.readPolicy(workspaceId);
      return buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceGetPolicy,
          payload: {
            'request_id': requestId,
            ...policy.toJson(),
            'workspaceId': workspaceId,
            'canWiden': authority.isOwner,
          },
        ),
      );
    } catch (e) {
      return _policyError(
        requestId,
        'policy_read_failed',
        'Failed to read workspace policy.',
      );
    }
  }

  Future<Map<String, dynamic>> buildWorkspaceSetPermissionModeEnvelope(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final payload = event.payload;
    final requestId = payload['request_id'] as String?;
    final workspaceId = (payload['workspace_id'] as String?)?.trim();
    final authority = CommandAuthority.fromStamped(
      payload[CommandAuthority.payloadKey],
    );

    WorkspacePermissionMode? permissionMode;
    ExecutionMode? executionMode;
    HostDiscoveryPolicy? hostDiscoveryPolicy;
    int? expectedRevision;
    if (payload.containsKey('permission_mode')) {
      permissionMode = WorkspacePermissionMode.tryParse(
        payload['permission_mode']?.toString(),
      );
      if (permissionMode == null) {
        return _policyError(requestId, 'invalid_request', 'Unknown permission_mode.');
      }
    }
    if (payload.containsKey('execution_mode')) {
      executionMode = ExecutionMode.tryParse(
        payload['execution_mode']?.toString(),
      );
      if (executionMode == null) {
        return _policyError(requestId, 'invalid_request', 'Unknown execution_mode.');
      }
    }
    if (payload.containsKey('host_discovery_policy')) {
      hostDiscoveryPolicy = HostDiscoveryPolicy.tryParse(
        payload['host_discovery_policy']?.toString(),
      );
      if (hostDiscoveryPolicy == null) {
        return _policyError(
          requestId,
          'invalid_request',
          'Unknown host_discovery_policy.',
        );
      }
    }
    final rawRevision = payload['expected_revision'];
    if (rawRevision != null) {
      if (rawRevision is! int || rawRevision < 0) {
        return _policyError(requestId, 'invalid_request', 'Invalid expected_revision.');
      }
      expectedRevision = rawRevision;
    }
    if (workspaceId == null ||
        workspaceId.isEmpty ||
        (permissionMode == null &&
            executionMode == null &&
            hostDiscoveryPolicy == null)) {
      return _policyError(
        requestId,
        'invalid_request',
        'workspace_id and at least one policy field are required',
      );
    }

    final WorkspacePolicy updated;
    try {
      if (!workspaceId.startsWith(WorkspacePolicyStore.execRootPrefix)) {
        final workspace = await _runtimeService.describeWorkspaceById(
          workspaceId,
        );
        if (workspace == null) {
          return _policyError(requestId, 'workspace_not_found', 'Workspace not found.');
        }
        if (workspace['is_missing'] == true) {
          return _policyError(
            requestId,
            'workspace_unavailable',
            'Workspace folder is unavailable.',
          );
        }
      }
      updated = await _policyStore!.updateModes(
        workspaceId,
        authority: authority,
        expectedRevision: expectedRevision,
        permissionMode: permissionMode,
        executionMode: executionMode,
        hostDiscoveryPolicy: hostDiscoveryPolicy,
      );
    } on WorkspacePolicyDenied catch (e) {
      return _policyError(requestId, 'permission_denied', e.toString());
    } on WorkspacePolicyConflict catch (e) {
      return _policyError(requestId, 'stale_revision', e.toString(), {
        'current_revision': e.currentRevision,
      });
    } on StateError {
      return _policyError(
        requestId,
        'workspace_unavailable',
        'Workspace or execution root is unavailable.',
      );
    } catch (_) {
      return _policyError(
        requestId,
        'policy_update_failed',
        'Failed to update workspace policy.',
      );
    }

    // The store announces the change (with its new revision) to every
    // client through WorkspacePolicyAnnouncer.

    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.workspaceSetPermissionMode,
        payload: {
          'request_id': requestId,
          ...updated.toJson(),
          'workspaceId': workspaceId,
          'canWiden': authority.isOwner,
        },
      ),
    );
  }

  /// Resolves the policy key of a query: an explicit id, the registered
  /// workspace that owns a supplied path, or that path's `exec_root:` key.
  ///
  /// This is a read: resolving a path never registers a workspace, so opening
  /// a session that carries only an execution root cannot add one. The store
  /// validates the key; an invalid root reads clean defaults.
  Future<String?> _policyWorkspaceId(Map<String, dynamic> payload) async {
    final id = (payload['workspace_id'] as String?)?.trim();
    if (id != null && id.isNotEmpty) return id;
    final path = (payload['workspace_path'] as String?)?.trim();
    if (path == null || path.isEmpty) return null;
    final workspace = await _runtimeService.describeWorkspace(path);
    final resolved = workspace?['id']?.toString();
    if (resolved != null && resolved.isNotEmpty) return resolved;
    return '${WorkspacePolicyStore.execRootPrefix}$path';
  }

  Map<String, dynamic> _policyError(
    String? requestId,
    String code,
    String message, [
    Map<String, dynamic> extra = const {},
  ]) => buildAgentEventEnvelope(
    CanonicalEvent(
      type: 'error',
      payload: {
        'request_id': requestId,
        'code': code,
        'message': message,
        ...extra,
      },
    ),
  );
}
