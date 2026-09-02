import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy.dart';
import 'package:sanad_agent/capabilities/permissions/workspace_policy_store.dart';
import 'package:sanad_agent/core/provider_runtime/env_file_service.dart';
import 'package:sanad_agent/core/secrets_redactor.dart';
import 'package:sanad_agent/infrastructure/platform/automation_service_factory.dart';
import 'package:sanad_agent/interfaces/models/delivery/models.dart';
import 'package:sanad_agent/interfaces/models/device_control.dart';
import 'package:sanad_agent/interfaces/models/workspace_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import '../sanad_protocol_bridge.dart';

/// Handles workspace browsing, creation, MCP server management, slash-command
/// discovery, computer-use toggles, and workspace policy queries/mutations.
class WorkspaceCommandHandler {
  final LocalWorkspaceRuntimeService _runtimeService;
  final EnvFileService? _envFileService;
  final WorkspacePolicyStore? _policyStore;
  final SanadProtocolBridge _bridge;
  final DeviceCommandAdmission? _admission;
  final String _mcpFingerprintSalt = mintConfirmationToken();

  WorkspaceCommandHandler({
    required LocalWorkspaceRuntimeService runtimeService,
    EnvFileService? envFileService,
    WorkspacePolicyStore? policyStore,
    required SanadProtocolBridge bridge,
    DeviceCommandAdmission? admission,
  }) : _runtimeService = runtimeService,
       _envFileService = envFileService,
       _policyStore = policyStore,
       _bridge = bridge,
       _admission = admission;

  Future<Map<String, dynamic>> buildWorkspacesEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final rejected = _rejectManagedAdmission(event, requestId);
    if (rejected != null) return rejected;
    final workspaces = await _runtimeService.listWorkspaces();

