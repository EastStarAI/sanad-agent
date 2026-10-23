import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:sanad_agent/interfaces/models/device_control.dart';
import 'package:sanad_agent/interfaces/platforms/sanad_gateway/protocol/canonical_events.dart';
import 'package:sanad_agent/interfaces/runtime/device_command_admission.dart';
import 'package:sanad_agent/interfaces/runtime/local_workspace_runtime_service.dart';

import 'support/agent_event_envelope.dart';
import 'support/managed_command_admission.dart';

/// Handles MCP configuration CRUD, import/export, advanced JSON documents,
/// OAuth start/status/complete/cancel, and server inspection.
class McpCommandHandler {
  final LocalWorkspaceRuntimeService _runtimeService;
  final ManagedCommandAdmission _admission;
  final String _mcpFingerprintSalt = mintConfirmationToken();

  McpCommandHandler({
    required LocalWorkspaceRuntimeService runtimeService,
    DeviceCommandAdmission? admission,
  }) : _runtimeService = runtimeService,
       _admission = ManagedCommandAdmission(admission);

  Future<Map<String, dynamic>?> _admitCloudMcp({
    required CanonicalEvent event,
    required String? requestId,
    bool requireConfirmation = false,
    String? previewType,
    String? operation,
  }) async {
    if (!_admission.isCloudAdmitted(event)) return null;
    if (!_admission.isAvailable) {
      return _mcpAdmissionError(
        requestId: requestId,
        code: DeviceControlErrorCodes.invalidRequest,
        message: 'Cloud MCP admission is unavailable.',
      );
    }
    if (!requireConfirmation) {
      final decision = _admission.admitCorrelation(
        envelopeDeviceId: _admission.envelopeDeviceId(event),
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
      final ticket = _admission.issueConfirmation(
        deviceId: _admission.envelopeDeviceId(event) ?? '',
        operation: operation,
        fingerprint: fingerprint,
      );
      _admission.admitCorrelation(
        envelopeDeviceId: _admission.envelopeDeviceId(event),
        requestId: requestId,
        recordRequest: false,
      );
      return buildAgentEventEnvelope(
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
    final consumed = _admission.consumeConfirmation(
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
      envelopeDeviceId: _admission.envelopeDeviceId(event),
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
    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: 'error',
        payload: {'request_id': requestId, 'code': code, 'message': message},
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

    return buildAgentEventEnvelope(
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

      return buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.mcpServerSaved,
          payload: {'request_id': requestId, ...snapshot},
        ),
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
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

      return buildAgentEventEnvelope(
        CanonicalEvent(
          type: CanonicalEventTypes.mcpServerDeleted,
          payload: {'request_id': requestId, ...snapshot},
        ),
      );
    } catch (error) {
      return buildCommandMutationErrorEnvelope(
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
    if (_admission.isCloudAdmitted(event)) {
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

    return buildAgentEventEnvelope(
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
        _runtimeService.previewMcpImport(requiredCommandString(event, 'input')),
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
      serverName: requiredCommandString(event, 'server_name'),
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
      serverName: requiredCommandString(event, 'server_name'),
      scope: event.payload['scope'] as String? ?? 'global',
      input: requiredCommandString(event, 'input'),
      workspaceId: event.payload['workspace_id'] as String?,
    ),
  );

  Future<Map<String, dynamic>> buildSaveAdvancedMcpServerEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpAdvancedSaved,
    () => _runtimeService.saveAdvancedMcpServer(
      serverName: requiredCommandString(event, 'server_name'),
      scope: event.payload['scope'] as String? ?? 'global',
      input: requiredCommandString(event, 'input'),
      baseRevision: requiredCommandString(event, 'base_revision'),
      previewRevision: requiredCommandString(event, 'preview_revision'),
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
      serverName: requiredCommandString(event, 'server_name'),
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
        _runtimeService.mcpOAuthStatus(requiredCommandString(event, 'flow_id')),
  );

  Future<Map<String, dynamic>> buildCancelMcpOAuthEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpOAuthCancelled,
    () =>
        _runtimeService.cancelMcpOAuth(requiredCommandString(event, 'flow_id')),
  );

  Future<Map<String, dynamic>> buildCompleteMcpOAuthEnvelope(
    CanonicalEvent event,
  ) async => _mcpAdmittedResult(
    event,
    CanonicalEventTypes.mcpOAuthCompleted,
    () => _runtimeService.completeMcpOAuth(
      flowId: requiredCommandString(event, 'flow_id'),
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
      return buildCommandMutationErrorEnvelope(
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
  ) => buildAgentEventEnvelope(
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
        'error': commandErrorMessage(error),
        'tools': const [],
      };
    }

    return buildAgentEventEnvelope(
      CanonicalEvent(
        type: CanonicalEventTypes.mcpServerInspected,
        payload: {'request_id': requestId, ...inspection},
      ),
    );
  }
}