    return _bridge.buildAgentEventEnvelope(
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
    final rejected = _rejectManagedAdmission(event, requestId);
    if (rejected != null) return rejected;
    try {
      final workspace = await _runtimeService.createWorkspace(
        name: event.payload['name'] as String? ?? '',
        path: event.payload['path'] as String?,
        description: event.payload['description'] as String?,
        managedRemote: _isManagedRemote(event),
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceCreated,
          sessionId: event.sessionId,
          payload: {'request_id': requestId, 'workspace': workspace},
        ),
      );
    } catch (error) {
      return _mutationError(
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
    final rejected = _rejectManagedAdmission(event, requestId);
    if (rejected != null) return rejected;
    try {
      final workspace = await _runtimeService.renameWorkspace(
        workspaceId: _requiredString(event, 'workspace_id'),
        displayName: _requiredString(event, 'display_name'),
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceRenamed,
          payload: {'request_id': requestId, 'workspace': workspace},
        ),
      );
    } catch (error) {
      return _mutationError(
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
    final rejected = _rejectManagedAdmission(event, requestId);
    if (rejected != null) return rejected;
    try {
      final workspaceId = await _runtimeService.removeWorkspace(
        workspaceId: _requiredString(event, 'workspace_id'),
        managedRemote: _isManagedRemote(event),
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceRemoved,
          payload: {'request_id': requestId, 'workspace_id': workspaceId},
        ),
      );
    } catch (error) {
      return _mutationError(
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
    final rejected = _rejectManagedAdmission(event, requestId);
    if (rejected != null) return rejected;
    try {
      final managedRemote = _isManagedRemote(event);
      if (managedRemote) {
        final previewOrError = await _managedConfirmationStep(
          event: event,
          requestId: requestId,
          operation: CanonicalEventTypes.relocateWorkspace,
          previewType: CanonicalEventTypes.relocateWorkspacePreview,
          preview: () => _runtimeService.previewRelocateWorkspace(
            workspaceId: _requiredString(event, 'workspace_id'),
            newPath: _requiredString(event, 'new_path'),
          ),
        );
        if (previewOrError != null) return previewOrError;
      }
      final workspace = await _runtimeService.relocateWorkspace(
        workspaceId: _requiredString(event, 'workspace_id'),
        newPath: _requiredString(event, 'new_path'),
        managedRemote: managedRemote,
        expectedFingerprint: event.payload['confirmation_fingerprint']
            ?.toString(),
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceRelocated,
          payload: {'request_id': requestId, 'workspace': workspace},
        ),
      );
    } catch (error) {
      return _mutationError(
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
    final rejected = _rejectManagedAdmission(event, requestId);
    if (rejected != null) return rejected;
    try {
      final tree = await _runtimeService.browseWorkspaceTree(
        workspaceId: event.payload['workspace_id'] as String?,
        path: event.payload['path'] as String?,
        managedRemote: _isManagedRemote(event),
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceTree,
          payload: {'request_id': requestId, ...tree},
        ),
      );
    } catch (error) {
      return _mutationError(
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
    final rejected = _rejectManagedAdmission(event, requestId);
    if (rejected != null) return rejected;
    try {
      final path = await _runtimeService.createFolder(
        parentPath: _requiredString(event, 'parent_path'),
        name: _requiredString(event, 'name'),
        managedRemote: _isManagedRemote(event),
      );
      return _folderMutationSuccess(
        type: CanonicalEventTypes.folderCreated,
        requestId: requestId,
        path: path,
      );
    } catch (error) {
      return _mutationError(
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
    final rejected = _rejectManagedAdmission(event, requestId);
    if (rejected != null) return rejected;
    try {
      final path = await _runtimeService.renameFolder(
        path: _requiredString(event, 'path'),
        newName: _requiredString(event, 'new_name'),
        managedRemote: _isManagedRemote(event),
      );
      return _folderMutationSuccess(
        type: CanonicalEventTypes.folderRenamed,
        requestId: requestId,
        path: path,
      );
    } catch (error) {
      return _mutationError(
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
    final rejected = _rejectManagedAdmission(event, requestId);
    if (rejected != null) return rejected;
    try {
      final managedRemote = _isManagedRemote(event);
      final path = _requiredString(event, 'path');
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
      return _mutationError(
        requestId: requestId,
        action: 'delete folder',
        error: error,
      );
    }
  }

  bool _isManagedRemote(CanonicalEvent event) =>
      event.payload['managed_remote'] == true;

  bool _isCloudAdmittedMcp(CanonicalEvent event) =>
      event.payload['cloud_admitted'] == true;

  String? _envelopeDeviceId(CanonicalEvent event) {
    final value = event.payload['device_id']?.toString().trim();
    return value == null || value.isEmpty ? null : value;
  }

  Map<String, dynamic>? _rejectManagedAdmission(
    CanonicalEvent event,
    String? requestId,
  ) {
    if (!_isManagedRemote(event)) {
      return null;
    }
    if (_admission == null) {
      return _mutationError(
        requestId: requestId,
        action: 'admit workspace command',
        error: const WorkspaceCommandException(
          WorkspaceCommandErrorCodes.invalidRequest,
          'Managed remote workspace admission is unavailable.',
        ),
      );
    }
    final decision = _admission.admitCorrelation(
      envelopeDeviceId: _envelopeDeviceId(event),
      requestId: requestId,
      recordRequest:
          event.type != CanonicalEventTypes.deleteFolder &&
          event.type != CanonicalEventTypes.relocateWorkspace,
    );
    if (decision.allowed) return null;
    return _mutationError(
      requestId: requestId,
      action: 'admit workspace command',
      error: WorkspaceCommandException(decision.code!, decision.message!),
    );
  }

  Future<Map<String, dynamic>?> _admitCloudMcp({
    required CanonicalEvent event,
    required String? requestId,
    bool requireConfirmation = false,
    String? previewType,
    String? operation,
  }) async {
    if (!_isCloudAdmittedMcp(event)) return null;
    if (_admission == null) {
      return _mcpAdmissionError(
        requestId: requestId,
        code: DeviceControlErrorCodes.invalidRequest,
        message: 'Cloud MCP admission is unavailable.',
      );
    }
    if (!requireConfirmation) {
      final decision = _admission.admitCorrelation(
        envelopeDeviceId: _envelopeDeviceId(event),
        requestId: requestId,
      );
      if (decision.allowed) return null;
      return _mcpAdmissionError(
        requestId: requestId,
        code: decision.code!,
        message: decision.message!,
      );
    }
    return _mcpConfirmationStep(
      event: event,
      requestId: requestId,
      operation: operation ?? event.type,
      previewType: previewType ?? event.type,
    );
  }

  Future<Map<String, dynamic>?> _mcpConfirmationStep({
    required CanonicalEvent event,
    required String? requestId,
    required String operation,
    required String previewType,
  }) async {
    final fingerprint = await _runtimeService.mcpMutationFingerprint(
      operation: operation,
      scope: event.payload['scope'] as String? ?? 'global',
      workspaceId: event.payload['workspace_id'] as String?,
      serverName:
          event.payload['server_name'] as String? ??
          (event.payload['config'] is Map
              ? (event.payload['config'] as Map)['name']?.toString()
              : null),
      intent: _mcpIntent(event),
    );
    final token = event.payload['confirmation_token']?.toString().trim() ?? '';
    if (token.isEmpty) {
      final ticket = _admission!.issueConfirmation(
        deviceId: _envelopeDeviceId(event) ?? '',
        operation: operation,
        fingerprint: fingerprint,
      );
      _admission.admitCorrelation(
        envelopeDeviceId: _envelopeDeviceId(event),
        requestId: requestId,
        recordRequest: false,
      );
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: previewType,
          payload: {
            'request_id': requestId,
            'confirmation_token': ticket.token,
            'confirmation_fingerprint': ticket.fingerprint,
            'expires_at': ticket.expiresAt.toUtc().toIso8601String(),
            'operation': operation,
          },
        ),
      );
    }
    final consumed = _admission!.consumeConfirmation(
      token: token,
      operation: operation,
      fingerprint: fingerprint,
    );
    if (!consumed.allowed) {
      return _mcpAdmissionError(
        requestId: requestId,
        code: consumed.code!,
        message: consumed.message!,
      );
    }
    final correlation = _admission.admitCorrelation(
      envelopeDeviceId: _envelopeDeviceId(event),
      requestId: requestId,
    );
    if (correlation.allowed) return null;
    return _mcpAdmissionError(
      requestId: requestId,
      code: correlation.code!,
      message: correlation.message!,
    );
  }

  Map<String, dynamic> _mcpIntent(CanonicalEvent event) {
    final config = event.payload['config'];
    final secrets = event.payload['secrets'];
    return {
      if (event.payload['server_name'] != null)
        'server_name': event.payload['server_name']?.toString(),
      if (event.payload['scope'] != null)
        'scope': event.payload['scope']?.toString(),
      if (config is Map)
        'config': _redactedMcpConfig(Map<String, dynamic>.from(config)),
      if (secrets is Map && secrets.isNotEmpty)
        'secret_intent_digest': sha256
            .convert(utf8.encode('$_mcpFingerprintSalt:${jsonEncode(secrets)}'))
            .toString(),
      if (event.payload['input'] is String)
        'input_length': (event.payload['input'] as String).length,
      if (event.payload['flow_id'] != null)
        'flow_id': event.payload['flow_id']?.toString(),
    };
  }

  Map<String, dynamic> _redactedMcpConfig(Map<String, dynamic> config) {
    final copy = Map<String, dynamic>.from(config);
    copy.remove('secrets');
    copy.remove('_secretMutations');
    copy.remove('bearerToken');
    copy.remove('bearer_token');
    return copy;
  }

  bool _mcpInspectNeedsConfirmation(CanonicalEvent event) {
    final config = event.payload['config'];
    if (config is Map) {
      final command = config['command']?.toString().trim() ?? '';
      final transport = config['transport']?.toString().toLowerCase() ?? '';
      return command.isNotEmpty || transport == 'stdio';
    }
    return true;
  }

  Map<String, dynamic> _mcpAdmissionError({
    required String? requestId,
    required String code,
    required String message,
  }) {
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: 'error',
        payload: {'request_id': requestId, 'code': code, 'message': message},
      ),
    );
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
      final ticket = _admission!.issueConfirmation(
        deviceId: _envelopeDeviceId(event) ?? '',
        operation: operation,
        fingerprint: snapshot.fingerprint,
      );
      _admission.admitCorrelation(
        envelopeDeviceId: _envelopeDeviceId(event),
        requestId: requestId,
      );
      return _bridge.buildAgentEventEnvelope(
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
    final consumed = _admission!.consumeConfirmation(
      token: token,
      operation: operation,
      fingerprint: event.payload['confirmation_fingerprint']?.toString(),
    );
    if (consumed.allowed) {
      _admission.admitCorrelation(
        envelopeDeviceId: _envelopeDeviceId(event),
        requestId: requestId,
      );
      return null;
    }
    return _mutationError(
      requestId: requestId,
      action: 'confirm workspace mutation',
      error: WorkspaceCommandException(consumed.code!, consumed.message!),
    );
  }

  String _requiredString(CanonicalEvent event, String key) {
    final value = event.payload[key];
    if (value is! String || value.trim().isEmpty) {
      throw FormatException('$key is required.');
    }
    return value.trim();
  }

  Map<String, dynamic> _mutationError({
    required String? requestId,
    required String action,
    required Object error,
  }) {
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: 'error',
        payload: {
          'request_id': requestId,
          if (error is WorkspaceCommandException) 'code': error.code,
          'message': 'Failed to $action: ${_errorMessage(error)}',
        },
      ),
    );
  }

  String _errorMessage(Object error) {
    final raw = switch (error) {
      WorkspaceCommandException() => error.message,
      StateError() => error.message,
      FormatException() => error.message,
      FileSystemException() => error.message,
      _ => error.toString(),
    };
    return const SecretsRedactor().redact(raw);
  }

  Map<String, dynamic> _folderMutationSuccess({
    required String type,
    required String? requestId,
    required String path,
  }) {
    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: type,
        payload: {'request_id': requestId, 'path': path},
      ),
    );
  }

  Future<Map<String, dynamic>> buildMcpServersEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final admitted = await _admitCloudMcp(event: event, requestId: requestId);
    if (admitted != null) return admitted;
    final workspaceId = event.payload['workspace_id'] as String?;
    final snapshot = await _runtimeService.readMcpSnapshot(
      workspaceId: workspaceId,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.mcpServersList,
        payload: {
          'request_id': requestId,
          'workspace_id': workspaceId,
          ...snapshot,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildSaveMcpServerEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final admitted = await _admitCloudMcp(
      event: event,
      requestId: requestId,
      requireConfirmation: true,
      previewType: CanonicalEventTypes.mcpServerSavePreview,
      operation: CanonicalEventTypes.saveMcpServer,
    );
    if (admitted != null) return admitted;
    final workspaceId = event.payload['workspace_id'] as String?;
    final scope = event.payload['scope'] as String? ?? 'global';
    final config = Map<String, dynamic>.from(
      event.payload['config'] as Map? ?? const {},
    );
    try {
      final snapshot = await _runtimeService.saveMcpServer(
        scope: scope,
        workspaceId: workspaceId,
        config: {
          ...config,
          '_secretMutations': Map<String, dynamic>.from(
            event.payload['secrets'] as Map? ?? const {},
          ),
        },
      );

      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.mcpServerSaved,
          payload: {'request_id': requestId, ...snapshot},
        ),
      );
    } catch (error) {
      return _mutationError(
        requestId: requestId,
        action: 'save MCP server',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildDeleteMcpServerEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final admitted = await _admitCloudMcp(
      event: event,
      requestId: requestId,
      requireConfirmation: true,
      previewType: CanonicalEventTypes.mcpServerDeletePreview,
      operation: CanonicalEventTypes.deleteMcpServer,
    );
    if (admitted != null) return admitted;
    final workspaceId = event.payload['workspace_id'] as String?;
    final scope = event.payload['scope'] as String? ?? 'global';
    final serverName = event.payload['server_name'] as String? ?? '';
    try {
      final snapshot = await _runtimeService.deleteMcpServer(
        scope: scope,
        workspaceId: workspaceId,
        serverName: serverName,
      );

      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.mcpServerDeleted,
          payload: {'request_id': requestId, ...snapshot},
        ),
      );
    } catch (error) {
      return _mutationError(
        requestId: requestId,
        action: 'delete MCP server',
        error: error,
      );
    }
  }

  Future<Map<String, dynamic>> buildReplaceMcpConfigEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    if (_isCloudAdmittedMcp(event)) {
      return _mcpAdmissionError(
        requestId: requestId,
        code: 'remote_mcp_management_disabled',
        message: 'Remote MCP management is disabled for security reasons.',
      );
    }
    final workspaceId = event.payload['workspace_id'] as String?;
    final scope = event.payload['scope'] as String? ?? 'global';
    final document = Map<String, dynamic>.from(
      event.payload['document'] as Map? ?? const {},
    );
    final snapshot = await _runtimeService.replaceMcpConfig(
      scope: scope,
      workspaceId: workspaceId,
      document: document,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.mcpConfigReplaced,
        payload: {'request_id': requestId, ...snapshot},
      ),
    );
  }

  Future<Map<String, dynamic>> buildPreviewMcpImportEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpImportPreviewed,
    () async =>
        _runtimeService.previewMcpImport(_requiredString(event, 'input')),
  );

  Future<Map<String, dynamic>> buildExportMcpServersEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpServersExported,
    () => _runtimeService.exportMcpServers(
      serverNames: (event.payload['server_names'] as List? ?? const [])
          .map((item) => item.toString())
          .toList(growable: false),
      scope: event.payload['scope'] as String? ?? 'effective',
      workspaceId: event.payload['workspace_id'] as String?,
    ),
  );

  Future<Map<String, dynamic>> buildReadAdvancedMcpServerEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpAdvancedRead,
    () => _runtimeService.readAdvancedMcpServer(
      serverName: _requiredString(event, 'server_name'),
      scope: event.payload['scope'] as String? ?? 'global',
      workspaceId: event.payload['workspace_id'] as String?,
    ),
  );

  Future<Map<String, dynamic>> buildPreviewAdvancedMcpServerEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpAdvancedPreviewed,
    () => _runtimeService.previewAdvancedMcpServer(
      serverName: _requiredString(event, 'server_name'),
      scope: event.payload['scope'] as String? ?? 'global',
      input: _requiredString(event, 'input'),
      workspaceId: event.payload['workspace_id'] as String?,
    ),
  );

  Future<Map<String, dynamic>> buildSaveAdvancedMcpServerEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpAdvancedSaved,
    () => _runtimeService.saveAdvancedMcpServer(
      serverName: _requiredString(event, 'server_name'),
      scope: event.payload['scope'] as String? ?? 'global',
      input: _requiredString(event, 'input'),
      baseRevision: _requiredString(event, 'base_revision'),
      previewRevision: _requiredString(event, 'preview_revision'),
      workspaceId: event.payload['workspace_id'] as String?,
    ),
    requireConfirmation: true,
    previewType: CanonicalEventTypes.mcpServerSavePreview,
    operation: CanonicalEventTypes.saveAdvancedMcpServer,
  );

  Future<Map<String, dynamic>> buildStartMcpOAuthEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpOAuthStarted,
    () => _runtimeService.startMcpOAuth(
      serverName: _requiredString(event, 'server_name'),
      draftConfig: Map<String, dynamic>.from(
        event.payload['config'] as Map? ?? const {},
      ),
      secretMutations: Map<String, dynamic>.from(
        event.payload['secrets'] as Map? ?? const {},
      ),
    ),
  );

  Future<Map<String, dynamic>> buildMcpOAuthStatusEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpOAuthStatus,
    () async =>
        _runtimeService.mcpOAuthStatus(_requiredString(event, 'flow_id')),
  );

  Future<Map<String, dynamic>> buildCancelMcpOAuthEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpOAuthCancelled,
    () => _runtimeService.cancelMcpOAuth(_requiredString(event, 'flow_id')),
  );

  Future<Map<String, dynamic>> buildCompleteMcpOAuthEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpOAuthCompleted,
    () => _runtimeService.completeMcpOAuth(
      flowId: _requiredString(event, 'flow_id'),
      scope: event.payload['scope'] as String? ?? 'global',
      workspaceId: event.payload['workspace_id'] as String?,
      config: Map<String, dynamic>.from(
        event.payload['config'] as Map? ?? const {},
      ),
    ),
    requireConfirmation: true,
    previewType: CanonicalEventTypes.mcpOAuthCompletePreview,
    operation: CanonicalEventTypes.completeMcpOAuth,
  );

  Future<Map<String, dynamic>> _mcpAdmittedResult(
    CanonicalEvent event,
    String type,
    Future<Map<String, dynamic>> Function() result, {
    bool requireConfirmation = false,
    String? previewType,
    String? operation,
  }) async {
    final admitted = await _admitCloudMcp(
      event: event,
      requestId: event.payload['request_id'] as String?,
      requireConfirmation: requireConfirmation,
      previewType: previewType,
      operation: operation,
    );
    if (admitted != null) return admitted;
    try {
      return _mcpResultEnvelope(event, type, await result());
    } catch (error) {
      return _mutationError(
        requestId: event.payload['request_id'] as String?,
        action: 'run MCP command',
        error: error,
      );
    }
  }

  Map<String, dynamic> _mcpResultEnvelope(
    CanonicalEvent event,
    String type,
    Map<String, dynamic> result,
  ) => _bridge.buildAgentEventEnvelope(
    CanonicalEvent(
      type: type,
      payload: {
        'request_id': event.payload['request_id'] as String?,
        ...result,
      },
    ),
  );

  Future<Map<String, dynamic>> buildInspectMcpServerEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final admitted = await _admitCloudMcp(
      event: event,
      requestId: requestId,
      requireConfirmation: _mcpInspectNeedsConfirmation(event),
      previewType: CanonicalEventTypes.mcpServerInspectPreview,
      operation: CanonicalEventTypes.inspectMcpServer,
    );
    if (admitted != null) return admitted;
    final workspaceId = event.payload['workspace_id'] as String?;
    final scope = event.payload['scope'] as String? ?? 'effective';
    final serverName = event.payload['server_name'] as String? ?? '';
    Map<String, dynamic> inspection;
    try {
      inspection = event.payload['config'] is Map
          ? await _runtimeService.inspectMcpDraft(
              serverName: serverName,
              scope: scope,
              workspaceId: workspaceId,
              draftConfig: Map<String, dynamic>.from(
                event.payload['config'] as Map,
              ),
              secretMutations: Map<String, dynamic>.from(
                event.payload['secrets'] as Map? ?? const {},
              ),
            )
          : await _runtimeService.inspectMcpServer(
              serverName: serverName,
              scope: scope,
              workspaceId: workspaceId,
            );
    } catch (error) {
      inspection = {
        'name': serverName,
        'scope': scope,
        'workspace_id': workspaceId,
        'success': false,
        'error': _errorMessage(error),
        'tools': const [],
      };
    }

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.mcpServerInspected,
        payload: {'request_id': requestId, ...inspection},
      ),
    );
  }

  Future<Map<String, dynamic>> buildSlashCommandsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final query = event.payload['query'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final commands = await _runtimeService.searchSlashCommands(
      query: query,
      workspaceId: workspaceId,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.slashCommandsList,
        payload: {
          'request_id': requestId,
          'query': query,
          'workspace_id': workspaceId,
          'commands': commands,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildSkillsEnvelope(CanonicalEvent event) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final includeShadowed =
        event.payload['include_shadowed'] as bool? ?? workspaceId != null;
    final inventory = await _runtimeService.listSkills(
      workspaceId: workspaceId,
      includeShadowed: includeShadowed,
    );

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.skillsList,
        payload: {
          'request_id': requestId,
          'workspace_id': workspaceId,
          ...inventory,
        },
      ),
    );
  }

  Future<Map<String, dynamic>> buildCheckComputerUsePermissionsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final service = AutomationServiceFactory.instance;
    final granted = await service.checkPermissions();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.systemCheckComputerUsePermissionsResult,
        payload: {'request_id': requestId, 'granted': granted},
      ),
    );
  }

  Future<Map<String, dynamic>> buildRequestComputerUsePermissionsEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final service = AutomationServiceFactory.instance;
    final granted = await service.requestPermissions();

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.systemRequestComputerUsePermissionsResult,
        payload: {'request_id': requestId, 'granted': granted},
      ),
    );
  }

  Future<Map<String, dynamic>> buildToggleComputerUseEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final value = event.payload['enabled'] as bool? ?? false;

    await _envFileService?.upsert({'COMPUTER_USE': value.toString()});

    return _bridge.buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.systemToggleComputerUseResult,
        payload: {'request_id': requestId, 'enabled': value, 'saved': true},
      ),
    );
  }

  Future<Map<String, dynamic>> buildWorkspaceGetPolicyEnvelope(
    CanonicalEvent event,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspacePath = event.payload['workspace_path'] as String?;

    if (workspacePath == null || workspacePath.isEmpty) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'workspace_path is required',
          },
        ),
      );
    }

    try {
      final policy = await _policyStore!.readPolicy(workspacePath);
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceGetPolicy,
          payload: {'request_id': requestId, ...policy.toJson()},
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'Failed to read workspace policy: $e',
          },
        ),
      );
    }
  }

  Future<Map<String, dynamic>> buildWorkspaceSetPermissionModeEnvelope(
    CanonicalEvent event,
    Future<void> Function(Map<String, dynamic> envelope) emitEnvelope,
  ) async {
    final requestId = event.payload['request_id'] as String?;
    final workspaceId = event.payload['workspace_id'] as String?;
    final permissionModeString = event.payload['permission_mode'] as String?;

    if (workspaceId == null ||
        workspaceId.isEmpty ||
        permissionModeString == null) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'workspace_id and permission_mode are required',
          },
        ),
      );
    }

    final mode = WorkspacePermissionMode.fromValue(permissionModeString);
    try {
      final workspace = await _runtimeService.describeWorkspaceById(
        workspaceId,
      );
      if (workspace == null) {
        throw StateError('Workspace not found.');
      }
      if (workspace['is_missing'] == true) {
        throw StateError('Workspace folder is unavailable.');
      }
      final workspacePath = workspace['path'] as String;
      final current = await _policyStore!.readPolicy(workspacePath);
      final updated = current.copyWith(permissionMode: mode);
      await _policyStore.savePolicy(workspacePath, updated);

      final broadcastEvent = CanonicalEvent(
        type: CanonicalEventTypes.workspacePolicyChanged,
        payload: {'workspace_id': workspaceId, 'policy': updated.toJson()},
        delivery: const DeliveryPolicy.platformFamily(
          PlatformFamily.sanadClient,
        ),
      );
      await emitEnvelope(_bridge.buildAgentEventEnvelope(broadcastEvent));

      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.workspaceSetPermissionMode,
          payload: {'request_id': requestId, ...updated.toJson()},
        ),
      );
    } catch (e) {
      return _bridge.buildAgentEventEnvelope(
        CanonicalEvent(
          type: 'error',
          payload: {
            'request_id': requestId,
            'message': 'Failed to update workspace policy: $e',
          },
        ),
      );
    }
  }
}
